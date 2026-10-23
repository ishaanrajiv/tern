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

/// Folders and tabs.
struct GeneralSettings: View {
    @AppStorage(Prefs.worktrees) private var worktrees = false
    @AppStorage(Prefs.folderOrder) private var folderOrder = FolderOrder.manual.rawValue
    @AppStorage(Prefs.repoRoots) private var repoRoots = "~/dev"

    var body: some View {
        Form {
            Section("Folders") {
                Picker(selection: $folderOrder) {
                    Text("As opened").tag(FolderOrder.manual.rawValue)
                    Text("Most recent first").tag(FolderOrder.recent.rawValue)
                } label: {
                    Labeled("Order", caption: folderOrder == FolderOrder.manual.rawValue
                            ? "Drag to reorder. ⌘1–9 follow this order." : nil)
                }
                RepoRootsList(text: $repoRoots)
            }

            Section("Tabs") {
                Toggle(isOn: $worktrees) {
                    Labeled("New tabs use git worktrees", caption: "⌘⇧T always opens a worktree.")
                }
            }
        }
        .settingsPane()
    }
}

/// Theme, and how the sidebar shows work.
struct AppearanceSettings: View {
    @AppStorage(Prefs.theme) private var theme = Theme.defaultID
    @AppStorage(Prefs.workingIndicator) private var indicator = WorkingIndicator.trailing

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(Theme.builtIn + [GhosttyApp.shared.userTheme], id: \.id) { option in
                        ThemeSwatch(theme: option, selected: theme == option.id) { theme = option.id }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } header: {
                Text("Theme")
            } footer: {
                Text(theme == "ghostty"
                     ? "Uses the colours from your Ghostty config."
                     : "Applies to the sidebar and terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Sidebar") {
                Picker(selection: $indicator) {
                    Text("Trailing spinner").tag(WorkingIndicator.trailing)
                    Text("Turning agent logo").tag(WorkingIndicator.turning)
                } label: {
                    Text("Working indicator")
                }
            }
        }
        .settingsPane()
    }
}

/// Hooks, notifications and resuming conversations.
struct AgentSettings: View {
    let hooks: AgentHooks
    let updates: AgentUpdates
    let runUpdate: (AgentUpdates.Version) -> Void
    @AppStorage(Prefs.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDone) private var notifyDone = true
    @AppStorage(Prefs.resumeAgents) private var resumeAgents = true
    @AppStorage(Prefs.claudeAccountUsage) private var claudeAccountUsage = false

