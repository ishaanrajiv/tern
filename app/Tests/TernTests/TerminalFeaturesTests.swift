import AppKit
import XCTest
@testable import Tern

@MainActor
final class TerminalFeaturesTests: XCTestCase {
    func testLinkSchemesAndControlCharacters() {
        for text in ["https://example.com/a?q=1", "http://localhost:3000", "mailto:me@example.com", "file:///tmp/a", "vscode://file/tmp/a:2"] {
            XCTAssertNotNil(TerminalLink.url(text), text)
        }
        for text in ["javascript:alert(1)", "data:text/html,hello", "https://example.com\n", "relative/path", "https://example.com\0"] {
            XCTAssertNil(TerminalLink.url(text), text)
        }
    }

    func testResizeNearestMatchingDividerAndClamp() {
        let tree = SplitNode.split(.horizontal, ratio: 0.4, .pane("a"), .split(.vertical, ratio: 0.5, .pane("b"), .pane("c")))
        guard case .split(.horizontal, let ratio, let a, let b) = tree.resizing("c", axis: .horizontal, delta: 0.1) else { return XCTFail("Expected the outer divider to resize") }
        XCTAssertEqual(ratio, 0.3, accuracy: 0.000001)
        XCTAssertEqual(a, .pane("a"))
        XCTAssertEqual(b, .split(.vertical, ratio: 0.5, .pane("b"), .pane("c")))
        XCTAssertEqual(tree.resizing("b", axis: .vertical, delta: 10), .split(.horizontal, ratio: 0.4, .pane("a"), .split(.vertical, ratio: 0.9, .pane("b"), .pane("c"))))
        XCTAssertNil(tree.resizing("missing", axis: .horizontal, delta: 0.1))
    }

    func testSwapAndDetachPreserveSessionIdentity() {
        let w = Workspace()
        let tab = w.newTab(projectPath: "/tmp", cwd: "/tmp", paneID: "a")
        w.split(.horizontal)
        let second = w.selectedTab!.focusedPane
        w.swapPane(1)
        XCTAssertEqual(w.selectedTab?.root.panes, [second, "a"])
        w.detachPane()
        XCTAssertEqual(w.allTabs.count, 2)
        XCTAssertEqual(Set(w.allTabs.flatMap { $0.root.panes }), Set(["a", second]))
        XCTAssertEqual(w.allTabs.first { $0.id == tab.id }?.root, .pane("a"))
        XCTAssertEqual(w.selectedTab?.root, .pane(second))
    }

    func testMovePaneAndTabPreserveAllPanes() {
        let w = Workspace()
        let first = w.newTab(projectPath: "/tmp", cwd: "/tmp", paneID: "a")
        w.split(.vertical)
        let b = w.selectedTab!.focusedPane
        let second = w.newTab(projectPath: "/tmp", cwd: "/tmp", paneID: "c")
        w.select(first.id)
        w.movePaneToNextTab()
        XCTAssertEqual(w.selectedTabID, second.id)
        XCTAssertEqual(w.selectedTab?.root.panes, ["c", b])
        _ = w.newTab(projectPath: "/private/tmp", cwd: "/tmp", paneID: "d")
        w.moveTab(first.id, to: "/private/tmp")
        XCTAssertEqual(Set(w.allTabs.flatMap { $0.root.panes }), Set(["a", b, "c", "d"]))
        XCTAssertEqual(w.projects.first { $0.path == "/private/tmp" }?.tabs.count, 2)
    }

    func testTabReorderInBothDirections() {
        let w = Workspace()
        let a = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        let b = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        let c = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        w.shiftTab(-1)
        XCTAssertEqual(w.allTabs.map(\.id), [a.id, c.id, b.id])
        w.shiftTab(1)
        XCTAssertEqual(w.allTabs.map(\.id), [a.id, b.id, c.id])
    }

    func testRemoteValidationAndQuoting() throws {
        let remote = RemoteConnection(host: "me@build-box", directory: "/tmp/a 'quoted' $(touch bad)", tmuxSession: "agents_1")
        try remote.validate()
        let command = remote.command(startup: "printf '%s' \"$VALUE\"", environment: ["VALUE": "a'; touch bad; '"])
        XCTAssertTrue(command.hasPrefix("TERM=xterm-256color ssh -t -- 'me@build-box' "))
        XCTAssertTrue(command.contains("tmux new-session -A"))
        for host in ["-oProxyCommand=bad", "host;bad", "host name", "$(bad)", "host\n"] {
            XCTAssertThrowsError(try RemoteConnection(host: host).validate(), host)
        }
        XCTAssertThrowsError(try RemoteConnection(host: "box", tmuxSession: "bad.name").validate())
        XCTAssertThrowsError(try RemoteConnection(host: "box", directory: "relative").validate())
    }

