import AppKit
import SwiftUI

/// Installs and inspects agent hooks through `tern hooks`, so the logic lives in one place.
@Observable
final class AgentHooks {
    struct Status: Decodable {
        let agent: String
        let installed: Bool
        let available: Bool
    }

    private(set) var statuses: [String: Status] = [:]
    private(set) var error: String?
    let ternBinary: String

    init(ternBinary: String) {
        self.ternBinary = ternBinary
        refresh()
    }

    var anyMissing: Bool { statuses.values.contains { $0.available && !$0.installed } }

    func refresh() {
        guard let out = run(["hooks", "status"]),
              let list = try? JSONDecoder().decode([Status].self, from: Data(out.utf8)) else { return }
        statuses = Dictionary(list.map { ($0.agent, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func set(_ agent: String, installed: Bool) {
        error = nil
        if run(["hooks", installed ? "install" : "uninstall", agent]) == nil {
            error = "Couldn't update \(agent == "claude" ? "Claude Code" : "Codex") hooks. See Console for details."
        }
        refresh()
    }

    /// Keeps the stable hook path pointing at this copy of tern, and updates hooks
    /// an older tern installed (never installs them where there were none).
    nonisolated func link() { _ = run(["hooks", "link"]) }

    @discardableResult
    nonisolated private func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ternBinary)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

// MARK: The settings, in one table

/// Settings' sections, in the sidebar's order. The raw value is the index saved between launches.
enum SettingsPane: Int, CaseIterable, Identifiable {
    case general, appearance, terminal, agents, devices, updates
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .agents: "Agents"
        case .devices: "Devices"
        case .updates: "Updates"
        }
    }
}

/// One setting as Settings shows it and search finds it.
struct SettingInfo: Identifiable {
    /// The config key when there is one; otherwise a name of its own.
    let id: String
    let pane: SettingsPane
    let title: String
    var caption: String?
    /// Shown under the row, in the config file's spelling.
    var key: String?
    /// Other words search should match.
    var terms = ""
}

/// Every row's title, explanation and config key, so the rows and search agree.
enum SettingsIndex {
    static var all: [SettingInfo] {
        [
            SettingInfo(id: "folder-order", pane: .general, title: "Folder order", key: "folder-order", terms: "sidebar sort recent"),
            SettingInfo(id: "repo-root", pane: .general, title: "Find repositories in", key: "repo-root", terms: "git folders open"),
            SettingInfo(id: "file-editor", pane: .general, title: "Open file links with", key: "file-editor",
                        terms: "editor vscode cursor zed click"),
            SettingInfo(id: "global-hotkey", pane: .general, title: "Show or hide tern with \(ShortcutRegistry.label("app.globalHotkey"))",
                        key: "global-hotkey", terms: "shortcut quick access hotkey"),
            SettingInfo(id: "notify-command-done", pane: .general, title: "Notify when a background command takes over 10 seconds",
                        key: "notify-command-done", terms: "notifications"),
            SettingInfo(id: "tab-worktrees", pane: .general, title: "New tabs use git worktrees",
                        caption: "\(ShortcutRegistry.label("tab.newWorktree")) always opens a worktree.", key: "tab-worktrees"),

            SettingInfo(id: "theme", pane: .appearance, title: "Theme", key: "theme", terms: "colours colors dark light mode ghostty"),
            SettingInfo(id: "working-indicator", pane: .appearance, title: "Working indicator", key: "working-indicator",
                        terms: "spinner logo sidebar"),

            SettingInfo(id: "font-family", pane: .terminal, title: "Font family", key: "font-family"),
            SettingInfo(id: "font-size", pane: .terminal, title: "Font size", key: "font-size", terms: "text"),
            SettingInfo(id: "cursor-style", pane: .terminal, title: "Cursor", key: "cursor-style"),
            SettingInfo(id: "macos-option-as-alt", pane: .terminal, title: "Option as Alt", key: "macos-option-as-alt", terms: "meta keyboard"),
            SettingInfo(id: "scrollback-limit", pane: .terminal, title: "Scrollback",
                        caption: "Bytes of history kept in the terminal and in ternd. Lowering it drops older output.",
                        key: "scrollback-limit", terms: "history"),
            SettingInfo(id: "shortcut", pane: .terminal, title: "App shortcuts", key: "shortcut", terms: "keys keyboard"),
            SettingInfo(id: "keybind", pane: .terminal, title: "Terminal bindings", key: "keybind", terms: "keys keyboard ghostty"),

            SettingInfo(id: "hooks", pane: .agents, title: "Claude Code and Codex hooks", terms: "integrations status"),
            SettingInfo(id: "notify-needs-you", pane: .agents, title: "An agent needs your input", key: "notify-needs-you",
                        terms: "notifications notify"),
            SettingInfo(id: "notify-done", pane: .agents, title: "An agent finishes", caption: "Only for sessions you aren't looking at.",
                        key: "notify-done", terms: "notifications notify"),
            SettingInfo(id: "resume-agents", pane: .agents, title: "Resume agents after a reboot",
                        caption: "Reopens the Claude Code or Codex conversation when its previous session is gone.", key: "resume-agents"),
            SettingInfo(id: "claude-account-usage", pane: .agents, title: "Read Claude account usage",
                        caption: "Reads Claude Code's sign-in from the Keychain, the way Claude Code does, and sends it to Anthropic every five minutes to fetch your usage limits. tern never refreshes the token. Off, limits still show while Claude Code runs in a tern tab with hooks set up.",
                        key: "claude-account-usage", terms: "limits keychain"),
            SettingInfo(id: "notify-ntfy", pane: .agents, title: "Push to my phone while I'm away",
                        caption: "An ntfy topic URL. ternd sends only a title, like “Claude Code needs you · api”, never what the agent asked.",
                        key: "notify-ntfy", terms: "notifications notify away phone"),
            SettingInfo(id: "away-after", pane: .agents, title: "Count me away after",
                        caption: "Without keyboard or mouse input, or with the screen locked, and tern not in front.",
                        key: "away-after", terms: "idle phone"),

            SettingInfo(id: "device", pane: .devices, title: "Devices", key: "device", terms: "ssh remote linux machine"),

            SettingInfo(id: "versions", pane: .updates, title: "Versions", terms: "ternd claude codex update restart"),
            SettingInfo(id: "check-app-updates", pane: .updates, title: "Check for updates automatically", key: "check-app-updates"),
            SettingInfo(id: "download-app-updates", pane: .updates, title: "Download updates in the background",
                        caption: "Checked against its checksum and Developer ID signature before it's offered.", key: "download-app-updates"),
            SettingInfo(id: "install-updates-on-quit", pane: .updates, title: "Install downloaded updates when tern quits",
                        caption: "Sessions keep running in ternd.", key: "install-updates-on-quit"),
            SettingInfo(id: "include-prereleases", pane: .updates, title: "Include alpha prereleases", key: "include-prereleases"),
            SettingInfo(id: "offer-agent-updates", pane: .updates, title: "Offer Claude Code and Codex updates",
                        caption: "They run out of sight; the console opens if one needs you or fails.", key: "offer-agent-updates"),
        ]
    }

    static subscript(id: String) -> SettingInfo {
        all.first { $0.id == id } ?? SettingInfo(id: id, pane: .general, title: id)
    }

    /// Rows whose title, key, section or other words contain every word typed.
    static func search(_ query: String) -> [SettingInfo] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return all.filter { info in
            let text = [info.title, info.key ?? "", info.pane.title, info.terms, info.caption ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

/// What Settings shows: the section, the search, and the row a result points at.
@Observable
final class SettingsModel {
    static let key = "settingsPane"
    /// Posted when Find is chosen with Settings in front.
    static let find = Notification.Name("tern.settingsFind")

    var pane: SettingsPane {
        didSet { Prefs.defaults.set(pane.rawValue, forKey: Self.key) }
    }
    var query = ""
    /// The row a search result went to, lit for a moment.
    var focus: String?
    var terminalPage = TerminalSettings.Page.text

    init() {
        pane = SettingsPane(rawValue: Prefs.defaults.integer(forKey: Self.key)) ?? .general
    }

    func go(to info: SettingInfo) {
        pane = info.pane
        if info.id == "shortcut" { terminalPage = .shortcuts }
        else if info.id == "keybind" { terminalPage = .bindings }
        else if info.pane == .terminal { terminalPage = .text }
        focus = nil
        // A turn later, so the section's rows exist to scroll to; the highlight fades after a moment.
        DispatchQueue.main.async { self.focus = info.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.focus == info.id { withAnimation(Motion.animation()) { self.focus = nil } }
        }
    }
}

// MARK: The window

struct SettingsRoot: View {
    let model: SettingsModel
    let hooks: AgentHooks
    let updates: UpdateCenter
    let usage: AgentUsage

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
            Rectangle().fill(Palette.border).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch model.pane {
                    case .general: GeneralSettings()
                    case .appearance: AppearanceSettings()
                    case .terminal: TerminalSettings(model: model)
                    case .agents: AgentSettings(hooks: hooks, updates: updates, usage: usage)
                    case .devices: DeviceSettings()
                    case .updates: UpdatesSettings(center: updates)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ConfigFooter()
            }
            .background(Palette.terminal)
        }
        .ignoresSafeArea()
        .environment(model)
        .toggleStyle(TernSwitchStyle())
        .buttonStyle(QuietButtonStyle())
        .tint(Palette.amber)
        .themedText()
        .frame(minWidth: 760, minHeight: 500)
    }
}

/// The sections, a search across them, and tern's name at the foot.
private struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let results = SettingsIndex.search(model.query)
        VStack(alignment: .leading, spacing: 2) {
            SearchField(text: $model.query) { if let first = results.first { model.go(to: first) } }
                .padding(.top, 44)
                .padding(.bottom, 10)
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(SettingsPane.allCases) { pane in
                    NavRow(pane: pane, selected: model.pane == pane) { model.pane = pane }
                }
            } else if results.isEmpty {
                Text("No settings match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { info in
                            ResultRow(info: info, selected: model.focus == info.id) { model.go(to: info) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                TernLogo().frame(width: 18, height: 18)
                Wordmark(height: 12).foregroundStyle(.primary)
                Text(AppUpdates.currentVersion)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 16)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }
}

private struct SearchField: View {
    @Binding var text: String
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Palette.chip, in: shape)
        .overlay(shape.strokeBorder(focused ? Palette.amber : .clear, lineWidth: 1.5))
        // Find (⌘F) while Settings is in front.
        .onReceive(NotificationCenter.default.publisher(for: SettingsModel.find)) { _ in focused = true }
    }
}

/// A section in the sidebar. The chosen one is lit, and only its glyph's cursor is.
private struct NavRow: View {
    let pane: SettingsPane
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                SettingsGlyph(pane: pane, lit: selected,
                              ink: selected ? Palette.onLit : Palette.lit,
                              accent: selected ? Palette.onLitAmber : Palette.amber)
                    .frame(width: 18, height: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.onLit : Palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(selected ? Palette.lit : hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A search result: the setting, and where it lives.
private struct ResultRow: View {
    let info: SettingInfo
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.onLit : Palette.text)
                    .lineLimit(2)
                Text(info.pane.title + (info.key.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Palette.onLit.opacity(Ink.mid) : Palette.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected ? Palette.lit : hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Where the settings are saved, on every page, and what's wrong with the file if you edited it.
private struct ConfigFooter: View {
    private let store = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.problems, id: \.self) { problem in
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.errorText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("Saved to").foregroundStyle(.tertiary)
                Text((store.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Open") { store.openInEditor() }.buttonStyle(LinkButtonStyle())
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }.buttonStyle(LinkButtonStyle())
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .help("Settings are saved here. Edits apply when you save the file; a line tern can't use keeps the last good value.")
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

// MARK: Page parts

/// A page's title and what it's for.
struct SettingsHeader: View {
    let pane: SettingsPane
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(pane.title)
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.4)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A scrolling page that goes to the row a search picked.
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    var subtitle: String?
    /// False when the page draws its header above the scrolling part itself.
    var header = true
    @ViewBuilder let content: () -> Content
    @Environment(SettingsModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if header { SettingsHeader(pane: pane, subtitle: subtitle) }
                    content()
                }
                .padding(.horizontal, 32)
                .padding(.top, header ? 40 : 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.focus) { _, id in scroll(to: id, proxy) }
            .onAppear { scroll(to: model.focus, proxy) }
        }
    }

    private func scroll(to id: String?, _ proxy: ScrollViewProxy) {
        guard let id, SettingsIndex[id].pane == pane else { return }
        withAnimation(Motion.animation()) { proxy.scrollTo(id, anchor: .center) }
    }
}

/// A heading and its rows, each row ruled off from the one above.
struct SettingsSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            content()
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}

/// A row's rule, its padding, and the highlight when a search lands on it.
private struct SettingsRowChrome: ViewModifier {
    let id: String?
    @Environment(SettingsModel.self) private var model

    func body(content: Content) -> some View {
        let lit = id != nil && model.focus == id
        content
            .padding(.vertical, 10)
            .padding(.horizontal, lit ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if lit {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.chip)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Palette.amber).frame(width: 3).padding(.vertical, 8)
                        }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1).opacity(lit ? 0 : 1) }
            .modifier(ScrollAnchor(id: id))
    }
}

/// An id to scroll to, only on the rows search can find.
private struct ScrollAnchor: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id { content.id(id) } else { content }
    }
}

