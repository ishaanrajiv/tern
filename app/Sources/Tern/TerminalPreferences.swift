import AppKit
import SwiftUI
import GhosttyKit

/// The terminal's settings, kept in the config file under Ghostty's own names (`font-size`,
/// `keybind`…), plus `shortcut` lines for app shortcuts. Only the keys the file gives override
/// your Ghostty config.
struct TerminalPreferences: Codable, Equatable {
    var font = ""
    var size = 13.0
    var scrollback = 10_000_000
    var cursor = "block"
    var option = "false"
    var bindings = ""
    var shortcuts = ""

    private(set) static var current = Self()
    /// The keys the config file sets, which are the ones passed on to Ghostty.
    private(set) static var given: Set<String> = []
    /// Where older terns kept these settings; read once, to migrate them.
    static var legacyURL: URL { Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("terminal-settings.json") }
    static let didChange = Notification.Name("tern.terminalSettingsChanged")
    static let configKeys = ["font-family", "font-size", "scrollback-limit", "cursor-style", "macos-option-as-alt", "keybind", "shortcut"]
    private static let cursors = ["block", "bar", "underline", "block_hollow"]
    private static let options = ["false", "true", "left", "right"]

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// As config lines, by key.
    var entries: [(key: String, values: [String])] {
        [("font-family", font.isEmpty ? [] : [font]),
         ("font-size", [size == size.rounded() && abs(size) < 1e6 ? String(Int(size)) : String(size)]),
         ("scrollback-limit", [String(scrollback)]),
         ("cursor-style", [cursor]),
         ("macos-option-as-alt", [option]),
         ("keybind", Self.lines(bindings)),
         ("shortcut", Self.lines(shortcuts))]
    }

    /// Ghostty config lines for `keys`.
    func ghostty(_ keys: Set<String>) -> String {
        entries.filter { $0.key != "shortcut" && keys.contains($0.key) }
            .flatMap { entry in entry.values.map { "\(entry.key) = \($0)" } }
            .joined(separator: "\n") + "\n"
    }

    var config: String { ghostty(Set(Self.configKeys)) }

    /// Changes the config file. Applying it, as for an edit to the file, updates the terminals.
    func save() throws {
        guard size.isFinite, (6...72).contains(size), (100_000...1_000_000_000).contains(scrollback),
              !font.contains(where: { $0.isNewline }), Self.cursors.contains(cursor), Self.options.contains(option) else {
            throw PreferencesError.invalid("Check the font size, scrollback limit, and font name.")
        }
        if let problem = ShortcutRegistry.resolve(shortcuts).problems.first { throw PreferencesError.invalid(problem) }
        if let problem = Self.ghosttyProblems(config) { throw PreferencesError.invalid(problem) }
        try ConfigStore.shared.write { file in
            for entry in entries { file.set(entry.key, entry.values) }
        }
    }

    /// What Ghostty says is wrong with these config lines, if anything.
    private static func ghosttyProblems(_ text: String) -> String? {
        let candidate = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("terminal-settings-check")
        guard (try? text.write(to: candidate, atomically: true, encoding: .utf8)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: candidate) }
        let c = ghostty_config_new()
        defer { ghostty_config_free(c) }
        candidate.path.withCString { ghostty_config_load_file(c, $0) }
        ghostty_config_finalize(c)
        let count = ghostty_config_diagnostics_count(c)
        guard count > 0 else { return nil }
        return (0..<count).compactMap { ghostty_config_get_diagnostic(c, $0).message.map { String(cString: $0) } }.joined(separator: "\n")
    }

    /// Takes the terminal settings from the config file. A bad value keeps the last good one;
    /// `check` asks Ghostty about changed key bindings too, once it's running.
    static func apply(_ file: ConfigText, check: Bool, problems: inout [String]) {
        let defaults = Self()
        var next = current
        var given: Set<String> = []
        func scalar(_ key: String, _ read: (String) -> Bool, reset: () -> Void, rule: String) {
            guard let value = file.all(key).last else { return reset() }
            given.insert(key)
            if !read(value) { problems.append("Line \(file.line(of: key) ?? 0): \(key) \(rule), not \(value). Keeping the last good value.") }
        }
        scalar("font-family", { next.font = $0; return true }, reset: { next.font = defaults.font }, rule: "is a font name")
        scalar("font-size", { v in
            guard let size = Double(v), size.isFinite, (6...72).contains(size) else { return false }
            next.size = size
            return true
        },
               reset: { next.size = defaults.size }, rule: "is a size from 6 to 72")
        scalar("scrollback-limit", { v in
            guard let bytes = Int(v), (100_000...1_000_000_000).contains(bytes) else { return false }
            next.scrollback = bytes
            return true
        },
               reset: { next.scrollback = defaults.scrollback }, rule: "is a number of bytes from 100000 to 1000000000")
        scalar("cursor-style", { v in
            guard cursors.contains(v) else { return false }
            next.cursor = v
            return true
        },
               reset: { next.cursor = defaults.cursor }, rule: "is one of \(cursors.joined(separator: ", "))")
        scalar("macos-option-as-alt", { v in
            guard options.contains(v) else { return false }
            next.option = v
            return true
        },
               reset: { next.option = defaults.option }, rule: "is one of \(options.joined(separator: ", "))")
        let bindings = file.all("keybind")
        if !bindings.isEmpty { given.insert("keybind") }
        next.bindings = bindings.joined(separator: "\n")
        if check, next.bindings != current.bindings,
           let problem = ghosttyProblems(next.ghostty(["keybind"])) {
            problems.append("Ghostty can't use a keybind line, so the last good ones stay: \(problem)")
            next.bindings = current.bindings
        }
        next.shortcuts = file.all("shortcut").joined(separator: "\n")
        problems += ShortcutRegistry.resolve(next.shortcuts).problems.map { "shortcut: \($0)" }

        guard next != current || given != Self.given else { return }
        let scrollback = current.scrollback
        current = next
        Self.given = given
        if next.scrollback != scrollback { TernClient.setScrollback(next.scrollback) }
        ShortcutRegistry.reload()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Moves settings an older tern saved into the config file, unless it already sets them.
    static func migrate(from url: URL, into file: inout ConfigText) {
        guard let data = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(Self.self, from: data) else { return }
        for entry in old.entries where !file.has(entry.key) { file.set(entry.key, entry.values) }
    }

    enum PreferencesError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let text): text } }
    }
}

struct TerminalSettings: View {
    private enum Page: String, CaseIterable, Identifiable {
        case text = "Text & input"
        case shortcuts = "App shortcuts"
        case bindings = "Terminal bindings"
        var id: Self { self }
    }

    @State private var draft = TerminalPreferences.current
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
                         ? "Use command palette titles; none removes a shortcut. App shortcuts take priority."
                         : "Use Ghostty key binding syntax, one binding per line.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(page == .shortcuts ? "New Tab = cmd+shift+y\nMove Tab Later = none" : "ctrl+shift+c=copy_to_clipboard")
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
        // An edit to the config file shows here.
        .onReceive(NotificationCenter.default.publisher(for: TerminalPreferences.didChange)) { _ in draft = TerminalPreferences.current }
        .settingsPane()
    }
}
