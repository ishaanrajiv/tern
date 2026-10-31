import AppKit
import XCTest
@testable import Tern

@MainActor
final class PolishTests: XCTestCase {
    func testEaseRunsFromZeroToOneWithoutGoingBack() {
        XCTAssertEqual(Motion.ease(0), 0)
        XCTAssertEqual(Motion.ease(1), 1)
        XCTAssertEqual(Motion.ease(-1), 0)
        XCTAssertEqual(Motion.ease(2), 1)
        var last = 0.0
        for i in 1...100 {
            let y = Motion.ease(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(y, last)
            XCTAssertLessThanOrEqual(y, 1.0001)
            last = y
        }
        // Fast out: most of the way there in the first third.
        XCTAssertGreaterThan(Motion.ease(1.0 / 3), 0.75)
    }

    func testChoicesWrapAndSteppersStopAtTheirEnds() {
        var value = "b"
        let choice = QuickSetting(section: "S", title: "Choice", symbol: "circle",
                                  control: .choice([("a", "A"), ("b", "B"), ("c", "C")], get: { value }, set: { value = $0 }))
        XCTAssertEqual(choice.valueLabel, "B")
        XCTAssertTrue(choice.step(1))
        XCTAssertEqual(value, "c")
        XCTAssertTrue(choice.step(1))
        XCTAssertEqual(value, "a")
        XCTAssertTrue(choice.step(-1))
        XCTAssertEqual(value, "c")

        var size = 31.0
        var writes = 0
        let stepper = QuickSetting(section: "S", title: "Size", symbol: "circle",
                                   control: .stepper(get: { size }, set: { size = $0; writes += 1 }, range: 8...32, unit: "pt"))
        XCTAssertTrue(stepper.step(1))
        XCTAssertTrue(stepper.step(1))
        XCTAssertEqual(size, 32)
        XCTAssertEqual(writes, 1, "a value already at its end isn't written again")
        XCTAssertEqual(stepper.valueLabel, "32 pt")

        var on = false
        let toggle = QuickSetting(section: "S", title: "On", symbol: "circle", control: .toggle(get: { on }, set: { on = $0 }))
        XCTAssertFalse(toggle.step(1), "switches flip on Return, not with the arrows")
        XCTAssertFalse(on)
    }

    func testQuickSettingsCoverEverySectionOnce() {
        let all = QuickSetting.all(openSettings: {}, settingsShortcut: "⌘,")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        // Sections stay together, so each heading appears once.
        var seen: [String] = []
        for setting in all where seen.last != setting.section {
            XCTAssertFalse(seen.contains(setting.section), "\(setting.section) is split up")
            seen.append(setting.section)
        }
        XCTAssertEqual(seen, ["Appearance", "Terminal", "Agents", "General"])
        XCTAssertEqual(fuzzyRank(all, "cursor", title: \.title, subtitle: \.section).first?.title, "Cursor")
    }

    func testPaneStatusFollowsItsOwnSession() {
        let w = Workspace()
        _ = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        let pane = w.selectedTab!.focusedPane
        // On screen with no session yet: being started.
        XCTAssertEqual(w.status(pane: pane), .starting)
        XCTAssertNil(w.agent(pane: pane))
        XCTAssertEqual(w.status(pane: "p-gone"), .dormant)
    }

    func testProgramsReportingTheirOwnStatusNeedNoHeartbeatAndShowFailures() throws {
        let w = Workspace()
        _ = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        let background = w.selectedTab!
        _ = w.newTab(projectPath: "/tmp", cwd: "/tmp")
        let pane = background.root.panes[0]
        let long = UInt64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        func session(_ fields: String) throws -> SessionInfo {
            let json = """
            {"id":"\(pane)","pid":1,"cols":80,"rows":24,"clients":0,"process":"cargo","title":"",
             "last_output_ms":\(long),"bells":0,\(fields)}
            """
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return try d.decode(SessionInfo.self, from: Data(json.utf8))
        }
        // Quiet for ten minutes: a hook turn is over, a program's own report still stands.
        w.update(sessions: [try session(#""agent_state":"working","agent_state_ms":\#(long),"agent_osc":true,"program":"cargo","agent_progress":40"#)])
        XCTAssertEqual(w.status(for: background), .working)
        XCTAssertEqual(w.program(for: background), "cargo")
        XCTAssertEqual(w.urgentSession(background)?.agentProgress, 40)
        w.update(sessions: [try session(#""agent_state":"failed","agent_state_ms":\#(long + 1),"agent_osc":true,"agent_message":"Build failed""#)])
        XCTAssertEqual(w.status(for: background), .failed)
        XCTAssertEqual(w.agentMessage(background), "Build failed")
        XCTAssertLessThan(SessionStatus.needsYou, SessionStatus.failed)
        XCTAssertLessThan(SessionStatus.failed, SessionStatus.working)
    }
}
