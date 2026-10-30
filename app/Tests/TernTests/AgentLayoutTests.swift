import XCTest
@testable import Tern

/// ternd edits the saved layout for `tern split`, `tab` and `close`, so its shape is a
/// contract between the app and crates/tern/src/bin/ternd/layout.rs.
@MainActor
final class AgentLayoutTests: XCTestCase {
    func testSplitPanesEncodeTheWayTerndReadsThem() throws {
        let node = SplitNode.split(.vertical, ratio: 0.5, .pane("p-1"), .pane("p-2"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any]
        let split = try XCTUnwrap(json?["split"] as? [String: Any])
        XCTAssertEqual(split["_0"] as? String, "vertical")
        XCTAssertEqual(split["ratio"] as? Double, 0.5)
        XCTAssertEqual((split["_2"] as? [String: Any])?["pane"] as? [String: String], ["_0": "p-1"])
        XCTAssertEqual((split["_3"] as? [String: Any])?["pane"] as? [String: String], ["_0": "p-2"])
    }

    func testALayoutTerndChangedLoadsWithNamesAndOpeners() throws {
        // As ternd writes it after `tern split --name tests` from Claude Code in p-1.
        let doc = """
        {"version": 1, "selectedTabID": "t-1", "paneCwd": {"p-1": "/repo", "p-2": "/repo"},
         "paneName": {"p-2": "tests"}, "paneOpener": {"p-2": "claude"},
         "projects": [{"path": "/repo", "collapsed": false, "tabs": [{"id": "t-1", "number": 1, "focusedPane": "p-1",
           "root": {"split": {"_0": "horizontal", "ratio": 0.5, "_2": {"pane": {"_0": "p-1"}}, "_3": {"pane": {"_0": "p-2"}}}}}]}]}
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-agent-" + UUID().uuidString)
        defer { Workspace.finishSaving(); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("layout.json")
        try Data(doc.utf8).write(to: url)
        let workspace = Workspace(storageURL: url)
        workspace.load()
        XCTAssertEqual(workspace.selectedTab?.root.panes, ["p-1", "p-2"])
        XCTAssertEqual(workspace.selectedTab?.focusedPane, "p-1")
        XCTAssertEqual(workspace.name(pane: "p-2"), "tests")
        XCTAssertEqual(workspace.opener(pane: "p-2"), "claude")
        // Nothing was set aside: the file is one this build reads whole.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["layout.json"])

        // Saved back, the names survive; closing the pane drops them.
        workspace.save(); Workspace.finishSaving()
        let again = Workspace(storageURL: url)
        again.load()
        XCTAssertEqual(again.name(pane: "p-2"), "tests")
        again.removePane("p-2")
        XCTAssertNil(again.name(pane: "p-2"))
        XCTAssertNil(again.opener(pane: "p-2"))
    }
}
