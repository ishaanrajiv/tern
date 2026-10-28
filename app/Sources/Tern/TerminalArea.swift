import AppKit
import GhosttyKit

/// Shows the selected tab's panes as cards on the window's ground. Surfaces are created on
/// first display and kept (hidden) while other tabs are selected, so switching is instant.
final class TerminalArea: NSView {
    private let workspace: Workspace
    private let ternBinary: String
    private var terminals: [String: TerminalView] = [:]
    private var cards: [String: PaneCard] = [:]
    private var dividers: [(rect: CGRect, path: [Bool], axis: SplitAxis, parent: CGRect)] = []
    private var dragging: (path: [Bool], axis: SplitAxis, parent: CGRect)?
    private let searchBar = TerminalSearch(frame: .zero)
    private var reattached: [String: Date] = [:]
    /// What the last refresh showed: a change within the same tab (a split, a close, a resize
    /// from the keyboard) animates; a switch to another tab fades in instead.
    private var shownTab: Tab?
    private var shownPanes: Set<String> = []
    private var animateLayout = false
    /// Panes just split off, which grow out of their edge of the split.
    private var growing: Set<String> = []
    private lazy var mover = FrameAnimator(host: self)

    var onSplit: ((String, SplitAxis) -> Void)?
    var onClosePane: ((String) -> Void)?
    /// Shown, as a card of its own, when there are no tabs.
    var emptyView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let emptyView { addSubview(emptyView, positioned: .below, relativeTo: searchBar) }
        }
    }
    /// None beside the sidebar, whose edge the cards meet; a margin when the sidebar is hidden.
    var leadingPadding: CGFloat = 0 { didSet { needsLayout = true } }

    static let gap: CGFloat = 6
    static let padding: CGFloat = 8
    private static let dividerHitSlop: CGFloat = 2

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

        let sameTab = tab != nil && tab?.id == shownTab?.id

        // Drop views for panes that no longer exist anywhere. One closed on screen fades out.
        let live = Set(workspace.allTabs.flatMap { $0.root.panes })
        for (pane, view) in terminals where !live.contains(pane) {
            view.detach()
            if let card = cards[pane] {
                if sameTab, shownPanes.contains(pane), !card.isHidden {
                    Motion.animate(Motion.exit, { card.animator().alphaValue = 0 }) { card.removeFromSuperview() }
                } else {
                    card.removeFromSuperview()
                }
            }
            terminals[pane] = nil
            cards[pane] = nil
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
            let header = PaneHeader(workspace: workspace, pane: pane,
                                    split: { [weak self] axis in self?.onSplit?(pane, axis) },
                                    close: { [weak self] in self?.onClosePane?(pane) })
            let card = PaneCard(terminal: view, header: header)
            addSubview(card, positioned: .below, relativeTo: searchBar)
            terminals[pane] = view
            cards[pane] = card
        }

        for (pane, card) in cards {
            let show = visible.contains(pane)
            let appearing = show && !shownPanes.contains(pane)
            card.isHidden = !show
            card.terminal.setVisible(show)
            card.setDimmed(show && pane != tab?.focusedPane && visible.count > 1, animated: sameTab && !appearing)
            guard appearing else { continue }
            if sameTab, shownTab?.root.panes.contains(pane) == false { growing.insert(pane) }
            // Another tab's panes rise into place; a new or unzoomed pane only fades in.
            Motion.reveal(card.layer, rise: sameTab ? 0 : 5, duration: sameTab ? Motion.duration : 0.2)
        }
        animateLayout = sameTab && dragging == nil && (tab?.root != shownTab?.root || tab?.zoomed != shownTab?.zoomed)
        shownTab = tab
        shownPanes = visible
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
                    original.detach()
                    self.cards[pane]?.removeFromSuperview()
                    self.terminals[pane] = nil; self.cards[pane] = nil
                    self.refresh(focus: self.workspace.selectedTab?.focusedPane == pane)
                }
            }
        }
    }

    func themeChanged() {
        cards.values.forEach { $0.recolor() }
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
        window?.invalidateCursorRects(for: self)
        let searchHeight: CGFloat = searchBar.isHidden ? 0 : 38
        searchBar.frame = NSRect(x: 0, y: bounds.height - 38, width: bounds.width, height: 38)
        let area = NSRect(x: leadingPadding, y: Self.padding,
                          width: max(0, bounds.width - leadingPadding - Self.padding),
                          height: max(0, bounds.height - Self.padding - searchHeight))
        emptyView?.frame = area
        let animate = animateLayout && window != nil
        animateLayout = false
        defer { growing = [] }
        // The tab as of the last refresh, not the model: a layout pass can come between a change
        // to the model and the refresh that animates it.
        guard let tab = shownTab else { return }
        if tab.zoomed {
            place(tab.focusedPane, in: area, from: nil, animate: animate)
            return
        }
        layoutNode(tab.root, in: area, path: [], parent: nil, animate: animate)
    }

    private func layoutNode(_ node: SplitNode, in rect: CGRect, path: [Bool], parent: SplitAxis?, animate: Bool) {
        switch node {
        case .pane(let id):
            // A new pane starts as a sliver at its outer edge of the split.
            var start = rect
            switch (parent, path.last ?? false) {
            case (.horizontal, true): start.origin.x = rect.maxX; start.size.width = 0
            case (.horizontal, false): start.size.width = 0
            case (.vertical, true): start.size.height = 0
            case (.vertical, false): start.origin.y = rect.maxY; start.size.height = 0
            case (nil, _): break
            }
            place(id, in: rect, from: start, animate: animate)
        case .split(let axis, let ratio, let a, let b):
            var (ra, rb) = SplitNode.divide(rect, axis: axis, ratio: ratio)
            // The gap comes half out of each side.
            let half = Self.gap / 2
            let divider: CGRect
            switch axis {
            case .horizontal:
                ra.size.width -= half
                rb.origin.x += half
                rb.size.width -= half
                divider = CGRect(x: ra.maxX, y: rect.minY, width: Self.gap, height: rect.height)
            case .vertical:
                ra.origin.y += half
                ra.size.height -= half
                rb.size.height -= half
                divider = CGRect(x: rect.minX, y: rb.maxY, width: rect.width, height: Self.gap)
            }
            dividers.append((divider, path, axis, rect))
            layoutNode(a, in: ra, path: path + [false], parent: axis, animate: animate)
            layoutNode(b, in: rb, path: path + [true], parent: axis, animate: animate)
        }
    }

    /// Moves a pane's card to `rect`: the contents at once, the card's edges on tern's curve.
    private func place(_ pane: String, in rect: CGRect, from start: CGRect?, animate: Bool) {
        guard let card = cards[pane], card.target != rect else { return }
        let begin = growing.contains(pane) ? start : card.target == nil ? nil : card.frame
        card.target = rect
        card.place(size: rect.size)
        if animate, !Motion.reduced, let begin, begin != rect {
            mover.move(card, from: begin, to: rect)
        } else {
            mover.cancel(card)
            card.frame = rect
        }
    }

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