extension View {
    func settingsRow(id: String? = nil) -> some View { modifier(SettingsRowChrome(id: id)) }
}

/// A setting: its name, an explanation, its config key, and its control on the right.
struct SettingsRow<Control: View>: View {
    let id: String
    var caption: String?
    @ViewBuilder let control: () -> Control

    init(_ id: String, caption: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.id = id
        self.caption = caption
        self.control = control
    }

    var body: some View {
        let info = SettingsIndex[id]
        HStack(alignment: .center, spacing: 16) {
            SettingLabel(info: info, caption: caption)
            Spacer(minLength: 12)
            control()
        }
        .settingsRow(id: id)
    }
}

/// A setting's name, a quieter explanation, and its key in the config file.
struct SettingLabel: View {
    let info: SettingInfo
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title).font(.system(size: 13))
            if let caption = caption ?? info.caption {
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let key = info.key {
                Text(key)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct SettingToggle: View {
    let id: String
    @Binding var isOn: Bool
    var caption: String?

    init(_ id: String, isOn: Binding<Bool>, caption: String? = nil) {
        self.id = id
        _isOn = isOn
        self.caption = caption
    }

    var body: some View {
        SettingsRow(id, caption: caption) {
            TernSwitch(isOn: $isOn).accessibilityLabel(SettingsIndex[id].title)
        }
    }
}

// MARK: General

/// Folders and tabs.
struct GeneralSettings: View {
    @AppStorage(Prefs.globalHotkey, store: Prefs.defaults) private var globalHotkey = false
    @AppStorage(Prefs.notifyCommandDone, store: Prefs.defaults) private var notifyCommandDone = true
    @AppStorage(Prefs.fileEditor, store: Prefs.defaults) private var fileEditor = "system"
    @AppStorage(Prefs.worktrees, store: Prefs.defaults) private var worktrees = false
    @AppStorage(Prefs.folderOrder, store: Prefs.defaults) private var folderOrder = FolderOrder.manual.rawValue
    @AppStorage(Prefs.repoRoots, store: Prefs.defaults) private var repoRoots = "~/dev"

    var body: some View {
        SettingsPage(pane: .general) {
            SettingsSection("Folders") {
                SettingsRow("folder-order", caption: folderOrder == FolderOrder.manual.rawValue
                           ? "Drag to reorder. Folder shortcuts (⌘1–9) follow this order." : nil) {
                    SegmentedChoice(options: [(FolderOrder.manual.rawValue, "As opened"), (FolderOrder.recent.rawValue, "Most recent first")],
                                    selection: $folderOrder)
                }
                RepoRootsList(text: $repoRoots)
            }
            SettingsSection("Files") {
                SettingsRow("file-editor") {
                    ChoiceMenu(options: [("system", "Default application"), ("vscode", "Visual Studio Code"),
                                         ("cursor", "Cursor"), ("zed", "Zed")],
                               selection: $fileEditor)
                }
            }
            SettingsSection("Quick access") {
                SettingToggle("global-hotkey", isOn: $globalHotkey)
            }
            SettingsSection("Notifications") {
                SettingToggle("notify-command-done", isOn: $notifyCommandDone)
            }
            SettingsSection("Tabs") {
                SettingToggle("tab-worktrees", isOn: $worktrees)
            }
        }
    }
}

/// The folders searched for git repositories: one row each, with a button to remove it.
private struct RepoRootsList: View {
    @Binding var text: String

    var body: some View {
        let roots = Prefs.parseRoots(text)
        SettingsRow("repo-root", caption: roots.isEmpty
                   ? "Only recent folders appear in \(ShortcutRegistry.label("folder.open"))."
                   : "Searched up to three levels deep.") {
            Button("Add Folder…", action: add)
        }
        ForEach(roots, id: \.self) { root in
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(root).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if !FileManager.default.fileExists(atPath: Workspace.normalize(root)) {
                    Text("not found").font(.system(size: 11.5)).foregroundStyle(Palette.errorText)
                }
                Spacer()
                Button { text = Prefs.joinRoots(roots.filter { $0 != root }) } label: {
                    Image(systemName: "minus").font(.system(size: 10, weight: .semibold))
                }
                .help("Stop searching \(root)")
            }
            .padding(.leading, 12)
            .settingsRow()
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for git repositories"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        var roots = Prefs.parseRoots(text)
        for url in panel.urls {
            let path = abbreviateHome(url.path)
            if !roots.contains(path) { roots.append(path) }
        }
        text = Prefs.joinRoots(roots)
    }
}

// MARK: Appearance

/// Theme, and how the sidebar shows work.
struct AppearanceSettings: View {
    @AppStorage(Prefs.theme, store: Prefs.defaults) private var theme = Theme.defaultID
    @AppStorage(Prefs.workingIndicator, store: Prefs.defaults) private var indicator = WorkingIndicator.trailing

    var body: some View {
        SettingsPage(pane: .appearance) {
            SettingsSection("Theme", footer: footer) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ThemeSwatch(theme: .ternDark, alternate: .ternLight, selected: theme == Theme.defaultID) { theme = Theme.defaultID }
                        ForEach(Theme.fixed + [GhosttyApp.shared.userTheme], id: \.id) { option in
                            ThemeSwatch(theme: option, selected: theme == option.id) { theme = option.id }
                        }
                    }
                    Text("theme")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .settingsRow(id: "theme")
            }
            SettingsSection("Sidebar") {
                SettingsRow("working-indicator") {
                    SegmentedChoice(options: [(WorkingIndicator.trailing, "Spinner"), (WorkingIndicator.turning, "Turning logo")],
                                    selection: $indicator)
                }
            }
        }
    }

    private var footer: String {
        switch theme {
        case "ghostty": "Uses the colours from your Ghostty config."
        case Theme.defaultID: "tern follows macOS's light or dark mode. The others look the same in both."
        default: "Applies to the sidebar, the terminal and Settings."
        }
    }
}

