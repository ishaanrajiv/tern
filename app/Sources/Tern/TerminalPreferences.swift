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
        if let problem = ShortcutRegistry.resolve(shortcuts).problems.first { throw PreferencesError.invalid(problem) }
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
        ShortcutRegistry.reload()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
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
        .settingsPane()
    }
}
