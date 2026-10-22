import Foundation

func quoteShell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

struct RemoteConnection: Codable, Equatable {
    var host = ""
    var directory = "~"
    var tmuxSession = ""

    func validate() throws {
        guard host.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.@:\[\]%-]*$"#, options: .regularExpression) != nil else {
            throw LaunchError.invalid("Enter an SSH host alias or user@host, without spaces or options. Configure ports and jump hosts in ~/.ssh/config.")
        }
        guard directory == "~" || directory.hasPrefix("~/") || directory.hasPrefix("/"),
              !directory.contains(where: { $0.isNewline }),
              tmuxSession.isEmpty || tmuxSession.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw LaunchError.invalid("Use an absolute remote folder or ~/path. A tmux session name may contain letters, numbers, _ and -.")
        }
    }
    func command(startup: String = "", environment: [String: String] = [:]) -> String {
        let dir = directory == "~" ? "\"$HOME\"" : directory.hasPrefix("~/") ? "\"$HOME\"/" + quoteShell(String(directory.dropFirst(2))) : quoteShell(directory)
        let script = LaunchPane.script(command: startup, environment: environment)
        let shell = script.isEmpty ? "exec \"${SHELL:-/bin/sh}\" -l" : "exec \"${SHELL:-/bin/sh}\" -lc " + quoteShell(script + "; exec \"${SHELL:-/bin/sh}\" -l")
        let remote = "cd " + dir + " && " + (tmuxSession.isEmpty ? shell : "exec tmux new-session -A -s " + quoteShell(tmuxSession) + " -c \"$PWD\" " + quoteShell(shell))
        // A conservative TERM works on hosts without Ghostty's terminfo installed.
        return "TERM=xterm-256color ssh -t -- " + quoteShell(host) + " " + quoteShell(remote)
    }
}

enum LaunchError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

struct LaunchPane: Codable, Equatable {
    var directory: String
    var command = ""
    var environment: [String: String] = [:]
    var remote: RemoteConnection?

    static func script(command: String, environment: [String: String]) -> String {
        let exports = environment.keys.sorted().map { "export \($0)=\(quoteShell(environment[$0]!))" }
        return (exports + (command.isEmpty ? [] : [command])).joined(separator: "; ")
    }
    var startup: String {
        remote?.command(startup: command, environment: environment) ?? Self.script(command: command, environment: environment)
    }
    func validate() throws {
        if let remote { try remote.validate() }
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              environment.keys.allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }),
              !command.contains("\0"), environment.values.allSatisfy({ !$0.contains("\0") }) else {
            throw LaunchError.invalid("Each local folder must exist. Environment names must be shell variable names and values cannot contain NUL.")
        }
    }
}

struct LaunchTab: Codable, Equatable {
    var name: String?
    var root: SplitNode
    var panes: [String: LaunchPane]
}

struct LaunchPreset: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var project: String
    var tabs: [LaunchTab]

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.hasPrefix("/"), !tabs.isEmpty else { throw LaunchError.invalid("Name the preset and choose a local project folder.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory), isDirectory.boolValue, tabs.count <= 128 else {
            throw LaunchError.invalid("Choose an existing project folder, with at most 128 tabs.")
        }
        func valid(_ root: SplitNode, depth: Int = 0) -> Bool {
            guard depth < 64 else { return false }
            switch root {
            case .pane: return true
            case .split(_, let ratio, let a, let b): return ratio.isFinite && (0.1...0.9).contains(ratio) && valid(a, depth: depth + 1) && valid(b, depth: depth + 1)
            }
        }
        for tab in tabs {
            let ids = tab.root.panes
            guard !ids.isEmpty, ids.count <= 64, valid(tab.root), Set(ids).count == ids.count, Set(ids) == Set(tab.panes.keys) else {
                throw LaunchError.invalid("The preset's panes do not match its layout.")
            }
            for pane in tab.panes.values { try pane.validate() }
        }
    }
}

struct LaunchPresetFile: Codable {
    var version = 1
    var presets: [LaunchPreset] = []
    static var url: URL { Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("launch-presets.json") }
    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw LaunchError.invalid("This preset file was written by a newer Tern. It has been left unchanged.") }
        return value
    }
    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}
