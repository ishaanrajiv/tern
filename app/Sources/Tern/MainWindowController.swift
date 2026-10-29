import AppKit
import SwiftUI

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let windowID: String
    let workspace: Workspace
    private let terminalArea: TerminalArea
    private let splitController = NSSplitViewController()
    var outputDocuments: [OutputDocumentController] = []
    private var workflowWindow: NSWindowController?
    private var paletteHost: NSView?
    private var pickerHost: NSView?
    private var picker: FolderPickerModel?
    private var emptyState: NSView?
    private var emptyHost: NSHostingView<EmptyState>?
    private var contentView: NSView?
    private var settingsObserver: Any?
    private var themeObserver: Any?
    private var keyMonitor: Any?
    /// The window closes when its last tab does, not when it starts out empty.
    private var hadTabs = false
    private var lastFocusKey = ""
    private var wasRenaming = false
    private let headerLayout = HeaderLayout()
    private let hints = ShortcutHints()
    private var collapseObservation: NSKeyValueObservation?
    private var saveScheduled = false
    private var savedLayout: ([Project], String?)?
    private(set) var commands: [Command] = []
    var paletteSessions: (() -> [PaletteItem])?
    /// Jumps to the next tab needing attention in any window; true goes backward.
    var onNextAttention: ((Bool) -> Void)?
    var onNewWindow: (() -> Void)?
    var onMoveTab: ((Bool) -> Void)?
    var onFocusWindow: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    var ownedPanes: () -> Set<String> = { [] }
    var worktreeInUse: ((String) -> Bool)?
    var onReattach: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenUpdates: (() -> Void)?
    /// Runs after every model change (the Dock badge follows it).
    var onSync: (() -> Void)?

    private let updates: UpdateCenter
    private let ternBinary: String

    init(workspace: Workspace, ternBinary: String, hooks: AgentHooks, usage: AgentUsage, updates: UpdateCenter, windowID: String = "main", restoredFrame: NSRect? = nil) {
        self.windowID = windowID
        self.workspace = workspace
        self.updates = updates
        self.ternBinary = ternBinary
        self.terminalArea = TerminalArea(workspace: workspace, ternBinary: ternBinary)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("tern.window." + windowID)
        window.title = "tern"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        window.delegate = self
        workspace.onWorktreeClosed = { [weak self] path in self?.offerWorktreeRemoval(path) }

        let sidebar = NSHostingController(rootView: SidebarView(workspace: workspace, hooks: hooks, usage: usage, updates: updates, hints: hints, layout: headerLayout, actions: SidebarActions(
            newTab: { [weak self] path in self?.newSession { $0.newSession(projectPath: path, cwd: path) } },
            newWorktreeTab: { [weak self] path in self?.newSession { $0.newSession(projectPath: path, cwd: path, worktree: true) } },
            closeFolder: { [weak self] path in self?.closeFolder(path) },
            setUpHooks: { [weak self] in self?.onOpenSettings?() },
            rename: { [weak self] id in self?.rename(tabID: id) },
            close: { [weak self] id in self?.closeTab(id) }
        )))
        let split = ThemedSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitController.splitView = split
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        splitController.addSplitViewItem(sidebarItem)

        let content = NSViewController()
        content.view = NSView()
        content.view.wantsLayer = true
        contentView = content.view
        terminalArea.onSplit = { [weak self] pane, axis in
            self?.workspace.focus(pane: pane)
            self?.workspace.split(axis)
        }
        terminalArea.onClosePane = { [weak self] pane in
            self?.workspace.focus(pane: pane)
            self?.closeFocusedPane()
        }
        let header = DraggableHostingView(rootView: ContentHeader(workspace: workspace, layout: headerLayout))
        // It lives in the titlebar strip; without this SwiftUI pushes it below the strip, out of sight.
        header.safeAreaRegions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(header)
        terminalArea.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(terminalArea)
        let empty = NSHostingView(rootView: EmptyState())
        emptyHost = empty
        terminalArea.emptyView = empty
        emptyState = empty
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.view.topAnchor),
            header.bottomAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
            header.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            // Below the titlebar, not under it.
            terminalArea.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            terminalArea.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
        ])
        header.leadingAnchor.constraint(equalTo: content.view.leadingAnchor).isActive = true
        // With the sidebar hidden, the traffic lights and sidebar buttons sit over the header's left end.
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, change in
            let collapsed = change.newValue ?? false
            DispatchQueue.main.async {
                self?.headerLayout.leadingInset = collapsed ? 146 : 0
                self?.terminalArea.leadingPadding = collapsed ? TerminalArea.padding : 0
            }
        }

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "tern.split"

        window.contentViewController = splitController
        let toolbar = NSToolbar(identifier: "tern.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        if let frame = restoredFrame, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
        } else {
            let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1180, height: 760)
            window.setContentSize(NSSize(width: min(1180, available.width), height: min(760, max(320, available.height - 40))))
            window.center()
        }

        commands = makeCommands()
        updateEmptyState()
        settingsObserver = NotificationCenter.default.addObserver(forName: TerminalPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                GhosttyApp.shared.applyTheme()
                self.commands = self.makeCommands()
                self.updateEmptyState()
                if self.window?.isKeyWindow == true { NSApp.mainMenu = MenuBuilder.build(commands: self.commands) }
            }
        }
        applyTheme()
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeStore.didChange, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.applyTheme() }
        }
        measureTitlebar()
        installKeyMonitor()
        observe()
        sync()
    }

    /// Watches modifiers for the number hints. Number keys themselves are menu items.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.modifiersChanged(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
                return event
            }
            // Any key press means the user knows what they want; the hints go.
            self.setHints(nil)
            return event
        }
    }

    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Holding Folder 1's modifiers (⌘) numbers the folders; Tab 1's (⌃⌘) numbers the current folder's tabs.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let folders = ShortcutRegistry.primary("folder.select.1")?.modifiers
        let tabs = ShortcutRegistry.primary("tab.select.1")?.modifiers
        let held = flags.intersection([.command, .shift, .option, .control])
        let kind: ShortcutHints.Kind? = held == folders ? .folders : held == tabs ? .tabs : nil
        guard window?.isKeyWindow == true else { return setHints(nil) }
        setHints(kind)
    }

    private func setHints(_ kind: ShortcutHints.Kind?) {
        guard hints.kind != kind else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { hints.kind = kind }
    }

    func windowDidResignKey(_ notification: Notification) { setHints(nil); workspace.isActive = false }

    /// The AppKit side of the theme; SwiftUI views read it themselves.
    private func applyTheme() {
        let theme = ThemeStore.shared.theme
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.sidebar
        // Sidebar, header and the ground under the panes are one surface; the panes sit on it as cards.
        contentView?.layer?.backgroundColor = theme.sidebar.cgColor
        (splitController.splitView as? ThemedSplitView)?.needsDisplay = true
        terminalArea.themeChanged()
    }

    private func measureTitlebar() {
        guard let window else { return }
        let height = window.frame.height - window.contentLayoutRect.height
        if headerLayout.titlebarHeight != height { headerLayout.titlebarHeight = height }
    }

    func windowDidResize(_ notification: Notification) { measureTitlebar(); onGeometryChanged?() }
    func windowDidMove(_ notification: Notification) { onGeometryChanged?() }
    func windowDidBecomeKey(_ notification: Notification) { onFocusWindow?() }
    func windowDidEnterFullScreen(_ notification: Notification) { measureTitlebar() }
    func windowDidExitFullScreen(_ notification: Notification) { measureTitlebar() }

    // MARK: Model -> views

    private func observe() {
        withObservationTracking {
            _ = workspace.projects
            _ = workspace.selectedTabID
            _ = workspace.sessions
            _ = workspace.renamingTabID
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        let tab = workspace.selectedTab
        // Renaming in the sidebar holds the focus; the terminal gets it back afterwards.
        let renaming = workspace.renamingTabID != nil
        let focusKey = renaming ? lastFocusKey : "\(tab?.id ?? "")/\(tab?.focusedPane ?? "")/\(tab?.zoomed ?? false)"
        let focusChanged = focusKey != lastFocusKey || (wasRenaming && !renaming)
        lastFocusKey = focusKey
        wasRenaming = renaming
        terminalArea.refresh(focus: focusChanged && paletteHost == nil && pickerHost == nil)

        if let tab {
            window?.title = workspace.title(for: tab)
            let s = workspace.sessions[tab.focusedPane]
            let dir = s?.cwd.map(abbreviateHome) ?? ""
            window?.subtitle = [dir, s?.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            window?.title = "tern"
            window?.subtitle = ""
        }

        let empty = workspace.allTabs.isEmpty
        emptyState?.isHidden = !empty
        if empty && hadTabs && !workspace.keepsEmptyWindow {
            // Last pane closed: like any terminal, the window goes with it.
            window?.close()
        }
        hadTabs = !empty
        scheduleSave()
        onSync?()
    }

    private func scheduleSave() {
        // Session updates arrive several times a second; only layout changes need a write.
        if let saved = savedLayout, saved.0 == workspace.projects, saved.1 == workspace.selectedTabID { return }
        savedLayout = (workspace.projects, workspace.selectedTabID)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.workspace.save()
        }
    }

    func windowWillClose(_ notification: Notification) {
        for document in outputDocuments { document.close() }
        workspace.save()
        onWindowClosed?()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleSidebar, .init("new"), .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id.rawValue == "new" else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")
        item.label = "Open Folder"
        item.toolTip = "Open Folder (\(ShortcutRegistry.label("folder.open")))"
        item.isBordered = true
        item.target = self
        item.action = #selector(openFolderAction)
        return item
    }

    @objc private func openFolderAction() { toggleFolderPicker() }

    /// ⌘T: a tab in the current folder, or the picker when there's no folder yet.
    private func newTab(worktree: Bool? = nil) {
        guard workspace.currentProject != nil else { return showFolderPicker() }
        newSession { $0.newTabInCurrentProject(worktree: worktree) }
    }

    /// Creates a session, explaining if its worktree couldn't be made.
    private func newSession(_ make: (Workspace) -> Worktree.Failure?) {
        guard let failure = make(workspace), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't create a worktree"
        alert.informativeText = failure.description
        alert.beginSheetModal(for: window)
    }

    private func showPresets() {
        showWorkflow(title: "Project Launch Presets", view: LaunchPresetsView(workspace: workspace) { [weak self] in self?.workflowWindow?.close() })
    }

    private func showRemote() {
        showWorkflow(title: "SSH Connection", view: RemoteSessionView(workspace: workspace) { [weak self] in self?.workflowWindow?.close() })
    }

    func showWorkflow<V: View>(title: String, view: V) {
        workflowWindow?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("tern.workflow")
        window.styleMask = [.titled, .closable]
        workflowWindow = NSWindowController(window: window)
        window.center()
        workflowWindow?.showWindow(nil)
    }

    // MARK: Commands (the keymap)

    /// Actions for the shortcuts declared in `ShortcutRegistry`, in menu order.
    private func makeCommands() -> [Command] {
        let w = workspace
        return [
            Command("app.secureKeyboard") {
                SecureKeyboard.shared.toggle()
                for item in NSApp.mainMenu?.items.first?.submenu?.items ?? [] where (item.representedObject as? Command)?.id == "app.secureKeyboard" {
                    item.state = SecureKeyboard.shared.enabled ? .on : .off
                }
            },
            Command("app.checkUpdates") { [weak self] in
                self?.onOpenUpdates?()
                self?.updates.checkAll()
            },
            Command("app.settings") { [weak self] in self?.onOpenSettings?() },
            Command("settings.quick") { [weak self] in self?.showQuickSettings() },
            Command("help.shortcuts") { [weak self] in
                self?.showWorkflow(title: "Keyboard Shortcuts", view: ShortcutSheet { [weak self] in self?.workflowWindow?.close() })
            },
            Command("window.new") { [weak self] in self?.onNewWindow?() },
            Command("window.close") { [weak self] in self?.window?.performClose(nil) },
            Command("tab.toNewWindow") { [weak self] in self?.onMoveTab?(true) },
            Command("tab.toNextWindow") { [weak self] in self?.onMoveTab?(false) },
            Command("pane.toNewWindow") { [weak self] in
                self?.workspace.detachPane(); self?.onMoveTab?(true)
            },
            Command("folder.open") { [weak self] in self?.toggleFolderPicker() },
            Command("folder.presets") { [weak self] in self?.showPresets() },
            Command("remote.ssh") { [weak self] in self?.showRemote() },
            Command("tab.new") { [weak self] in self?.newTab() },
            Command("tab.newAtRoot") { [weak self] in
                self?.newSession { $0.newTabInCurrentProject(worktree: false, projectRoot: true) }
            },
            Command("edit.pasteImagePath") { [weak self] in self?.terminalArea.focusedTerminal()?.pasteImagePath(nil) },
            Command("file.openSelected") { [weak self] in self?.terminalArea.focusedTerminal()?.openSelectedFile(nil) },
            Command("tab.newWorktree") { [weak self] in self?.newTab(worktree: true) },
            Command("folder.browse") { [weak self] in self?.browseForFolder() },
            Command("pane.splitRight") { w.split(.horizontal) },
            Command("pane.splitDown") { w.split(.vertical) },
            Command("tab.rename") { [weak self] in
                if let id = w.selectedTabID { self?.rename(tabID: id) }
            },
            Command("tab.detach") { [weak self] in
                guard let self, let id = self.workspace.selectedTabID else { return }
                self.workspace.detachTab(id)
            },
            Command("tab.detached") { [weak self] in
                guard let self else { return }
                let owned = self.ownedPanes()
                self.showWorkflow(title: "Detached Sessions", view: DetachedSessionsView(sessions: self.workspace.sessions.values.filter { !owned.contains($0.id) }.sorted { $0.id < $1.id }) { [weak self] id in self?.onReattach?(id) })
            },
            Command("tab.reopen") { w.reopenClosedTab() },
            Command("pane.close") { [weak self] in self?.closeFocusedPane() },
            Command("tab.close") { [weak self] in
                if let id = w.selectedTabID { self?.closeTab(id) }
            },
            Command("folder.close") { [weak self] in
                if let path = w.currentProject?.path { self?.closeFolder(path) }
            },

            Command("app.reloadConfig") { GhosttyApp.shared.applyTheme() },
            Command("daemon.restart") { [weak self] in self?.confirmDaemonRestart(force: true) },

            Command("prompt.previous") { [weak self] in self?.terminalArea.focusedTerminal()?.performBinding("jump_to_prompt:-1") },
            Command("prompt.next") { [weak self] in self?.terminalArea.focusedTerminal()?.performBinding("jump_to_prompt:1") },
            Command("output.copyLast") { [weak self] in self?.showOutput(lastCommand: true, copy: true) },
            Command("output.selectLast") { [weak self] in self?.showOutput(lastCommand: true) },
            Command("output.export") { [weak self] in self?.showOutput(lastCommand: false) },
            Command("search.advanced") { [weak self] in self?.searchOutput(all: false) },
            Command("search.all") { [weak self] in self?.searchOutput(all: true) },
            Command("search.find") { [weak self] in self?.terminalArea.find() },
            Command("search.next") { [weak self] in self?.terminalArea.findNext() },
            Command("search.previous") { [weak self] in self?.terminalArea.findNext(previous: true) },
            Command("search.useSelection") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("search_selection")
            },
            Command("terminal.clear") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("clear_screen")
            },

            Command("palette.toggle") { [weak self] in self?.togglePalette() },
            Command("view.sidebar") { [weak self] in
                self?.splitController.toggleSidebar(nil)
            },
            Command("tab.moveEarlier") { w.shiftTab(-1) },
            Command("tab.moveLater") { w.shiftTab(1) },
            Command("pane.swapPrevious") { w.swapPane(-1) },
            Command("pane.swapNext") { w.swapPane(1) },
            Command("pane.toNewTab") { w.detachPane() },
            Command("pane.toNextTab") { w.movePaneToNextTab() },
            Command("pane.equalize") { w.equalizePanes() },
            Command("pane.widen") { w.resizePane(axis: .horizontal, delta: 0.05) },
            Command("pane.narrow") { w.resizePane(axis: .horizontal, delta: -0.05) },
            Command("pane.taller") { w.resizePane(axis: .vertical, delta: 0.05) },
            Command("pane.shorter") { w.resizePane(axis: .vertical, delta: -0.05) },
            // ⌘↩ also opens the picker's choice in a worktree: the menu sees the key before the picker does.
            Command("pane.zoom") { [weak self] in
                if let picker = self?.picker { picker.submit(worktree: true) } else { w.toggleZoom() }
            },
            Command("text.bigger") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("increase_font_size:1")
            },
            Command("text.smaller") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("decrease_font_size:1")
            },
            Command("text.reset") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("reset_font_size")
            },

            Command("attention.next") { [weak self] in
                if let jump = self?.onNextAttention { jump(false) }
                else if !w.jumpToNextUnread() { NSSound.beep() }
            },
            Command("attention.previous") { [weak self] in
                if let jump = self?.onNextAttention { jump(true) }
                else if !w.jumpToNextUnread(backward: true) { NSSound.beep() }
            },
            Command("tab.next") { w.cycleTab(1) },
            Command("tab.previous") { w.cycleTab(-1) },
            Command("folder.next") { w.cycleFolder(1) },
            Command("folder.previous") { w.cycleFolder(-1) },
        ]
        + (1...9).map { n in Command("folder.select.\(n)") { w.selectFolder(index: n - 1) } }
        + (1...9).map { n in Command("tab.select.\(n)") { w.selectTabInFolder(index: n - 1) } }
        + [
            Command("pane.focusLeft") { w.moveFocus(.left) },
            Command("pane.focusRight") { w.moveFocus(.right) },
            Command("pane.focusUp") { w.moveFocus(.up) },
            Command("pane.focusDown") { w.moveFocus(.down) },
            Command("pane.next") { w.cyclePane(1) },
            Command("pane.previous") { w.cyclePane(-1) },
        ]
        // Palette-only: "theme" finds them all.
        + (Theme.builtIn.map { ($0.id, $0.name) } + [("ghostty", "Ghostty Colours")]).map { id, name in
            Command(id: "theme.\(id)", title: "Theme: \(name)", menu: "View", inMenu: false) {
                UserDefaults.standard.set(id, forKey: Prefs.theme)
            }
        }
        // Each agent's own updater, whether or not tern has seen a newer version yet.
        + [("claude", "Claude Code"), ("codex", "Codex")].map { agent, name in
            Command(id: "agent.update.\(agent)", title: "Update \(name)", menu: "tern", inMenu: false) { [weak self] in
                self?.updates.runAgent(agent)
            }
        }
        + [
            Command(id: "app.installUpdate", title: "Restart to Update tern", menu: "tern", inMenu: false) { [weak self] in
                guard let self else { return }
                if self.updates.app.phase == .ready { self.updates.perform(.installApp) }
                else { self.onOpenUpdates?(); self.updates.checkAll() }
            },
        ]
        // For the debug harness, which can't hold a modifier down.
        + (ProcessInfo.processInfo.environment["TERN_DEBUG"] == "1" ? [
            Command(id: "debug.hints.folders", title: "Debug Hints Folders", menu: "Navigate", inMenu: false, inPalette: false) { [weak self] in self?.setHints(.folders) },
            Command(id: "debug.hints.tabs", title: "Debug Hints Tabs", menu: "Navigate", inMenu: false, inPalette: false) { [weak self] in self?.setHints(.tabs) },
            Command(id: "debug.hints.off", title: "Debug Hints Off", menu: "Navigate", inMenu: false, inPalette: false) { [weak self] in self?.setHints(nil) },
            // Stand-in updaters, so the update rows can be tried without touching the real agents.
            Command(id: "debug.update.ok", title: "Debug Update OK", menu: "tern", inMenu: false, inPalette: false) { [weak self] in
                self?.updates.runner.start(agent: "codex", command: "echo Updating Codex; sleep 8; echo Done")
            },
            Command(id: "debug.update.fail", title: "Debug Update Fail", menu: "tern", inMenu: false, inPalette: false) { [weak self] in
                self?.updates.runner.start(agent: "claude", command: "echo 'Error: permission denied'; exit 2")
            },
            Command(id: "debug.update.prompt", title: "Debug Update Prompt", menu: "tern", inMenu: false, inPalette: false) { [weak self] in
                self?.updates.runner.start(agent: "codex", command: "printf 'Replace the existing install? [y/N] '; read answer; echo \"got $answer\"")
            },
        ] : [])
    }

    /// The empty card names the Open Folder shortcut as it's currently bound.
    private func updateEmptyState() {
        emptyHost?.rootView = EmptyState(shortcut: ShortcutRegistry.label("folder.open"))
    }

    // MARK: Palette

    /// The palette in its settings mode: theme, text size, cursor and the rest, changed in place.
    func showQuickSettings() {
        if paletteHost != nil { closePalette() }
        togglePalette(settings: true)
    }

    func togglePalette(settings: Bool = false) {
        if paletteHost != nil {
            closePalette()
            return
        }
        closeFolderPicker()
        guard let contentView = window?.contentView else { return }
        var items = commands.filter(\.inPalette).map { c in
            PaletteItem(title: c.title, subtitle: "", shortcut: c.shortcutLabel, symbol: c.symbol, action: c.action)
        }
        let tabs = workspace.allTabs
        let sessions = paletteSessions?() ?? tabs.map { tab in
            let s = workspace.sessions[tab.focusedPane]
            let title = workspace.title(for: tab)
            let folder = workspace.project(containing: tab.id)?.name
            let where_ = [folder, workspace.strayCwd(tab), s?.branch].compactMap { $0 }.joined(separator: " · ")
            return PaletteItem(
                title: title, subtitle: where_,
                shortcut: "",
                symbol: Workspace.agents.contains(s?.process ?? "") ? "sparkles" : "terminal",
                action: { [weak self] in self?.workspace.select(tab.id) })
        }
        items = sessions + items

        let quick = QuickSetting.all(
            openSettings: { [weak self] in self?.onOpenSettings?() },
            settingsShortcut: commands.first { $0.title == "Settings…" }?.shortcutLabel ?? "")
        let host = NSHostingView(rootView: CommandPaletteView(items: items, settings: quick, startInSettings: settings,
                                                              dismiss: { [weak self] in self?.closePalette() }))
        window?.makeFirstResponder(nil)
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host)
        paletteHost = host
    }

    private func closePalette() {
        if let host = paletteHost {
            Motion.animate(0.12, { host.animator().alphaValue = 0 }) { host.removeFromSuperview() }
        }
        paletteHost = nil
        lastFocusKey = ""
        sync()
    }

    // MARK: Folder picker

    func toggleFolderPicker() {
        if pickerHost != nil { closeFolderPicker() } else { showFolderPicker() }
    }

    func showFolderPicker() {
        guard pickerHost == nil, let contentView = window?.contentView else { return }
        if paletteHost != nil { closePalette() }
        let model = FolderPickerModel(workspace: workspace)
        model.onDismiss = { [weak self] in self?.closeFolderPicker() }
        model.onOpen = { [weak self] path, worktree in
            self?.closeFolderPicker()
            self?.newSession { $0.openFolder(path, worktree: worktree) }
        }
        let host = NSHostingView(rootView: FolderPickerView(model: model))
        // The terminal lets go of the keyboard, or it can keep it from the picker's field.
        window?.makeFirstResponder(nil)
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host)
        pickerHost = host
        picker = model
    }

    private func closeFolderPicker() {
        guard pickerHost != nil else { return }
        pickerHost?.removeFromSuperview()
        pickerHost = nil
        picker = nil
        lastFocusKey = ""
        sync()
    }

    // MARK: Actions

    private func browseForFolder() {
        closeFolderPicker()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.workspace.openFolder(url.path)
        }
    }

    private func closeFolder(_ path: String) {
        guard let project = workspace.project(at: path) else { return }
        confirmClose(panes: project.tabs.flatMap(\.root.panes))
    }

    /// Edits the tab's name in place in the sidebar.
    private func rename(tabID: String) {
        guard let tab = workspace.allTabs.first(where: { $0.id == tabID }) else { return }
        if splitController.splitViewItems.first?.isCollapsed == true { splitController.toggleSidebar(nil) }
        if let project = workspace.projects.first(where: { $0.tabs.contains { $0.id == tab.id } }), project.collapsed {
            workspace.setCollapsed(project.path, false)
        }
        workspace.select(tab.id)
        workspace.renamingTabID = tab.id
    }

    // MARK: ternd

    /// After installing a new build, the old ternd keeps running under launchd until
    /// it's restarted: offer that, since restarting ends what runs in the tabs.
    /// An incompatible ternd gets a sheet as well as the sidebar row: tabs can misbehave until it restarts.
    func checkDaemon() {
        updates.checkDaemon { [weak self] status in
            guard status.running, !status.compatible else { return }
            self?.offerDaemonRestart()
        }
    }

    private func offerDaemonRestart() {
        let alert = NSAlert()
        alert.messageText = "ternd needs a restart"
        alert.informativeText = "tern's background service is from an older tern and may not understand this one, so tabs can misbehave until it restarts."
            + " Restarting ends the programs running in your tabs. Their screens come back, and Claude Code and Codex conversations resume."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Later")
        presentSheet(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.updates.restartDaemonNow() }
        }
    }

    /// Restart ternd from the card or the palette. With programs running, the sheet names them.
    func confirmDaemonRestart(force: Bool = false, then restart: (() -> Void)? = nil) {
        let programs = updates.busy
        let restart = restart ?? { [weak self] in self?.updates.restartDaemonNow() }
        guard !programs.isEmpty else {
            if force || updates.daemon?.current == false { restart() }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Restart ternd?"
        alert.informativeText = "This ends \(programs.count == 1 ? "1 running program" : "\(programs.count) running programs"): "
            + programs.formatted(.list(type: .and)) + ". Their screens come back, and Claude Code and Codex conversations resume."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        presentSheet(alert) { response in
            if response == .alertFirstButtonReturn { restart() }
        }
    }

    /// A closed tab leaves its worktree behind: offer to remove it, branch kept.
    func offerWorktreeRemoval(_ path: String) {
        guard !(worktreeInUse?(path) ?? workspace.usesWorktree(path)) else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let changes = Worktree.changes(in: path)
        let branch = Worktree.branch(of: path).map { "Branch \($0) is kept." } ?? ""
        let alert = NSAlert()
        alert.messageText = "Remove worktree \(name)?"
        if changes.isEmpty {
            alert.informativeText = "It has no uncommitted changes. \(branch)"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Keep")
        } else {
            let n = changes.count
            alert.informativeText = "It has \(n) uncommitted change\(n == 1 ? "" : "s"), which removing it deletes. \(branch)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep")
            alert.addButton(withTitle: "Remove Anyway")
            alert.buttons[1].hasDestructiveAction = true
        }
        let removeButton: NSApplication.ModalResponse = changes.isEmpty ? .alertFirstButtonReturn : .alertSecondButtonReturn
        presentSheet(alert) { [weak self] response in
            guard response == removeButton, let self,
                  !(self.worktreeInUse?(path) ?? self.workspace.usesWorktree(path)) else { return }
            if let failure = Worktree.remove(path, force: !changes.isEmpty) {
                self.showError("Couldn't remove the worktree", failure.description)
            }
        }
    }

    /// Shows an alert once any sheet already up (say, the close confirmation) has gone.
    private func presentSheet(_ alert: NSAlert, then handler: @escaping (NSApplication.ModalResponse) -> Void) {
        // The last tab closing takes the window with it, so there's nothing to attach to.
        guard let window, !workspace.allTabs.isEmpty else {
            NSApp.activate()
            return handler(alert.runModal())
        }
        guard window.attachedSheet == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.presentSheet(alert, then: handler) }
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handler)
    }

    func showError(_ title: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    private func closeFocusedPane() {
        guard let tab = workspace.selectedTab else { return }
        confirmClose(panes: [tab.focusedPane])
    }

    private func closeTab(_ id: String) {
        guard let tab = workspace.allTabs.first(where: { $0.id == id }) else { return }
        confirmClose(panes: tab.root.panes, tabID: id)
    }

    /// Ends sessions, asking first if any of them is running something.
    private func confirmClose(panes: [String], tabID: String? = nil) {
        let busy = panes.compactMap { workspace.sessions[$0]?.process }.filter { !Workspace.shells.contains($0) }
        let close = { [weak self] in
            if let tabID { self?.workspace.rememberClosedTab(tabID) }
            else if let tab = self?.workspace.selectedTab, tab.root.panes == panes { self?.workspace.rememberClosedTab(tab.id) }
            for pane in panes {
                TernClient.kill(pane)
                self?.workspace.removePane(pane)
            }
        }
        guard !busy.isEmpty, let window else { return close() }
        let alert = NSAlert()
        alert.messageText = panes.count == 1 ? "Close this pane?" : "Close \(panes.count) panes?"
        alert.informativeText = "\(busy.joined(separator: ", ")) is still running and will be stopped."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
    }
}