    func testShellQuoteRoundTripsWithoutExecutingValue() throws {
        let value = "a 'quoted' $(printf bad); `printf bad`\nline"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + quoteShell(value)]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), value)
    }

    func testSSHCommandRoundTripsRemotePathAndEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tern-ssh-" + UUID().uuidString)
        let remoteFolder = folder.appendingPathComponent("a 'quote' $(printf BAD)")
        try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("result")
        let value = "a 'quote' $(printf BAD); `printf BAD`"
        let remote = RemoteConnection(host: "example", directory: remoteFolder.path)
        // Replace only the transport. Execute the exact remote shell command locally.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        let startup = "printf '%s\\n%s' \"$PWD\" \"$TERN_VALUE\" > " + quoteShell(output.path) + "; exit"
        shell.arguments = ["-c", "ssh() { shift 3; /bin/sh -c \"$1\"; }; " + remote.command(startup: startup, environment: ["TERN_VALUE": value])]
        try shell.run(); shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), remoteFolder.path + "\n" + value)
    }

    func testPresetLaunchUsesFreshIDsAndQueuesHiddenPanes() throws {
        let w = Workspace()
        _ = w.newTab(projectPath: "/tmp", cwd: "/tmp", paneID: "old")
        w.split(.horizontal)
        var preset = w.capturePreset(name: "Build")
        for id in preset.tabs[0].root.panes { preset.tabs[0].panes[id]?.command = "echo ready" }
        let old = Set(w.allTabs.flatMap { $0.root.panes })
        try w.launch(preset)
        let firstLaunch = Set(w.selectedTab!.root.panes)
        XCTAssertTrue(old.isDisjoint(with: firstLaunch))
        XCTAssertEqual(w.panesNeedingLaunch, firstLaunch)
        try w.launch(preset)
        XCTAssertTrue(firstLaunch.isDisjoint(with: Set(w.selectedTab!.root.panes)))
        XCTAssertEqual(w.allTabs.count, 3)
        let id = w.selectedTab!.root.panes[0]
        XCTAssertEqual(w.resumeCommand(for: id), "echo ready")
        XCTAssertEqual(w.resumeCommand(for: id), "echo ready")
    }

    func testInvalidPresetDoesNotPartiallyCreateTabs() {
        let w = Workspace()
        let preset = LaunchPreset(name: "Bad", project: "/tmp", tabs: [LaunchTab(root: .pane("a"), panes: ["a": LaunchPane(directory: "/tmp")]), LaunchTab(root: .pane("b"), panes: [:])])
        XCTAssertThrowsError(try w.launch(preset))
        XCTAssertTrue(w.allTabs.isEmpty)
    }

    func testPresetRejectsFilesEnvironmentInjectionAndBadRatios() {
        XCTAssertThrowsError(try LaunchPane(directory: "/etc/hosts").validate())
        XCTAssertThrowsError(try LaunchPane(directory: "/tmp", environment: ["A;bad": "x"]).validate())
        let preset = LaunchPreset(name: "Bad", project: "/tmp", tabs: [LaunchTab(root: .split(.horizontal, ratio: 2, .pane("a"), .pane("b")), panes: ["a": LaunchPane(directory: "/tmp"), "b": LaunchPane(directory: "/tmp")])])
        XCTAssertThrowsError(try preset.validate())
    }

    func testRemoteLaunchAndSplitRetainConnection() throws {
        let w = Workspace()
        let remote = RemoteConnection(host: "box", directory: "~/repo", tmuxSession: "work")
        try w.openRemote(remote)
        let original = w.selectedTab!.focusedPane
        XCTAssertEqual(w.remote(for: original), remote)
        XCTAssertEqual(w.resumeCommand(for: original), remote.command())
        w.split(.horizontal)
        XCTAssertEqual(w.remote(for: w.selectedTab!.focusedPane), remote)
        XCTAssertEqual(w.resumeCommand(for: w.selectedTab!.focusedPane), remote.command())
        XCTAssertEqual(w.capturePreset(name: "SSH").tabs[0].panes[original]?.remote, remote)
    }

    func testSavedLayoutRoundTripsRemoteConnections() throws {
        let remote = RemoteConnection(host: "box")
        let saved = Workspace.Saved(version: 1, projects: [], paneCwd: [:], paneRemote: ["p": remote])
        let (loaded, dropped) = Workspace.decodeLayout(try JSONEncoder().encode(saved))
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(loaded?.paneRemote?["p"], remote)
    }
}
