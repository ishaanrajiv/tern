import AppKit
import SwiftUI

/// The colours of the window chrome and of the terminal. The default, "tern", follows the
/// shared design language (~/dev/design) and macOS's light or dark mode; the others are fixed.
/// "Ghostty" keeps the user's own Ghostty colours and builds the chrome around them.
struct Theme: Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let sidebar: NSColor
    let terminal: NSColor
    let border: NSColor
    let text: NSColor
    let text2: NSColor
    let text3: NSColor
    let selection: NSColor
    let hover: NSColor
    let chip: NSColor
    let ring: NSColor
    /// The accent: needs you, and the tint of toggles, links, progress and focus. Fills and marks.
    let amber: NSColor
    /// The accent where it colours text, which needs more contrast on a light ground.
    let amberText: NSColor
    /// Text on an amber pill.
    let onAmber: NSColor
    let working: NSColor
    /// A program that failed and stopped.
    let failed: NSColor
    /// Lit: the fill of the selected thing and of the primary button, never text on its own.
    let lit: NSColor
    /// Text and marks on the lit fill.
    let onLit: NSColor
    let claude: Mark
    let codex: Mark
    /// nil: the terminal keeps the colours from the user's Ghostty config.
    let terminalColors: TerminalColors?

    struct Mark: Equatable {
        let fg: NSColor
        let bg: NSColor
    }

    struct TerminalColors: Equatable {
        let foreground: String
        let cursor: String
        let selection: String
        /// ANSI 0–15.
        let palette: [String]
    }

    static let defaultID = "tern"

    /// The themes that look the same in light and dark mode.
    static let fixed: [Theme] = [graphite, midnight, ember, paper]

    /// Every built-in theme as it looks now, the default first.
    static func builtIn(dark: Bool) -> [Theme] { [tern(dark: dark)] + fixed }

    /// Every built-in theme's id, the values `theme` takes besides "ghostty".
    static let builtInIDs = [defaultID] + fixed.map(\.id)

    /// A built-in theme by id, resolved for the appearance; nil for "ghostty" or an unknown id.
    static func builtIn(_ id: String, dark: Bool) -> Theme? {
        id == defaultID ? tern(dark: dark) : fixed.first { $0.id == id }
    }

    static func tern(dark: Bool) -> Theme { dark ? ternDark : ternLight }

    /// What a theme looks like at the moment: the default has a light and a dark side.
    var variant: String { id == Self.defaultID ? "\(id)-\(isDark ? "dark" : "light")" : id }

    /// The amber and red to draw on the lit fill, which is light on a dark theme and dark on a light one.
    var onLitAmber: NSColor { NSColor(hex: lit.luminance > 0.5 ? "#B87E09" : "#F5B83D") }
    var onLitFailed: NSColor { NSColor(hex: lit.luminance > 0.5 ? "#A83630" : "#E5675B") }

    /// Night: the design language's grounds, system text, cream lit and the Tern amber.
    static let ternDark = Theme(
        id: "tern", name: "tern", isDark: true,
        sidebar: NSColor(hex: "#161616"), terminal: NSColor(hex: "#080808"), border: NSColor(hex: "#272624"),
        text: NSColor(hex: "#FFFFFF"), text2: NSColor(hex: "#EBEBF5", alpha: 0.6), text3: NSColor(hex: "#EBEBF5", alpha: 0.3),
        selection: NSColor(hex: "#1F1E1D"), hover: NSColor(hex: "#1B1A19"), chip: NSColor(hex: "#1F1E1D"),
        ring: NSColor(hex: "#F3EBDD", alpha: 0.32),
        amber: NSColor(hex: "#F5B83D"), amberText: NSColor(hex: "#F5B83D"), onAmber: NSColor(hex: "#0C0E15"),
        // Working has no colour in the language: it's the neutral ink.
        working: NSColor(hex: "#F3EBDD", alpha: 0.6), failed: NSColor(hex: "#E5675B"),
        lit: NSColor(hex: "#F3EBDD"), onLit: NSColor(hex: "#0C0E15"),
        claude: Mark(fg: NSColor(hex: "#F0A47E"), bg: NSColor(hex: "#3A2A22")),
        codex: Mark(fg: NSColor(hex: "#8CC4FF"), bg: NSColor(hex: "#1F2B38")),
        // Red, green and yellow are the shared critical, fine and the Tern amber; the cursor is the mark's.
        terminalColors: TerminalColors(
            foreground: "#ECE9E4", cursor: "#F5B83D", selection: "#34312D",
            palette: ["#2A2826", "#E5675B", "#8FAE8B", "#F5B83D", "#84A3F4", "#B58CFF", "#6CC4BE", "#D6D1CA",
                      "#6E6A64", "#F08A7F", "#ABC7A7", "#F8CB72", "#A6BDF8", "#CBAEFF", "#93D6D1", "#F5F2ED"]))

    /// Light paper: the same roles in light mode, with navy lit and the amber's darker shades.
    static let ternLight = Theme(
        id: "tern", name: "tern", isDark: false,
        sidebar: NSColor(hex: "#EAE4E3"), terminal: NSColor(hex: "#F2EDED"), border: NSColor(hex: "#DAD5D6"),
        text: NSColor(hex: "#000000"), text2: NSColor(hex: "#3C3C43", alpha: 0.6), text3: NSColor(hex: "#3C3C43", alpha: 0.3),
        selection: NSColor(hex: "#E0D9D8"), hover: NSColor(hex: "#E5DFDE"), chip: NSColor(hex: "#E0D9D8"),
        ring: NSColor(hex: "#232838", alpha: 0.32),
        amber: NSColor(hex: "#B87E09"), amberText: NSColor(hex: "#8F6207"), onAmber: NSColor(hex: "#FFFFFF"),
        working: NSColor(hex: "#232838", alpha: 0.6), failed: NSColor(hex: "#A83630"),
        lit: NSColor(hex: "#232838"), onLit: NSColor(hex: "#F3EBDD"),
        claude: Mark(fg: NSColor(hex: "#9C431B"), bg: NSColor(hex: "#F6E1D5")),
        codex: Mark(fg: NSColor(hex: "#1D5AA6"), bg: NSColor(hex: "#DCE7F7")),
        terminalColors: TerminalColors(
            foreground: "#1C1B1A", cursor: "#B87E09", selection: "#DCD4D0",
            palette: ["#1F1E1D", "#A83630", "#376B43", "#8F6207", "#2F5BC4", "#8240B0", "#1E6E69", "#5E5955",
                      "#77726D", "#C2443C", "#2F7D45", "#9F6D08", "#3F6BD6", "#9450C4", "#257F79", "#2C2A28"]))

    static let graphite = Theme(
        id: "graphite", name: "Graphite", isDark: true,
        sidebar: "#1A1A1C", terminal: "#121214", border: "#26262A",
        text: "#ECECEE", text2: "#A3A3AB", text3: "#8E8E96",
        selection: "#2A2A30", hover: "#202024", chip: "#26262B", ring: "#6E6E76",
        amber: "#F5B83D", onAmber: "#1A1A1C", working: "#7DB7FF", failed: "#FF7A7A",
        claude: ("#F0A47E", "#3A2A22"), codex: ("#8CC4FF", "#1F2B38"),
        terminalColors: TerminalColors(
            foreground: "#ECECEE", cursor: "#ECECEE", selection: "#34343C",
            palette: ["#2A2A2F", "#FF7A7A", "#8BD17C", "#E8C36A", "#7AA7FF", "#D38CF5", "#6FD3D3", "#C8C8CE",
                      "#5C5C66", "#FF9A9A", "#A6E09A", "#F2D58E", "#9DBFFF", "#E2ABF8", "#94E2E2", "#F4F4F6"]))

    static let midnight = Theme(
        id: "midnight", name: "Midnight", isDark: true,
        sidebar: "#0F121A", terminal: "#0A0C12", border: "#1C2130",
        text: "#E3E7F1", text2: "#9DA6BB", text3: "#8C95AB",
        selection: "#1D2335", hover: "#151927", chip: "#1C2232", ring: "#5F6880",
        amber: "#F2B84B", onAmber: "#0F121A", working: "#8B9CFF", failed: "#FF7B8A",
        claude: ("#F0A47E", "#33251F"), codex: ("#8CC4FF", "#1A2740"),
        terminalColors: TerminalColors(
            foreground: "#E3E7F1", cursor: "#C3CAD9", selection: "#233050",
            palette: ["#1C2130", "#FF7B8A", "#A3D98B", "#FFCB6B", "#82AAFF", "#C792EA", "#89DDFF", "#C3CAD9",
                      "#4E5670", "#FF9AA6", "#BDE6A9", "#FFDA92", "#A5C2FF", "#D9B2F0", "#ADE8FF", "#F2F4FA"]))

    static let ember = Theme(
        id: "ember", name: "Ember", isDark: true,
        sidebar: "#1E1A17", terminal: "#161311", border: "#2E2723",
        text: "#F0E8DF", text2: "#B6AA9D", text3: "#A09485",
        selection: "#312A25", hover: "#26211D", chip: "#2E2823", ring: "#7A6F64",
        amber: "#F2C14E", onAmber: "#1E1A17", working: "#79C2B8", failed: "#E8806B",
        claude: ("#F2A77F", "#3D2A20"), codex: ("#8FD1C6", "#20302E"),
        terminalColors: TerminalColors(
            foreground: "#F0E8DF", cursor: "#F2C14E", selection: "#3D342D",
            palette: ["#2E2723", "#E8806B", "#B5CC7A", "#E6C36F", "#8DB3D9", "#D4A0C8", "#84C8BC", "#D6CCC0",
                      "#6A5F55", "#F09C8A", "#C9DB98", "#F0D392", "#ABC8E6", "#E2BAD8", "#A3D8CE", "#FAF4EC"]))

    static let paper = Theme(
        id: "paper", name: "Paper", isDark: false,
        sidebar: "#F1F0ED", terminal: "#FBFBF9", border: "#E0DED9",
        text: "#1E1E1C", text2: "#5B5954", text3: "#66645E",
        selection: "#E2E0DA", hover: "#E9E8E4", chip: "#E5E3DE", ring: "#9A978F",
        amber: "#B0700F", onAmber: "#FFFFFF", working: "#2F6FEB", failed: "#C3332E",
        claude: ("#9C431B", "#F6E1D5"), codex: ("#1D5AA6", "#DCE7F7"),
        terminalColors: TerminalColors(
            foreground: "#1E1E1C", cursor: "#1E1E1C", selection: "#DCE3F2",
            palette: ["#1E1E1C", "#C3332E", "#2B7A3B", "#8A6100", "#2F62D1", "#9B37B0", "#0F7480", "#77756F",
                      "#9A978F", "#D9443E", "#36914A", "#A07400", "#3F74E6", "#B04AC6", "#168C99", "#2E2D2A"]))

    /// Chrome derived from the terminal colours in the user's Ghostty config.
    static func ghostty(background bg: NSColor, foreground fg: NSColor) -> Theme {
        let dark = bg.luminance < 0.5
        func mix(_ f: CGFloat) -> NSColor { bg.blended(withFraction: f, of: fg) ?? bg }
        let graphite = Theme.graphite
        let paper = Theme.paper
        return Theme(
            id: "ghostty", name: "Ghostty", isDark: dark,
            sidebar: mix(dark ? 0.045 : 0.035), terminal: bg, border: mix(0.1),
            text: fg, text2: mix(0.36), text3: mix(0.44),
            selection: mix(0.12), hover: mix(0.07), chip: mix(0.1), ring: mix(0.55),
            amber: dark ? graphite.amber : paper.amber, amberText: dark ? graphite.amber : paper.amber, onAmber: dark ? bg : .white,
            working: dark ? graphite.working : paper.working, failed: dark ? graphite.failed : paper.failed,
            lit: fg, onLit: bg,
            claude: dark ? graphite.claude : paper.claude, codex: dark ? graphite.codex : paper.codex,
            terminalColors: nil)
    }

    private init(id: String, name: String, isDark: Bool, sidebar: NSColor, terminal: NSColor, border: NSColor,
                 text: NSColor, text2: NSColor, text3: NSColor, selection: NSColor, hover: NSColor, chip: NSColor,
                 ring: NSColor, amber: NSColor, amberText: NSColor, onAmber: NSColor, working: NSColor, failed: NSColor,
                 lit: NSColor, onLit: NSColor, claude: Mark, codex: Mark, terminalColors: TerminalColors?) {
        self.id = id; self.name = name; self.isDark = isDark
        self.sidebar = sidebar; self.terminal = terminal; self.border = border
        self.text = text; self.text2 = text2; self.text3 = text3
        self.selection = selection; self.hover = hover; self.chip = chip; self.ring = ring
        self.amber = amber; self.amberText = amberText; self.onAmber = onAmber; self.working = working; self.failed = failed
        self.lit = lit; self.onLit = onLit
        self.claude = claude; self.codex = codex; self.terminalColors = terminalColors
    }

    private init(id: String, name: String, isDark: Bool, sidebar: String, terminal: String, border: String,
                 text: String, text2: String, text3: String, selection: String, hover: String, chip: String,
                 ring: String, amber: String, onAmber: String, working: String, failed: String,
                 claude: (String, String), codex: (String, String), terminalColors: TerminalColors) {
        self.init(id: id, name: name, isDark: isDark, sidebar: NSColor(hex: sidebar), terminal: NSColor(hex: terminal),
                  border: NSColor(hex: border), text: NSColor(hex: text), text2: NSColor(hex: text2),
                  text3: NSColor(hex: text3), selection: NSColor(hex: selection), hover: NSColor(hex: hover),
                  chip: NSColor(hex: chip), ring: NSColor(hex: ring), amber: NSColor(hex: amber), amberText: NSColor(hex: amber),
                  onAmber: NSColor(hex: onAmber), working: NSColor(hex: working), failed: NSColor(hex: failed),
                  // The fixed themes light things with their own text colour.
                  lit: NSColor(hex: text), onLit: NSColor(hex: sidebar),
                  claude: Mark(fg: NSColor(hex: claude.0), bg: NSColor(hex: claude.1)),
                  codex: Mark(fg: NSColor(hex: codex.0), bg: NSColor(hex: codex.1)),
                  terminalColors: terminalColors)
    }

    /// Ghostty config lines that colour the terminal.
    var ghosttyConfig: String? {
        guard let c = terminalColors else { return nil }
        var lines = [
            "background = \(terminal.hex)",
            "foreground = \(c.foreground)",
            "cursor-color = \(c.cursor)",
            "selection-background = \(c.selection)",
            "selection-foreground = \(c.foreground)",
        ]
        lines += c.palette.enumerated().map { "palette = \($0.offset)=\($0.element)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The theme in use, which follows the Theme setting.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("tern.themeDidChange")

    private(set) var theme: Theme = .ternDark
    @ObservationIgnored private var defaultsObserver: Any?
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?

    private init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, as asked.
            MainActor.assumeIsolated { self?.reload() }
        }
        // The default theme follows macOS's light or dark mode. tern never sets the app's own
        // appearance (only its windows'), so the app's is the system's.
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.reload()
                GhosttyApp.shared.updateColorScheme()
            }
        }
    }

    static var selectedID: String { Prefs.defaults.string(forKey: Prefs.theme) ?? Theme.defaultID }

    /// Whether macOS is in dark mode.
    static var systemIsDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The theme the settings ask for, as it should look now (see `Theme.variant`).
    static var selectedVariant: String {
        let id = selectedID
        return id == Theme.defaultID ? Theme.tern(dark: systemIsDark).variant : id
    }

    /// Picks up a change of setting or of macOS's appearance: recolours the terminals, then the chrome.
    func reload() {
        let wanted = Self.selectedVariant
        guard wanted != theme.variant || GhosttyApp.shared.theme.variant != wanted else { return }
        GhosttyApp.shared.applyTheme()
        theme = GhosttyApp.shared.theme
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Called once GhosttyApp has loaded its config.
    func set(_ theme: Theme) { self.theme = theme }
}

