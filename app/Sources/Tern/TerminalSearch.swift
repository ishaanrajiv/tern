import AppKit

/// One find bar per window, bound to the pane that opened it.
final class TerminalSearch: NSView, NSSearchFieldDelegate {
    weak var terminal: TerminalView?
    var onClose: (() -> Void)?
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private var total = 0
    private var selected = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        field.placeholderString = "Find in terminal"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Find in terminal")
        let previous = NSButton(title: "↑", target: self, action: #selector(previousMatch))
        let next = NSButton(title: "↓", target: self, action: #selector(nextMatch))
        let close = NSButton(title: "Done", target: self, action: #selector(closeSearch))
        previous.setAccessibilityLabel("Previous match")
        next.setAccessibilityLabel("Next match")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func open(_ terminal: TerminalView, needle: String?) {
        if self.terminal !== terminal { self.terminal?.performBinding("end_search") }
        self.terminal = terminal
        if let needle { field.stringValue = needle }
        total = 0; selected = -1
        updateCount()
        isHidden = false
        window?.makeFirstResponder(field)
        search()
    }
    func setTotal(_ value: Int) { total = value; updateCount() }
    func setSelected(_ value: Int) { selected = value; updateCount() }
    private func updateCount() {
        count.stringValue = total < 0 ? "Searching…" : total == 0 ? "No matches" : selected < 0 ? "\(total) matches" : "\(selected + 1) of \(total)"
    }
    private func search() { terminal?.performBinding("search:" + field.stringValue) }
    func controlTextDidChange(_ obj: Notification) { search() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            navigate(previous: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }
    func navigate(previous: Bool) { terminal?.performBinding(previous ? "navigate_search:previous" : "navigate_search:next") }
    @objc private func previousMatch() { navigate(previous: true) }
    @objc private func nextMatch() { navigate(previous: false) }
    @objc func closeSearch() { close(restoreFocus: true) }
    func close(restoreFocus: Bool) {
        let target = terminal
        terminal = nil
        isHidden = true
        target?.performBinding("end_search")
        if restoreFocus, let target { window?.makeFirstResponder(target) }
        onClose?()
    }
}
