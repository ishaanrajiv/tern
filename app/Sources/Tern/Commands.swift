import AppKit

/// One user-facing action. The menu bar and the ⌘K palette are both built from
/// the same list, so every shortcut is discoverable in both places.
final class Command {
    let title: String
    let menu: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    /// Shown in the palette but not the menu (or the reverse, for aliases).
    let inMenu: Bool
    let inPalette: Bool
    let action: () -> Void

    init(_ title: String, menu: String, key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
         inMenu: Bool = true, inPalette: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.menu = menu
        self.key = key
        self.modifiers = modifiers
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
        if t.hasPrefix("Settings") { return "gearshape" }
        if t.hasPrefix("Toggle Sidebar") { return "sidebar.left" }
        if t.hasPrefix("Zoom") { return "arrow.up.left.and.arrow.down.right" }
        if t.contains("Text") || t.hasPrefix("Actual Size") { return "textformat.size" }
        if t.hasPrefix("Next Needing") { return "bell" }
        if t.hasPrefix("Focus") { return "rectangle.inset.filled" }
        return "arrow.right"
    }

    /// "⌥⌘←" style label.
    var shortcutLabel: String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let keyLabel: String = switch key {
        case Key.left: "←"
        case Key.right: "→"
        case Key.up: "↑"
        case Key.down: "↓"
        case "\r": "↩"
        case "\t": "⇥"
        default: key.uppercased()
        }
        return s + keyLabel
    }
}

enum Key {
    static let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
}

/// Routes menu items to their Command.
final class CommandRunner: NSObject {
    static let shared = CommandRunner()

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Command)?.action()
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
            let item = NSMenuItem(title: command.title, action: #selector(CommandRunner.run(_:)), keyEquivalent: command.key)
            item.keyEquivalentModifierMask = command.modifiers
            item.target = CommandRunner.shared
            item.representedObject = command
            appMenu.addItem(item)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide tern", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit tern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "tern", to: main)

        for name in order {
            let menu = NSMenu(title: name)
            var lastGroup: String?
            for command in commands where command.menu == name {
                // Separate runs of related items: Next…/Previous…, Folder N, Tab N, Focus…
                let group = command.title.components(separatedBy: " ").first.map { $0 == "Previous" ? "Next" : $0 }
                if let lastGroup, lastGroup != group, name == "Navigate" { menu.addItem(.separator()) }
                lastGroup = group
                let item = NSMenuItem(title: command.title, action: #selector(CommandRunner.run(_:)), keyEquivalent: command.key)
                item.keyEquivalentModifierMask = command.modifiers
                item.target = CommandRunner.shared
                item.representedObject = command
                if !command.inMenu {
                    // Alias shortcuts (⌃⇥ for ⌘⇧]) work without cluttering the menu.
                    item.isHidden = true
                    item.allowsKeyEquivalentWhenHidden = true
                }
                menu.addItem(item)
            }
            if name == "Edit" {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
                menu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
                menu.addItem(withTitle: "Select All", action: #selector(TerminalView.selectAll(_:)), keyEquivalent: "a")
            }
            if name == "Window" {
                menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
                menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
                menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
                    .keyEquivalentModifierMask = [.command, .control]
                NSApp.windowsMenu = menu
            }
            add(menu, title: name, to: main)
        }
        return main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