/// A theme in miniature: sidebar, terminal and its colours, with the name under it. The default
/// shows its light side across the corner.
private struct ThemeSwatch: View {
    let theme: Theme
    var alternate: Theme?
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 7) {
                ZStack {
                    Miniature(theme: theme)
                    if let alternate {
                        Miniature(theme: alternate).mask(Corner())
                    }
                }
                .frame(width: 84, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Palette.lit : Palette.border, lineWidth: selected ? 2 : 1))
                Text(theme.id == "ghostty" ? "Ghostty" : theme.name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(theme.id == "ghostty" ? "Your Ghostty colours" : alternate != nil ? "tern: follows macOS's light or dark mode" : theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct Corner: Shape {
        nonisolated func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.15))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    private struct Miniature: View {
        let theme: Theme

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: theme.text2)).frame(width: 18, height: 3)
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.lit)).frame(width: 22, height: 7)
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: theme.text3)).frame(width: 15, height: 3)
                }
                .padding(5)
                .frame(width: 34, height: 54, alignment: .topLeading)
                .background(Color(nsColor: theme.sidebar))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(nsColor: line(i)))
                            .frame(width: [28, 20, 24][i], height: 3)
                    }
                    CursorPill().fill(Color(nsColor: theme.amber)).frame(width: 8, height: 5)
                }
                .padding(6)
                .frame(width: 50, height: 54, alignment: .topLeading)
                .background(Color(nsColor: theme.terminal))
            }
        }

        private func line(_ i: Int) -> NSColor {
            guard let palette = theme.terminalColors?.palette else { return [theme.text, theme.text2, theme.text3][i] }
            return NSColor(hex: [palette[4], palette[2], palette[5]][i])
        }
    }
}

