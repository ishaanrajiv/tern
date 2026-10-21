import AppKit
import UserNotifications

/// Tells you when an agent needs you or finishes while you're looking elsewhere:
/// a notification, a Dock badge with how many are waiting, and a Dock bounce.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let workspace: Workspace
    private var authorized = false
    /// macOS refused permission (see README: open issue).
    static var unavailable = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error { NSLog("tern: notification authorization failed: %@", String(describing: error)) }
            NSLog("tern: notifications authorized: %@", granted ? "yes" : "no")
            DispatchQueue.main.async {
                self?.authorized = granted
                AgentNotifier.unavailable = !granted
            }
        }
        workspace.onAgentEvent = { [weak self] tab, info in self?.agentChanged(tab: tab, info: info) }
    }

    private func agentChanged(tab: Tab, info: SessionInfo) {
        updateBadge()
        guard !workspace.isVisible(tab) else { return }
        let defaults = UserDefaults.standard
        let title = workspace.title(for: tab)
        let agent = info.agent.map { $0 == "claude" ? "Claude Code" : $0 == "codex" ? "Codex" : $0 } ?? "Agent"
        switch info.agentState {
        case "needs_you":
            NSApp.requestUserAttention(.informationalRequest)
            guard defaults.bool(forKey: Prefs.notifyNeedsYou) else { return }
            post(tab: tab, title: "\(title) needs you", body: info.agentMessage ?? "\(agent) is waiting for your answer.", sound: true)
        case "done":
            guard defaults.bool(forKey: Prefs.notifyDone) else { return }
            post(tab: tab, title: "\(title) is done", body: info.agentMessage ?? "\(agent) finished its turn.", sound: false)
        default:
            break
        }
    }

    /// Dock badge: how many sessions are waiting on you.
    func updateBadge() {
        let n = workspace.needsYouCount
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["tab"] as? String {
            DispatchQueue.main.async {
                self.workspace.select(id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        done()
    }

    // tern is frontmost but on another session: still show the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