/// SwiftUI colours of the current theme.
enum Palette {
    private static var t: Theme { ThemeStore.shared.theme }
    static var amber: Color { Color(nsColor: t.amber) }
    static var amberText: Color { Color(nsColor: t.amberText) }
    static var lit: Color { Color(nsColor: t.lit) }
    static var onLit: Color { Color(nsColor: t.onLit) }
    static var onLitAmber: Color { Color(nsColor: t.onLitAmber) }
    static var onLitFailed: Color { Color(nsColor: t.onLitFailed) }
    /// The shared states: fine, and error text (critical is `failed`).
    static var fine: Color { Color(nsColor: NSColor(hex: t.isDark ? "#8FAE8B" : "#376B43")) }
    static var errorText: Color { Color(nsColor: NSColor(hex: t.isDark ? "#F39C92" : "#A83630")) }
    static var onAmber: Color { Color(nsColor: t.onAmber) }
    static var working: Color { Color(nsColor: t.working) }
    static var failed: Color { Color(nsColor: t.failed) }
    static var sidebar: Color { Color(nsColor: t.sidebar) }
    static var terminal: Color { Color(nsColor: t.terminal) }
    static var border: Color { Color(nsColor: t.border) }
    static var text: Color { Color(nsColor: t.text) }
    static var text2: Color { Color(nsColor: t.text2) }
    static var text3: Color { Color(nsColor: t.text3) }
    static var selection: Color { Color(nsColor: t.selection) }
    static var hover: Color { Color(nsColor: t.hover) }
    static var chip: Color { Color(nsColor: t.chip) }
    static var ring: Color { Color(nsColor: t.ring) }
}

extension View {
    /// Text in the theme's three levels, so `.secondary` and `.tertiary` follow it.
    func themedText() -> some View {
        foregroundStyle(Palette.text, Palette.text2, Palette.text3)
    }
}

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
