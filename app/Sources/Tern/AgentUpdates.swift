import Foundation
import os

/// Installed and newest versions of Claude Code and Codex, and the command that updates each.
@Observable
final class AgentUpdates {
    struct Version: Equatable {
        let agent: String
        var installed: String?
        var latest: String?
        /// Every copy on PATH, the one that runs first; entries that are the same file count once.
        var paths: [String] = []
        /// The file the first copy runs, symlinks resolved (a Homebrew cask lives in its Caskroom).
        var resolved: String?

        var name: String { agent == "claude" ? "Claude Code" : "Codex" }

        /// The agent's own updater, or Homebrew's for a cask install, which the updater refuses.
        var updateCommand: String { Self.updateCommand(agent: agent, path: resolved) }

        nonisolated static func updateCommand(agent: String, path: String?) -> String {
            if let path, path.contains("/Caskroom/") {
                return agent == "claude" ? "brew upgrade --cask claude-code" : "brew upgrade --cask codex"
            }
            return agent == "claude" ? "claude update" : "codex update"
        }

        var behind: Bool {
            guard let installed, let latest else { return false }
            return AgentUpdates.compare(installed, latest) == .orderedAscending
        }

        /// An update to the first copy is no use while another one comes first, and vice versa.
        var shadowWarning: String? {
            guard paths.count > 1 else { return nil }
            let home = NSHomeDirectory()
            let tidy = { (p: String) in p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
            return "\(paths.count) copies are on PATH; \(tidy(paths[0])) runs first."
        }
    }

    private(set) var versions: [String: Version] = [:]
    private(set) var checking = false
    private(set) var lastChecked: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var recheck = false
    /// After each check, so a finished update can tell whether it took.
    @ObservationIgnored var onChecked: (() -> Void)?

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        // A check asked for mid-check (an update just finished) runs once this one ends.
        guard !checking else { recheck = true; return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let installed = Self.probe()
            let group = DispatchGroup()
            let latest = OSAllocatedUnfairLock(initialState: [String: String]())
            for (agent, package) in [("claude", "@anthropic-ai/claude-code"), ("codex", "@openai/codex")] {
                group.enter()
                Self.latestVersion(package: package, channel: agent == "claude" ? Self.claudeChannel() : "latest") {
                    if let v = $0 { latest.withLock { $0[agent] = v } }
                    group.leave()
                }
            }
            group.wait()
            let newest = latest.withLock { $0 }
            DispatchQueue.main.async {
                var found: [String: Version] = [:]
                for agent in ["claude", "codex"] {
                    guard let probe = installed[agent], probe.version != nil else { continue }
                    // Keep the last known newest version if the registry didn't answer this time.
                    found[agent] = Version(agent: agent, installed: probe.version,
                                           latest: newest[agent] ?? self.versions[agent]?.latest,
                                           paths: probe.paths, resolved: probe.resolved.first)
                }
                self.versions = found
                self.lastChecked = Date()
                self.checking = false
                self.onChecked?()
                if self.recheck { self.recheck = false; self.check() }
            }
        }
    }

    nonisolated struct Probe: Equatable, Sendable {
        var version: String?
        /// PATH entries, one per distinct file, and the files they resolve to.
        var paths: [String] = []
        var resolved: [String] = []
    }

    /// Asks the user's own shell, so the versions are the ones a tern tab runs.
    nonisolated private static func probe() -> [String: Probe] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `which -a` lists every copy on PATH; /usr/bin/which in shells without a builtin one.
        let script = "echo @@claude; claude --version 2>/dev/null; echo @@claude-paths; which -a claude 2>/dev/null; "
            + "echo @@codex; codex --version 2>/dev/null; echo @@codex-paths; which -a codex 2>/dev/null"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let deadline = DispatchTime.now() + 20
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseProbe(String(decoding: data, as: UTF8.self)) { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// Reads the probe's sections. `resolve` turns a PATH entry into the file it runs.
    nonisolated static func parseProbe(_ text: String, resolve: (String) -> String = { $0 }) -> [String: Probe] {
        var probes: [String: Probe] = [:]
        var agent: String?, paths = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") {
                let name = String(line.dropFirst(2))
                paths = name.hasSuffix("-paths")
                agent = paths ? String(name.dropLast(6)) : name
                if let agent, probes[agent] == nil { probes[agent] = Probe() }
                continue
            }
            guard let agent else { continue }
            if paths {
                // zsh's builtin `which` also reports aliases and functions; only files count.
                guard line.hasPrefix("/") else { continue }
                let target = resolve(line)
                if !probes[agent]!.resolved.contains(target) {
                    probes[agent]!.resolved.append(target)
                    probes[agent]!.paths.append(line)
                }
            } else if probes[agent]?.version == nil, let v = firstVersion(in: line) {
                probes[agent]?.version = v
            }
        }
        return probes
    }

    nonisolated private static func firstVersion(in text: String) -> String? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// Claude Code's native updater follows "latest" unless settings say "stable".
    nonisolated private static func claudeChannel() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = json["autoUpdatesChannel"] as? String else { return "latest" }
        return channel
    }

    nonisolated private static func latestVersion(package: String, channel: String, done: @escaping @Sendable (String?) -> Void) {
        guard let url = URL(string: "https://registry.npmjs.org/-/package/\(package)/dist-tags") else { return done(nil) }
        var request = URLRequest(url: url, timeout: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let tags = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            done(tags?[channel] ?? tags?["latest"])
        }.resume()
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
