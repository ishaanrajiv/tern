import AppKit
import SwiftUI

/// One split pane: a rounded card with a header line over the terminal, and a veil that
/// dims it while another pane has focus.
final class PaneCard: NSView {
    let terminal: TerminalView
    private let header: NSHostingView<PaneHeader>
    private let veil = DimView()
    /// Where layout last put the card. An animation already heading there is left to finish.
    var target: CGRect?

    static let headerHeight: CGFloat = 28
    static let radius: CGFloat = 10

    init(terminal: TerminalView, header: PaneHeader) {
        self.terminal = terminal
        self.header = NSHostingView(rootView: header)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        // The contents are placed at their final size once, so an animated frame only moves the
        // clip: the terminal (and the PTY behind it) resizes once, not every frame.
        autoresizesSubviews = false
        addSubview(self.header)
        addSubview(terminal)
        addSubview(veil)
        veil.alphaValue = 0
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    func recolor() {
        let theme = ThemeStore.shared.theme
        layer?.backgroundColor = theme.terminal.cgColor
        layer?.borderColor = theme.border.cgColor
        veil.recolor()
    }

    func place(size: CGSize) {
        let h = Self.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: size.width, height: h)
        // Inside the 1px outline on three sides; the header already clears the top.
        terminal.frame = CGRect(x: 1, y: h, width: max(0, size.width - 2), height: max(0, size.height - h - 1))
        veil.frame = CGRect(origin: .zero, size: size)
    }

    func setDimmed(_ dimmed: Bool, animated: Bool) {
        let alpha: CGFloat = dimmed ? 1 : 0
        guard veil.alphaValue != alpha else { return }
        if animated {
            Motion.animate(0.16) { veil.animator().alphaValue = alpha }
        } else {
            veil.alphaValue = alpha
        }
    }
}

/// Veil over an unfocused pane, in the terminal's own background colour so it fades the text
/// on dark and light themes alike.
private final class DimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        recolor()
    }

    func recolor() {
        layer?.backgroundColor = ThemeStore.shared.theme.terminal.withAlphaComponent(0.45).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Clicks go through to the terminal underneath, which focuses it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The line at the top of a pane: its status glyph, what runs there and where, and (on hover
/// or focus) split and close.
struct PaneHeader: View {
    let workspace: Workspace
    let pane: String
    let split: (SplitAxis) -> Void
    let close: () -> Void
    @AppStorage(Prefs.workingIndicator) private var indicator = WorkingIndicator.trailing
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = workspace.sessions[pane]
            let focused = workspace.selectedTab?.focusedPane == pane
            let status = workspace.status(pane: pane, now: context.date)
            let agent = workspace.agent(pane: pane)
            HStack(spacing: 7) {
                StatusIcon(status: status, agent: agent, program: workspace.program(pane: pane), turning: indicator == .turning)
                Text(name(s, agent: agent))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(focused ? .primary : .secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let opener = workspace.opener(pane: pane) {
                    // Opened from the CLI by an agent, which may be in another pane.
                    Text("by " + agentName(opener))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("\(agentName(opener)) opened this pane")
                }
                if let place = place(s) {
                    Text(place)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if hovering || focused {
                    HStack(spacing: 2) {
                        PaneButton(symbol: "rectangle.split.2x1", help: "Split right") { split(.horizontal) }
                        PaneButton(symbol: "rectangle.split.1x2", help: "Split down") { split(.vertical) }
                        PaneButton(symbol: "xmark", help: "Close pane") { close() }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { workspace.focus(pane: pane) }
            .animation(.easeOut(duration: 0.16), value: hovering || focused)
        }
        .onHover { hovering = $0 }
        .themedText()
    }

    /// "Claude Code", "npm run dev", "zsh".
    private func name(_ s: SessionInfo?, agent: String?) -> String {
        if let given = workspace.name(pane: pane) { return given }
        if let agent { return agentName(agent) }
        guard let s else { return "Starting…" }
        if !Workspace.shells.contains(s.process), let command = s.command, !command.isEmpty { return command }
        return s.process
    }

    private func place(_ s: SessionInfo?) -> String? {
        if let remote = workspace.remote(for: pane) { return remote.host + ":" + remote.directory }
        return s?.cwd.map(abbreviateHome)
    }
}

private struct PaneButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 20)
                .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
