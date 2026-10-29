import SwiftUI

/// The sidebar's foot: each agent's usage limits, 5-hour and weekly, as rings.
struct UsageFooter: View {
    let usage: AgentUsage
    let now: Date

    var body: some View {
        let rows = ["claude", "codex"].compactMap { agent in usage.limits[agent].map { (agent, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.0) { agent, limits in
                    UsageRow(agent: agent, limits: limits, now: now)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }
}

private struct UsageRow: View {
    let agent: String
    let limits: UsageLimits
    let now: Date

    var body: some View {
        let five = limits.fiveHour?.used(at: now)
        let week = limits.weekly?.used(at: now)
        HStack(spacing: 7) {
            UsageRings(outer: five, inner: week, color: Self.color(agent))
            Text(agent == "claude" ? "Claude" : "Codex")
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let five { Figure(value: five, unit: "5h") }
            if let week { Figure(value: week, unit: "wk") }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
        .help(help)
    }

    static func color(_ agent: String) -> Color {
        let theme = ThemeStore.shared.theme
        return Color(nsColor: agent == "claude" ? theme.claude.fg : theme.codex.fg)
    }

    private var help: String {
        let name = agent == "claude" ? "Claude Code" : "Codex"
        let line = { (label: String, w: UsageWindow?) -> String? in
            guard let w else { return nil }
            let reset = w.resetsAt.map { ", resets \(resetText($0))" } ?? ""
            return "\(label): \(Int(w.used(at: now).rounded()))% used\(reset)"
        }
        return ([name] + [line("5-hour limit", limits.fiveHour), line("Weekly limit", limits.weekly)].compactMap { $0 })
            .joined(separator: "\n")
    }

    private func resetText(_ date: Date) -> String {
        if date <= now { return "now" }
        let f = DateFormatter()
        f.dateFormat = date.timeIntervalSince(now) < 20 * 3600 ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }
}

/// "42% 5h": the number in the text colour, amber once the limit is close.
private struct Figure: View {
    let value: Double
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(value >= 80 ? Palette.amber : Palette.text)
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
        .frame(minWidth: 38, alignment: .trailing)
    }
}

/// Two concentric rings: the 5-hour window outside, the week inside.
struct UsageRings: View {
    let outer: Double?
    let inner: Double?
    let color: Color

    var body: some View {
        ZStack {
            ring(outer, diameter: 16)
            ring(inner, diameter: 8.5, dim: true)
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private func ring(_ value: Double?, diameter: CGFloat, dim: Bool = false) -> some View {
        let tint = (value ?? 0) >= 80 ? Palette.amber : color.opacity(dim ? 0.7 : 1)
        ZStack {
            Circle().stroke(Palette.border, lineWidth: 2.25)
            Circle()
                .trim(from: 0, to: max(0.001, (value ?? 0) / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(value == nil ? 0 : 1)
        }
        .frame(width: diameter - 2.25, height: diameter - 2.25)
    }
}