// MARK: Agents

/// Hooks, notifications and resuming conversations.
struct AgentSettings: View {
    let hooks: AgentHooks
    let updates: UpdateCenter
    let usage: AgentUsage
    @AppStorage(Prefs.notifyNeedsYou, store: Prefs.defaults) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDone, store: Prefs.defaults) private var notifyDone = true
    @AppStorage(Prefs.resumeAgents, store: Prefs.defaults) private var resumeAgents = true
    @AppStorage(Prefs.claudeAccountUsage, store: Prefs.defaults) private var claudeAccountUsage = false
    private let permission = NotificationPermission.shared

    var body: some View {
        SettingsPage(pane: .agents, subtitle: "Hooks tell tern when an agent is working, waiting on you, or done.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    AgentCard(hooks: hooks, agent: "claude", updates: updates)
                    AgentCard(hooks: hooks, agent: "codex", updates: updates)
                }
                if let error = hooks.error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Palette.errorText).textSelection(.enabled)
                }
            }
            .id("hooks")
            SettingsSection("Notify me when") {
                SettingToggle("notify-needs-you", isOn: $notifyNeedsYou)
                SettingToggle("notify-done", isOn: $notifyDone)
                if permission.denied {
                    HStack(spacing: 12) {
                        Text("Notifications are off for tern in System Settings. macOS also turns them off when its request goes unanswered, and doesn't ask again.")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.errorText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Notification Settings") { permission.openSystemSettings() }
                    }
                    .settingsRow()
                }
            }
            AwaySettings()
            SettingsSection("Sessions") {
                SettingToggle("resume-agents", isOn: $resumeAgents)
                SettingToggle("claude-account-usage", isOn: $claudeAccountUsage)
                if claudeAccountUsage && usage.accountDenied {
                    HStack {
                        Text("macOS blocked access to Claude Code's sign-in.")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.errorText)
                        Spacer()
                        Button("Try Again") { usage.retryAccount() }
                    }
                    .settingsRow()
                }
            }
        }
        .onAppear { hooks.refresh() }
    }
}

