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
    private let searchBar = TerminalSearch(frame: .zero)
    private var reattached: [String: Date] = [:]

    static let dividerWidth: CGFloat = 1
    private static let dividerHitSlop: CGFloat = 4

    init(workspace: Workspace, ternBinary: String) {
        self.workspace = workspace
        self.ternBinary = ternBinary
        super.init(frame: .zero)
        wantsLayer = true
        searchBar.isHidden = true
        searchBar.onClose = { [weak self] in self?.needsLayout = true }
        addSubview(searchBar)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }

    /// Re-syncs views with the model. Called whenever the workspace changes.
    func refresh(focus: Bool) {
        let tab = workspace.selectedTab
        if !searchBar.isHidden, searchBar.terminal?.sessionID != tab?.focusedPane { searchBar.close(restoreFocus: false) }
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

        for pane in visible.union(workspace.panesNeedingLaunch) where terminals[pane] == nil {
            let view = TerminalView(sessionID: pane, ternBinary: ternBinary, cwd: workspace.cwd(for: pane),
                                    initLine: workspace.resumeCommand(for: pane))
            view.onSearch = { [weak self, weak view] needle in
                guard let self, let view else { return }
                self.searchBar.open(view, needle: needle)
                self.needsLayout = true
            }
            view.onEndSearch = { [weak self, weak view] in
                guard let self, self.searchBar.terminal === view else { return }
                self.searchBar.isHidden = true
                self.needsLayout = true
                if let view { self.window?.makeFirstResponder(view) }
            }
            view.onSearchTotal = { [weak self, weak view] value in
                guard let self, self.searchBar.terminal === view else { return }
                self.searchBar.setTotal(value)
            }
            view.onSearchSelected = { [weak self, weak view] value in
                guard let self, self.searchBar.terminal === view else { return }
                self.searchBar.setSelected(value)
            }
            view.workingDirectory = { [weak self] in self?.workspace.cwd(for: pane) ?? NSHomeDirectory() }
            view.onFocus = { [weak self] in self?.workspace.focus(pane: pane) }
            view.onClose = { [weak self] in self?.attachEnded(pane) }
            view.onResize = { [weak self] in self?.workspace.noteResize(pane) }
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

        if focus, searchBar.isHidden, let tab, let view = terminals[tab.focusedPane], window?.firstResponder !== view {
            window?.makeFirstResponder(view)
        }
    }

    /// `tern attach` exited. Normally the session ended with it; if ternd still has the
    /// session (the client was killed or crashed), attach again rather than lose the tab.
    private func attachEnded(_ pane: String) {
        guard let original = terminals[pane] else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, weak original] in
            let list = TernClient.listNow()
            DispatchQueue.main.async {
                guard let self, let original, self.terminals[pane] === original,
                      self.workspace.allTabs.contains(where: { $0.root.panes.contains(pane) }) else { return }
                if let list, !list.contains(where: { $0.id == pane }) {
                    self.reattached[pane] = nil
                    self.workspace.removePane(pane)
                    return
                }
                let delay = self.reattached[pane].map { max(0, 2 + $0.timeIntervalSinceNow) } ?? 0
                self.reattached[pane] = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak original] in
                    guard let self, let original, self.terminals[pane] === original else { return }
                    original.detach(); original.removeFromSuperview()
                    self.dimmers[pane]?.removeFromSuperview()
                    self.terminals[pane] = nil; self.dimmers[pane] = nil
                    self.refresh(focus: self.workspace.selectedTab?.focusedPane == pane)
                }
            }
        }
    }

    func themeChanged() {
        dimmers.values.forEach { ($0 as? DimView)?.recolor() }
        needsDisplay = true
    }

    func focusedTerminal() -> TerminalView? {
        guard let tab = workspace.selectedTab else { return nil }
        return terminals[tab.focusedPane]
    }

    func find() { focusedTerminal()?.performBinding("start_search") }
    func findNext(previous: Bool = false) { searchBar.navigate(previous: previous) }

    override func layout() {
        super.layout()
        dividers = []
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        guard let tab = workspace.selectedTab else { return }
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - (searchBar.isHidden ? 0 : 38)))
        searchBar.frame = NSRect(x: 0, y: area.height, width: bounds.width, height: 38)
        if tab.zoomed {
            terminals[tab.focusedPane]?.frame = area
            dimmers[tab.focusedPane]?.frame = area
            return
        }
        layoutNode(tab.root, in: area, path: [])
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
        ThemeStore.shared.theme.border.setFill()
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
        recolor()
    }

    func recolor() {
        layer?.backgroundColor = ThemeStore.shared.theme.terminal.withAlphaComponent(0.45).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Clicks go through to the terminal underneath, which focuses it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