/// The card shown with no tabs: tern's mark and the way to start.
private struct EmptyState: View {
    var shortcut = ""

    var body: some View {
        VStack(spacing: 10) {
            TernMark()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.tertiary)
                .frame(width: 44, height: 44)
            Text("Open a folder to start")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if !shortcut.isEmpty {
                HStack(spacing: 6) {
                    Text(shortcut)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.border))
                    Text("open a folder")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let card = RoundedRectangle(cornerRadius: PaneCard.radius, style: .continuous)
            card.fill(Palette.terminal).overlay(card.strokeBorder(Palette.border))
        }
        .themedText()
    }
}

/// A tern in flight, drawn in two strokes: wings, then the forked tail.
private nonisolated struct TernMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 48
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(6, 20))
        path.addCurve(to: p(24, 28), control1: p(14, 19), control2: p(19, 22))
        path.addCurve(to: p(42, 20), control1: p(29, 22), control2: p(34, 19))
        path.move(to: p(21, 40))
        path.addLine(to: p(24, 28))
        path.addLine(to: p(27, 40))
        return path
    }
}

/// Sidebar and content share one ground, so the divider takes its colour and the pane cards'
/// outlines draw the edge.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { ThemeStore.shared.theme.sidebar }

    override func drawDivider(in rect: NSRect) {
        dividerColor.setFill()
        rect.fill()
    }
}