/// An agent tern integrates with: its mark, version, whether its hooks are set up, and the buttons for both.
private struct AgentCard: View {
    let hooks: AgentHooks
    let agent: String
    let updates: UpdateCenter
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let theme = ThemeStore.shared.theme
        let mark = agent == "claude" ? theme.claude : theme.codex
        let status = hooks.statuses[agent]
        let version = updates.agents.versions[agent]
        let checking = updates.agents.checking
        let installed = status?.installed == true
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentGlyph(agent: agent, color: Color(nsColor: mark.fg))
                    .frame(width: 15, height: 15)
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: mark.bg), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agentName(agent)).font(.system(size: 13, weight: .semibold))
                    Text(versionText(version, checking: checking))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    CursorPill().fill(installed ? Palette.fine : Palette.ring).frame(width: 8, height: 5)
                    Text(status == nil ? "Checking…" : installed ? "Hooks on" : status?.available == false ? "Not installed" : "No hooks")
                }
                .font(.system(size: 11))
                .foregroundStyle(installed ? Palette.fine : Palette.text2)
            }
            HStack(spacing: 6) {
                if let version, version.behind, updates.runner.runs[agent]?.phase != .running {
                    Button("Update") { updates.runAgent(agent) }
                        .buttonStyle(LitButtonStyle())
                        .help("Update to \(version.latest ?? "the latest version")")
                }
                Button(installed ? "Remove Hooks" : "Set Up Hooks") { hooks.set(agent, installed: !installed) }
                    .buttonStyle(installed ? AnyButtonStyle(QuietButtonStyle()) : AnyButtonStyle(LitButtonStyle()))
                    .disabled(status?.available == false)
                    .help(agent == "codex"
                          ? "Reports agent status through ~/.codex/hooks.json, and adds a tern skill for driving panes. Run /hooks in Codex once to trust new hooks."
                          : "Reports agent status through ~/.claude/settings.json, records usage through its status line, and adds a tern skill for driving panes.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebar, in: shape)
        .overlay(shape.strokeBorder(model.focus == "hooks" ? Palette.amber : Palette.border))
    }

    private func versionText(_ version: AgentUpdates.Version?, checking: Bool) -> String {
        guard let version, let installed = version.installed else { return checking ? "Checking version…" : "Not found in PATH" }
        guard version.behind, let latest = version.latest else { return installed }
        return "\(installed) → \(latest)"
    }
}

