import AppKit
import GhosttyKit

extension TerminalView {
    func visibleText() -> String {
        guard let surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text), let pointer = text.text else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal · " + workingDirectory() }
    override func accessibilityHelp() -> String? { "Terminal input and output. Use Find to search, or Export Scrollback to read all retained output in a text window." }
    override func accessibilityValue() -> Any? { visibleText() }
    override func accessibilitySelectedText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text), let pointer = text.text else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        guard let selection = accessibilitySelectedText(), !selection.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return (visibleText() as NSString).range(of: selection)
    }
    override func accessibilityNumberOfCharacters() -> Int { (visibleText() as NSString).length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityNumberOfCharacters()) }
    override func accessibilityString(for range: NSRange) -> String? {
        let text = visibleText()
        guard let range = Range(range, in: text) else { return nil }
        return String(text[range])
    }
    override func accessibilityLine(for index: Int) -> Int {
        let text = visibleText() as NSString
        guard index >= 0, index <= text.length else { return NSNotFound }
        return text.substring(to: index).filter { $0 == "\n" }.count
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    func terminalContextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Paste Image as File Path", #selector(pasteImagePath(_:))), ("Select All", #selector(selectAll(_:))), ("Open Selected File in Editor", #selector(openSelectedFile(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
}
