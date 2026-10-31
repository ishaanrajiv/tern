import AppKit
import UserNotifications

/// Tells you when an agent needs you or finishes while you're looking elsewhere:
/// a notification, a Dock badge with how many are waiting, and a Dock bounce.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var workspaces: [Workspace] = []
    var activate: ((String) -> Void)?
    private var authorized = false
    /// macOS refused permission (see README: open issue).
    static var unavailable = false

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Answered on a background queue.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable [weak self] granted, error in
            if let error { NSLog("tern: notification authorization failed: %@", String(describing: error)) }
            NSLog("tern: notifications authorized: %@", granted ? "yes" : "no")
            DispatchQueue.main.async {
                self?.authorized = granted
                AgentNotifier.unavailable = !granted
            }
        }
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
        guard authorized else { return }
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
