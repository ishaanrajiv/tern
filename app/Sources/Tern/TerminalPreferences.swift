import AppKit
import SwiftUI
import GhosttyKit

struct TerminalPreferences: Codable, Equatable {
    var font = ""
    var size = 13.0
    var scrollback = 10_000_000
    var cursor = "block"
    var option = "false"
    var bindings = ""
    var shortcuts = ""

    static var current = load()
    static var url: URL { Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("terminal-settings.json") }
    static let didChange = Notification.Name("tern.terminalSettingsChanged")
    static func load() -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    var config: String {
        var lines = ["font-size = \(size)", "scrollback-limit = \(scrollback)", "cursor-style = \(cursor)", "macos-option-as-alt = \(option)"]
        if !font.isEmpty { lines.append("font-family = \(font)") }
        lines += bindings.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { "keybind = \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }
    func save() throws {
        guard size.isFinite, (6...72).contains(size), (100_000...1_000_000_000).contains(scrollback),
              !font.contains(where: { $0.isNewline }), ["block", "bar", "underline", "block_hollow"].contains(cursor),
              ["false", "true", "left", "right"].contains(option) else {
            throw PreferencesError.invalid("Check the font size, scrollback limit, and font name.")
        }
        let custom = try Self.parseShortcuts(shortcuts)
        for title in custom.keys where Command.defaults[title] == nil {
            throw PreferencesError.invalid("Unknown app command: \(title). Copy its exact title from the palette.")
        }
        var effective: [String: Shortcut] = Command.defaults
        for (title, shortcut) in custom { effective[title] = shortcut }
        let reserved: [Shortcut] = [Shortcut(key: "c", modifiers: .command), Shortcut(key: "v", modifiers: .command), Shortcut(key: "a", modifiers: .command), Shortcut(key: "q", modifiers: .command), Shortcut(key: "h", modifiers: .command), Shortcut(key: "m", modifiers: .command), Shortcut(key: "k", modifiers: .command)]
        for (title, shortcut) in custom {
            if ("123456789".contains(shortcut.key) && (shortcut.modifiers == .command || shortcut.modifiers == [.command, .shift])) {
                throw PreferencesError.invalid("Folder and tab number shortcuts are reserved.")
            }
            if reserved.contains(where: { $0.key == shortcut.key && $0.modifiers == shortcut.modifiers }) || effective.contains(where: { $0.key != title && $0.value.key == shortcut.key && $0.value.modifiers == shortcut.modifiers }) {
                throw PreferencesError.invalid("Shortcut for \(title) conflicts with another command.")
            }
        }
        let candidate = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("terminal-settings-check")
        try config.write(to: candidate, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: candidate) }
        let c = ghostty_config_new()
        defer { ghostty_config_free(c) }
        candidate.path.withCString { ghostty_config_load_file(c, $0) }
        ghostty_config_finalize(c)
        let count = ghostty_config_diagnostics_count(c)
        if count > 0 {
            let message = (0..<count).compactMap { ghostty_config_get_diagnostic(c, $0).message.map { String(cString: $0) } }.joined(separator: "\n")
            throw PreferencesError.invalid(message)
        }
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        Self.current = self
        TernClient.setScrollback(scrollback)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    enum PreferencesError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let text): text } }
    }
    struct Shortcut {
        var key: String
        var modifiers: NSEvent.ModifierFlags
    }
    static func parseShortcuts(_ text: String) throws -> [String: Shortcut] {
        var result: [String: Shortcut] = [:]
        var used = Set<String>()
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty else { throw PreferencesError.invalid("Use Command title = cmd+shift+x, one per line.") }
            let tokens = pair[1].lowercased().split(separator: "+").map(String.init)
            guard let key = tokens.last, key.count == 1 else { throw PreferencesError.invalid("Shortcut keys must be a single character.") }
            var mods: NSEvent.ModifierFlags = []
            for token in tokens.dropLast() {
                switch token {
                case "cmd": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "alt": mods.insert(.option)
                case "ctrl": mods.insert(.control)
                default: throw PreferencesError.invalid("Unknown modifier: \(token)")
                }
            }
            guard !mods.isEmpty, used.insert("\(mods.rawValue):\(key)").inserted, result[pair[0]] == nil else {
                throw PreferencesError.invalid("Shortcuts need a modifier and cannot repeat a key or command.")
            }
            result[pair[0]] = Shortcut(key: key, modifiers: mods)
        }
        return result
    }
}

struct TerminalSettings: View {
    private enum Page: String, CaseIterable, Identifiable {
        case text = "Text & input"
        case shortcuts = "App shortcuts"
        case bindings = "Terminal bindings"
        var id: Self { self }
    }

    @State private var draft = TerminalPreferences.load()
    @State private var page = Page.text
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Terminal settings", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)

            if page == .text {
                Form {
                    Section("Text") {
                        TextField("Font family", text: $draft.font, prompt: Text("Ghostty default"))
                        TextField("Font size", value: $draft.size, format: .number)
                        Picker("Cursor", selection: $draft.cursor) {
                            Text("Block").tag("block")
                            Text("Bar").tag("bar")
                            Text("Underline").tag("underline")
                            Text("Hollow block").tag("block_hollow")
                        }
                    }
                    Section("Input and history") {
                        Picker("Option as Alt", selection: $draft.option) {
                            Text("Off").tag("false")
                            Text("Both keys").tag("true")
                            Text("Left only").tag("left")
                            Text("Right only").tag("right")
                        }
                        TextField("Scrollback bytes", value: $draft.scrollback, format: .number)
                            .help("Limits retained history in bytes in both the terminal and daemon. Reducing it discards older output.")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(page == .shortcuts
                         ? "Use exact command palette titles. App shortcuts take priority."
                         : "Use Ghostty key binding syntax, one binding per line.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(page == .shortcuts ? "New Tab = cmd+shift+y" : "ctrl+shift+c=copy_to_clipboard")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    TextEditor(text: page == .shortcuts ? $draft.shortcuts : $draft.bindings)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .accessibilityLabel(page.rawValue)
                    Text("Changes apply when you click Save and Apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !message.isEmpty {
                    ScrollView {
                        Text(message).font(.caption)
                            .foregroundStyle(failed ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: failed ? 42 : 16)
                }
                HStack {
                    Button("Reload Ghostty Config") {
                        GhosttyApp.shared.applyTheme()
                        failed = !GhosttyApp.shared.diagnostics.isEmpty
                        message = failed ? GhosttyApp.shared.diagnostics : "Reloaded."
                    }
                    Spacer()
                    Button("Save and Apply") {
                        do { try draft.save(); failed = false; message = "Applied." }
                        catch { failed = true; message = error.localizedDescription }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .settingsPane()
    }
}
