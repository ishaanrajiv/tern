import Foundation
import XCTest
@testable import Tern

final class UpdateTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "tern-update-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return d
    }

    func testSkipHidesOnlyThatVersion() {
        let hidden = UpdateDismissals(defaults: defaults())
        hidden.skip(.codex, version: "0.164.0")
        XCTAssertTrue(hidden.isHidden(.codex, version: "0.164.0"))
        XCTAssertFalse(hidden.isHidden(.codex, version: "0.165.0"))
        XCTAssertFalse(hidden.isHidden(.claude, version: "0.164.0"))
    }

    func testSnoozeLastsADayForThatVersion() {
        let hidden = UpdateDismissals(defaults: defaults())
        let now = Date(timeIntervalSince1970: 1_000_000)
        hidden.snooze(.app, version: "v0.0.4", now: now)
        XCTAssertTrue(hidden.isHidden(.app, version: "v0.0.4", now: now.addingTimeInterval(23 * 3600)))
        XCTAssertFalse(hidden.isHidden(.app, version: "v0.0.4", now: now.addingTimeInterval(25 * 3600)))
        XCTAssertFalse(hidden.isHidden(.app, version: "v0.0.5", now: now))
    }

    func testOlderNotNowStillSkipsItsVersion() {
        let d = defaults()
        d.set("2.1.0", forKey: "dismissedAgentUpdate.claude")
        let hidden = UpdateDismissals(defaults: d)
        XCTAssertTrue(hidden.isHidden(.claude, version: "2.1.0"))
        XCTAssertFalse(hidden.isHidden(.claude, version: "2.1.1"))
        hidden.reset(.claude)
        XCTAssertFalse(hidden.isHidden(.claude, version: "2.1.0"))
    }

    func testUrgentRowsComeFirstThenRunsThenOffers() {
        let rows = UpdateEntry.sorted([
            UpdateEntry(source: .codex, title: "offer"),
            UpdateEntry(source: .claude, title: "running", tone: .progress),
            UpdateEntry(source: .app, title: "ready"),
            UpdateEntry(source: .daemon, title: "incompatible", tone: .warning),
        ])
        XCTAssertEqual(rows.map(\.source), [.daemon, .claude, .app, .codex])
    }

    private func session(_ id: String, process: String, agent: String? = nil, command: String? = nil) throws -> SessionInfo {
        var json: [String: Any] = ["id": id, "pid": 1, "cols": 80, "rows": 24, "clients": 1, "process": process,
                                   "title": "", "last_output_ms": 0, "bells": 0]
        if let agent { json["agent"] = agent }
        if let command { json["command"] = command }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testARestartCountsProgramsNotPrompts() throws {
        let sessions = [
            try session("p-1", process: "zsh", command: "ls"),
            try session("p-2", process: "-zsh"),
            try session("p-3", process: "node", command: "npm run dev"),
            try session("p-4", process: "claude", agent: "claude"),
            try session("p-5", process: "vim"),
            // A shell running a script, not sitting at its prompt.
            try session("p-6", process: "bash", command: "bash long-script.sh"),
            // A shell whose terminal can't be read.
            try session("p-7", process: "zsh"),
            try session("update-codex-1234", process: "codex"),
            try session("update-claude-5678", process: "sh"),
        ]
        let atPrompt: Set = ["p-1", "p-2", "p-5"]
        XCTAssertEqual(BusySessions.programs(in: sessions, updating: ["update-claude-5678"]) { atPrompt.contains($0.id) },
                       ["npm run dev", "Claude Code", "vim", "bash long-script.sh", "zsh", "the Claude Code update"])
        XCTAssertEqual(BusySessions.summary(["a", "b", "c", "d"]), "a, b and 2 more")
        XCTAssertEqual(BusySessions.summary(["a", "b"]), "a and b")
    }

    func testProbeFindsVersionsAndEveryCopyOnPath() {
        let text = """
        @@claude
        2.1.4 (Claude Code)
        @@claude-paths
        claude: aliased to claude --verbose
        /Users/me/.local/bin/claude
        /Users/me/.local/bin/claude
        @@codex
        codex-cli 0.164.0
        @@codex-paths
        /Users/me/.npm-packages/bin/codex
        /Users/me/.local/bin/codex
        """
        let probes = AgentUpdates.parseProbe(text)
        XCTAssertEqual(probes["claude"], AgentUpdates.Probe(version: "2.1.4", paths: ["/Users/me/.local/bin/claude"],
                                                            resolved: ["/Users/me/.local/bin/claude"]))
        XCTAssertEqual(probes["codex"]?.version, "0.164.0")
        XCTAssertEqual(probes["codex"]?.paths, ["/Users/me/.npm-packages/bin/codex", "/Users/me/.local/bin/codex"])
        // Two PATH entries that are one file count once.
        let linked = AgentUpdates.parseProbe("@@codex\n1.0.0\n@@codex-paths\n/a/codex\n/b/codex\n") { _ in "/real/codex" }
        XCTAssertEqual(linked["codex"]?.paths, ["/a/codex"])
        XCTAssertEqual(linked["codex"]?.resolved, ["/real/codex"])
        XCTAssertNil(AgentUpdates.parseProbe("@@claude\n@@claude-paths\n")["claude"]?.version)
    }

    @MainActor
    func testUpdateCommandFollowsTheInstall() {
        XCTAssertEqual(AgentUpdates.Version.updateCommand(agent: "claude", path: "/Users/me/.local/share/claude/versions/2.1.4"), "claude update")
        XCTAssertEqual(AgentUpdates.Version.updateCommand(agent: "claude", path: "/opt/homebrew/Caskroom/claude-code/2.1.4/claude"),
                       "brew upgrade --cask claude-code")
        XCTAssertEqual(AgentUpdates.Version.updateCommand(agent: "codex", path: nil), "codex update")
        var version = AgentUpdates.Version(agent: "codex", installed: "0.163.0", latest: "0.164.0", paths: ["/a/codex"])
        XCTAssertTrue(version.behind)
        XCTAssertNil(version.shadowWarning)
        version.paths.append("/b/codex")
        XCTAssertEqual(version.shadowWarning, "2 copies are on PATH; /a/codex runs first.")
    }

    /// The session command records the updater's exit code, even with awkward paths.
    func testRunScriptRecordsTheExitCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tern update's \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func run(_ command: String) throws -> (Int32, String?) {
            let status = dir.appendingPathComponent("run.status")
            try? FileManager.default.removeItem(at: status)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", UpdateRunner.script(command: command, shell: "/bin/sh", status: status.path)]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return (p.terminationStatus, try? String(contentsOf: status, encoding: .utf8))
        }
        XCTAssertEqual(try run("true").0, 0)
        XCTAssertEqual(try run("true").1, "0")
        let failed = try run("echo 'it''s broken'; exit 3")
        XCTAssertEqual(failed.0, 3)
        XCTAssertEqual(failed.1, "3")
    }

    func testRowsQuoteTheLastLineAndTimeTheRun() {
        XCTAssertEqual(UpdateRunner.lastLine("Downloading…\n  Install the update? [y/N]  \n\n"), "Install the update? [y/N]")
        XCTAssertNil(UpdateRunner.lastLine("\n  \n"))
        XCTAssertEqual(UpdateRunner.duration(14.4), "14s")
        XCTAssertEqual(UpdateRunner.duration(125), "2m 5s")
        XCTAssertEqual(UpdateRunner.duration(-3), "0s")
    }

    func testFailuresAndQuestionsOutlineTheCard() {
        XCTAssertTrue(UpdateEntry(source: .codex, title: "", tone: .waiting).needsYou)
        XCTAssertTrue(UpdateEntry(source: .claude, title: "", tone: .failure).needsYou)
        XCTAssertFalse(UpdateEntry(source: .daemon, title: "", tone: .scheduled).needsYou)
        XCTAssertFalse(UpdateEntry(source: .app, title: "").needsYou)
        let rows = UpdateEntry.sorted([
            UpdateEntry(source: .app, title: "offer"),
            UpdateEntry(source: .daemon, title: "when idle", tone: .scheduled),
            UpdateEntry(source: .claude, title: "failed", tone: .failure),
        ])
        XCTAssertEqual(rows.map(\.source), [.claude, .daemon, .app])
    }

    func testAQuietQuestionLooksLikeAPrompt() {
        XCTAssertTrue(UpdateRunner.looksLikePrompt("Downloading…\nPassword:"))
        XCTAssertTrue(UpdateRunner.looksLikePrompt("Install the update? [y/N] \n\n"))
        XCTAssertTrue(UpdateRunner.looksLikePrompt("Select a version ›"))
        XCTAssertFalse(UpdateRunner.looksLikePrompt("Downloading 2.1.4 (34%)"))
        XCTAssertFalse(UpdateRunner.looksLikePrompt(""))
    }

    func testRunSessionsAreNotTabs() {
        XCTAssertTrue(UpdateRunner.isRunSession("update-claude-1a2b3c4d"))
        XCTAssertFalse(UpdateRunner.isRunSession("p-123"))
        XCTAssertEqual(UpdateRunner.agent(ofRun: "update-codex-1a2b3c4d"), "codex")
        XCTAssertNil(UpdateRunner.agent(ofRun: "p-123"))
    }

    /// launchd (pid 1) has no terminal, so it never reads as a shell at its prompt.
    func testAProcessWithoutATerminalIsNotAtAPrompt() throws {
        let me = try session("p-1", process: "zsh")
        XCTAssertFalse(BusySessions.shellHoldsTerminal(me))
    }

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, assets: Bool = true) -> [String: Any] {
        let name = "Tern-\(tag.dropFirst())-macos-arm64.zip"
        let url = "https://github.com/ishaanrajiv/tern/releases/download/\(tag)/"
        return ["tag_name": tag, "html_url": "https://github.com/ishaanrajiv/tern/releases/tag/\(tag)", "draft": draft,
                "prerelease": prerelease,
                "assets": assets ? [["name": name, "browser_download_url": url + name, "size": 10],
                                    ["name": name + ".sha256", "browser_download_url": url + name + ".sha256", "size": 64]] : []]
    }

    /// Checks carry on once a release is staged, and a different pick replaces it.
    @MainActor
    func testANewerReleaseReplacesTheStagedOne() throws {
        let defaults = UserDefaults.standard
        let saved = [Prefs.includePrereleases, Prefs.downloadAppUpdates].map { ($0, defaults.object(forKey: $0)) }
        addTeardownBlock { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: Prefs.includePrereleases)
        defaults.set(false, forKey: Prefs.downloadAppUpdates)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tern-staged-\(UUID().uuidString)")
        let bundle = dir.appendingPathComponent("Tern.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let decode = { (list: [[String: Any]]) in
            try JSONDecoder().decode([AppRelease].self, from: JSONSerialization.data(withJSONObject: list))
        }

        let updates = AppUpdates()
        updates.staged(bundle, tag: "v9.0.0")
        updates.received(try decode([release("v9.0.0")]), interactive: false, current: "0.0.3")
        XCTAssertEqual(updates.phase, .ready)
        XCTAssertEqual(updates.staged, bundle)

        updates.received(try decode([release("v9.0.1"), release("v9.0.0")]), interactive: false, current: "0.0.3")
        XCTAssertEqual(updates.release?.tag_name, "v9.0.1")
        XCTAssertNil(updates.staged)
        XCTAssertEqual(updates.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        // Prereleases turned off: a staged alpha is no longer offered.
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        updates.staged(bundle, tag: "v9.1.0-alpha.1")
        updates.received(try decode([release("v9.1.0-alpha.1", prerelease: true)]), interactive: false, current: "0.0.3")
        XCTAssertNil(updates.release)
        XCTAssertNil(updates.staged)
    }

    func testNewestReleaseSkipsDraftsIncompleteAndUnwantedPrereleases() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            release("v0.0.6", draft: true),
            release("v0.0.5", assets: false),
            release("v0.0.4-alpha.1", prerelease: true),
            release("v0.0.3"),
            release("v0.0.2"),
        ])
        let releases = try JSONDecoder().decode([AppRelease].self, from: data)
        XCTAssertEqual(AppUpdates.newest(in: releases, current: "0.0.2", prereleases: true)?.tag_name, "v0.0.4-alpha.1")
        XCTAssertEqual(AppUpdates.newest(in: releases, current: "0.0.2", prereleases: false)?.tag_name, "v0.0.3")
        XCTAssertNil(AppUpdates.newest(in: releases, current: "0.0.4", prereleases: true))
    }
}
