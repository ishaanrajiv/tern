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
    func link() { _ = run(["hooks", "link"]) }

    @discardableResult
    private func run(_ args: [String]) -> String? {
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

struct SettingsView: View {
    let hooks: AgentHooks
    @AppStorage(Prefs.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDone) private var notifyDone = true
    @AppStorage(Prefs.worktrees) private var worktrees = false
    @AppStorage(Prefs.resumeAgents) private var resumeAgents = true

    var body: some View {
        Form {
            Section("Agent status") {
                AgentToggle(hooks: hooks, agent: "claude", name: "Claude Code",
                            caption: "Adds hooks to ~/.claude/settings.json.")
                AgentToggle(hooks: hooks, agent: "codex", name: "Codex",
                            caption: "Adds hooks to ~/.codex/hooks.json. Run /hooks in Codex once to trust them.")
                if let error = hooks.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            Section("Notifications") {
                Toggle(isOn: $notifyNeedsYou) {
                    Labeled("When an agent needs you", caption: AgentNotifier.unavailable
                            ? "macOS isn't letting tern post notifications yet." : nil)
                }
                Toggle(isOn: $notifyDone) {
                    Labeled("When an agent finishes", caption: "Only for sessions you aren't looking at.")
                }
            }

            Section("Sessions") {
                Toggle(isOn: $worktrees) {
                    Labeled("Give each new session its own git worktree",
                            caption: "⌘T in a git project creates <repo>-worktrees/session-N on branch tern/session-N. ⌘⇧T always does.")
                }
                Toggle(isOn: $resumeAgents) {
                    Labeled("Resume agent conversations after a restart",
                            caption: "If a session was lost to a reboot, tern reopens its Claude Code or Codex conversation.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hooks.refresh() }
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AgentToggle: View {
    let hooks: AgentHooks
    let agent: String
    let name: String
    let caption: String

    var body: some View {
        let status = hooks.statuses[agent]
        Toggle(isOn: Binding(
            get: { status?.installed == true },
            set: { hooks.set(agent, installed: $0) }
        )) {
            Labeled(name, caption: status?.available == false ? "Not installed on this Mac." : caption)
        }
        .disabled(status?.available == false)
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init(hooks: AgentHooks) {
        let host = NSHostingController(rootView: SettingsView(hooks: hooks))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        self.init(window: window)
    }
}
