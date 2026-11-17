import AppKit
import XCTest
@testable import Tern

/// The default theme follows the shared design language and macOS's appearance; Settings' search
/// and row captions come from one table that has to cover every config key.
@MainActor
final class ThemeTests: XCTestCase {
    func testTheDefaultFollowsTheAppearance() {
        XCTAssertEqual(Theme.defaultID, "tern")
        XCTAssertEqual(Theme.builtIn("tern", dark: true), .ternDark)
        XCTAssertEqual(Theme.builtIn("tern", dark: false), .ternLight)
        XCTAssertTrue(Theme.ternDark.isDark)
        XCTAssertFalse(Theme.ternLight.isDark)
        XCTAssertNotEqual(Theme.ternDark.variant, Theme.ternLight.variant, "a light/dark flip must reload the theme")
        XCTAssertEqual(Theme.builtIn("graphite", dark: false), .graphite, "the other themes look the same in both")
        XCTAssertEqual(Theme.graphite.variant, "graphite")
        XCTAssertNil(Theme.builtIn("ghostty", dark: true))
        XCTAssertEqual(Theme.builtInIDs, ["tern", "graphite", "midnight", "ember", "paper"])
    }

    func testTheConfigFileAcceptsEveryTheme() {
        guard case .choice(let options) = ConfigStore.settings.first(where: { $0.key == "theme" })?.kind else {
            return XCTFail("theme is a choice")
        }
        XCTAssertEqual(options, Theme.builtInIDs + ["ghostty"])
    }

    /// The design language's tokens (~/dev/design/tokens/tokens.json): grounds, lit and states.
    func testTheDefaultUsesTheLanguagesTokens() {
        let dark = Theme.ternDark, light = Theme.ternLight
        XCTAssertEqual([dark.terminal, dark.sidebar, dark.selection, dark.border].map(\.hex), ["#080808", "#161616", "#1F1E1D", "#272624"])
        XCTAssertEqual([light.terminal, light.sidebar, light.selection, light.border].map(\.hex), ["#F2EDED", "#EAE4E3", "#E0D9D8", "#DAD5D6"])
        XCTAssertEqual([dark.lit.hex, dark.onLit.hex, light.lit.hex, light.onLit.hex], ["#F3EBDD", "#0C0E15", "#232838", "#F3EBDD"])
        XCTAssertEqual([dark.amber.hex, light.amber.hex, light.amberText.hex], ["#F5B83D", "#B87E09", "#8F6207"])
        XCTAssertEqual([dark.failed.hex, light.failed.hex], ["#E5675B", "#A83630"])
        XCTAssertLessThan(dark.terminal.luminance, dark.sidebar.luminance, "the terminal is the darker ground")
    }

    /// ANSI 1–7 are text colours, so they need 4.5:1 on the terminal's ground; the bright ones and
    /// bright black (comments, suggestions) need 3:1.
    func testTheDefaultTerminalColoursAreReadable() {
        for theme in [Theme.ternDark, Theme.ternLight] {
            let colors = try! XCTUnwrap(theme.terminalColors)
            let ground = theme.terminal.hex
            XCTAssertEqual(colors.palette.count, 16)
            XCTAssertGreaterThanOrEqual(Self.contrast(colors.foreground, ground), 7, "\(theme.variant) foreground")
            for i in 1...7 {
                XCTAssertGreaterThanOrEqual(Self.contrast(colors.palette[i], ground), 4.5, "\(theme.variant) colour \(i)")
            }
            for i in 8...14 {
                XCTAssertGreaterThanOrEqual(Self.contrast(colors.palette[i], ground), 3, "\(theme.variant) colour \(i)")
            }
            XCTAssertGreaterThanOrEqual(Self.contrast(colors.foreground, colors.selection), 4.5, "\(theme.variant) selected text")
        }
    }

    func testStatusInkOnTheLitFillReads() {
        for theme in [Theme.ternDark, Theme.ternLight, Theme.graphite, Theme.paper] {
            XCTAssertGreaterThanOrEqual(Self.contrast(theme.onLit.hex, theme.lit.hex), 7, "\(theme.variant) text on lit")
            XCTAssertGreaterThanOrEqual(Self.contrast(theme.onLitAmber.hex, theme.lit.hex), 2.5, "\(theme.variant) needs-you on lit")
            XCTAssertGreaterThanOrEqual(Self.contrast(theme.onLitFailed.hex, theme.lit.hex), 3, "\(theme.variant) failed on lit")
        }
    }

    func testSettingsCoverEveryConfigKey() {
        let shown = Set(SettingsIndex.all.compactMap(\.key))
        let keys = ConfigStore.settings.map(\.key) + TerminalPreferences.configKeys + ["notify-ntfy", "away-after"]
        for key in keys { XCTAssertTrue(shown.contains(key), "Settings has no row for \(key)") }
        XCTAssertEqual(SettingsIndex.all.count, Set(SettingsIndex.all.map(\.id)).count, "row ids are unique")
    }

    func testSearchFindsByTitleKeyAndSection() {
        XCTAssertEqual(Set(SettingsIndex.search("notif").map(\.id)),
                       ["notify-command-done", "notify-needs-you", "notify-done", "notify-ntfy"])
        XCTAssertEqual(SettingsIndex.search("away-after").map(\.id), ["away-after"])
        XCTAssertTrue(SettingsIndex.search("terminal cursor").map(\.id).contains("cursor-style"))
        XCTAssertTrue(SettingsIndex.search("  ").isEmpty)
    }

    private static func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let c = NSColor(hex: hex).usingColorSpace(.sRGB)!
            func f(_ v: CGFloat) -> Double { v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
