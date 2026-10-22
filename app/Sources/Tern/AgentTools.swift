import AppKit
import Foundation
import Security
import os

/// One usage window: how much of it is used, and when it starts over.
nonisolated struct UsageWindow: Equatable, Sendable {
    let usedPercent: Double
    /// Unknown for a window not yet started.
    let resetsAt: Date?

    /// Past its reset, a window is empty again even if no newer report came.
    func used(at now: Date) -> Double {
        if let resetsAt, now >= resetsAt { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

/// An agent's subscription limits, as last reported.
nonisolated struct UsageLimits: Equatable, Sendable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    var reportedAt: Date? = nil
}

/// Usage limits for Claude Code and Codex. Claude Code's come from its account (see
/// ClaudeAccount) or, newer if Claude Code ran in a terminal since, from `tern statusline`
/// (see crates/tern/src/usage.rs). Codex's come from the rate limits it logs in its sessions.
@Observable
final class AgentUsage {
    private(set) var limits: [String: UsageLimits] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var account: UsageLimits?
    @ObservationIgnored private var accountAsked = Date.distantPast

    init() {
        refresh()
        // Scheduled on the main run loop, so it fires there.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        if !UserDefaults.standard.bool(forKey: Prefs.claudeAccountUsage) {
            (account, accountAsked) = (nil, .distantPast)
        } else if Date().timeIntervalSince(accountAsked) >= 300 {
            askAccount()
        }
        let account = self.account
        DispatchQueue.global(qos: .utility).async {
            var found: [String: UsageLimits] = [:]
            found["claude"] = [Self.claude(), account].compactMap { $0 }
                .max { ($0.reportedAt ?? .distantPast) < ($1.reportedAt ?? .distantPast) }
            found["codex"] = Self.codex()
            DispatchQueue.main.async { if self.limits != found { self.limits = found } }
        }
    }

    private func askAccount() {
        accountAsked = Date()
        DispatchQueue.global(qos: .utility).async {
            ClaudeAccount.usage { result in
                DispatchQueue.main.async {
                    switch result {
                    case .limits(let limits):
                        self.account = limits
                        self.refresh()
                    case .denied:
                        // Asking again every few minutes would be worse than not showing it.
                        UserDefaults.standard.set(false, forKey: Prefs.claudeAccountUsage)
                    case .unavailable:
                        break
                    }
                }
            }
        }
    }

    nonisolated private static func claude() -> UsageLimits? {
        let url = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("usage/claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let window = { (key: String) -> UsageWindow? in
            guard let w = json[key] as? [String: Any], let used = w["used_percent"] as? Double,
                  let resets = w["resets_at"] as? Double else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let limits = UsageLimits(fiveHour: window("five_hour"), weekly: window("seven_day"),
                                 reportedAt: (json["updated_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }

    /// The newest `rate_limits` in Codex's most recent session logs.
    nonisolated private static func codex() -> UsageLimits? {
        for file in recentCodexSessions().prefix(6) {
            if let limits = lastRateLimits(in: file) { return limits }
        }
        return nil
    }

    /// Session logs newest first, from ~/.codex/sessions/YYYY/MM/DD.
    nonisolated private static func recentCodexSessions() -> [URL] {
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

    nonisolated private static func lastRateLimits(in file: URL) -> UsageLimits? {
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

/// Claude Code's limits as its account reports them, the numbers `/usage` shows, wherever
/// Claude Code runs (the desktop app never runs a status line). It uses the sign-in Claude
/// Code keeps in the Keychain, which macOS asks before handing over. tern never refreshes
/// that token, which would sign Claude Code out; an expired one waits for Claude Code to renew it.
nonisolated enum ClaudeAccount {
    enum Result: Sendable { case limits(UsageLimits), denied, unavailable }
    private enum Token { case token(String), denied, none }

    static func usage(done: @escaping @Sendable (Result) -> Void) {
        let token: String
        switch accessToken() {
        case .token(let t): token = t
        case .denied: return done(.denied)
        case .none: return done(.unavailable)
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return done(.unavailable) }
        var request = URLRequest(url: url, timeout: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("tern: Claude usage unavailable (HTTP %d%@)", status, error.map { ", \($0.localizedDescription)" } ?? "")
                return done(.unavailable)
            }
            let window = { (key: String) -> UsageWindow? in
                guard let w = json[key] as? [String: Any], let used = w["utilization"] as? Double else { return nil }
                return UsageWindow(usedPercent: used, resetsAt: (w["resets_at"] as? String).flatMap(date))
            }
            let limits = UsageLimits(fiveHour: window("five_hour"), weekly: window("seven_day"), reportedAt: Date())
            done(limits.fiveHour == nil && limits.weekly == nil ? .unavailable : .limits(limits))
        }.resume()
    }

    private static func accessToken() -> Token {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: break
        case errSecUserCanceled, errSecAuthFailed: return .denied
        default: return .none
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return .none }
        if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 { return .none }
        return .token(token)
    }

    /// "2026-10-21T23:00:00.943648+00:00": more fraction digits than ISO8601DateFormatter takes.
    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
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
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
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
                for agent in ["claude", "codex"] where installed[agent] != nil {
                    // Keep the last known newest version if the registry didn't answer this time.
                    found[agent] = Version(agent: agent, installed: installed[agent],
                                           latest: newest[agent] ?? self.versions[agent]?.latest)
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
    nonisolated private static func installedVersions() -> [String: String] {
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

private nonisolated extension URLRequest {
    init(url: URL, timeout: TimeInterval) {
        self.init(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    }
}
