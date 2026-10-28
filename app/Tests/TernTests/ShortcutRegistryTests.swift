import AppKit
import Carbon
import XCTest
@testable import Tern

@MainActor
final class ShortcutRegistryTests: XCTestCase {
    private let specs = ShortcutRegistry.specs

    func testIDsAndTitlesAreUnique() {
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count)
        // Overrides may name a command by title, so titles must be unique too.
        XCTAssertEqual(Set(specs.map(\.title)).count, specs.count)
    }

    func testDefaultsDoNotClash() {
        let clashes = ShortcutRegistry.clashes(ShortcutRegistry.defaults)
        XCTAssertTrue(clashes.isEmpty, clashes.map { "\($0.binding.label): \($0.ids)" }.joined(separator: "\n"))
    }

    func testDefaultsFollowTheRules() {
        for spec in specs where !spec.locked {
            for binding in spec.defaults {
                XCTAssertNil(ShortcutRegistry.ruleProblem(binding, global: spec.global), "\(spec.id) \(binding.label)")
                XCTAssertNil(ShortcutRegistry.system[binding], "\(spec.id) takes macOS's \(binding.label)")
            }
        }
        // Screenshots, Spotlight and window cycling stay with macOS.
        for text in ["cmd+shift+3", "cmd+shift+4", "cmd+shift+5", "cmd+space", "cmd+`", "cmd+shift+/"] {
            let binding = try! KeyBinding(parsing: text)
            XCTAssertFalse(specs.contains { $0.defaults.contains(binding) }, text)
        }
    }

    func testRulesKeepControlAndOptionKeysForTheTerminal() throws {
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "ctrl+r")))
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "alt+p")))
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "cmd+shift+7")))
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "cmd+shift+4")))
        XCTAssertNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "ctrl+tab")))
        XCTAssertNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "ctrl+cmd+7")))
        // A system-wide hotkey may leave out ⌘, but not every modifier or macOS's own keys.
        XCTAssertNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "ctrl+alt+space"), global: true))
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(KeyBinding("x", []), global: true))
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "cmd+space"), global: true))
        // Registration needs a Carbon key code.
        XCTAssertNotNil(ShortcutRegistry.ruleProblem(try KeyBinding(parsing: "ctrl+alt+é"), global: true))
        XCTAssertNotNil(ShortcutRegistry.resolve("app.globalHotkey = ctrl+alt+é").problems.first)
        XCTAssertEqual(ShortcutRegistry.resolve("app.globalHotkey = ctrl+alt+t").bindings["app.globalHotkey"],
                       [KeyBinding("t", [.control, .option])])
    }

    func testShiftedCharactersMatchTheirKeyWithShift() throws {
        XCTAssertEqual(try KeyBinding(parsing: "cmd+}"), try KeyBinding(parsing: "cmd+shift+]"))
        XCTAssertEqual(try KeyBinding(parsing: "cmd+Y"), try KeyBinding(parsing: "cmd+shift+y"))
        XCTAssertEqual(try KeyBinding(parsing: "CMD+Shift+Left"), KeyBinding(Key.left, [.command, .shift]))
        XCTAssertEqual(KeyBinding("{", [.control, .command]), KeyBinding("[", [.control, .shift, .command]))
        // So an override can't slip past a clash or the digit rule by naming the shifted character.
        let clash = ShortcutRegistry.resolve("New Tab = cmd+}")
        XCTAssertEqual(clash.bindings["tab.new"], ShortcutRegistry.defaults["tab.new"])
        XCTAssertTrue(clash.problems.contains { $0.contains("Next Tab") }, "\(clash.problems)")
        XCTAssertFalse(ShortcutRegistry.resolve("New Tab = cmd+#").problems.isEmpty)
        XCTAssertFalse(ShortcutRegistry.resolve("New Tab = cmd+P").problems.isEmpty)
    }

    func testGlobalHotkeyKeyCodes() {
        let expected = ["a": kVK_ANSI_A, "m": kVK_ANSI_M, "t": kVK_ANSI_T, "5": kVK_ANSI_5, "0": kVK_ANSI_0, "`": kVK_ANSI_Grave,
                        "\\": kVK_ANSI_Backslash, "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period, "'": kVK_ANSI_Quote, " ": kVK_Space]
        for (key, code) in expected { XCTAssertEqual(TerminalHotkey.keyCodes[key], code, key) }
        XCTAssertNotNil(TerminalHotkey.keyCodes[ShortcutRegistry.defaults["app.globalHotkey"]![0].key])
    }

    func testParsingAndConfigRoundTrip() throws {
        XCTAssertEqual(try KeyBinding(parsing: "cmd+shift+Y"), KeyBinding("y", [.command, .shift]))
        XCTAssertEqual(try KeyBinding(parsing: "control+option+command+left"), KeyBinding(Key.left, [.control, .option, .command]))
        XCTAssertEqual(try KeyBinding(parsing: "cmd+return").label, "⌘↩")
        XCTAssertEqual(try KeyBinding(parsing: "cmd++"), KeyBinding("=", [.command, .shift]))
        for text in ["x", "cmd+", "meta+x", "cmd+xx", "cmd+f13", ""] {
            XCTAssertThrowsError(try KeyBinding(parsing: text), text)
        }
        let all = specs.flatMap(\.defaults) + ShortcutRegistry.system.keys
        for binding in all {
            XCTAssertEqual(try KeyBinding(parsing: binding.config), binding, binding.config)
        }
    }

    func testOverridesApplyByIDOrTitle() {
        let result = ShortcutRegistry.resolve("""
            # comments and blank lines are ignored

            New Tab = cmd+shift+y
            pane.zoom = ctrl+cmd+z
            Move Tab Later = none
            """)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.bindings["tab.new"], [KeyBinding("y", [.command, .shift])])
        // An override replaces the aliases too.
        XCTAssertEqual(result.bindings["pane.zoom"], [KeyBinding("z", [.control, .command])])
        XCTAssertEqual(result.bindings["tab.moveLater"], [])
        XCTAssertEqual(result.bindings["tab.close"], ShortcutRegistry.defaults["tab.close"])
    }

    func testOverridesMaySwapKeys() {
        let result = ShortcutRegistry.resolve("Split Right = cmd+shift+d\nSplit Down = cmd+d")
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.bindings["pane.splitRight"], [KeyBinding("d", [.command, .shift])])
        XCTAssertEqual(result.bindings["pane.splitDown"], [KeyBinding("d", .command)])
    }

    func testBadOverridesFallBackToDefaults() {
        let cases = [
            "New Tab = cmd+w",              // Close Pane's
            "New Tab = cmd+c",              // Copy, which is locked
            "Copy = cmd+shift+y",           // locked
            "Nonexistent = cmd+shift+y",
            "New Tab = ctrl+t",             // no ⌘: the terminal's
            "New Tab = cmd+shift+3",        // screenshot
            "New Tab = cmd+space",          // Spotlight
            "New Tab = cmd+shift+y\nNew Tab = cmd+shift+u",
            "New Tab",
            "New Tab = x",
        ]
        for text in cases {
            let result = ShortcutRegistry.resolve(text)
            XCTAssertFalse(result.problems.isEmpty, text)
            XCTAssertTrue(ShortcutRegistry.clashes(result.bindings).isEmpty, text)
            XCTAssertEqual(result.bindings["edit.copy"], ShortcutRegistry.defaults["edit.copy"], text)
        }
        XCTAssertEqual(ShortcutRegistry.resolve("New Tab = cmd+w").bindings["tab.new"], ShortcutRegistry.defaults["tab.new"])
        // Putting one override back can make another clash; that one goes back too.
        let chained = ShortcutRegistry.resolve("New Tab = cmd+w\nRename Tab… = cmd+t")
        XCTAssertTrue(ShortcutRegistry.clashes(chained.bindings).isEmpty)
        XCTAssertEqual(chained.bindings["tab.new"], ShortcutRegistry.defaults["tab.new"])
        XCTAssertEqual(chained.bindings["tab.rename"], ShortcutRegistry.defaults["tab.rename"])
    }

    func testMenuHasHiddenAliasesAndStandardItems() {
        _ = NSApplication.shared
        let commands = ["tab.next", "view.sidebar", "folder.select.1", "app.settings"].map { Command($0) {} }
        let menu = MenuBuilder.build(commands: commands)
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        func find(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
            items.first { $0.title == title && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }
        }
        XCTAssertEqual(find("Next Tab", "]", [.shift, .command])?.isHidden, false)
        XCTAssertEqual(find("Next Tab", "\t", .control)?.isHidden, true)
        XCTAssertEqual(find("Next Tab", "\t", .control)?.allowsKeyEquivalentWhenHidden, true)
        XCTAssertEqual(find("Toggle Sidebar", "s", [.control, .command])?.isHidden, false)
        XCTAssertEqual(find("Toggle Sidebar", "\\", .command)?.isHidden, true)
        XCTAssertEqual(find("Folder 1", "1", .command)?.isHidden, false)
        XCTAssertNotNil(find("Copy", "c", .command))
        XCTAssertNotNil(find("Quit tern", "q", .command))
        XCTAssertNotNil(find("Enter Full Screen", "f", [.control, .command]))
    }

    func testReadmeKeysTableMatchesRegistry() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: url, encoding: .utf8)
        let lower = try XCTUnwrap(readme.range(of: "<!-- keys:start -->\n"))
        let upper = try XCTUnwrap(readme.range(of: "<!-- keys:end -->", range: lower.upperBound..<readme.endIndex))
        let table = ShortcutRegistry.markdownTable() + "\n"
        if String(readme[lower.upperBound..<upper.lowerBound]) != table {
            if ProcessInfo.processInfo.environment["TERN_UPDATE_README"] == "1" {
                try readme.replacingCharacters(in: lower.upperBound..<upper.lowerBound, with: table).write(to: url, atomically: true, encoding: .utf8)
            } else {
                XCTFail("README's Keys table is out of date. Run TERN_UPDATE_README=1 swift test --package-path app, or use:\n\(table)")
            }
        }
    }

    func testReadmeTableCoversEveryBoundCommand() {
        let documented = Set(ShortcutRegistry.docRows.flatMap(\.ids).flatMap { id in
            id.hasSuffix(".*") ? (1...9).map { "\(id.dropLast())\($0)" } : [id]
        })
        for id in ShortcutRegistry.docRows.flatMap(\.ids) where !id.hasSuffix(".*") {
            XCTAssertNotNil(ShortcutRegistry.spec(id), id)
        }
        for spec in specs where !spec.defaults.isEmpty && !spec.locked && !spec.reserved {
            XCTAssertTrue(documented.contains(spec.id), "\(spec.id) has a default key but no README row")
        }
    }

    func testCycleFolderSkipsFoldersWithoutTabs() {
        let w = Workspace()
        let a = w.newTab(projectPath: "/a", cwd: "/a", paneID: "a")
        let b = w.newTab(projectPath: "/b", cwd: "/b", paneID: "b")
        w.select(a.id)
        w.cycleFolder(1)
        XCTAssertEqual(w.selectedTabID, b.id)
        w.cycleFolder(1)
        XCTAssertEqual(w.selectedTabID, a.id)
        w.cycleFolder(-1)
        XCTAssertEqual(w.selectedTabID, b.id)
    }

    /// ⌃⌘ number and bracket keys reach their menu items; tabs by number used to need a key monitor.
    /// Shifted keys are left out: events made here skip keyboard layout translation, which
    /// AppKit needs to match ⇧⌘P to a "p" item with ⇧ in its mask.
    func testMenuMatchesControlCommandKeys() {
        _ = NSApplication.shared
        var ran: [String] = []
        let ids = ["tab.select.3", "pane.swapNext", "view.sidebar", "pane.zoom", "pane.equalize"]
        let menu = MenuBuilder.build(commands: ids.map { id in Command(id) { ran.append(id) } })
        // (characters, characters ignoring modifiers, key code, modifiers), as a US layout reports them.
        let presses: [(String, String, UInt16, NSEvent.ModifierFlags)] = [
            ("3", "3", 20, [.control, .command]),
            ("\u{1d}", "]", 30, [.control, .command]),
            ("\u{13}", "s", 1, [.control, .command]),
            ("\r", "\r", 36, [.shift, .command]),
            ("=", "=", 24, [.control, .command]),
        ]
        for (chars, plain, code, mods) in presses {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                         context: nil, characters: chars, charactersIgnoringModifiers: plain,
                                         isARepeat: false, keyCode: code)!
            XCTAssertTrue(menu.performKeyEquivalent(with: event), plain)
        }
        XCTAssertEqual(ran, ids)
    }
}
