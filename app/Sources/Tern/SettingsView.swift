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

    /// Keeps the stable hook path pointing at this copy of tern.
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
            Section {
                AgentRow(hooks: hooks, agent: "claude", name: "Claude Code",
                         note: "Adds hooks to ~/.claude/settings.json.")
                AgentRow(hooks: hooks, agent: "codex", name: "Codex",
                         note: "Adds hooks to ~/.codex/hooks.json. Codex asks you to trust them once: run /hooks in Codex.")
                if let error = hooks.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Agent status")
            } footer: {
                Text("Hooks tell tern when an agent is working, waiting for you, or done. Outside tern they do nothing.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("When an agent needs you", isOn: $notifyNeedsYou)
                Toggle("When an agent finishes", isOn: $notifyDone)
                Text("Only for sessions you aren't looking at.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Sessions") {
                Toggle("Give each new session its own git worktree", isOn: $worktrees)
                Text("In a git project, ⌘T creates `<repo>-worktrees/session-N` on a new branch `tern/session-N`. ⌘⇧T does this whatever the setting.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Resume agent conversations after a restart", isOn: $resumeAgents)
                Text("When a session was lost (for example, to a reboot), tern runs `claude --resume` or `codex resume` in its place.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hooks.refresh() }
    }
}

private struct AgentRow: View {
    let hooks: AgentHooks
    let agent: String
    let name: String
    let note: String

    var body: some View {
        let status = hooks.statuses[agent]
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(status?.available == false ? "Not installed on this Mac." : note)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status?.installed == true {
                Label("On", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                Button("Remove") { hooks.set(agent, installed: false) }
            } else {
                Button("Set Up") { hooks.set(agent, installed: true) }
                    .disabled(status?.available == false)
            }
        }
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init(hooks: AgentHooks) {
        let host = NSHostingController(rootView: SettingsView(hooks: hooks))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = "tern Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        self.init(window: window)
    }
}
