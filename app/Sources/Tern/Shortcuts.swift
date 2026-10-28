import AppKit

/// A key and its modifiers, as a menu key equivalent takes them.
struct KeyBinding: Hashable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    /// A shifted character becomes its key plus ⇧, so ⌘} and ⇧⌘] (or ⌘Y and ⇧⌘Y) are one
    /// binding, as AppKit matches them.
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        var key = key
        var modifiers = modifiers.intersection([.command, .shift, .option, .control])
        if key.count == 1, let c = key.first {
            if let base = Self.shifted[c] {
                key = String(base)
                modifiers.insert(.shift)
            } else if c.isUppercase {
                key = key.lowercased()
                modifiers.insert(.shift)
            }
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// Shifted characters and the key that types them, on the US layout menu key equivalents assume.
    static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.modifiers == b.modifiers }
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    /// Keys that aren't a printable character: config name, menu character, label.
    static let named: [(name: String, key: String, symbol: String)] = [
        ("left", Key.left, "←"), ("right", Key.right, "→"), ("up", Key.up, "↑"), ("down", Key.down, "↓"),
        ("return", "\r", "↩"), ("tab", "\t", "⇥"), ("space", " ", "Space"), ("escape", "\u{1b}", "⎋"),
    ]

    /// "⌥⌘←", in the menu bar's modifier order.
    var label: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.named.first { $0.key == key }?.symbol ?? key.uppercased())
    }

    /// "cmd+alt+left", as overrides are written.
    var config: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [Self.named.first { $0.key == key }?.name ?? key]).joined(separator: "+")
    }

    /// Reads "cmd+shift+]" or "ctrl+tab".
    init(parsing text: String) throws {
        // Case matters only for the key: "cmd+Y" is ⇧⌘Y.
        var tokens = text.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "cmd++": the key is the plus sign.
        if tokens.count > 2, tokens.suffix(2) == ["", ""] { tokens.removeLast(2); tokens.append("+") }
        guard let last = tokens.last, tokens.count > 1 else {
            throw ShortcutRegistry.Problem("Write shortcuts as modifiers and a key, like cmd+shift+x.")
        }
        guard let key = last.count == 1 ? last : Self.named.first(where: { $0.name == last.lowercased() })?.key else {
            throw ShortcutRegistry.Problem("Unknown key: \(last). Use one character, or left, right, up, down, return, tab.")
        }
        var mods: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            switch token.lowercased() {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "alt", "opt", "option": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: throw ShortcutRegistry.Problem("Unknown modifier: \(token)")
            }
        }
        self.init(key, mods)
    }
}

enum Key {
    static let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
}

/// One shortcut's declaration. `id` is stable: overrides and the debug harness use it,
/// so a title can change without breaking anyone's settings.
struct ShortcutSpec {
    enum Category: String, CaseIterable {
        case app = "App", folders = "Folders", tabs = "Tabs", panes = "Panes", search = "Search"
        case terminal = "Terminal", view = "View", standard = "Standard"
    }

    let id: String
    let title: String
    let category: Category
    let menu: String
    /// The first is shown in the menu and palette; the rest are hidden aliases.
    let defaults: [KeyBinding]
    var inMenu = true
    var inPalette = true
    /// AppKit's standard items (Copy, Quit…): listed so nothing else takes their keys.
    var locked = false
    /// Held for a command another change adds; no menu item or docs until then.
    var reserved = false
    /// A system-wide hotkey rather than a menu item: it may leave out ⌘.
    var global = false
}

