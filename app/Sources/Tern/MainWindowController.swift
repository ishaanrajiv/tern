import AppKit
import SwiftUI

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let workspace: Workspace
    private let terminalArea: TerminalArea
    private let splitController = NSSplitViewController()
    private var paletteHost: NSView?
    private var pickerHost: NSView?
    private var picker: FolderPickerModel?
    private var emptyState: NSView?
    private var keyMonitor: Any?
    /// The window closes when its last tab does, not when it starts out empty.
    private var hadTabs = false
    private var lastFocusKey = ""
    private let headerLayout = HeaderLayout()
    private var collapseObservation: NSKeyValueObservation?
    private var saveScheduled = false
    private var savedLayout: ([Project], String?)?
    private(set) var commands: [Command] = []
    var onOpenSettings: (() -> Void)?
    /// Runs after every model change (the Dock badge follows it).
    var onSync: (() -> Void)?

    init(workspace: Workspace, ternBinary: String, hooks: AgentHooks) {
        self.workspace = workspace
        self.terminalArea = TerminalArea(workspace: workspace, ternBinary: ternBinary)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "tern"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: GhosttyApp.shared.isDark ? .darkAqua : .aqua)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        window.delegate = self
        workspace.onWorktreeClosed = { [weak self] path in self?.offerWorktreeRemoval(path) }

        let sidebar = NSHostingController(rootView: SidebarView(workspace: workspace, hooks: hooks, actions: SidebarActions(
            newTab: { [weak self] path in self?.newSession { $0.newSession(projectPath: path, cwd: path) } },
            newWorktreeTab: { [weak self] path in self?.newSession { $0.newSession(projectPath: path, cwd: path, worktree: true) } },
            closeFolder: { [weak self] path in self?.closeFolder(path) },
            setUpHooks: { [weak self] in self?.onOpenSettings?() },
            rename: { [weak self] id in self?.rename(tabID: id) },
            close: { [weak self] id in self?.closeTab(id) }
        )))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        splitController.addSplitViewItem(sidebarItem)

        let content = NSViewController()
        content.view = NSView()
        // The strip under the titlebar and the terminal share one colour, so they read as one surface.
        content.view.wantsLayer = true
        content.view.layer?.backgroundColor = GhosttyApp.shared.background.cgColor
        let header = DraggableHostingView(rootView: ContentHeader(workspace: workspace, layout: headerLayout))
        // It lives in the titlebar strip; without this SwiftUI pushes it below the strip, out of sight.
        header.safeAreaRegions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(header)
        terminalArea.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(terminalArea)
        let empty = NSHostingView(rootView: EmptyState())
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(empty)
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
            empty.centerXAnchor.constraint(equalTo: terminalArea.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: terminalArea.centerYAnchor),
        ])
        header.leadingAnchor.constraint(equalTo: content.view.leadingAnchor).isActive = true
        // With the sidebar hidden, the traffic lights and sidebar buttons sit over the header's left end.
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.headerLayout.leadingInset = item.isCollapsed ? 146 : 0 }
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
        window.setFrameAutosaveName("tern.main")
        if !window.setFrameUsingName("tern.main") { window.center() }

        commands = makeCommands()
        installKeyMonitor()
        observe()
        sync()
    }

    /// ⌘⇧1–9 picks a tab in the current folder. A menu key equivalent can't say it:
    /// with shift held the key reads "!", "@"… depending on the layout.
    private func installKeyMonitor() {
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  let n = digits[event.keyCode] else { return event }
            self.workspace.selectTabInFolder(index: n - 1)
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Model -> views

    private func observe() {
        withObservationTracking {
            _ = workspace.projects
            _ = workspace.selectedTabID
            _ = workspace.sessions
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        let tab = workspace.selectedTab
        let focusKey = "\(tab?.id ?? "")/\(tab?.focusedPane ?? "")/\(tab?.zoomed ?? false)"
        let focusChanged = focusKey != lastFocusKey
        lastFocusKey = focusKey
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
        if empty && hadTabs {
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
        workspace.save()
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
        item.toolTip = "Open Folder (⌘N)"
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

    // MARK: Commands (the keymap)

    private func makeCommands() -> [Command] {
        let w = workspace
        return [
            Command("Settings…", menu: "tern", key: ",") { [weak self] in self?.onOpenSettings?() },
            Command("Open Folder…", menu: "File", key: "n") { [weak self] in self?.toggleFolderPicker() },
            Command("New Tab", menu: "File", key: "t") { [weak self] in self?.newTab() },
            Command("New Tab in Worktree", menu: "File", key: "t", [.command, .shift]) { [weak self] in self?.newTab(worktree: true) },
            Command("Browse for Folder…", menu: "File", key: "o") { [weak self] in self?.browseForFolder() },
            Command("Split Right", menu: "File", key: "d") { w.split(.horizontal) },
            Command("Split Down", menu: "File", key: "d", [.command, .shift]) { w.split(.vertical) },
            Command("Rename Tab…", menu: "File", key: "r") { [weak self] in
                if let id = w.selectedTabID { self?.rename(tabID: id) }
            },
            Command("Close Pane", menu: "File", key: "w") { [weak self] in self?.closeFocusedPane() },
            Command("Close Tab", menu: "File", key: "w", [.command, .shift]) { [weak self] in
                if let id = w.selectedTabID { self?.closeTab(id) }
            },
            Command("Close Folder", menu: "File", key: "w", [.command, .option]) { [weak self] in
                if let path = w.currentProject?.path { self?.closeFolder(path) }
            },

            Command("Clear Screen", menu: "Edit", key: "k", [.command, .shift]) { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("clear_screen")
            },

            Command("Command Palette", menu: "View", key: "k", inPalette: false) { [weak self] in self?.togglePalette() },
            Command("Toggle Sidebar", menu: "View", key: "\\") { [weak self] in
                self?.splitController.toggleSidebar(nil)
            },
            // ⌘↩ also opens the picker's choice in a worktree: the menu sees the key before the picker does.
            Command("Zoom Pane", menu: "View", key: "\r") { [weak self] in
                if let picker = self?.picker { picker.submit(worktree: true) } else { w.toggleZoom() }
            },
            Command("Bigger Text", menu: "View", key: "=") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("increase_font_size:1")
            },
            Command("Smaller Text", menu: "View", key: "-") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("decrease_font_size:1")
            },
            Command("Actual Size", menu: "View", key: "0") { [weak self] in
                self?.terminalArea.focusedTerminal()?.performBinding("reset_font_size")
            },

            Command("Next Needing Attention", menu: "Navigate", key: "j") {
                if !w.jumpToNextUnread() { NSSound.beep() }
            },
            Command("Next Tab", menu: "Navigate", key: "]", [.command, .shift]) { w.cycleTab(1) },
            Command("Previous Tab", menu: "Navigate", key: "[", [.command, .shift]) { w.cycleTab(-1) },
            Command("Next Tab", menu: "Navigate", key: "\t", .control, inMenu: false, inPalette: false) { w.cycleTab(1) },
            Command("Previous Tab", menu: "Navigate", key: "\t", [.control, .shift], inMenu: false, inPalette: false) { w.cycleTab(-1) },
        ]
        + (1...9).map { n in
            Command("Folder \(n)", menu: "Navigate", key: "\(n)", inPalette: false) { w.selectFolder(index: n - 1) }
        }
        // Listed for reference; the key monitor handles ⌘⇧1–9.
        + (1...9).map { n in
            Command("Tab \(n)", menu: "Navigate", key: "\(n)", [.command, .shift], inPalette: false) { w.selectTabInFolder(index: n - 1) }
        }
        + [
            Command("Focus Pane Left", menu: "Navigate", key: Key.left, [.command, .option]) { w.moveFocus(.left) },
            Command("Focus Pane Right", menu: "Navigate", key: Key.right, [.command, .option]) { w.moveFocus(.right) },
            Command("Focus Pane Above", menu: "Navigate", key: Key.up, [.command, .option]) { w.moveFocus(.up) },
            Command("Focus Pane Below", menu: "Navigate", key: Key.down, [.command, .option]) { w.moveFocus(.down) },
            Command("Focus Next Pane", menu: "Navigate", key: "]") { w.cyclePane(1) },
            Command("Focus Previous Pane", menu: "Navigate", key: "[") { w.cyclePane(-1) },
        ]
    }

    // MARK: Palette

    func togglePalette() {
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
        items = tabs.map { tab in
            let s = workspace.sessions[tab.focusedPane]
            let title = workspace.title(for: tab)
            let folder = workspace.project(containing: tab.id)?.name
            let where_ = [folder, workspace.strayCwd(tab), s?.branch].compactMap { $0 }.joined(separator: " · ")
            return PaletteItem(
                title: title, subtitle: where_,
                shortcut: "",
                symbol: Workspace.agents.contains(s?.process ?? "") ? "sparkles" : "terminal",
                action: { [weak self] in self?.workspace.select(tab.id) })
        } + items

        let host = NSHostingView(rootView: CommandPaletteView(items: items, dismiss: { [weak self] in self?.closePalette() }))
        window?.makeFirstResponder(nil)
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host)
        paletteHost = host
    }

    private func closePalette() {
        paletteHost?.removeFromSuperview()
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

    private func rename(tabID: String) {
        guard let tab = workspace.allTabs.first(where: { $0.id == tabID }), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to name it after what's running."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tab.name ?? workspace.title(for: tab)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.workspace.rename(tabID, to: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A closed tab leaves its worktree behind: offer to remove it, branch kept.
    func offerWorktreeRemoval(_ path: String) {
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
            guard response == removeButton else { return }
            if let failure = Worktree.remove(path, force: !changes.isEmpty) {
                self?.showError("Couldn't remove the worktree", failure.description)
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

    private func showError(_ title: String, _ detail: String) {
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
        confirmClose(panes: tab.root.panes)
    }

    /// Ends sessions, asking first if any of them is running something.
    private func confirmClose(panes: [String]) {
        let busy = panes.compactMap { workspace.sessions[$0]?.process }.filter { !Workspace.shells.contains($0) }
        let close = { [weak self] in
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

/// The terminal area with nothing open.
private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a folder to start")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("⌘N")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
