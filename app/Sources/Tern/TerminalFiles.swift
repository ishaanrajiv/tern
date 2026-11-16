import AppKit
import GhosttyKit

/// A compiler diagnostic's path and optional source location.
nonisolated struct FileReference: Equatable {
    let path: String
    let line: Int?
    let column: Int?
    /// The device the file is on; nil on this Mac.
    var host: String? = nil

    /// `home` is what `~` means: a device's home for a path on a device.
    static func parse(_ text: String, cwd: String, home: String = NSHomeDirectory(), host: String? = nil) -> Self? {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'()[]{}<>.,;"))
        guard !value.contains("://"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let regex = try! NSRegularExpression(pattern: #"^(.+?)(?::([1-9][0-9]*)(?::([1-9][0-9]*))?)?:?$"#)
        let ns = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        guard !raw.isEmpty else { return nil }
        let tilde = { (p: String) in p == "~" ? home : p.hasPrefix("~/") ? home + p.dropFirst() : p }
        let expanded = tilde(raw)
        let path = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: tilde(cwd)).appendingPathComponent(expanded)).standardized.path
        let number = { (i: Int) -> Int? in
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
        }
        return Self(path: path, line: number(2), column: number(3), host: host)
    }

    /// Editors opened by URL. Each also reaches a file on a device over SSH, through its own
    /// remote support; the system's default app can't.
    static let urlEditors: Set<String> = ["vscode", "cursor", "zed"]

    func editorURL(_ editor: String) -> URL? {
        guard Self.urlEditors.contains(editor) else { return nil }
        if let host {
            // VS Code and Cursor treat a remote path with a line as a file, not a folder.
            let position = ":\(line ?? 1):\(column ?? 1)"
            let allowed = CharacterSet.urlPathAllowed
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed),
                  let target = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed.union(["@"])) else { return nil }
            return editor == "zed" ? URL(string: "zed://ssh/\(target)\(encoded)")
                : URL(string: "\(editor)://vscode-remote/ssh-remote+\(target)\(encoded)\(position)")
        }
        var parts = URLComponents()
        parts.scheme = editor
        parts.host = "file"
        parts.path = path + (line.map { ":\($0)" } ?? "") + (column.map { ":\($0)" } ?? "")
        return parts.url
    }
}

enum FileEditor {
    static var editor: String { Prefs.defaults.string(forKey: Prefs.fileEditor) ?? "system" }

    static func open(_ ref: FileReference) {
        let editor = editor
        // A file on a device opens only in an editor that reaches it over SSH.
        if ref.host != nil, ref.editorURL(editor) == nil { return NSSound.beep() }
        if let url = ref.editorURL(editor) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: ref.path))
        }
    }
}

extension TerminalView {
    /// Programmatic paste still uses Ghostty's bracketed-paste and confirmation handling.
    func pasteText(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(text.utf8.count)) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        pasteText(urls.map { quoteShell($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// Read the row under the mouse using Ghostty's own grid dimensions. Let Ghostty
    /// continue handling OSC 8 and ordinary URLs when there is no existing local file.
    func fileReference(at event: NSEvent) -> FileReference? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_height_px > 0, size.cell_width_px > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1
        let paddingX = max(0, (Double(size.width_px) - Double(size.columns) * Double(size.cell_width_px)) / 2)
        let paddingY = max(0, (Double(size.height_px) - Double(size.rows) * Double(size.cell_height_px)) / 2)
        let row = Int(((bounds.height - p.y) * scale - paddingY) / Double(size.cell_height_px))
        let col = Int((p.x * scale - paddingX) / Double(size.cell_width_px))
        guard row >= 0, row < Int(size.rows), col >= 0, col < Int(size.columns) else { return nil }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row))
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(size.columns - 1), y: UInt32(row))
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text), let ptr = text.text else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let line = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
        // Graphemes can span cells. The common ASCII compiler diagnostic is exact;
        // non-ASCII paths can also be opened through the selected-text menu action.
        let chars = Array(line)
        guard col < chars.count else { return nil }
        var start = col, end = col
        while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
        while end < chars.count && !chars[end].isWhitespace { end += 1 }
        let token = String(chars[start..<end])
        if let host {
            // A device's files can't be checked from here, so only what looks like a path to
            // one counts, and only when the editor can open it there.
            guard FileReference.urlEditors.contains(FileEditor.editor), token.contains("/"),
                  let home = Device.home(host) else { return nil }
            return FileReference.parse(token, cwd: workingDirectory(), home: home, host: host)
        }
        guard let ref = FileReference.parse(token, cwd: workingDirectory()), FileManager.default.fileExists(atPath: ref.path) else { return nil }
        return ref
    }

    @objc func openSelectedFile(_ sender: Any?) {
        guard let surface else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text), let ptr = text.text else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        let value = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
        // A device's home is known once its link is up.
        guard let home = host == nil ? NSHomeDirectory() : host.flatMap(Device.home) else { return NSSound.beep() }
        if let ref = FileReference.parse(value, cwd: workingDirectory(), home: home, host: host) { FileEditor.open(ref) }
    }
}


extension TerminalView {
    @objc func pasteImagePath(_ sender: Any?) {
        let board = NSPasteboard.general
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { NSSound.beep(); return }
        let directory = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("clipboard-images")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let path = directory.appendingPathComponent("paste-" + UUID().uuidString + ".png")
                try png.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                DispatchQueue.main.async { self?.pasteText(quoteShell(path.path) + " ") }
            } catch {
                DispatchQueue.main.async { let alert = NSAlert(error: error); alert.runModal() }
            }
        }
    }
}
