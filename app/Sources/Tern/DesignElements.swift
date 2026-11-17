import AppKit
import SwiftUI

// The shared design language (~/dev/design) as tern's own controls: grounds from the theme,
// the accent for toggles, links and focus, Lit for the selected thing and the primary button,
// and marks built from flat rounded pieces on the ink ladder (1 · 0.9 · 0.6 · 0.32 · 0.2).

extension EnvironmentValues {
    /// True inside something drawn on the Lit fill, like the selected sidebar row: text, chips
    /// and status marks take the ink that reads on it.
    @Entry var onLit = false
}

/// The ink ladder of the mark grammar.
nonisolated enum Ink {
    static let full = 1.0
    static let strong = 0.9
    static let mid = 0.6
    static let faint = 0.32
    static let faintest = 0.2
}

/// The logo's lit cursor, as a status mark: a small rounded bar.
struct CursorPill: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.height / 3, 2), style: .continuous)
    }
}

// MARK: Controls

/// An on/off switch: the accent when on, a raised track when off.
struct TernSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let track = Capsule(style: .continuous)
        ZStack(alignment: isOn ? .trailing : .leading) {
            track.fill(isOn ? Palette.amber : Palette.chip)
                .overlay(track.strokeBorder(isOn ? .clear : Palette.border))
            Circle()
                .fill(isOn ? Palette.onAmber : Palette.text2)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .frame(width: 32, height: 18)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(track)
        .onTapGesture { if enabled { withAnimation(Motion.animation()) { isOn.toggle() } } }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { isOn.toggle() }
    }
}

struct TernSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            TernSwitch(isOn: configuration.$isOn)
        }
    }
}

/// The primary button: the Lit fill.
struct LitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LitButton(configuration: configuration)
    }

    private struct LitButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.onLit)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Palette.lit.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// Every other button: a raised fill with a hairline.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(configuration.isPressed ? Palette.hover : Palette.chip, in: shape)
                .overlay(shape.strokeBorder(Palette.border))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// A text button in the accent, for links and quiet actions.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.amberText)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// A text field on the ground, with a hairline that turns the accent while it has focus.
struct FieldChrome: ViewModifier {
    var mono = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Palette.terminal, in: shape)
            .overlay(shape.strokeBorder(focused ? Palette.amber : Palette.border, lineWidth: focused ? 1.5 : 1))
    }
}

extension View {
    func fieldChrome(mono: Bool = false) -> some View { modifier(FieldChrome(mono: mono)) }
}

/// A choice of a few: a raised track with the chosen one lit.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let chosen = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Palette.onLit : Palette.text2)
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(chosen ? Palette.lit : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

/// A choice of several, as a menu: the current one in a raised button.
struct ChoiceMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.text2)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(QuietButtonStyle())
        .fixedSize()
    }
}

// MARK: Marks

/// tern's mark: the t's stem with its hooked foot, the crossbar a step down, and the lit cursor.
/// The same pieces as the app icon and the design repo's Tern mark.
struct TernLogo: View {
    var units: Color = Palette.lit
    /// Dims the t without letting its overlapping pieces show through each other.
    var unitsOpacity = 1.0
    var cursor: Color = Palette.amber

    var body: some View {
        ZStack {
            ZStack {
                LogoPiece(kind: .crossbar).fill(units.opacity(Ink.strong))
                LogoPiece(kind: .stem).fill(units)
            }
            .compositingGroup()
            .opacity(unitsOpacity)
            LogoPiece(kind: .cursor).fill(cursor)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct LogoPiece: Shape {
    enum Kind { case crossbar, stem, cursor }
    let kind: Kind

    nonisolated func path(in rect: CGRect) -> Path {
        // The mark's own 1024 grid, cropped to the square its pieces sit in.
        let origin: CGFloat = 174, span: CGFloat = 676
        let s = min(rect.width, rect.height) / span
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - origin) * s, y: rect.minY + (y - origin) * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> Path {
            Path(roundedRect: CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)), cornerRadius: radius * s)
        }
        switch kind {
        case .crossbar:
            return r(234, 360, 316, 96, 48)
        case .cursor:
            return r(606, 700, 184, 80, 24)
        case .stem:
            var path = Path()
            path.move(to: p(334, 276))
            path.addArc(center: p(382, 276), radius: 48 * s, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            path.addLine(to: p(430, 628))
            path.addQuadCurve(to: p(486, 684), control: p(430, 684))
            path.addLine(to: p(522, 684))
            path.addArc(center: p(522, 732), radius: 48 * s, startAngle: .degrees(270), endAngle: .degrees(450), clockwise: false)
            path.addLine(to: p(486, 780))
            path.addQuadCurve(to: p(334, 628), control: p(334, 780))
            path.closeSubpath()
            return path
        }
    }
}

/// "tern" in Geist Medium, tracked −0.025em, as outlines (Geist is SIL OFL 1.1). Lowercase, as
/// tern writes its own name everywhere.
struct Wordmark: View {
    var height: CGFloat = 13

