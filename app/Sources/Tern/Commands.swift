import AppKit

/// One user-facing action. The menu bar and the palette are both built from the
/// same list, so every shortcut is discoverable in both places. Keys come from
/// `ShortcutRegistry`, with the user's overrides applied.
final class Command {
    let id: String
    let title: String
    let menu: String
    /// The first is shown; the rest are hidden aliases.
    let bindings: [KeyBinding]
    /// Shown in the palette but not the menu (or the reverse, for number keys).
    let inMenu: Bool
    let inPalette: Bool
    let action: () -> Void

    /// A command declared in `ShortcutRegistry.specs`.
    init(_ id: String, action: @escaping () -> Void) {
        guard let spec = ShortcutRegistry.spec(id) else { preconditionFailure("No shortcut declared for \(id)") }
        self.id = id
        title = spec.title
        menu = spec.menu
        bindings = ShortcutRegistry.bindings[id] ?? []
        inMenu = spec.inMenu
        inPalette = spec.inPalette
        self.action = action
    }

    /// A generated command with no shortcut, such as a theme.
    init(id: String, title: String, menu: String, inMenu: Bool = true, inPalette: Bool = true, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.menu = menu
        bindings = []
        self.inMenu = inMenu
        self.inPalette = inPalette
        self.action = action
    }

    /// SF Symbol for the palette.
    var symbol: String {
        let t = title
        if t.hasPrefix("New Tab in Worktree") { return "arrow.triangle.branch" }
        if t.hasPrefix("New Tab") { return "plus" }
        if t.hasPrefix("Open Folder") { return "folder.badge.plus" }
        if t.hasPrefix("Browse") { return "folder" }
        if t == "Split Right" { return "rectangle.split.2x1" }
        if t == "Split Down" { return "rectangle.split.1x2" }
        if t.hasPrefix("Rename") { return "pencil" }
        if t.hasPrefix("Close") { return "xmark" }
        if t.hasPrefix("Clear") { return "eraser" }
        if t.hasPrefix("Quick Settings") { return "slider.horizontal.3" }
        if t.hasPrefix("Settings") { return "gearshape" }
        if t.hasPrefix("Toggle Sidebar") { return "sidebar.left" }
        if t.hasPrefix("Zoom") { return "arrow.up.left.and.arrow.down.right" }
        if t.contains("Text") || t.hasPrefix("Actual Size") { return "textformat.size" }
        if t.hasPrefix("Next Needing") { return "bell" }
        if t.hasPrefix("Focus") { return "rectangle.inset.filled" }
        if t.hasPrefix("Theme") { return "paintpalette" }
        if t.hasPrefix("Restart") { return "arrow.clockwise" }
        return "arrow.right"
    }

    /// "⌥⌘←" style label.
    var shortcutLabel: String { bindings.first?.label ?? "" }
}

/// Routes menu items to their Command.
final class CommandRunner: NSObject {
    static let shared = CommandRunner()

    @objc func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        if let window = NSApp.keyWindow, let document = window.windowController as? OutputDocumentController {
            switch command.id {
            case "pane.close": window.performClose(nil); return
            case "search.find": document.find(.showFindInterface); return
            case "search.next": document.find(.nextMatch); return
            case "search.previous": document.find(.previousMatch); return
            default: break
            }
        }
        if let window = NSApp.keyWindow, window.identifier?.rawValue == "tern.settings", command.id == "pane.close" {
            window.performClose(nil)
            return
        }
        // Editing a preset must not close a running pane behind its window.
        if let window = NSApp.keyWindow, window.identifier?.rawValue == "tern.workflow" {
            if command.id == "pane.close" { window.performClose(nil) }
            return
        }
        command.action()
    }
}

enum MenuBuilder {
    static let order = ["File", "Edit", "View", "Navigate", "Window"]

    static func build(commands: [Command]) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About tern", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        for command in commands where command.menu == "tern" {
            for item in items(for: command) {
                if command.id == "app.secureKeyboard" { item.state = SecureKeyboard.shared.enabled ? .on : .off }
                appMenu.addItem(item)
            }
        }
        appMenu.addItem(.separator())
        appMenu.addItem(standard("app.hide", #selector(NSApplication.hide(_:))))
        appMenu.addItem(standard("app.quit", #selector(NSApplication.terminate(_:))))
        add(appMenu, title: "tern", to: main)

        for name in order {
            let menu = NSMenu(title: name)
            var lastGroup: String?
            for command in commands where command.menu == name {
                // Separate runs of related items: Next…/Previous…, Folder N, Tab N, Focus…
                let group = command.title.components(separatedBy: " ").first.map { $0 == "Previous" ? "Next" : $0 }
                if let lastGroup, lastGroup != group, name == "Navigate", command.inMenu { menu.addItem(.separator()) }
                if command.inMenu { lastGroup = group }
                items(for: command).forEach(menu.addItem)
            }
            if name == "Edit" {
                menu.addItem(.separator())
                menu.addItem(standard("edit.undo", Selector(("undo:"))))
                menu.addItem(standard("edit.redo", Selector(("redo:"))))
                menu.addItem(standard("edit.cut", #selector(NSText.cut(_:))))
                menu.addItem(standard("edit.copy", #selector(TerminalView.copy(_:))))
                menu.addItem(standard("edit.paste", #selector(TerminalView.paste(_:))))
                menu.addItem(standard("edit.selectAll", #selector(TerminalView.selectAll(_:))))
            }
            if name == "Window" {
                menu.addItem(standard("window.minimize", #selector(NSWindow.performMiniaturize(_:))))
                menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
                menu.addItem(standard("window.fullScreen", #selector(NSWindow.toggleFullScreen(_:))))
                NSApp.windowsMenu = menu
            }
            add(menu, title: name, to: main)
        }
        return main
    }

    /// The command's item, then a hidden item per alias (⌃⇥ for ⇧⌘]) so its keys work
    /// without cluttering the menu. A command kept out of the menu gets only hidden items.
    private static func items(for command: Command) -> [NSMenuItem] {
        var keys: [KeyBinding?] = command.bindings
        if command.inMenu && keys.isEmpty { keys = [nil] }
        return keys.enumerated().map { i, binding in
            let item = NSMenuItem(title: command.title, action: #selector(CommandRunner.run(_:)), keyEquivalent: binding?.key ?? "")
            item.keyEquivalentModifierMask = binding?.modifiers ?? []
            item.target = CommandRunner.shared
            item.representedObject = command
            if i > 0 || !command.inMenu {
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            return item
        }
    }

    /// One of AppKit's standard items, with its key from the registry.
    private static func standard(_ id: String, _ action: Selector) -> NSMenuItem {
        let binding = ShortcutRegistry.primary(id)
        let item = NSMenuItem(title: ShortcutRegistry.spec(id)?.title ?? id, action: action, keyEquivalent: binding?.key ?? "")
        item.keyEquivalentModifierMask = binding?.modifiers ?? []
        return item
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