/// Every app shortcut, declared once. The menu bar, the palette, the sidebar's number hints
/// and the README's Keys table read from here. Users override bindings in
/// Settings → Terminal → App shortcuts (`TerminalPreferences.shortcuts`), one `id or title = keys`
/// per line; `none` removes a shortcut.
///
/// Rules every binding follows, defaults and overrides alike:
/// - it includes ⌘ (⌃⇥ aside), so ⌃ and ⌥ keys always reach the terminal and the agents in it;
/// - it isn't ⇧ with a digit, which macOS takes for screenshots and keyboard layouts remap;
/// - it isn't one of macOS's own shortcuts (`system`) or another command's.
enum ShortcutRegistry {
    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func spec(_ id: String, _ title: String, _ category: ShortcutSpec.Category, _ menu: String,
                             _ defaults: KeyBinding..., inMenu: Bool = true, inPalette: Bool = true,
                             locked: Bool = false, reserved: Bool = false, global: Bool = false) -> ShortcutSpec {
        ShortcutSpec(id: id, title: title, category: category, menu: menu, defaults: defaults,
                     inMenu: inMenu, inPalette: inPalette, locked: locked, reserved: reserved, global: global)
    }

    private static let cmd: NSEvent.ModifierFlags = .command
    private static let shiftCmd: NSEvent.ModifierFlags = [.shift, .command]
    private static let optCmd: NSEvent.ModifierFlags = [.option, .command]
    private static let ctrlCmd: NSEvent.ModifierFlags = [.control, .command]

