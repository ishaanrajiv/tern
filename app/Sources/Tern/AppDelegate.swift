import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MainWindowController] = []
    private var mainWindow: MainWindowController? {
        windows.first { $0.window === NSApp.keyWindow } ?? windows.first { $0.window === NSApp.mainWindow } ?? windows.first
    }
    private var settingsWindow: SettingsWindowController?
    private var openMonitor: AppOpenMonitor?
    private var pendingOpens: [AppOpenRequest] = []
    private var latestSessions: [SessionInfo] = []
    private var ready = false
    private var terminating = false
    private var lastFocusedWindowID: String?
    private var notifier: AgentNotifier?
    private var hotkey: TerminalHotkey?
    private lazy var hooks = AgentHooks(ternBinary: ternBinary)
    private lazy var usage = AgentUsage()
    private lazy var updates = UpdateCenter(ternBinary: ternBinary)
    private lazy var ternBinary: String = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tern").path

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // Overrides that break a rule or clash are logged and left out.
        ShortcutRegistry.reload()
        assert(ShortcutRegistry.clashes(ShortcutRegistry.defaults).isEmpty, "Default shortcuts clash")
        _ = GhosttyApp.shared
        DispatchQueue.global(qos: .utility).async { [hooks] in hooks.link(); DispatchQueue.main.async { hooks.refresh() } }
        let notifier = AgentNotifier()
        self.notifier = notifier
        notifier.activate = { [weak self] tabID in
            guard let owner = self?.windows.first(where: { $0.workspace.allTabs.contains { $0.id == tabID } }) else { return }
            owner.workspace.select(tabID); owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        }
        // Load all window layouts before adopting any daemon sessions, so a pane
        // restored in another window cannot also become an orphan in the first.
        let records = WindowCatalog.load()
        for record in records {
            let workspace = Workspace(storageURL: WindowCatalog.storageURL(record.id))
            workspace.adoptsOrphans = false
            workspace.load(excluding: ownedPanes)
            _ = makeWindow(workspace: workspace, id: record.id, frame: record.rect)
        }
        lastFocusedWindowID = records.first(where: \.active)?.id ?? windows.first?.windowID
        ready = true
        saveWindows()
        if let record = records.first(where: \.active), let controller = windows.first(where: { $0.windowID == record.id }) { controller.window?.makeKeyAndOrderFront(nil) }
        DebugHooks.install { [weak self] in self?.mainWindow?.commands ?? [] }
        NSApp.servicesProvider = self
        openMonitor = AppOpenMonitor { [weak self] request in self?.open(request) }
        for request in pendingOpens { open(request) }; pendingOpens = []
        if let controller = mainWindow, controller.workspace.allTabs.isEmpty { controller.showFolderPicker() }
        updates.confirmRestart = { [weak self] restart in self?.mainWindow?.confirmDaemonRestart(force: true, then: restart) }
        updates.onError = { [weak self] title, detail in self?.mainWindow?.showError(title, detail) }
        updates.openSettings = { [weak self] in self?.openSettings(pane: SettingsWindowController.updatesPane) }
        updates.start()
        mainWindow?.checkDaemon()
        hotkey = TerminalHotkey { [weak self] in self?.toggleTerminal() }
        TernClient.watch { [weak self] list in self?.updateSessions(list) }
        if ProcessInfo.processInfo.environment["TERN_RUNTIME_DIR"] == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    @discardableResult
    private func makeWindow(workspace: Workspace? = nil, id: String? = nil, frame: NSRect? = nil) -> MainWindowController {
        let id = id ?? "w-" + UUID().uuidString.lowercased()
        let workspace = workspace ?? Workspace(storageURL: WindowCatalog.storageURL(id))
        workspace.adoptsOrphans = false
        workspace.update(sessions: latestSessions)
        let controller = MainWindowController(workspace: workspace, ternBinary: ternBinary, hooks: hooks, usage: usage, updates: updates, windowID: id, restoredFrame: frame)
        windows.append(controller)
        notifier?.register(workspace)
        controller.paletteSessions = { [weak self] in
            self?.windows.enumerated().flatMap { index, owner in
                owner.workspace.allTabs.map { tab in
                    PaletteItem(title: owner.workspace.title(for: tab),
                        subtitle: (owner.workspace.project(containing: tab.id)?.name ?? "") + " · Window \(index + 1)",
                        shortcut: "", symbol: "terminal", action: { [weak owner] in
                            owner?.workspace.select(tab.id); owner?.showWindow(nil); owner?.window?.makeKeyAndOrderFront(nil)
                        })
                }
            } ?? []
        }
        controller.onNextAttention = { [weak self, weak controller] backward in
            guard let self, let controller else { return }
            let tabs = self.windows.flatMap { owner in owner.workspace.allTabs.map { (owner, $0) } }
            guard !tabs.isEmpty else { NSSound.beep(); return }
            let step = backward ? -1 : 1
            let start = tabs.firstIndex { $0.1.id == controller.workspace.selectedTabID } ?? (backward ? tabs.count : -1)
            let order = (1...tabs.count).map { tabs[((start + step * $0) % tabs.count + tabs.count) % tabs.count] }
                .filter { $0.1.id != controller.workspace.selectedTabID }
            let now = Date()
            let next = order.first { $0.0.workspace.status(for: $0.1, now: now) == .needsYou }
                ?? order.first { $0.0.workspace.status(for: $0.1, now: now) == .failed }
                ?? order.first { $0.0.workspace.status(for: $0.1, now: now) == .doneUnread }
                ?? order.first { $0.0.workspace.isUnread($0.1) }
            guard let (owner, tab) = next else { NSSound.beep(); return }
            owner.workspace.select(tab.id); owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        }
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onOpenUpdates = { [weak self] in self?.openSettings(pane: SettingsWindowController.updatesPane) }
        controller.onNewWindow = { [weak self] in let window = self?.makeWindow(); window?.showFolderPicker() }
        controller.onMoveTab = { [weak self, weak controller] new in
            guard let self, let controller, let tab = controller.workspace.selectedTabID else { return }
            let other = new ? self.makeWindow() : self.nextWindow(after: controller)
            guard let transfer = controller.workspace.takeTab(tab) else { return }
            other.workspace.insertTab(transfer)
            other.window?.makeKeyAndOrderFront(nil)
            controller.workspace.save(); other.workspace.save(); self.saveWindows()
        }
        controller.ownedPanes = { [weak self] in self?.ownedPanes ?? [] }
        controller.worktreeInUse = { [weak self] path in
            self?.windows.contains { $0.workspace.usesWorktree(path) } ?? true
        }
        controller.onReattach = { [weak self, weak controller] id in
            guard let self, let controller, !self.ownedPanes.contains(id) else { return }
            // Reattach a detached split layout in its original workspace when possible.
            let owner = self.windows.first { $0.workspace.detachedPanes.contains(id) } ?? controller
            owner.workspace.reattach(id)
            let ids = Set(owner.workspace.selectedTab?.root.panes ?? [id])
            for window in self.windows where window !== owner { window.workspace.forgetDetached(ids) }
            owner.window?.makeKeyAndOrderFront(nil)
        }
        controller.onFocusWindow = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.lastFocusedWindowID = controller.windowID
            for window in self.windows { window.workspace.isActive = window === controller && NSApp.isActive }
            NSApp.mainMenu = MenuBuilder.build(commands: controller.commands)
            self.saveWindows()
        }
        controller.onWindowClosed = { [weak self, weak controller] in
            guard let self, let controller, !self.terminating, self.windows.count > 1 else { return }
            guard let recipient = self.windows.first(where: { $0 !== controller }) else { return }
            for tab in controller.workspace.allTabs {
                if let transfer = controller.workspace.takeTab(tab.id) { recipient.workspace.rememberDetached(transfer) }
            }
            recipient.workspace.absorbRecovery(from: controller.workspace)
            self.notifier?.unregister(controller.workspace)
            self.windows.removeAll { $0 === controller }
            if self.lastFocusedWindowID == controller.windowID { self.lastFocusedWindowID = recipient.windowID }
            self.saveWindows()
        }
        controller.onGeometryChanged = { [weak self] in self?.saveWindows() }
        controller.onSync = { [weak self, weak controller] in
            self?.notifier?.updateBadge()
            if let controller, let id = controller.workspace.selectedTabID, controller.workspace.isActive { self?.notifier?.clear(tabID: id) }
        }
        controller.showWindow(nil)
        NSApp.mainMenu = MenuBuilder.build(commands: controller.commands)
        saveWindows()
        return controller
    }

    private var ownedPanes: Set<String> { Set(windows.flatMap { $0.workspace.allTabs.flatMap { $0.root.panes } }) }
    private func nextWindow(after window: MainWindowController) -> MainWindowController {
        guard windows.count > 1, let index = windows.firstIndex(where: { $0 === window }) else { return makeWindow() }
        return windows[(index + 1) % windows.count]
    }
    private var adopted = false
    private func updateSessions(_ list: [SessionInfo]) {
        latestSessions = list
        for window in windows { window.workspace.update(sessions: list) }
        updates.update(sessions: list)
        if !adopted, let first = windows.first {
            adopted = true
            let detached = Set(windows.flatMap { $0.workspace.detachedPanes })
            let known = ownedPanes.union(detached)
            for session in list where !known.contains(session.id) && !session.id.hasPrefix("bench-") && !UpdateRunner.isRunSession(session.id) {
                first.workspace.newTab(projectPath: session.gitRoot ?? session.cwd ?? NSHomeDirectory(), cwd: session.cwd ?? NSHomeDirectory(), paneID: session.id)
            }
            TernClient.setScrollback(TerminalPreferences.current.scrollback)
        }
        notifier?.updateBadge()
    }
    private func saveWindows() {
        guard ready else { return }
        WindowCatalog.save(windows.map { WindowRecord(id: $0.windowID, frame: $0.window.map { NSStringFromRect($0.frame) }, active: $0.windowID == lastFocusedWindowID) })
    }
    private func open(_ request: AppOpenRequest) {
        guard ready else { pendingOpens.append(request); return }
        let target = request.window ? makeWindow() : mainWindow ?? makeWindow()
        target.open(request)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { if let request = AppOpenRequest.from(url: url) { open(request) } }
    }
    @objc func openInTern(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for url in pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] { open(AppOpenRequest(directory: url.path)) }
    }
    func applicationDidBecomeActive(_ notification: Notification) { mainWindow?.workspace.isActive = true }
    func applicationDidResignActive(_ notification: Notification) { SecureKeyboard.shared.disable(); for window in windows { window.workspace.isActive = false } }
    private func toggleTerminal() {
        if NSApp.isActive, mainWindow?.window?.isVisible == true { NSApp.hide(nil) }
        else { let window = mainWindow ?? makeWindow(); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    private func openSettings(pane: Int? = nil) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(hooks: hooks, updates: updates, usage: usage) }
        if let pane { settingsWindow?.select(pane: pane) }
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        SecureKeyboard.shared.disable()
        terminating = true
        for window in windows { window.workspace.save() }
        saveWindows(); Workspace.finishSaving(); WindowCatalog.finishSaving()
        updates.app.installOnQuit()
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
