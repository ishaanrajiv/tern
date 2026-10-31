import AppKit

/// One row of the palette's settings mode: a value to step through, a switch, a stepper, the way
/// into the theme list, or a command. Values are read and written where the Settings window
/// keeps them, so both always agree.
struct QuickSetting: Identifiable {
    enum Control {
        /// ←/→ step through the options; ↩ moves to the next.
        case choice([(value: String, label: String)], get: () -> String, set: (String) -> Void)
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case stepper(get: () -> Double, set: (Double) -> Void, range: ClosedRange<Double>, unit: String)
        /// ↩ opens the theme list.
        case themes
        /// ↩ closes the palette and runs it.
        case action(shortcut: String, run: () -> Void)
    }

    let section: String
    let title: String
    let symbol: String
    let control: Control
    var id: String { title }

    /// What the row shows on its right.
    var valueLabel: String {
        switch control {
        case .choice(let options, let get, _):
            let value = get()
            return options.first { $0.value == value }?.label ?? value
        case .toggle(let get, _): return get() ? "On" : "Off"
        case .stepper(let get, _, _, let unit): return "\(Int(get())) \(unit)"
        case .themes: return QuickSetting.themes.first { $0.id == ThemeStore.selectedID }?.name ?? ThemeStore.selectedID
        case .action(let shortcut, _): return shortcut
        }
    }

    /// Steps a choice or stepper by `delta`. False for rows that don't step.
    func step(_ delta: Int) -> Bool {
        switch control {
        case .choice(let options, let get, let set):
            guard !options.isEmpty else { return false }
            let i = options.firstIndex { $0.value == get() } ?? 0
            set(options[(i + delta + options.count) % options.count].value)
            return true
        case .stepper(let get, let set, let range, _):
            let next = min(max(get() + Double(delta), range.lowerBound), range.upperBound)
            if next != get() { set(next) }
            return true
        case .toggle, .themes, .action:
            return false
        }
    }

    /// Theme ids and names, in the order the theme list shows them.
    static var themes: [(id: String, name: String, theme: Theme?)] {
        Theme.builtIn.map { ($0.id, $0.name, $0) } + [("ghostty", "Ghostty Colours", nil)]
    }

    /// Everything the palette offers, by section.
    static func all(openSettings: @escaping () -> Void, settingsShortcut: String) -> [QuickSetting] {
        [
            QuickSetting(section: "Appearance", title: "Theme", symbol: "paintpalette", control: .themes),
            QuickSetting(section: "Appearance", title: "Working indicator", symbol: "rays",
                         control: defaults(Prefs.workingIndicator, [(WorkingIndicator.trailing.rawValue, "Spinner"),
                                                                    (WorkingIndicator.turning.rawValue, "Turning logo")])),
            QuickSetting(section: "Terminal", title: "Text size", symbol: "textformat.size",
                         control: .stepper(get: { TerminalPreferences.current.size },
                                           set: { size in terminal { $0.size = size } }, range: 8...32, unit: "pt")),
            QuickSetting(section: "Terminal", title: "Cursor", symbol: "character.cursor.ibeam",
                         control: .choice([("block", "Block"), ("bar", "Bar"), ("underline", "Underline"), ("block_hollow", "Hollow")],
                                          get: { TerminalPreferences.current.cursor },
                                          set: { cursor in terminal { $0.cursor = cursor } })),
            QuickSetting(section: "Terminal", title: "Option as Alt", symbol: "option",
                         control: .choice([("false", "Off"), ("true", "Both"), ("left", "Left"), ("right", "Right")],
                                          get: { TerminalPreferences.current.option },
                                          set: { option in terminal { $0.option = option } })),
            QuickSetting(section: "Agents", title: "Notify when an agent needs you", symbol: "bell.badge",
                         control: toggle(Prefs.notifyNeedsYou)),
            QuickSetting(section: "Agents", title: "Notify when an agent finishes", symbol: "bell",
                         control: toggle(Prefs.notifyDone)),
            QuickSetting(section: "Agents", title: "Resume agents after a reboot", symbol: "arrow.clockwise",
                         control: toggle(Prefs.resumeAgents)),
            QuickSetting(section: "General", title: "Folder order", symbol: "list.bullet",
                         control: defaults(Prefs.folderOrder, [(FolderOrder.manual.rawValue, "As opened"),
                                                               (FolderOrder.recent.rawValue, "Recent first")])),
            QuickSetting(section: "General", title: "New tabs use worktrees", symbol: "arrow.triangle.branch",
                         control: toggle(Prefs.worktrees)),
            QuickSetting(section: "General", title: "Open file links with", symbol: "doc.text",
                         control: defaults(Prefs.fileEditor, [("system", "Default app"), ("vscode", "VS Code"),
                                                          ("cursor", "Cursor"), ("zed", "Zed")])),
            QuickSetting(section: "General", title: "All settings…", symbol: "gearshape",
                         control: .action(shortcut: settingsShortcut, run: openSettings)),
        ]
    }

    private static func defaults(_ key: String, _ options: [(value: String, label: String)]) -> Control {
        .choice(options, get: { Prefs.defaults.string(forKey: key) ?? options[0].value },
                set: { Prefs.defaults.set($0, forKey: key) })
    }

    private static func toggle(_ key: String) -> Control {
        .toggle(get: { Prefs.defaults.bool(forKey: key) }, set: { Prefs.defaults.set($0, forKey: key) })
    }

    /// Changes the terminal settings file, as the Settings window does. A value the palette offers
    /// always validates, so a failure here is left for the Settings window to explain.
    private static func terminal(_ change: (inout TerminalPreferences) -> Void) {
        var preferences = TerminalPreferences.current
        change(&preferences)
        try? preferences.save()
    }
}
