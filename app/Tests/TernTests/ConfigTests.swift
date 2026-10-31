import Foundation
import XCTest
@testable import Tern

/// The config file is where settings live: Settings writes to it, edits to it apply, and a bad
/// line keeps the last good value. ternd reads the same file, so its lines must survive.
@MainActor
final class ConfigTests: XCTestCase {
    private let nowhere = URL(fileURLWithPath: "/nonexistent/tern-legacy")

    private func store(_ text: String? = nil) throws -> (store: ConfigStore, defaults: UserDefaults, url: URL) {
        let name = "tern-config-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.register(defaults: [Prefs.notifyDone: true, Prefs.theme: Theme.defaultID, Prefs.repoRoots: "~/dev"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("config")
        if let text { try ConfigStore.writePrivate(Data(text.utf8), to: url) }
        return (ConfigStore(url: url, defaults: defaults, domain: name), defaults, url)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testSettingAKeyKeepsCommentsAndOtherLines() {
        var c = ConfigText("# mine\non-done = say hi\ntheme = paper\n\nrepo-root = ~/a\nrepo-root = ~/b\n")
        XCTAssertEqual(c.all("repo-root"), ["~/a", "~/b"])
        c.set("theme", ["midnight"])
        c.set("repo-root", ["~/c"])
        c.set("notify-done", [])
        c.set("file-editor", ["zed"])
        XCTAssertEqual(c.text, "# mine\non-done = say hi\ntheme = midnight\n\nrepo-root = ~/c\nfile-editor = zed\n")
        c.set("repo-root", [])
        XCTAssertFalse(c.has("repo-root"))
    }

    func testValuesParseAsTernReadsThem() {
        let c = ConfigText("a = 1\na =\na = \"  2  \"\nnot a setting\nb key = x\n")
        XCTAssertEqual(c.all("a"), ["  2  "])
        XCTAssertEqual(c.invalid, [4, 5])
        XCTAssertEqual(ConfigText.quoted("  x"), "\"  x\"")
        XCTAssertEqual(ConfigText.quoted("\"x\""), "\"\"x\"\"")
        XCTAssertEqual(ConfigText.quoted("cmd+t"), "cmd+t")
        var round = ConfigText("")
        round.set("shortcut", ["New Tab = cmd+shift+y"])
        XCTAssertEqual(round.all("shortcut"), ["New Tab = cmd+shift+y"])
    }

    func testMigratesOnlyTheSettingsYouChangedAndOnlyOnce() throws {
        let (store, defaults, url) = try store("on-done = say done\n")
        defaults.set(false, forKey: Prefs.notifyDone)
        defaults.set("ember", forKey: Prefs.theme)
        store.migrate(terminal: nowhere, presets: nowhere)
        let text = read(url)
        XCTAssertTrue(text.hasPrefix("on-done = say done\n"))
        XCTAssertTrue(text.contains("notify-done = false\n"))
        XCTAssertTrue(text.contains("theme = ember\n"))
        XCTAssertFalse(text.contains("resume-agents"))
        try ConfigStore.writePrivate(Data("on-done = say done\n".utf8), to: url)
        store.migrate(terminal: nowhere, presets: nowhere)
        XCTAssertEqual(read(url), "on-done = say done\n")
    }

    func testANewFileStartsWithTheHeader() throws {
        let (store, _, url) = try store()
        store.migrate(terminal: nowhere, presets: nowhere)
        XCTAssertEqual(read(url), ConfigStore.header)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testEditsApplyAndABadValueKeepsTheLastGood() throws {
        let (store, defaults, url) = try store("notify-done = false\ntheme = midnight\nrepo-root = ~/a\nrepo-root = ~/b\n")
        store.reload(force: true)
        XCTAssertFalse(defaults.bool(forKey: Prefs.notifyDone))
        XCTAssertEqual(defaults.string(forKey: Prefs.theme), "midnight")
        XCTAssertEqual(Prefs.parseRoots(defaults.string(forKey: Prefs.repoRoots) ?? ""), ["~/a", "~/b"])
        XCTAssertTrue(store.problems.isEmpty, "\(store.problems)")

        try ConfigStore.writePrivate(Data("notify-done = maybe\ntheme = paper\nbogus = 1\non-done = say hi\n".utf8), to: url)
        store.reload()
        XCTAssertFalse(defaults.bool(forKey: Prefs.notifyDone), "keeps the last good value")
        XCTAssertEqual(defaults.string(forKey: Prefs.theme), "paper")
        XCTAssertEqual(store.problems.count, 2, "\(store.problems)")
        XCTAssertTrue(store.problems.contains { $0.hasPrefix("Line 1: notify-done is true or false") })
        XCTAssertTrue(store.problems.contains { $0.contains("no setting called bogus") })

        try ConfigStore.writePrivate(Data("".utf8), to: url)
        store.reload()
        XCTAssertTrue(defaults.bool(forKey: Prefs.notifyDone), "a removed line goes back to the default")
        XCTAssertEqual(defaults.string(forKey: Prefs.theme), Theme.defaultID)
        XCTAssertTrue(store.problems.isEmpty)
    }

    func testChangesInTheAppAreWrittenInPlace() throws {
        let (store, defaults, url) = try store("# mine\ntheme = midnight\non-bell = afplay x\n")
        store.reload(force: true)
        defaults.set("paper", forKey: Prefs.theme)
        defaults.set(false, forKey: Prefs.notifyDone)
        defaults.set(true, forKey: Prefs.resumeAgents) // Unregistered here, so true isn't its default.
        defaults.set(true, forKey: Prefs.notifyDone)
        store.flush()
        XCTAssertEqual(read(url), "# mine\ntheme = paper\non-bell = afplay x\nresume-agents = true\n",
                       "notify-done went back to its default, so it isn't added")
    }

    func testAnEmptyListIsWrittenAsAClearedKey() throws {
        let (store, defaults, url) = try store("")
        store.reload(force: true)
        defaults.set("", forKey: Prefs.repoRoots)
        store.flush()
        XCTAssertEqual(read(url), "repo-root =\n")
        store.reload(force: true)
        XCTAssertEqual(defaults.string(forKey: Prefs.repoRoots), "", "not the ~/dev default")
    }

    func testABadLineIsNotOverwrittenByAnotherChange() throws {
        let (store, defaults, url) = try store("notify-done = maybe\n")
        store.reload(force: true)
        defaults.set("ember", forKey: Prefs.theme)
        store.flush()
        XCTAssertEqual(read(url), "notify-done = maybe\ntheme = ember\n")
    }

    func testTerminalSettingsKeepTheLastGoodValueAndOverrideOnlyWhatsGiven() {
        defer {
            var none: [String] = []
            TerminalPreferences.apply(ConfigText(""), check: false, problems: &none)
        }
        var problems: [String] = []
        TerminalPreferences.apply(ConfigText("font-size = 15\ncursor-style = bar\n"), check: false, problems: &problems)
        XCTAssertEqual(TerminalPreferences.current.size, 15)
        XCTAssertEqual(TerminalPreferences.given, ["font-size", "cursor-style"])
        XCTAssertEqual(TerminalPreferences.current.ghostty(TerminalPreferences.given), "font-size = 15\ncursor-style = bar\n")
        XCTAssertTrue(problems.isEmpty)

        TerminalPreferences.apply(ConfigText("font-size = huge\ncursor-style = bar\n"), check: false, problems: &problems)
        XCTAssertEqual(TerminalPreferences.current.size, 15)
        XCTAssertEqual(problems.count, 1)

        problems = []
        TerminalPreferences.apply(ConfigText(""), check: false, problems: &problems)
        XCTAssertEqual(TerminalPreferences.current, TerminalPreferences())
        XCTAssertTrue(TerminalPreferences.given.isEmpty)
    }

    func testTheReadmeExampleHasNoProblems() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: url, encoding: .utf8)
        let section = try XCTUnwrap(readme.range(of: "### Config file"))
        let start = try XCTUnwrap(readme.range(of: "```sh\n", range: section.upperBound..<readme.endIndex))
        let end = try XCTUnwrap(readme.range(of: "```", range: start.upperBound..<readme.endIndex))
        let example = String(readme[start.upperBound..<end.lowerBound])
        XCTAssertTrue(example.contains("shortcut = "))
        defer {
            var none: [String] = []
            TerminalPreferences.apply(ConfigText(""), check: false, problems: &none)
        }
        let (store, _, _) = try store(example)
        store.reload(force: true)
        XCTAssertEqual(store.problems, [])
        XCTAssertEqual(Set(ConfigText(example).entries.map(\.key)),
                       Set(ConfigStore.settings.map(\.key) + TerminalPreferences.configKeys), "the example shows every key")
    }