    var body: some View {
        Form {
            Section("Integrations") {
                AgentIntegrationRow(hooks: hooks, agent: "claude", name: "Claude Code",
                                    version: updates.versions["claude"], checking: updates.checking, update: runUpdate)
                AgentIntegrationRow(hooks: hooks, agent: "codex", name: "Codex",
                                    version: updates.versions["codex"], checking: updates.checking, update: runUpdate)
                Toggle(isOn: $claudeAccountUsage) {
                    Text("Read Claude account usage")
                    Text("Reads Claude Code's sign-in from the Keychain, after macOS asks you, and sends it to Anthropic every five minutes to fetch your usage limits. Tern never refreshes the token. Off, limits still show while Claude Code runs in a tern tab with hooks set up.")
                }
            }
            Section("Notifications and resume") {
                Toggle("Agent needs your input", isOn: $notifyNeedsYou)
                Toggle("Agent finishes", isOn: $notifyDone)
                    .help("Only for sessions you aren't looking at.")
                Toggle("Resume agents after a reboot", isOn: $resumeAgents)
                    .help("Reopens the Claude Code or Codex conversation when its previous session is gone.")
            }
            Section {
                HStack {
                    Text(updates.checking ? "Checking for updates…"
                         : updates.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "Updates not checked yet")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updates.check() }.disabled(updates.checking)
                }
                if let error = hooks.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if AgentNotifier.unavailable {
                    Text("macOS notification permission is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .settingsPane()
        .onAppear { hooks.refresh() }
    }
}

private struct AgentIntegrationRow: View {
    let hooks: AgentHooks
    let agent: String
    let name: String
    let version: AgentUpdates.Version?
    let checking: Bool
    let update: (AgentUpdates.Version) -> Void

    var body: some View {
        let status = hooks.statuses[agent]
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(version?.installed ?? (checking ? "Checking version…" : "Not found in PATH"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let version, version.behind {
                Button("Update") { update(version) }
                    .help("Update to \(version.latest ?? "the latest version")")
            }
            Button(status?.installed == true ? "Remove Hooks" : "Set Up Hooks") {
                hooks.set(agent, installed: status?.installed != true)
            }
            .disabled(status?.available == false)
            .help(agent == "codex"
                  ? "Reports agent status through ~/.codex/hooks.json. Run /hooks in Codex once to trust new hooks."
                  : "Reports agent status through ~/.claude/settings.json and records usage through its status line.")
        }
    }
}

extension View {
    /// Every tab has the same compact viewport. Forms scroll when content grows.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .controlSize(.small)
            .frame(width: 580, height: 460)
    }
}

/// A theme in miniature: sidebar, terminal and its colours, with the name under it.
private struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: theme.text)).frame(width: 16, height: 3)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: theme.selection)).frame(width: 20, height: 6)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: theme.text3)).frame(width: 14, height: 3)
                    }
                    .padding(5)
                    .frame(width: 30, height: 48, alignment: .topLeading)
                    .background(Color(nsColor: theme.sidebar))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            Circle().fill(Color(nsColor: theme.amber)).frame(width: 5, height: 5)
                            Circle().fill(Color(nsColor: theme.working)).frame(width: 5, height: 5)
                        }
                        ForEach(0..<3) { i in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(nsColor: line(i)))
                                .frame(width: [26, 18, 22][i], height: 3)
                        }
                    }
                    .padding(5)
                    .frame(width: 42, height: 48, alignment: .topLeading)
                    .background(Color(nsColor: theme.terminal))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
                Text(theme.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .help(theme.id == "ghostty" ? "Your Ghostty colours" : theme.name)
    }

    private func line(_ i: Int) -> NSColor {
        guard let palette = theme.terminalColors?.palette else { return [theme.text, theme.text2, theme.text3][i] }
        return NSColor(hex: [palette[4], palette[2], palette[5]][i])
    }
}

/// The folders searched for git repositories: one row each, with − to remove and Add Folder… to choose more.
private struct RepoRootsList: View {
    @Binding var text: String

    var body: some View {
        let roots = Prefs.parseRoots(text)
        LabeledContent {
            Button("Add Folder…", action: add)
        } label: {
            Labeled("Find repositories in", caption: roots.isEmpty
                    ? "Only recent folders appear in ⌘N."
                    : "Search up to three levels deep.")
        }
        ForEach(roots, id: \.self) { root in
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(root).lineLimit(1).truncationMode(.middle)
                if !FileManager.default.fileExists(atPath: Workspace.normalize(root)) {
                    Text("not found").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { text = Prefs.joinRoots(roots.filter { $0 != root }) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop searching \(root)")
            }
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

/// A setting's name with a quieter explanation under it.
private struct Labeled: View {
    let title: String
    let caption: String?

    init(_ title: String, caption: String?) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings use a shared, bounded viewport across all toolbar tabs.
final class SettingsWindowController: NSWindowController {
    convenience init(hooks: AgentHooks, updates: AgentUpdates, runUpdate: @escaping (AgentUpdates.Version) -> Void) {
        // Read before adding panes: adding the first one selects it, which saves its index.
        let last = min(max(UserDefaults.standard.integer(forKey: SettingsTabs.key), 0), 3)
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralSettings())
        pane("Appearance", "paintpalette", AppearanceSettings())
        pane("Terminal", "terminal", TerminalSettings())
        pane("Agents", "sparkles", AgentSettings(hooks: hooks, updates: updates, runUpdate: runUpdate))
        let window = NSWindow(contentViewController: tabs)
        window.identifier = NSUserInterfaceItemIdentifier("tern.settings")
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        self.init(window: window)
        tabs.selectedTabViewItemIndex = last
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Otherwise the first text field takes focus, with its text selected.
        DispatchQueue.main.async { self.window?.makeFirstResponder(nil) }
    }
}

/// Opens on the pane last shown.
private final class SettingsTabs: NSTabViewController {
    static let key = "settingsPane"

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.key)
    }
}
