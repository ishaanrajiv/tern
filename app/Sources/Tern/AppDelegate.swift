import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workspace = Workspace()
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var notifier: AgentNotifier?
    private lazy var hooks = AgentHooks(ternBinary: ternBinary)
    private lazy var usage = AgentUsage()
    private lazy var updates = AgentUpdates()

    /// `tern` and `ternd` ship in Contents/Helpers.
    private lazy var ternBinary: String = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/tern").path

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        _ = GhosttyApp.shared
        // Installed hooks call tern through a stable path; keep it pointing at this app,
        // and bring hooks set up by an older tern up to this one's events.
        DispatchQueue.global(qos: .utility).async { [hooks] in
            hooks.link()
            DispatchQueue.main.async { hooks.refresh() }
        }

        // Layout from last time, plus any sessions ternd is running that it doesn't know.
        workspace.load()
        if let running = TernClient.listNow() {
            workspace.update(sessions: running)
        }

        let notifier = AgentNotifier(workspace: workspace)
        self.notifier = notifier
        let controller = MainWindowController(workspace: workspace, ternBinary: ternBinary, hooks: hooks,
                                              usage: usage, updates: updates)
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onSync = { [weak self] in
            notifier.updateBadge()
            if let id = self?.workspace.selectedTabID, self?.workspace.isActive == true { notifier.clear(tabID: id) }
        }
        mainWindow = controller
        NSApp.mainMenu = MenuBuilder.build(commands: controller.commands)
        DebugHooks.install { [weak controller] in controller?.commands ?? [] }
        controller.showWindow(nil)
        // Nothing open: start by choosing a folder.
        if workspace.allTabs.isEmpty { controller.showFolderPicker() }

        TernClient.watch { [weak self] list in self?.workspace.update(sessions: list) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) { workspace.isActive = true }
    func applicationDidResignActive(_ notification: Notification) { workspace.isActive = false }

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(hooks: hooks, updates: updates) { [weak self] version in
                self?.mainWindow?.runUpdate(version)
            }
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        workspace.save()
    }
}

extension TerminalView {
    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBinding("select_all") }

    func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }
}
