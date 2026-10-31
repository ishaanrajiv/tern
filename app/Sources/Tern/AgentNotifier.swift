import AppKit
import UserNotifications

/// Whether macOS lets tern post notifications. It asks only while macOS hasn't decided: a prompt
/// that goes unanswered is recorded as denied, and macOS never asks again, so Settings offers the
/// way to System Settings instead.
@Observable
final class NotificationPermission {
    static let shared = NotificationPermission()
    private(set) var authorized = false
    private(set) var denied = false
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var observer: Any?

    private init() {
        // Back from System Settings, perhaps with notifications turned on.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        // Answered on a background queue.
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable [weak self] settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { self?.update(status) }
        }
    }

    private func update(_ status: UNAuthorizationStatus) {
        authorized = status == .authorized || status == .provisional
        denied = status == .denied
        guard status == .notDetermined, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable [weak self] granted, error in
            if let error { NSLog("tern: notification authorization failed: %@", String(describing: error)) }
            NSLog("tern: notifications authorized: %@", granted ? "yes" : "no")
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// System Settings → Notifications, at tern's entry.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.tern.Tern"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Tells you when an agent needs you or finishes while you're looking elsewhere:
/// a notification, a Dock badge with how many are waiting, and a Dock bounce.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var workspaces: [Workspace] = []
    var activate: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        NotificationPermission.shared.refresh()
    }

    func register(_ workspace: Workspace) {
        workspaces.append(workspace)
        workspace.onCommandEvent = { [weak self, weak workspace] tab, info in
            guard let self, let workspace, !workspace.isVisible(tab), (info.durationMs ?? 0) >= 10_000,
                  Prefs.defaults.bool(forKey: Prefs.notifyCommandDone) else { return }
            NSApp.requestUserAttention(.informationalRequest)
            self.post(tab: tab, title: workspace.title(for: tab) + " finished", body: CommandOutcome(exitCode: info.exitCode, durationMs: info.durationMs)?.text ?? "Stopped", sound: false)
        }
        workspace.onAgentEvent = { [weak self, weak workspace] tab, info in
            guard let workspace else { return }
            self?.agentChanged(tab: tab, info: info, workspace: workspace)
        }
    }

    func unregister(_ workspace: Workspace) {
        workspaces.removeAll { $0 === workspace }
        workspace.onCommandEvent = nil; workspace.onAgentEvent = nil
    }

    private func agentChanged(tab: Tab, info: SessionInfo, workspace: Workspace) {
        updateBadge()
        guard !workspace.isVisible(tab) else { return }
        let defaults = Prefs.defaults
        let title = workspace.title(for: tab)
        let agent = info.agent.map(agentName) ?? info.program ?? "Agent"
        switch info.agentState {
        case "needs_you":
            NSApp.requestUserAttention(.informationalRequest)
            guard defaults.bool(forKey: Prefs.notifyNeedsYou) else { return }
            post(tab: tab, title: "\(title) needs you", body: info.agentMessage ?? "\(agent) is waiting for your answer.", sound: true)
        case "done":
            guard defaults.bool(forKey: Prefs.notifyDone) else { return }
            post(tab: tab, title: "\(title) is done", body: info.agentMessage ?? "\(agent) finished its turn.", sound: false)
        case "failed":
            NSApp.requestUserAttention(.informationalRequest)
            guard defaults.bool(forKey: Prefs.notifyDone) else { return }
            post(tab: tab, title: "\(title) failed", body: info.agentMessage ?? "\(agent) stopped with an error.", sound: false)
        default:
            break
        }
    }

    /// Dock badge: how many sessions are waiting on you.
    func updateBadge() {
        let n = workspaces.reduce(0) { $0 + $1.needsYouCount }
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func post(tab: Tab, title: String, body: String, sound: Bool) {
        guard NotificationPermission.shared.authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["tab": tab.id]
        content.threadIdentifier = tab.id
        if sound { content.sound = .default }
        // One notification per session: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: tab.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Showing a session clears its notification.
    func clear(tabID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tabID])
    }

    // UserNotifications calls its delegate on a queue of its own.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["tab"] as? String {
            DispatchQueue.main.async {
                self.activate?(id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        done()
    }

    // tern is frontmost but on another session: still show the banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
