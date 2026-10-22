import XCTest
@testable import Tern

@MainActor
final class LayoutTests: XCTestCase {
    private func decode(_ json: String) -> (Workspace.Saved?, dropped: Int) {
        Workspace.decodeLayout(Data(json.utf8))
    }

    func testCurrentLayoutRoundTrips() throws {
        let tab = Tab(id: "t1", name: "api", root: .split(.horizontal, ratio: 0.5, .pane("p1"), .pane("p2")),
                      focusedPane: "p2", worktree: "/r-worktrees/session-1", number: 3)
        let saved = Workspace.Saved(version: Workspace.layoutVersion,
                                    projects: [Project(path: "/r", tabs: [tab], collapsed: true, lastTab: "t1")],
                                    selectedTabID: "t1", paneCwd: ["p1": "/r"],
                                    paneAgent: ["p2": AgentRef(agent: "claude", session: "abc")], recents: nil)
        let (back, dropped) = Workspace.decodeLayout(try JSONEncoder().encode(saved))
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(back?.projects, saved.projects)
        XCTAssertEqual(back?.paneAgent, saved.paneAgent)
        XCTAssertEqual(back?.version, Workspace.layoutVersion)
    }

    /// A layout from before `version`, `number` and `collapsed` existed.
    func testOlderLayoutLoadsWithDefaults() {
        let (saved, dropped) = decode("""
        {"projects": [{"path": "/r", "tabs": [{"id": "t1", "root": {"pane": {"_0": "p1"}}, "focusedPane": "p1"}]}],
         "paneCwd": {}}
        """)
        XCTAssertEqual(dropped, 0)
        XCTAssertNil(saved?.version)
        XCTAssertEqual(saved?.projects.first?.tabs.first?.id, "t1")
        XCTAssertEqual(saved?.projects.first?.collapsed, false)
        XCTAssertNil(saved?.projects.first?.tabs.first?.number)
    }

    /// One broken tab or field costs only itself, and is counted so the file is kept aside.
    func testBrokenPartsAreSkippedNotEverything() {
        let (saved, dropped) = decode("""
        {"version": 1,
         "projects": [
           {"path": "/a", "tabs": [{"id": "t1", "root": {"pane": {"_0": "p1"}}, "focusedPane": "p1"},
                                   {"id": "t2", "root": "garbage"}]},
           {"tabs": []},
           {"path": "/b", "collapsed": "yes", "tabs": [{"id": "t3", "root": {"pane": {"_0": "p3"}}, "focusedPane": "gone"}]}
         ],
         "paneCwd": 42,
         "selectedTabID": "t3"}
        """)
        XCTAssertEqual(saved?.projects.map(\.path), ["/a", "/b"])
        XCTAssertEqual(saved?.projects[0].tabs.map(\.id), ["t1"])
        XCTAssertEqual(saved?.projects[1].collapsed, false)
        // A focused pane the tree doesn't have falls back to its first pane.
        XCTAssertEqual(saved?.projects[1].tabs[0].focusedPane, "p3")
        XCTAssertEqual(saved?.paneCwd, [:])
        XCTAssertEqual(saved?.selectedTabID, "t3")
        // The bad tab, the folder with no path, "collapsed" and paneCwd.
        XCTAssertEqual(dropped, 4)
    }

    func testNotALayoutAtAll() {
        XCTAssertNil(decode("[1, 2, 3]").0)
        XCTAssertNil(decode("{ not json").0)
    }

    func testRepoRootsReadOldAndNewFormats() {
        XCTAssertEqual(Prefs.parseRoots("~/dev"), ["~/dev"])
        XCTAssertEqual(Prefs.parseRoots("~/dev, ~/src ,"), ["~/dev", "~/src"])
        XCTAssertEqual(Prefs.parseRoots(""), [])
        let roots = ["~/dev", "/Volumes/Work, Inc/code"]
        XCTAssertEqual(Prefs.parseRoots(Prefs.joinRoots(roots)), roots)
        // A single folder with a comma in it survives too.
        XCTAssertEqual(Prefs.parseRoots(Prefs.joinRoots(["/a,b"])), ["/a,b"])
    }
}