    func testPresetsAreFilesAndOnlyTheOnesYouRemoveAreDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tern-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func preset(_ name: String) -> LaunchPreset {
            LaunchPreset(name: name, project: "/tmp", tabs: [LaunchTab(root: .pane("shell"), panes: ["shell": LaunchPane(directory: "/tmp")])])
        }
        let a = preset("API"), b = preset("API"), c = preset("../web: dev")
        try LaunchPresetFile(presets: [a, b, c]).save(to: dir)
        var loaded = try LaunchPresetFile.load(from: dir)
        XCTAssertEqual(Set(loaded.files.values.map(\.lastPathComponent)), ["API.json", "API 2.json", "-web- dev.json"])
        XCTAssertEqual(Set(loaded.presets.map(\.id)), [a.id, b.id, c.id])

        // A preset added to the folder after loading survives a save that doesn't know it.
        try LaunchPresetFile(presets: [preset("Later")]).save(to: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        loaded.presets.removeAll { $0.id == b.id }
        try loaded.save(to: dir)
        let after = try LaunchPresetFile.load(from: dir)
        XCTAssertEqual(Set(after.presets.map(\.name)), ["API", "../web: dev", "Later"])
        XCTAssertFalse(after.presets.contains { $0.id == b.id })
        XCTAssertEqual(after.unreadable, ["broken.json"])
    }
}
