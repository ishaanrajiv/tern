import XCTest
@testable import Tern

@MainActor
final class DeviceTests: XCTestCase {
    private func session(_ pane: String, cwd: String?, host: String? = nil, owner: String? = nil, gitRoot: String? = nil) throws -> SessionInfo {
        var json: [String: Any] = ["id": pane, "pid": 1, "cols": 80, "rows": 24, "clients": 1, "process": "bash",
                                   "title": "", "last_output_ms": 0, "bells": 0]
        json["cwd"] = cwd
        json["owner"] = owner
        json["git_root"] = gitRoot
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var s = try decoder.decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: json))
        s.host = host
        return s
    }

    func testFoldersOnDevicesAreWrittenLikeScp() {
        let remote = FolderLocation("devbox:/home/me/dev/tern")
        XCTAssertEqual(remote.host, "devbox")
        XCTAssertEqual(remote.path, "/home/me/dev/tern")
        XCTAssertEqual(remote.string, "devbox:/home/me/dev/tern")
        XCTAssertEqual(FolderLocation("me@devbox:~/dev").host, "me@devbox")
        XCTAssertEqual(FolderLocation("devbox:").path, "~")
        // A local path stays local, colons and all.
        for local in ["/Users/me/a:b", "/tmp", "~/x:y", "notes:txt"] {
            XCTAssertNil(FolderLocation(local).host, local)
            XCTAssertEqual(FolderLocation(local).string, local)
        }
        XCTAssertEqual(Workspace.normalize("devbox:/home/me/dev//tern/"), "devbox:/home/me/dev/tern")
        XCTAssertEqual(Workspace.normalize("devbox:~/dev/"), "devbox:~/dev")
        XCTAssertEqual(FolderLocation("devbox:/srv/app").name, "app")
    }

    func testHostsAndFileNamesMatchTheCLI() {
        for ok in ["devbox", "me@devbox", "box.example.com", "dev-2", "10.0.0.5"] { XCTAssertTrue(Device.validHost(ok), ok) }
        for bad in ["", "-oProxyCommand=x", "dev box", "a;b", "host:/path", "$(x)", "[::1]", "dév"] { XCTAssertFalse(Device.validHost(bad), bad) }
        XCTAssertEqual(Device.fileName("me@devbox"), "me@devbox")
        // The same hash crates/tern/src/device.rs gives a long name.
        XCTAssertEqual(Device.fileName(String(repeating: "x", count: 40)), "h-cb6799335fb737c5")
        XCTAssertEqual(Device.abbreviate("/home/me/dev", home: "/home/me"), "~/dev")
        XCTAssertEqual(Device.abbreviate("/home/meow", home: "/home/me"), "/home/meow")
    }

    func testThePickerReadsADeviceFromTheQuery() {
        XCTAssertTrue(FolderSources.deviceQuery("devbox:") ?? ("", "x") == ("devbox", ""))
        XCTAssertTrue(FolderSources.deviceQuery("devbox:~/dev/te") ?? ("", "") == ("devbox", "~/dev/te"))
        XCTAssertNil(FolderSources.deviceQuery("/tmp/a:b"))
        XCTAssertNil(FolderSources.deviceQuery("tern"))
        XCTAssertNil(FolderSources.deviceQuery("a b:c"))
        XCTAssertTrue(FolderSources.splitRemotePath("~/dev/te") == ("~/dev", "te"))
        XCTAssertTrue(FolderSources.splitRemotePath("~/dev/") == ("~/dev/", ""))
        XCTAssertTrue(FolderSources.splitRemotePath("~") == ("~", ""))
        XCTAssertTrue(FolderSources.splitRemotePath("/srv") == ("/", "srv"))
        XCTAssertTrue(FolderSources.splitRemotePath("dev") == ("~", "dev"))
    }

    func testADeviceFolderKeepsItsTabsAndPanesOnTheDevice() throws {
        let w = Workspace()
        w.adoptsOrphans = false
        let remote = w.newTab(projectPath: "devbox:/home/me/api", cwd: "/home/me/api")
        let local = w.newTab(projectPath: "/tmp/proj", cwd: "/tmp/proj")
        XCTAssertEqual(w.host(pane: remote.focusedPane), "devbox")
        XCTAssertNil(w.host(pane: local.focusedPane))
        XCTAssertEqual(w.hosts, ["devbox"])
        XCTAssertEqual(w.cwd(for: remote.focusedPane), "/home/me/api")

        // The folder's own path is where a new tab there starts, on the device.
        XCTAssertNil(w.newSession(projectPath: "devbox:/home/me/api", cwd: "devbox:/home/me/api"))
        let second = try XCTUnwrap(w.project(at: "devbox:/home/me/api")?.tabs.last)
        XCTAssertEqual(w.cwd(for: second.focusedPane), "/home/me/api")
        XCTAssertNotNil(w.newSession(projectPath: "devbox:/home/me/api", cwd: "/home/me/api", worktree: true))

        // A tab can't move to another machine's folder.
        w.moveTab(remote.id, to: "/tmp/proj")
        XCTAssertEqual(w.project(containing: remote.id)?.path, "devbox:/home/me/api")

        // A subfolder on the device names the tab; elsewhere it goes by the device's home.
        w.update(sessions: [try session(remote.focusedPane, cwd: "/home/me/api/web", host: "devbox")])
        XCTAssertEqual(w.title(for: try XCTUnwrap(w.allTabs.first { $0.id == remote.id })), "web")
    }

    func testOnlyThisMacsSessionsOnADeviceBecomeTabs() throws {
        let ours = Device.clientID
        XCTAssertTrue(Workspace.adoptable(try session("p-1", cwd: "/tmp", owner: nil)))
        XCTAssertTrue(Workspace.adoptable(try session("p-2", cwd: "/tmp", owner: ours)))
        XCTAssertFalse(Workspace.adoptable(try session("p-3", cwd: "/tmp", owner: "c-0000000000000000")))
        XCTAssertTrue(Workspace.adoptable(try session("p-4", cwd: "/srv", host: "devbox", owner: ours)))
        XCTAssertFalse(Workspace.adoptable(try session("p-5", cwd: "/srv", host: "devbox", owner: nil)))
        let found = try session("p-6", cwd: "/home/me/api/web", host: "devbox", owner: ours, gitRoot: "/home/me/api")
        XCTAssertEqual(Workspace.folder(of: found), "devbox:/home/me/api")
        XCTAssertEqual(Workspace.folder(of: try session("p-7", cwd: nil, host: "devbox")), "devbox:~")
    }
}
