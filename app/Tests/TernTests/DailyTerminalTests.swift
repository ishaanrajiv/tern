import AppKit
import XCTest
@testable import Tern

@MainActor
final class DailyTerminalTests: XCTestCase {
    func testDiagnosticLocationsAndEditorEscaping() {
        XCTAssertEqual(FileReference.parse("src/main.rs:42:8:", cwd: "/tmp"), FileReference(path: "/tmp/src/main.rs", line: 42, column: 8))
        XCTAssertEqual(FileReference.parse("\"/tmp/a file.swift:2\"", cwd: "/"), FileReference(path: "/tmp/a file.swift", line: 2, column: nil))
        XCTAssertNil(FileReference.parse("https://example.com/a:2", cwd: "/tmp"))
        XCTAssertNil(FileReference.parse("bad\nfile", cwd: "/tmp"))
        let ref = FileReference(path: "/tmp/a #?.swift", line: 3, column: 4)
        let url = ref.editorURL("vscode")!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, "/tmp/a #?.swift:3:4")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }

    func testExternalURLsCannotCarryCommands() {
        let url = URL(string: "tern://open?path=%2Ftmp%2Fa%20b&command=rm&window=true")!
        XCTAssertEqual(AppOpenRequest.from(url: url), AppOpenRequest(directory: "/tmp/a b", window: true))
        XCTAssertNil(AppOpenRequest.from(url: URL(string: "tern://open?path=relative")!))
        XCTAssertNil(AppOpenRequest.from(url: URL(string: "https://open?path=/tmp")!))
    }

    func testNewTabsInheritCwdWithExplicitRootAction() {
        let w = Workspace()
        let first = w.newTab(projectPath: "/tmp", cwd: "/tmp/child")
        _ = w.newTabInCurrentProject(worktree: false)
        XCTAssertEqual(w.cwd(for: w.selectedTab!.focusedPane), "/tmp/child")
        XCTAssertNotEqual(w.selectedTab?.id, first.id)
        _ = w.newTabInCurrentProject(worktree: false, projectRoot: true)
        XCTAssertEqual(w.cwd(for: w.selectedTab!.focusedPane), "/tmp")
        w.split(.horizontal, directory: "/private/tmp", command: "printf hello")
        let pane = w.selectedTab!.focusedPane
        XCTAssertEqual(w.cwd(for: pane), "/private/tmp")
        XCTAssertEqual(w.resumeCommand(for: pane), "printf hello")
        XCTAssertEqual(w.resumeCommand(for: pane), "printf hello")
    }
    func testWindowCatalogSkipsBadEntriesAndUnsafeIdentifiers() throws {
        let data = Data(#"[{"id":"main","frame":"bad"},{"id":"../escape"},{"id":"w-deadbeef","active":true},{"id":"main"},17]"#.utf8)
        let records = WindowCatalog.decode(data)
        XCTAssertEqual(records.map(\.id), ["main", "w-deadbeef"])
        XCTAssertNil(records[0].rect)
        XCTAssertTrue(records[1].active)
        let record = WindowRecord(id: "main", frame: NSStringFromRect(NSRect(x: 20, y: 30, width: 800, height: 600)))
        XCTAssertEqual(record.rect, NSRect(x: 20, y: 30, width: 800, height: 600))
    }

    func testTransferPreservesPaneIdentityAndPendingCommand() {
        let source = Workspace(), destination = Workspace()
        let tab = source.newTab(projectPath: "/tmp", cwd: "/tmp/child")
        source.split(.vertical, directory: "/tmp", command: "printf ready")
        let panes = source.selectedTab!.root.panes
        let pending = source.selectedTab!.focusedPane
        let transfer = source.takeTab(tab.id)!
        XCTAssertTrue(source.allTabs.isEmpty)
        destination.insertTab(transfer)
        XCTAssertEqual(destination.selectedTab?.id, tab.id)
        XCTAssertEqual(destination.selectedTab?.root.panes, panes)
        XCTAssertEqual(destination.cwd(for: panes[0]), "/tmp/child")
        XCTAssertEqual(destination.resumeCommand(for: pending), "printf ready")
        XCTAssertEqual(destination.resumeCommand(for: pending), "printf ready")
        destination.insertTab(transfer)
        XCTAssertEqual(destination.allTabs.count, 1)
    }

    func testClosedTabReopensWithFreshPanesAndKeepsLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-recovery-" + UUID().uuidString)
        defer { Workspace.finishSaving(); try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storageURL: directory.appendingPathComponent("layout.json"))
        let tab = workspace.newTab(projectPath: "/tmp", cwd: "/tmp/child")
        workspace.split(.vertical)
        let original = Set(workspace.selectedTab!.root.panes)
        workspace.rememberClosedTab(tab.id)
        _ = workspace.takeTab(tab.id)
        workspace.reopenClosedTab()
        XCTAssertTrue(original.isDisjoint(with: workspace.selectedTab!.root.panes))
        XCTAssertEqual(workspace.selectedTab!.root.panes.count, 2)
        XCTAssertEqual(workspace.cwd(for: workspace.selectedTab!.root.panes[0]), "/tmp/child")
        workspace.save(); Workspace.finishSaving()
        let restored = Workspace(storageURL: workspace.storageURL)
        restored.load()
        XCTAssertEqual(restored.projects, workspace.projects)
    }

    func testWorktreeRemainsInUseAfterMovingAndDetachingPane() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-worktree-" + UUID().uuidString)
        defer { Workspace.finishSaving(); try? FileManager.default.removeItem(at: directory) }
        let source = Workspace(storageURL: directory.appendingPathComponent("source.json"))
        let destination = Workspace(storageURL: directory.appendingPathComponent("destination.json"))
        let tab = source.newTab(projectPath: "/tmp", cwd: "/tmp/worktree")
        var transfer = source.takeTab(tab.id)!
        transfer.tab.worktree = "/tmp/worktree"
        source.insertTab(transfer)
        source.split(.horizontal)
        source.detachPane()
        destination.insertTab(source.takeTab(source.selectedTabID!)!)
        source.rememberClosedTab(tab.id)
        source.removePane(tab.focusedPane)
        XCTAssertFalse(source.usesWorktree("/tmp/worktree"))
        XCTAssertTrue([source, destination].contains { $0.usesWorktree("/tmp/worktree") })
        destination.detachTab(destination.selectedTabID!)
        XCTAssertTrue(destination.usesWorktree("/tmp/worktree"))
        destination.forgetDetached(destination.detachedPanes)
        XCTAssertFalse(destination.usesWorktree("/tmp/worktree"))
    }

    func testOutputSearchUsesLiteralRegexAndCaseChoices() throws {
        let source = OutputSource(id: "p", title: "Build")
        let output = "Error [42]\nerror 17\nOK\n"
        XCTAssertEqual(OutputMatcher.range(ofLine: 2, in: "👍\n日本"), NSRange(location: 3, length: 2))
        XCTAssertNil(OutputMatcher.range(ofLine: 6, in: output))
        XCTAssertEqual(try OutputMatcher.matches(output, source: source, query: "[42]", regex: false, caseSensitive: false).map(\.line), [1])
        XCTAssertEqual(try OutputMatcher.matches(output, source: source, query: "^error", regex: true, caseSensitive: false).map(\.line), [1, 2])
        XCTAssertEqual(try OutputMatcher.matches(output, source: source, query: "Error", regex: false, caseSensitive: true).count, 1)
        XCTAssertThrowsError(try OutputMatcher.matches(output, source: source, query: "[", regex: true, caseSensitive: false))
    }

    func testReleaseVersionsAndDownloadOrigins() {
        XCTAssertTrue(AppVersion("v0.0.3")! > AppVersion("0.0.2")!)
        XCTAssertTrue(AppVersion("1.0.0")! > AppVersion("1.0.0-beta.2")!)
        XCTAssertTrue(AppVersion("1.0.0-beta.10")! > AppVersion("1.0.0-beta.2")!)
        for value in ["../../1.0.0", "1.0", "a.b.c", "1.0.0-", "1.0.0-a/b"] { XCTAssertNil(AppVersion(value)) }
        XCTAssertTrue(UpdateInstaller.trustedAsset(URL(string: "https://github.com/ishaanrajiv/tern/releases/download/v0.0.3/Tern.zip")!))
        for value in ["http://github.com/ishaanrajiv/tern/releases/download/a", "https://evil.test/ishaanrajiv/tern/releases/download/a", "https://github.com/another/tern/releases/download/a"] {
            XCTAssertFalse(UpdateInstaller.trustedAsset(URL(string: value)!))
        }
    }

    func testUpdateSignatureRequirementIsParsedAsText() throws {
        // Calculator is Apple-signed, so codesign must parse the requirement and then reject the identifier.
        let calculator = "/System/Applications/Calculator.app"
        XCTAssertThrowsError(try UpdateInstaller.run("/usr/bin/codesign", ["--verify", "-R", UpdateInstaller.requirement(team: "TU6PRMN38J"), calculator])) { error in
            guard case UpdateError.message(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("failed to satisfy"), text)
        }
    }

    func testUpdateArchiveRejectsTraversalSymlinksAndHeaderMismatch() throws {
        // A valid, empty stored file with matching local and central headers.
        func archive(_ name: String, localName: String? = nil, mode: UInt32 = 0o100644) -> Data {
            var bytes = Data()
            func append(_ value: UInt64, _ count: Int) { for i in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * i))) } }
            let local = Array((localName ?? name).utf8), central = Array(name.utf8)
            append(0x04034b50, 4); append(20, 2); append(0, 2); append(0, 2)
            append(0, 4); append(0, 4); append(0, 4); append(0, 4); append(UInt64(local.count), 2); append(0, 2)
            bytes.append(contentsOf: local)
            let offset = bytes.count
            append(0x02014b50, 4); append(0x0314, 2); append(20, 2); append(0, 2); append(0, 2)
            append(0, 4); append(0, 4); append(0, 4); append(0, 4); append(UInt64(central.count), 2)
            append(0, 2); append(0, 2); append(0, 2); append(0, 2); append(UInt64(mode) << 16, 4); append(0, 4)
            bytes.append(contentsOf: central)
            let directorySize = bytes.count - offset
            append(0x06054b50, 4); append(0, 2); append(0, 2); append(1, 2); append(1, 2)
            append(UInt64(directorySize), 4); append(UInt64(offset), 4); append(0, 2)
            return bytes
        }
        XCTAssertNoThrow(try UpdateArchive.validate(archive("Tern.app/Contents/Info.plist")))
        for name in ["../escape", "/Tern.app/evil", "Tern.app/../../evil", "Other.app/file", "Tern.app/a\\b"] {
            XCTAssertThrowsError(try UpdateArchive.validate(archive(name)))
        }
        XCTAssertThrowsError(try UpdateArchive.validate(archive("Tern.app/link", mode: 0o120777)))
        XCTAssertThrowsError(try UpdateArchive.validate(archive("Tern.app/safe", localName: "../unsafe")))
        XCTAssertThrowsError(try UpdateArchive.validate(Data([0, 1, 2])))
    }

    func testStartupCommandSurvivesRelayReplacementUntilDaemonAcknowledges() throws {
        let source = Workspace(), target = Workspace()
        source.adoptsOrphans = false; target.adoptsOrphans = false
        source.run("printf once", in: "/tmp")
        let tab = source.selectedTab!, pane = source.selectedTab!.focusedPane
        XCTAssertEqual(source.resumeCommand(for: pane), "printf once")
        target.insertTab(source.takeTab(tab.id)!)
        XCTAssertEqual(target.resumeCommand(for: pane), "printf once")
        let data = Data("{\"id\":\"\(pane)\",\"pid\":1,\"cols\":80,\"rows\":24,\"clients\":1,\"process\":\"zsh\",\"title\":\"\",\"lastOutputMs\":0,\"bells\":0}".utf8)
        let session = try JSONDecoder().decode(SessionInfo.self, from: data)
        target.update(sessions: [session])
        XCTAssertNil(target.resumeCommand(for: pane))
    }

    func testTabsGoByWhatTheyRunAndOtherwiseSayShell() throws {
        let w = Workspace()
        w.adoptsOrphans = false
        let first = w.newTab(projectPath: "/tmp/proj", cwd: "/tmp/proj")
        func session(_ pane: String, process: String = "zsh", cwd: String = "/tmp/proj", command: String? = nil) throws -> SessionInfo {
            var json: [String: Any] = ["id": pane, "pid": 1, "cols": 80, "rows": 24, "clients": 1, "process": process,
                                       "title": "", "lastOutputMs": 0, "bells": 0, "cwd": cwd]
            json["command"] = command
            return try JSONDecoder().decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: json))
        }
        w.update(sessions: [try session(first.focusedPane)])
        XCTAssertEqual(w.title(for: first), "Shell")
        XCTAssertTrue(w.hasPlaceholderTitle(first))

        // A second unnamed tab numbers both.
        let second = w.newTab(projectPath: "/tmp/proj", cwd: "/tmp/proj")
        w.update(sessions: [try session(first.focusedPane), try session(second.focusedPane)])
        XCTAssertEqual(w.title(for: first), "Shell \(first.number!)")
        XCTAssertEqual(w.title(for: second), "Shell \(second.number!)")

        // A subfolder, then a command, name it; the other goes back to plain "Shell".
        w.update(sessions: [try session(first.focusedPane, cwd: "/tmp/proj/app"), try session(second.focusedPane)])
        XCTAssertEqual(w.title(for: first), "app")
        XCTAssertFalse(w.hasPlaceholderTitle(first))
        XCTAssertEqual(w.title(for: second), "Shell")
        w.update(sessions: [try session(first.focusedPane, cwd: "/tmp/proj/app", command: "npm run dev"), try session(second.focusedPane)])
        XCTAssertEqual(w.title(for: first), "npm run dev")
        w.rename(first.id, to: "API")
        XCTAssertEqual(w.title(for: w.allTabs.first { $0.id == first.id }!), "API")

        // ternd reports the real path; "/tmp" is "/private/tmp", which is still the folder root.
        let tmp = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        w.update(sessions: [try session(tmp.focusedPane, cwd: "/private/tmp")])
        XCTAssertNil(w.strayCwd(tmp))
        XCTAssertEqual(w.title(for: tmp), "Shell")
    }

    func testAgentConversationNamesComeFromTheirOwnFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tern-names-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("-tmp-proj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let transcript = claude.appendingPathComponent("-tmp-proj/c1.jsonl")
        try Data("""
        {"type":"user","message":"hi"}
        {"type":"ai-title","aiTitle":"Summarize README","sessionId":"c1"}

        """.utf8).write(to: transcript)
        try Data("""
        {"id":"x1","thread_name":"Old name"}
        {"id":"x1","thread_name":"Explain updater flow"}

        """.utf8).write(to: codex.appendingPathComponent("session_index.jsonl"))
        let refs = [AgentRef(agent: "claude", session: "c1"), AgentRef(agent: "codex", session: "x1")]
        var (names, cache) = AgentNames.lookup(refs, cache: .init(), claudeRoot: claude, codexRoot: codex)
        XCTAssertEqual(names, ["c1": "Summarize README", "x1": "Explain updater flow"])

        // /rename wins over the generated title; a half-written line waits for its newline.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"custom-title","customTitle":"README tour"}"# + "\n" + #"{"type":"custom-title","custom"#).utf8))
        try handle.close()
        (names, cache) = AgentNames.lookup(refs, cache: cache, claudeRoot: claude, codexRoot: codex)
        XCTAssertEqual(names["c1"], "README tour")
    }

    func testAgentTabIgnoresTheShellTitleItInherited() throws {
        let w = Workspace()
        w.adoptsOrphans = false
        let tab = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        func session(_ process: String, agent: String?, title: String) throws -> SessionInfo {
            var json: [String: Any] = ["id": tab.focusedPane, "pid": 1, "cols": 80, "rows": 24, "clients": 1, "process": process,
                                       "title": title, "lastOutputMs": 0, "bells": 0, "cwd": "/tmp"]
            json["agent"] = agent
            return try JSONDecoder().decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: json))
        }
        w.update(sessions: [try session("zsh", agent: nil, title: "zsh in tmp")])
        w.update(sessions: [try session("claude", agent: "claude", title: "zsh in tmp")])
        XCTAssertEqual(w.title(for: tab), "claude")
        w.update(sessions: [try session("claude", agent: "claude", title: "✳ Fix login redirect")])
        XCTAssertEqual(w.title(for: tab), "Fix login redirect")
    }

    func testCommandOutcomesSpeakPlainly() throws {
        XCTAssertNil(CommandOutcome(exitCode: 0, durationMs: 40))
        XCTAssertNil(CommandOutcome(exitCode: nil, durationMs: 40))
        XCTAssertNil(CommandOutcome(exitCode: 130, durationMs: 60_000), "⌃C says nothing")
        XCTAssertEqual(CommandOutcome(exitCode: 0, durationMs: 134_000)?.text, "Done in 2m 14s")
        let failed = CommandOutcome(exitCode: 1, durationMs: 2300)
        XCTAssertEqual(failed?.text, "Failed")
        XCTAssertEqual(failed?.failed, true)
        XCTAssertEqual(failed?.detail, "Exit code 1 · 2.3s")
        XCTAssertEqual(CommandOutcome(exitCode: 127, durationMs: 5)?.text, "Command not found")
        XCTAssertEqual(CommandOutcome.duration(12_400), "12s")
        XCTAssertEqual(CommandOutcome.duration(3_900_000), "1h 5m")

        // `false`, then `read`: the shell stays in front, but the failure is the last command's.
        func session(running: Bool) throws -> SessionInfo {
            let json = #"{"id":"p","pid":1,"cols":80,"rows":24,"clients":1,"process":"zsh","title":"","last_output_ms":0,"bells":0,"#
                + #""exit_code":1,"duration_ms":4,"command_running":\#(running)}"#
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SessionInfo.self, from: Data(json.utf8))
        }
        XCTAssertEqual(CommandOutcome.shown(for: try session(running: false))?.text, "Failed")
        XCTAssertNil(CommandOutcome.shown(for: try session(running: true)))
    }

    func testClosingWindowTransfersDetachedRecoveryMetadata() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-detach-" + UUID().uuidString)
        defer { Workspace.finishSaving(); try? FileManager.default.removeItem(at: directory) }
        let source = Workspace(storageURL: directory.appendingPathComponent("source.json"))
        let destination = Workspace(storageURL: directory.appendingPathComponent("destination.json"))
        let tab = source.newTab(projectPath: "/tmp", cwd: "/tmp/child")
        source.split(.horizontal)
        let original = source.selectedTab!.root.panes
        source.detachTab(tab.id)
        XCTAssertTrue(source.keepsEmptyWindow)
        destination.absorbRecovery(from: source)
        XCTAssertEqual(destination.detachedPanes, Set(original))
        XCTAssertEqual(destination.closedTabs.first?.tab.root.panes, original)
        destination.save(); Workspace.finishSaving()
        let loaded = Workspace(storageURL: destination.storageURL)
        loaded.load()
        XCTAssertEqual(loaded.detachedPanes, Set(original))
        XCTAssertEqual(loaded.closedTabs.first?.directories[original[0]], "/tmp/child")
    }

    func testInvalidWindowLayoutsKeepSeparateBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-backups-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Workspace.finishSaving(); try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"version":1,"projects":[{"tabs":"broken"}]}"#.utf8)
        for name in ["w-a", "w-b"] {
            let url = directory.appendingPathComponent(name + ".json")
            try data.write(to: url)
            Workspace(storageURL: url).load()
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("layout-w-a-") }.count, 1)
        XCTAssertEqual(names.filter { $0.hasPrefix("layout-w-b-") }.count, 1)
    }

}
