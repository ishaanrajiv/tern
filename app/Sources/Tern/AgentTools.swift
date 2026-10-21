import AppKit
import Foundation

/// One usage window: how much of it is used, and when it starts over.
struct UsageWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date

    /// Past its reset, a window is empty again even if no newer report came.
    func used(at now: Date) -> Double { now >= resetsAt ? 0 : min(max(usedPercent, 0), 100) }
}

/// An agent's subscription limits, as last reported.
struct UsageLimits: Equatable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

/// Usage limits for Claude Code and Codex, read from what each leaves on disk:
/// Claude Code's through `tern statusline` (see crates/tern/src/usage.rs), Codex's
/// from the rate limits it logs in its session files.
@Observable
final class AgentUsage {
    private(set) var limits: [String: UsageLimits] = [:]
    @ObservationIgnored private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            var found: [String: UsageLimits] = [:]
            found["claude"] = Self.claude()
            found["codex"] = Self.codex()
            DispatchQueue.main.async { if self.limits != found { self.limits = found } }
        }
    }

    private static func claude() -> UsageLimits? {
        let url = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("usage/claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let window = { (key: String) -> UsageWindow? in
            guard let w = json[key] as? [String: Any], let used = w["used_percent"] as? Double,
                  let resets = w["resets_at"] as? Double else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let limits = UsageLimits(fiveHour: window("five_hour"), weekly: window("seven_day"))
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }

    /// The newest `rate_limits` in Codex's most recent session logs.
    private static func codex() -> UsageLimits? {
        for file in recentCodexSessions().prefix(6) {
            if let limits = lastRateLimits(in: file) { return limits }
        }
        return nil
    }

    /// Session logs newest first, from ~/.codex/sessions/YYYY/MM/DD.
    private static func recentCodexSessions() -> [URL] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var files: [URL] = []
        outer: for year in children(root) {
            for month in children(year) {
                for day in children(month) {
                    files += children(day).filter { $0.pathExtension == "jsonl" }
                    if files.count >= 6 { break outer }
                }
            }
        }
        let modified = { (url: URL) in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.sorted { modified($0) > modified($1) }
    }

    private static func lastRateLimits(in file: URL) -> UsageLimits? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        where line.contains("\"rate_limits\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            // Other ids are per-model extras; "codex" is the plan's own limit.
            if let id = limits["limit_id"] as? String, id != "codex" { continue }
            let window = { (key: String) -> UsageWindow? in
                guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double,
                      let resets = w["resets_at"] as? Double else { return nil }
                return UsageWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
            }
            return UsageLimits(fiveHour: window("primary"), weekly: window("secondary"))
        }
        return nil
    }
}

/// Installed and newest versions of Claude Code and Codex, and their own updaters.
@Observable
final class AgentUpdates {
    struct Version: Equatable {
        let agent: String
        var installed: String?
        var latest: String?

        var name: String { agent == "claude" ? "Claude Code" : "Codex" }
        var updateCommand: String { agent == "claude" ? "claude update" : "codex update" }
        var behind: Bool {
            guard let installed, let latest else { return false }
            return AgentUpdates.compare(installed, latest) == .orderedAscending
        }
    }

    private(set) var versions: [String: Version] = [:]
    private(set) var checking = false
    private(set) var lastChecked: Date?
    @ObservationIgnored private var timer: Timer?

    static let dismissedKey = "dismissedAgentUpdate."

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Updates worth offering: behind, and not waved off for that version.
    var offered: [Version] {
        versions.values.filter { v in
            v.behind && UserDefaults.standard.string(forKey: Self.dismissedKey + v.agent) != v.latest
        }.sorted { $0.agent < $1.agent }
    }

    func dismiss(_ version: Version) {
        UserDefaults.standard.set(version.latest, forKey: Self.dismissedKey + version.agent)
        versions[version.agent] = version  // Re-evaluate `offered`.
    }

    func check() {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let installed = Self.installedVersions()
            let group = DispatchGroup()
            var latest: [String: String] = [:]
            let lock = NSLock()
            for (agent, package) in [("claude", "@anthropic-ai/claude-code"), ("codex", "@openai/codex")] {
                group.enter()
                Self.latestVersion(package: package, channel: agent == "claude" ? Self.claudeChannel() : "latest") {
                    if let v = $0 { lock.lock(); latest[agent] = v; lock.unlock() }
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                var found: [String: Version] = [:]
                for agent in ["claude", "codex"] where installed[agent] != nil {
                    // Keep the last known newest version if the registry didn't answer this time.
                    found[agent] = Version(agent: agent, installed: installed[agent],
                                           latest: latest[agent] ?? self.versions[agent]?.latest)
                }
                self.versions = found
                self.lastChecked = Date()
                self.checking = false
            }
        }
    }

    /// After an update starts in a tab, look again until it has had time to finish.
    func recheckSoon() {
        for delay in [20.0, 60, 180] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    /// Asks the user's own shell, so the versions are the ones a tern tab runs.
    private static func installedVersions() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "echo @@claude; claude --version 2>/dev/null; echo @@codex; codex --version 2>/dev/null"
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
        var versions: [String: String] = [:]
        var agent: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("@@") { agent = String(line.dropFirst(2)); continue }
            if let agent, versions[agent] == nil, let v = firstVersion(in: String(line)) { versions[agent] = v }
        }
        return versions
    }

    private static func firstVersion(in text: String) -> String? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// Claude Code's native updater follows "latest" unless settings say "stable".
    private static func claudeChannel() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = json["autoUpdatesChannel"] as? String else { return "latest" }
        return channel
    }

    private static func latestVersion(package: String, channel: String, done: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://registry.npmjs.org/-/package/\(package)/dist-tags") else { return done(nil) }
        var request = URLRequest(url: url, timeout: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let tags = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            done(tags?[channel] ?? tags?["latest"])
        }.resume()
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

private extension URLRequest {
    init(url: URL, timeout: TimeInterval) {
        self.init(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    }
}
