import AppKit
import GhosttyKit

/// Shows the selected tab's panes. Surfaces are created on first display and
/// kept (hidden) while other tabs are selected, so switching is instant.
final class TerminalArea: NSView {
    private let workspace: Workspace
    private let ternBinary: String
    private var terminals: [String: TerminalView] = [:]
    private var dimmers: [String: NSView] = [:]
    private var dividers: [(rect: CGRect, path: [Bool], axis: SplitAxis, parent: CGRect)] = []
    private var dragging: (path: [Bool], axis: SplitAxis, parent: CGRect)?
    private var reattached: [String: Date] = [:]

    static let dividerWidth: CGFloat = 1
    private static let dividerHitSlop: CGFloat = 4

    init(workspace: Workspace, ternBinary: String) {
        self.workspace = workspace
        self.ternBinary = ternBinary
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }

    /// Re-syncs views with the model. Called whenever the workspace changes.
    func refresh(focus: Bool) {
        let tab = workspace.selectedTab
        let visible = Set(tab.map { $0.zoomed ? [$0.focusedPane] : $0.root.panes } ?? [])

        // Drop views for panes that no longer exist anywhere.
        let live = Set(workspace.allTabs.flatMap { $0.root.panes })
        for (pane, view) in terminals where !live.contains(pane) {
            view.detach()
            view.removeFromSuperview()
            dimmers[pane]?.removeFromSuperview()
            terminals[pane] = nil
            dimmers[pane] = nil
        }

        for pane in visible where terminals[pane] == nil {
            let view = TerminalView(sessionID: pane, ternBinary: ternBinary, cwd: workspace.cwd(for: pane),
                                    initLine: workspace.resumeCommand(for: pane))
            view.onFocus = { [weak self] in self?.workspace.focus(pane: pane) }
            view.onClose = { [weak self] in self?.attachEnded(pane) }
            addSubview(view)
            terminals[pane] = view
            let dim = DimView()
            addSubview(dim, positioned: .above, relativeTo: view)
            dimmers[pane] = dim
        }

        for (pane, view) in terminals {
            let show = visible.contains(pane)
            view.isHidden = !show
            view.setVisible(show)
            dimmers[pane]?.isHidden = !show || pane == tab?.focusedPane || visible.count < 2
        }
        needsLayout = true
        layoutSubtreeIfNeeded()

        if focus, let tab, let view = terminals[tab.focusedPane], window?.firstResponder !== view {
            window?.makeFirstResponder(view)
        }
    }

    /// `tern attach` exited. Normally the session ended with it; if ternd still has the
    /// session (the client was killed or crashed), attach again rather than lose the tab.
    private func attachEnded(_ pane: String) {
        let alive = TernClient.listNow()?.contains { $0.id == pane } == true
        let recent = reattached[pane].map { -$0.timeIntervalSinceNow < 5 } ?? false
        guard alive, !recent, let view = terminals[pane] else {
            reattached[pane] = nil
            return workspace.removePane(pane)
        }
        reattached[pane] = Date()
        view.detach()
        view.removeFromSuperview()
        dimmers[pane]?.removeFromSuperview()
        terminals[pane] = nil
        dimmers[pane] = nil
        refresh(focus: workspace.selectedTab?.focusedPane == pane)
    }

    func focusedTerminal() -> TerminalView? {
        guard let tab = workspace.selectedTab else { return nil }
        return terminals[tab.focusedPane]
    }

    override func layout() {
        super.layout()
        dividers = []
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        guard let tab = workspace.selectedTab else { return }
        if tab.zoomed {
            terminals[tab.focusedPane]?.frame = bounds
            dimmers[tab.focusedPane]?.frame = bounds
            return
        }
        layoutNode(tab.root, in: bounds, path: [])
    }

    private func layoutNode(_ node: SplitNode, in rect: CGRect, path: [Bool]) {
        switch node {
        case .pane(let id):
            terminals[id]?.frame = rect
            dimmers[id]?.frame = rect
        case .split(let axis, let ratio, let a, let b):
            var (ra, rb) = SplitNode.divide(rect, axis: axis, ratio: ratio)
            // Carve the divider out of the second pane.
            let divider: CGRect
            switch axis {
            case .horizontal:
                divider = CGRect(x: rb.minX, y: rb.minY, width: Self.dividerWidth, height: rb.height)
                rb.origin.x += Self.dividerWidth
                rb.size.width -= Self.dividerWidth
            case .vertical:
                divider = CGRect(x: rb.minX, y: rb.maxY - Self.dividerWidth, width: rb.width, height: Self.dividerWidth)
                rb.size.height -= Self.dividerWidth
            }
            ra = ra.integral
            dividers.append((divider, path, axis, rect))
            layoutNode(a, in: ra, path: path + [false])
            layoutNode(b, in: rb, path: path + [true])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        GhosttyApp.shared.foreground.withAlphaComponent(0.14).setFill()
        for d in dividers { d.rect.fill() }
    }

    override var wantsUpdateLayer: Bool { false }

    // MARK: Divider dragging

    private func divider(at point: CGPoint) -> (rect: CGRect, path: [Bool], axis: SplitAxis, parent: CGRect)? {
        dividers.first { $0.rect.insetBy(dx: -Self.dividerHitSlop, dy: -Self.dividerHitSlop).contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if divider(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for d in dividers {
            let r = d.rect.insetBy(dx: -Self.dividerHitSlop, dy: -Self.dividerHitSlop)
            addCursorRect(r, cursor: d.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let d = divider(at: p) { dragging = (d.path, d.axis, d.parent) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = dragging, let tab = workspace.selectedTab else { return }
        let p = convert(event.locationInWindow, from: nil)
        let ratio: Double = switch drag.axis {
        case .horizontal: (p.x - drag.parent.minX) / drag.parent.width
        case .vertical: (drag.parent.maxY - p.y) / drag.parent.height
        }
        workspace.setRatio(tabID: tab.id, path: drag.path, ratio: min(max(ratio, 0.1), 0.9))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        window?.invalidateCursorRects(for: self)
    }
}

/// Veil over unfocused split panes, in the terminal's own background colour so it
/// fades the text on dark and light themes alike.
private final class DimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GhosttyApp.shared.background.withAlphaComponent(0.45).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Clicks go through to the terminal underneath, which focuses it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