/// ternd's pushes while you're away. ternd reads these keys from the config file itself, so
/// Settings writes them there directly.
private struct AwaySettings: View {
    private let store = ConfigStore.shared
    @State private var topic = ""
    @State private var problem: String?

    private static let defaultAfter = 120

    var body: some View {
        // Read so an edit to the file shows here.
        let _ = store.revision
        let saved = store.config.all("notify-ntfy").last ?? ""
        let after = store.config.all("away-after").last.flatMap(Double.init).map { Int($0) } ?? Self.defaultAfter
        SettingsSection("While you're away") {
            SettingsRow("notify-ntfy") {
                HStack(spacing: 6) {
                    TextField("", text: $topic, prompt: Text("https://ntfy.sh/your-topic"))
                        .fieldChrome(mono: true)
                        .frame(width: 250)
                        .onSubmit(save)
                    if topic != saved {
                        Button("Save", action: save).buttonStyle(LitButtonStyle())
                    }
                }
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.errorText).padding(.bottom, 8)
            }
            SettingsRow("away-after") {
                ChoiceMenu(options: Self.afterOptions(including: after),
                           selection: Binding(get: { after }, set: { seconds in
                               try? store.write { $0.set("away-after", [String(seconds)]) }
                           }))
            }
        }
        .onAppear { topic = saved }
        .onChange(of: saved) { _, now in topic = now }
    }

    private func save() {
        let url = topic.trimmingCharacters(in: .whitespaces)
        guard url.isEmpty || url.hasPrefix("https://") || url.hasPrefix("http://") else {
            problem = "Use the topic's whole URL, like https://ntfy.sh/a-topic-only-you-know."
            return
        }
        problem = nil
        do { try store.write { $0.set("notify-ntfy", url.isEmpty ? [] : [url]) } }
        catch { problem = "Couldn't save the config file: \(error.localizedDescription)" }
    }

    static func afterOptions(including current: Int) -> [(Int, String)] {
        var seconds = [60, 120, 300, 600, 1800]
        if !seconds.contains(current) { seconds.append(current); seconds.sort() }
        return seconds.map { s in
            (s, s % 60 == 0 ? "\(s / 60) minute\(s == 60 ? "" : "s")" : "\(s) seconds")
        }
    }
}

/// A button style chosen at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: The window controller

/// Settings: a sidebar of sections, as tern's own window, in the theme's colours.
final class SettingsWindowController: NSWindowController {
    static let updatesPane = SettingsPane.updates.rawValue
    private let model = SettingsModel()
    private var themeObserver: Any?

    init(hooks: AgentHooks, updates: UpdateCenter, usage: AgentUsage) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        let host = NSHostingController(rootView: SettingsRoot(model: model, hooks: hooks, updates: updates, usage: usage))
        host.sizingOptions = []
        window.contentViewController = host
        window.identifier = NSUserInterfaceItemIdentifier("tern.settings")
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.setContentSize(NSSize(width: 820, height: 580))
        if !window.setFrameUsingName("tern.settings") { window.center() }
        window.setFrameAutosaveName("tern.settings")
        applyTheme()
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(pane: Int) {
        if let pane = SettingsPane(rawValue: pane) { model.pane = pane }
    }

    /// The window's own parts (title bar, menus, scroll bars) in the theme's light or dark.
    private func applyTheme() {
        let theme = ThemeStore.shared.theme
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.terminal
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Otherwise the search field takes focus at once.
        DispatchQueue.main.async { self.window?.makeFirstResponder(nil) }
    }
}