    private static let image: NSImage? = {
        let d = "M278.8 0Q203 0 167 -34.9Q131 -69.8 131 -144.4V-656.6H237V-151.6Q237 -114.8 253.1 -100.7Q269.2 -86.6 302.4 -86.6H378V0ZM50.2 -445.4V-532H378V-445.4ZM678.8 12Q601.4 12 544.8 -22.2Q488.2 -56.4 457.4 -119.1Q426.6 -181.8 426.6 -266Q426.6 -350.2 457.4 -412.4Q488.2 -474.6 544 -509.3Q599.8 -544 675.6 -544Q748.2 -544 803.3 -510.7Q858.4 -477.4 888.8 -414.4Q919.2 -351.4 919.2 -262V-235.2H537Q541.4 -157.4 578.9 -118.3Q616.4 -79.2 679.6 -79.2Q727 -79.2 757.9 -101Q788.8 -122.8 801 -160.4L911.4 -152.8Q890.2 -78.6 828.6 -33.3Q767 12 678.8 12ZM537 -315.2H806.8Q801.8 -386.2 766.2 -419.9Q730.6 -453.6 675.6 -453.6Q619.4 -453.6 582.9 -418.4Q546.4 -383.2 537 -315.2ZM1011.2 0V-532H1108L1112.4 -390.8L1103.2 -393.6Q1114.2 -466 1147.6 -499Q1181 -532 1237.8 -532H1288.6V-437.2H1238.2Q1197.6 -437.2 1170.9 -423.9Q1144.2 -410.6 1130.7 -383.6Q1117.2 -356.6 1117.2 -313.8V0ZM1380.2 0V-532H1476.6L1480.6 -389.6L1467.8 -397.2Q1477 -448.6 1501.9 -480.9Q1526.8 -513.2 1562.7 -528.6Q1598.6 -544 1640.6 -544Q1700.6 -544 1740.5 -517.6Q1780.4 -491.2 1800.6 -445.7Q1820.8 -400.2 1820.8 -342.2V0H1714.8V-309.6Q1714.8 -356.6 1704.7 -388.9Q1694.6 -421.2 1671.9 -438.1Q1649.2 -455 1612 -455Q1555.8 -455 1521 -417.8Q1486.2 -380.6 1486.2 -309.6V0Z"
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="50 -657 1771 669" width="1771" height="669"><path d="\#(d)"/></svg>"#
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(1771.0 / 669.0, contentMode: .fit)
                .frame(height: height)
                .accessibilityLabel("tern")
        } else {
            Text("tern").font(.system(size: height, weight: .medium))
        }
    }
}

/// A settings section's glyph in the mark grammar: flat rounded pieces on the ink ladder, the
/// one lit piece in the accent only when the section is chosen.
struct SettingsGlyph: View {
    let pane: SettingsPane
    var lit = false
    var ink: Color = Palette.lit
    var accent: Color = Palette.amber

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 100
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: r * s)
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            func fill(_ path: Path, _ opacity: Double) { context.fill(path, with: .color(ink.opacity(opacity))) }
            func cursor(_ path: Path) { context.fill(path, with: .color(lit ? accent : ink.opacity(Ink.mid))) }
            switch pane {
            case .general:
                for y in [22.0, 44, 66] { fill(rect(16, y, 68, 12, 6), Ink.faint) }
                fill(circle(34, 28, 10), Ink.full)
                fill(circle(46, 72, 10), Ink.strong)
                cursor(circle(66, 50, 10))
            case .appearance:
                fill(rect(16, 20, 24, 60, 7), Ink.mid)
                fill(rect(44, 20, 40, 60, 7), Ink.strong)
                cursor(rect(52, 62, 16, 9, 3))
            case .terminal:
                fill(rect(16, 20, 68, 60, 9), Ink.faint)
                fill(rect(26, 32, 36, 9, 4.5), Ink.strong)
                fill(rect(26, 47, 24, 9, 4.5), Ink.mid)
                cursor(rect(54, 62, 18, 9, 3))
            case .agents:
                fill(rect(16, 24, 68, 20, 7), Ink.strong)
                fill(rect(16, 54, 68, 20, 7), Ink.faint)
                // Cut out of the bar it sits on, so it reads unlit too.
                context.blendMode = .destinationOut
                context.fill(rect(60, 28, 18, 12, 4), with: .color(.black))
                context.blendMode = .normal
                cursor(rect(62, 30, 14, 8, 3))
            case .devices:
                fill(rect(14, 30, 32, 40, 7), Ink.strong)
                fill(rect(54, 30, 32, 40, 7), Ink.faint)
                fill(rect(40, 46, 20, 8, 4), Ink.mid)
                cursor(rect(62, 56, 16, 8, 3))
            case .updates:
                fill(rect(43, 16, 14, 44, 7), Ink.strong)
                var arrow = Path()
                arrow.move(to: CGPoint(x: 30 * s, y: 46 * s))
                arrow.addLine(to: CGPoint(x: 70 * s, y: 46 * s))
                arrow.addLine(to: CGPoint(x: 50 * s, y: 74 * s))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(ink.opacity(Ink.mid)))
                cursor(rect(24, 80, 52, 9, 4.5))
            }
        }
        .accessibilityHidden(true)
    }
}