    /// Modifier grammar: [ and ] go back and forward, through panes with ⌘, tabs with ⇧⌘ and
    /// folders with ⌥⌘; adding ⌃ moves the pane or tab instead. ⌥⌘ arrows move focus, ⌃⌘ arrows
    /// resize. ⇧ reverses or widens a ⌘ shortcut (⌘G / ⇧⌘G, ⌘C / ⇧⌘C), and ⌥ gives a variant
    /// (⌘V / ⌥⌘V, ⌘F / ⌥⌘F).
    static let specs: [ShortcutSpec] = [
        spec("app.settings", "Settings…", .app, "tern", KeyBinding(",", cmd)),
        spec("settings.quick", "Quick Settings…", .app, "tern", KeyBinding(",", shiftCmd)),
        spec("app.secureKeyboard", "Secure Keyboard Entry", .app, "tern"),
        spec("app.checkUpdates", "Check for Tern Updates…", .app, "tern"),
        spec("app.reloadConfig", "Reload Configuration", .app, "tern"),
        spec("daemon.restart", "Restart ternd", .app, "tern"),
        spec("app.hide", "Hide tern", .standard, "tern", KeyBinding("h", cmd), locked: true),
        spec("app.quit", "Quit tern", .standard, "tern", KeyBinding("q", cmd), locked: true),

        // Opt-in in Settings → General; TerminalHotkey registers it with the system.
        spec("app.globalHotkey", "Show or Hide tern", .app, "", KeyBinding(" ", [.control, .option]),
             inMenu: false, inPalette: false, global: true),

        spec("window.new", "New Window", .app, "File", KeyBinding("n", shiftCmd)),
        spec("folder.open", "Open Folder…", .folders, "File", KeyBinding("n", cmd)),
        spec("folder.presets", "Project Launch Presets…", .folders, "File"),
        spec("remote.ssh", "Connect over SSH…", .folders, "File", KeyBinding("k", shiftCmd)),
        spec("tab.new", "New Tab", .tabs, "File", KeyBinding("t", cmd)),
        spec("tab.newAtRoot", "New Tab at Project Root", .tabs, "File"),
        spec("tab.newWorktree", "New Tab in Worktree", .tabs, "File", KeyBinding("t", optCmd)),
        spec("tab.detach", "Detach Tab", .tabs, "File"),
        spec("tab.detached", "Detached Sessions…", .tabs, "File"),
        spec("tab.reopen", "Reopen Closed Tab", .tabs, "File", KeyBinding("t", shiftCmd)),
        spec("output.export", "Export Scrollback…", .terminal, "File", KeyBinding("s", shiftCmd)),
        spec("folder.browse", "Browse for Folder…", .folders, "File", KeyBinding("o", cmd)),
        spec("pane.splitRight", "Split Right", .panes, "File", KeyBinding("d", cmd)),
        spec("pane.splitDown", "Split Down", .panes, "File", KeyBinding("d", shiftCmd)),
        spec("tab.rename", "Rename Tab…", .tabs, "File", KeyBinding("r", cmd)),
        spec("pane.close", "Close Pane", .panes, "File", KeyBinding("w", cmd)),
        spec("tab.close", "Close Tab", .tabs, "File", KeyBinding("w", shiftCmd)),
        spec("folder.close", "Close Folder", .folders, "File", KeyBinding("w", optCmd)),

        spec("edit.pasteImagePath", "Paste Image as File Path", .terminal, "Edit", KeyBinding("v", optCmd)),
        spec("file.openSelected", "Open Selected File in Editor", .terminal, "Edit", KeyBinding("o", shiftCmd)),
        spec("output.copyLast", "Copy Last Command Output", .terminal, "Edit", KeyBinding("c", shiftCmd)),
        spec("output.selectLast", "Select Last Command Output…", .terminal, "Edit"),
        spec("search.advanced", "Advanced Find…", .search, "Edit", KeyBinding("f", optCmd)),
        spec("search.all", "Search All Terminal Output…", .search, "Edit", KeyBinding("f", shiftCmd)),
        spec("search.find", "Find…", .search, "Edit", KeyBinding("f", cmd)),
        spec("search.next", "Find Next", .search, "Edit", KeyBinding("g", cmd)),
        spec("search.previous", "Find Previous", .search, "Edit", KeyBinding("g", shiftCmd)),
        spec("search.useSelection", "Use Selection for Find", .search, "Edit", KeyBinding("e", cmd)),
        spec("terminal.clear", "Clear Screen", .terminal, "Edit", KeyBinding("k", cmd)),
        spec("edit.undo", "Undo", .standard, "Edit", KeyBinding("z", cmd), locked: true),
        spec("edit.redo", "Redo", .standard, "Edit", KeyBinding("z", shiftCmd), locked: true),
        spec("edit.cut", "Cut", .standard, "Edit", KeyBinding("x", cmd), locked: true),
        spec("edit.copy", "Copy", .standard, "Edit", KeyBinding("c", cmd), locked: true),
        spec("edit.paste", "Paste", .standard, "Edit", KeyBinding("v", cmd), locked: true),
        spec("edit.selectAll", "Select All", .standard, "Edit", KeyBinding("a", cmd), locked: true),

        spec("palette.toggle", "Command Palette", .app, "View", KeyBinding("p", shiftCmd), inPalette: false),
        spec("view.sidebar", "Toggle Sidebar", .view, "View", KeyBinding("s", ctrlCmd), KeyBinding("\\", cmd)),
        spec("pane.swapPrevious", "Swap Pane with Previous", .panes, "View", KeyBinding("[", ctrlCmd)),
        spec("pane.swapNext", "Swap Pane with Next", .panes, "View", KeyBinding("]", ctrlCmd)),
        spec("pane.toNewTab", "Move Pane to New Tab", .panes, "View"),
        spec("pane.toNextTab", "Move Pane to Next Tab", .panes, "View"),
        spec("pane.equalize", "Equalize Panes", .panes, "View", KeyBinding("=", ctrlCmd)),
        spec("pane.widen", "Widen Pane", .panes, "View", KeyBinding(Key.right, ctrlCmd)),
        spec("pane.narrow", "Narrow Pane", .panes, "View", KeyBinding(Key.left, ctrlCmd)),
        spec("pane.taller", "Taller Pane", .panes, "View", KeyBinding(Key.up, ctrlCmd)),
        spec("pane.shorter", "Shorter Pane", .panes, "View", KeyBinding(Key.down, ctrlCmd)),
        // ⌘↩ also opens the folder picker's choice in a worktree.
        spec("pane.zoom", "Zoom Pane", .panes, "View", KeyBinding("\r", shiftCmd), KeyBinding("\r", cmd)),
        spec("text.bigger", "Bigger Text", .terminal, "View", KeyBinding("=", cmd)),
        spec("text.smaller", "Smaller Text", .terminal, "View", KeyBinding("-", cmd)),
        spec("text.reset", "Actual Size", .terminal, "View", KeyBinding("0", cmd)),

        spec("prompt.previous", "Previous Prompt", .terminal, "Navigate", KeyBinding(Key.up, shiftCmd)),
        spec("prompt.next", "Next Prompt", .terminal, "Navigate", KeyBinding(Key.down, shiftCmd)),
        spec("tab.moveEarlier", "Move Tab Earlier", .tabs, "Navigate", KeyBinding("[", [.control, .shift, .command])),
        spec("tab.moveLater", "Move Tab Later", .tabs, "Navigate", KeyBinding("]", [.control, .shift, .command])),
        spec("attention.next", "Next Needing Attention", .tabs, "Navigate", KeyBinding("j", cmd)),
        spec("attention.previous", "Previous Needing Attention", .tabs, "Navigate", KeyBinding("j", shiftCmd)),
        spec("tab.next", "Next Tab", .tabs, "Navigate", KeyBinding("]", shiftCmd), KeyBinding("\t", .control)),
        spec("tab.previous", "Previous Tab", .tabs, "Navigate", KeyBinding("[", shiftCmd), KeyBinding("\t", [.control, .shift])),
        spec("folder.next", "Next Folder", .folders, "Navigate", KeyBinding("]", optCmd)),
        spec("folder.previous", "Previous Folder", .folders, "Navigate", KeyBinding("[", optCmd)),
    ]
    + (1...9).map { spec("folder.select.\($0)", "Folder \($0)", .folders, "Navigate", KeyBinding("\($0)", cmd), inPalette: false) }
    + (1...9).map { spec("tab.select.\($0)", "Tab \($0)", .tabs, "Navigate", KeyBinding("\($0)", ctrlCmd), inPalette: false) }
    + [
        spec("pane.focusLeft", "Focus Pane Left", .panes, "Navigate", KeyBinding(Key.left, optCmd)),
        spec("pane.focusRight", "Focus Pane Right", .panes, "Navigate", KeyBinding(Key.right, optCmd)),
        spec("pane.focusUp", "Focus Pane Above", .panes, "Navigate", KeyBinding(Key.up, optCmd)),
        spec("pane.focusDown", "Focus Pane Below", .panes, "Navigate", KeyBinding(Key.down, optCmd)),
        spec("pane.next", "Focus Next Pane", .panes, "Navigate", KeyBinding("]", cmd)),
        spec("pane.previous", "Focus Previous Pane", .panes, "Navigate", KeyBinding("[", cmd)),

        spec("window.close", "Close Window", .app, "Window"),
        spec("tab.toNewWindow", "Move Tab to New Window", .tabs, "Window"),
        spec("tab.toNextWindow", "Move Tab to Next Window", .tabs, "Window"),
        spec("pane.toNewWindow", "Move Pane to New Window", .panes, "Window"),
        spec("window.minimize", "Minimize", .standard, "Window", KeyBinding("m", cmd), locked: true),
        spec("window.fullScreen", "Enter Full Screen", .standard, "Window", KeyBinding("f", ctrlCmd), locked: true),

        spec("help.shortcuts", "Keyboard Shortcuts", .app, "Help", KeyBinding("/", cmd)),
    ]

