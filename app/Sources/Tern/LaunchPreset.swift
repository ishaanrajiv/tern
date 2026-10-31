import Foundation

nonisolated func quoteShell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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

/// Launch presets, one JSON file each in the presets folder beside the config file
/// (`~/.config/tern/presets/`), named after the preset when it's first saved. A file that
/// doesn't read as a preset is left alone and reported.
struct LaunchPresetFile {
    var presets: [LaunchPreset] = []
    /// The file each preset came from, by id, so a renamed preset keeps its file.
    var files: [String: URL] = [:]
    var unreadable: [String] = []

    static var directory: URL { ConfigStore.shared.presetsURL }
    /// Where older terns kept every preset; read once, to migrate them.
    static var legacyURL: URL { Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("launch-presets.json") }

    private struct Legacy: Codable {
        var version = 1
        var presets: [LaunchPreset] = []
    }

    private static func names(in dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
    }

    static func load(from dir: URL = directory) throws -> Self {
        var file = Self()
        for name in try names(in: dir) {
            let url = dir.appendingPathComponent(name)
            if let preset = try? JSONDecoder().decode(LaunchPreset.self, from: Data(contentsOf: url)), file.files[preset.id] == nil {
                file.presets.append(preset)
                file.files[preset.id] = url
            } else {
                file.unreadable.append(name)
            }
        }
        return file
    }

    /// Writes each preset to its file, and removes the files of presets loaded or saved here and
    /// then taken out. Presets added to the folder since loading stay. `files` follows along, so
    /// a preset saved here can be deleted here.
    mutating func save(to dir: URL = directory) throws {
        let onDisk = try Self.load(from: dir)
        var taken = Set(try Self.names(in: dir))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for preset in presets {
            let url = files[preset.id] ?? onDisk.files[preset.id] ?? Self.newFile(for: preset.name, in: dir, taken: &taken)
            try ConfigStore.writePrivate(encoder.encode(preset), to: url)
            files[preset.id] = url
        }
        for (id, url) in files where !presets.contains(where: { $0.id == id }) {
            if onDisk.files[id] == url { try FileManager.default.removeItem(at: url) }
            files[id] = nil
        }
    }

    static func newFile(for name: String, in dir: URL, taken: inout Set<String>) -> URL {
        var base = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(64))
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "preset" }
        var candidate = base + ".json"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(n).json"
            n += 1
        }
        taken.insert(candidate)
        return dir.appendingPathComponent(candidate)
    }

    /// Splits an older tern's preset file into the folder, unless the folder has presets already.
    /// The old file stays, for an older tern.
    static func migrate(from url: URL, to dir: URL) throws {
        guard try names(in: dir).isEmpty, let data = try? Data(contentsOf: url),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data), legacy.version == 1, !legacy.presets.isEmpty else { return }
        var file = Self(presets: legacy.presets)
        try file.save(to: dir)
    }
}
