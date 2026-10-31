import AppKit
import Foundation
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
    /// The Keychain refused Claude Code's sign-in. The setting stays on; tern stops asking
    /// until the next launch or `retryAccount()`, since asking every few minutes would be worse.
    private(set) var accountDenied = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var account: UsageLimits?
    @ObservationIgnored private var accountAsked = Date.distantPast
    @ObservationIgnored private var asking = false

    init() {
        refresh()
        // Scheduled on the main run loop, so it fires there.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        if !Prefs.defaults.bool(forKey: Prefs.claudeAccountUsage) {
            (account, accountAsked) = (nil, .distantPast)
            if accountDenied { accountDenied = false }
        } else if !accountDenied, !asking, Date().timeIntervalSince(accountAsked) >= 300 {
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

    /// Asks the Keychain again after it refused.
    func retryAccount() {
        (accountDenied, accountAsked) = (false, .distantPast)
        refresh()
    }

    private func askAccount() {
        (accountAsked, asking) = (Date(), true)
        DispatchQueue.global(qos: .utility).async {
            ClaudeAccount.usage { result in
                DispatchQueue.main.async {
                    self.asking = false
                    switch result {
                    case .limits(let limits):
                        self.account = limits
                        self.refresh()
                    case .denied:
                        // Never turn the setting off: a refusal can come from a dialog dismissed
                        // during an update, or from a dev build sharing these defaults.
                        self.accountDenied = true
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
/// Code keeps in the Keychain, only once the user turns this on. tern never refreshes
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

    /// Read through `security`, the tool Claude Code itself stores the item with, so the item
    /// already trusts it. Reading it directly would make macOS ask again whenever tern's
    /// signature changes or Claude Code rewrites the item on a token refresh.
    private static func accessToken() -> Token {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .none }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        switch p.terminationStatus {
        case 0: break
        // The low byte of the OSStatus: errSecUserCanceled (-128), errSecAuthFailed (-25293).
        case 128, 51: return .denied
        default: return .none
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

nonisolated extension URLRequest {
    init(url: URL, timeout: TimeInterval) {
        self.init(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    }
}