    /// Keys macOS or a window keeps for itself, which no command may take.
    static let system: [KeyBinding: String] = [
        KeyBinding("3", shiftCmd): "screenshot of the screen",
        KeyBinding("4", shiftCmd): "screenshot of a selection",
        KeyBinding("5", shiftCmd): "screenshot and recording options",
        KeyBinding("6", shiftCmd): "Touch Bar screenshot",
        KeyBinding(" ", cmd): "Spotlight",
        KeyBinding(" ", optCmd): "Finder search window",
        KeyBinding(" ", ctrlCmd): "Character Viewer",
        KeyBinding("\t", cmd): "app switcher",
        KeyBinding("`", cmd): "window cycling",
        KeyBinding("`", shiftCmd): "window cycling",
        KeyBinding("/", shiftCmd): "Help menu search",
        KeyBinding("\u{1b}", optCmd): "Force Quit",
        KeyBinding("q", ctrlCmd): "Lock Screen",
        KeyBinding("q", shiftCmd): "Log Out",
        KeyBinding("q", [.option, .shift, .command]): "Log Out",
        KeyBinding("d", optCmd): "Dock hiding",
        KeyBinding("d", ctrlCmd): "Look Up in Dictionary",
        KeyBinding("h", optCmd): "Hide Others",
        KeyBinding("m", optCmd): "Minimize All",
        KeyBinding("8", optCmd): "Zoom",
        KeyBinding("=", optCmd): "Zoom In",
        KeyBinding("-", optCmd): "Zoom Out",
        KeyBinding(".", cmd): "Cancel in dialogs",
        KeyBinding("s", cmd): "Save and Apply in Settings",
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
    private static let byTitle = Dictionary(specs.map { ($0.title, $0) }) { a, _ in a }
    static let defaults = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0.defaults) })

    static func spec(_ id: String) -> ShortcutSpec? { byID[id] }

    /// The bindings in effect: defaults with the user's valid overrides.
    private(set) static var bindings: [String: [KeyBinding]] = resolve(TerminalPreferences.current.shortcuts).bindings

    /// The binding shown for `id`, or nil when it has none.
    static func primary(_ id: String) -> KeyBinding? { bindings[id]?.first }
    static func label(_ id: String) -> String { primary(id)?.label ?? "" }

    /// Re-reads the user's overrides; ones that break a rule or clash are skipped and logged.
    static func reload() {
        let result = resolve(TerminalPreferences.current.shortcuts)
        bindings = result.bindings
        for problem in result.problems { NSLog("tern shortcuts: %@", problem) }
    }

    /// Why `binding` can't be an app shortcut (or, `global`, a system-wide hotkey), if it can't.
    static func ruleProblem(_ binding: KeyBinding, global: Bool = false) -> String? {
        if global, binding.modifiers.isEmpty {
            return "\(binding.label) needs a modifier: on its own the key would stop typing everywhere."
        }
        if global, TerminalHotkey.keyCodes[binding.key] == nil {
            return "\(binding.label) can't be a system-wide hotkey. Use a letter, digit, punctuation, Space, Return, Tab, Esc or an arrow."
        }
        if !global, !binding.modifiers.contains(.command) && !(binding.key == "\t" && binding.modifiers.contains(.control)) {
            return "\(binding.label) needs ⌘: keys without it belong to the terminal."
        }
        if binding.modifiers.contains(.shift), binding.key.count == 1, binding.key.first!.isNumber {
            return "\(binding.label) can't be used: ⇧ with a digit is a screenshot key and differs between keyboard layouts."
        }
        if let owner = system[binding] { return "\(binding.label) is macOS's \(owner) shortcut." }
        return nil
    }

    /// Every binding held by more than one command, with the ids holding it, in registry order.
    static func clashes(_ bindings: [String: [KeyBinding]]) -> [(binding: KeyBinding, ids: [String])] {
        var owners: [KeyBinding: [String]] = [:]
        var order: [KeyBinding] = []
        for spec in specs {
            for binding in bindings[spec.id] ?? [] {
                if owners[binding] == nil { order.append(binding) }
                owners[binding, default: []].append(spec.id)
            }
        }
        return order.compactMap { b in owners[b]!.count > 1 ? (b, owners[b]!) : nil }
    }

    /// Applies override text (`id or title = cmd+shift+x`, or `= none`, one per line) to the
    /// defaults. A line that's malformed, breaks a rule or clashes is left out, and says why.
    static func resolve(_ text: String) -> (bindings: [String: [KeyBinding]], problems: [String]) {
        var problems: [String] = []
        var overrides: [String: [KeyBinding]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else {
                problems.append("Write each shortcut as “command = cmd+shift+x”: \(line)")
                continue
            }
            guard let spec = byID[pair[0]] ?? byTitle[pair[0]], !spec.reserved else {
                problems.append("Unknown app command: \(pair[0]). Use its title from the palette.")
                continue
            }
            guard !spec.locked else {
                problems.append("\(spec.title) keeps its standard macOS shortcut.")
                continue
            }
            guard overrides[spec.id] == nil else {
                problems.append("\(spec.title) is set more than once.")
                continue
            }
            if pair[1].lowercased() == "none" {
                overrides[spec.id] = []
                continue
            }
            do {
                let binding = try KeyBinding(parsing: pair[1])
                if let rule = ruleProblem(binding, global: spec.global) {
                    problems.append("\(spec.title): \(rule)")
                } else {
                    overrides[spec.id] = [binding]
                }
            } catch {
                problems.append("\(spec.title): \(error.localizedDescription)")
            }
        }

        // The defaults never clash, so putting back clashing overrides ends clash-free.
        var result = defaults.merging(overrides) { $1 }
        while true {
            var reverted = false
            for (binding, ids) in clashes(result) {
                for id in ids where result[id] != defaults[id] {
                    let others = ids.filter { $0 != id }.compactMap { byID[$0]?.title }.joined(separator: ", ")
                    problems.append("\(byID[id]!.title): \(binding.label) is already used by \(others).")
                    result[id] = defaults[id]
                    reverted = true
                }
            }
            if !reverted { break }
        }
        return (result, problems)
    }

    // MARK: Docs

    /// The README's Keys table: each row's action and the ids whose default keys it lists.
    /// A trailing `*` stands for 1–9.
    static let docRows: [(action: String, ids: [String])] = [
        ("Command palette and session search across windows", ["palette.toggle"]),
        ("Next / previous tab needing attention", ["attention.next", "attention.previous"]),
        ("Open a folder / new window", ["folder.open", "window.new"]),
        ("Browse for a folder in Finder", ["folder.browse"]),
        ("Connect over SSH", ["remote.ssh"]),
        ("New tab / new tab in its own worktree", ["tab.new", "tab.newWorktree"]),
        ("Split right / split down", ["pane.splitRight", "pane.splitDown"]),
        ("Folder / tab within the folder", ["folder.select.*", "tab.select.*"]),
        ("Previous / next pane", ["pane.previous", "pane.next"]),
        ("Previous / next tab", ["tab.previous", "tab.next"]),
        ("Previous / next folder", ["folder.previous", "folder.next"]),
        ("Move focus between panes", ["pane.focusLeft", "pane.focusRight", "pane.focusUp", "pane.focusDown"]),
        ("Resize the focused pane", ["pane.narrow", "pane.widen", "pane.taller", "pane.shorter"]),
        ("Equalize panes", ["pane.equalize"]),
        ("Zoom the focused pane", ["pane.zoom"]),
        ("Swap pane with previous / next", ["pane.swapPrevious", "pane.swapNext"]),
        ("Move tab earlier / later", ["tab.moveEarlier", "tab.moveLater"]),
        ("Close pane / tab / folder", ["pane.close", "tab.close", "folder.close"]),
        ("Reopen closed tab", ["tab.reopen"]),
        ("Find, next / previous match", ["search.find", "search.next", "search.previous"]),
        ("Find the selection", ["search.useSelection"]),
        ("Advanced find / search output across sessions", ["search.advanced", "search.all"]),
        ("Copy the last command's output", ["output.copyLast"]),
        ("Export scrollback", ["output.export"]),
        ("Open the selected file in your editor", ["file.openSelected"]),
        ("Paste a clipboard image as a file path", ["edit.pasteImagePath"]),
        ("Previous / next prompt", ["prompt.previous", "prompt.next"]),
        ("Rename tab", ["tab.rename"]),
        ("Toggle sidebar", ["view.sidebar"]),
        ("Clear screen", ["terminal.clear"]),
        ("Text size", ["text.bigger", "text.smaller", "text.reset"]),
        ("Settings / quick settings", ["app.settings", "settings.quick"]),
        ("Keyboard shortcuts cheat sheet", ["help.shortcuts"]),
        ("Show or hide tern from any app, once enabled in Settings → General", ["app.globalHotkey"]),
    ]

    /// Labels for `id`'s keys: the one shown, then hidden aliases. A trailing `*` stands for 1–9.
    private static func keys(_ id: String, in bindings: [String: [KeyBinding]]) -> (primary: String?, aliases: [String]) {
        if id.hasSuffix(".*") {
            let base = id.dropLast(1)
            let all = (1...9).compactMap { bindings["\(base)\($0)"]?.first }
            guard all.count == 9, Set(all.map(\.modifiers.rawValue)).count == 1,
                  all.map(\.key) == (1...9).map(String.init) else {
                return (all.first.map { "\($0.label)…" }, [])
            }
            return (String(all[0].label.dropLast()) + "1–9", [])
        }
        let list = bindings[id] ?? []
        return (list.first?.label, list.dropFirst().map(\.label))
    }

    struct Section {
        struct Row: Hashable {
            let title: String
            let keys: [String]
        }
        let category: ShortcutSpec.Category
        let rows: [Row]
    }

    /// The cheat sheet's sections: every bound command by category, in registry order, with
    /// Folder 1–9 and Tab 1–9 on one row each. macOS's standard items are left out.
    static func cheatSheet(_ bindings: [String: [KeyBinding]] = bindings, globalHotkey: Bool = false) -> [Section] {
        ShortcutSpec.Category.allCases.filter { $0 != .standard }.compactMap { category -> Section? in
            var rows: [Section.Row] = []
            for spec in specs where spec.category == category && !spec.reserved && !spec.locked {
                if spec.global, !globalHotkey { continue }
                var id = spec.id, title = spec.title
                if id.hasPrefix("folder.select.") || id.hasPrefix("tab.select.") {
                    guard id.hasSuffix(".1") else { continue }
                    id = String(id.dropLast()) + "*"
                    title = String(title.dropLast(2)) + " by Number"
                }
                let found = keys(id, in: bindings)
                guard let primary = found.primary else { continue }
                rows.append(Section.Row(title: title, keys: [primary] + found.aliases))
            }
            return rows.isEmpty ? nil : Section(category: category, rows: rows)
        }
    }

    /// The Keys table for `bindings`, as Markdown.
    static func markdownTable(_ bindings: [String: [KeyBinding]] = defaults) -> String {
        let keys = { (id: String) in Self.keys(id, in: bindings) }
        var lines = ["| Keys | Action |", "|---|---|"]
        for row in docRows {
            let found = row.ids.map(keys)
            let primary = found.compactMap(\.primary)
            guard !primary.isEmpty else { continue }
            var text = primary.joined(separator: " / ")
            // Four arrows with the same modifiers read better as one phrase.
            if primary.count == 4, primary.allSatisfy({ ["←", "→", "↑", "↓"].contains($0.suffix(1)) }),
               Set(primary.map { $0.dropLast() }).count == 1 {
                text = "\(primary[0].dropLast()) + arrows"
            }
            let aliases = found.flatMap(\.aliases)
            if !aliases.isEmpty { text += ", " + aliases.joined(separator: " / ") }
            lines.append("| \(text) | \(row.action) |")
        }
        return lines.joined(separator: "\n")
    }
}
