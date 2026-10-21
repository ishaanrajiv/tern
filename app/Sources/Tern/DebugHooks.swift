import AppKit

/// Development aid, on only when launched with TERN_DEBUG=1:
///   kill -USR1 <pid>   saves a PNG of each window to <support>/tern/debug/window-N.png
///   kill -USR2 <pid>   runs the command named in <support>/tern/debug/command (a palette title;
///                      Escape, Return, Tab, Up, Down, Cmd+A, Cmd+C or Cmd+V to press that key;
///                      Type <text>; Drag X1 Y1 X2 Y2; or Button N to answer an alert sheet)
/// An app may capture its own windows without screen-recording permission.
enum DebugHooks {
    private static var sources: [DispatchSourceSignal] = []

    static func install(commands: @escaping () -> [Command]) {
        guard ProcessInfo.processInfo.environment["TERN_DEBUG"] == "1" else { return }
        let dir = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("debug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        on(SIGUSR1) { snapshot(to: dir) }
        on(SIGUSR2) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("command"), encoding: .utf8) else { return }
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Button N" answers the alert sheet up, as if its Nth button were clicked.
            if title.hasPrefix("Button "), let n = Int(title.dropFirst(7)),
               let parent = NSApp.windows.first(where: { $0.attachedSheet != nil }), let sheet = parent.attachedSheet {
                parent.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + n - 1))
                return
            }
            // "Hover X Y" / "Click X Y": mouse events at window point (X, Y), measured from the top left.
            let parts = title.split(separator: " ")
            // "Drag X1 Y1 X2 Y2": a left-button drag, to select text.
            if parts.count == 5, parts[0] == "Drag",
               let x1 = Double(parts[1]), let y1 = Double(parts[2]), let x2 = Double(parts[3]), let y2 = Double(parts[4]),
               let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                let steps: [(NSEvent.EventType, Double, Double)] = [(.leftMouseDown, x1, y1)]
                    + (1...8).map { (.leftMouseDragged, x1 + (x2 - x1) * Double($0) / 8, y1 + (y2 - y1) * Double($0) / 8) }
                    + [(.leftMouseUp, x2, y2)]
                for (type, x, y) in steps {
                    if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.frame.height - y), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        window.sendEvent(e)
                    }
                }
                return
            }
            if parts.count == 3, parts[0] == "Hover" || parts[0] == "Click",
               let x = Double(parts[1]), let y = Double(parts[2]),
               let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                let point = NSPoint(x: x, y: window.frame.height - y)
                let types: [NSEvent.EventType] = parts[0] == "Hover" ? [.mouseMoved] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
                for type in types {
                    if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        window.sendEvent(e)
                    }
                }
                return
            }
            // "Type <text>" enters text into whatever has focus (say, the folder picker).
            if title.hasPrefix("Type ") {
                let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
                (window?.firstResponder as? NSTextView)?.insertText(String(title.dropFirst(5)), replacementRange: NSRange(location: NSNotFound, length: 0))
                return
            }
            let arrow = { (k: Int) in String(UnicodeScalar(UInt16(k))!) }
            let keys: [String: (String, UInt16)] = [
                "Escape": ("\u{1b}", 53), "Return": ("\r", 36), "Tab": ("\t", 48), "Backspace": ("\u{7f}", 51),
                "Down": (arrow(NSDownArrowFunctionKey), 125), "Up": (arrow(NSUpArrowFunctionKey), 126),
            ]
            // "Cmd+C" style: a letter with ⌘, as the menu bar sees it.
            let letters: [String: UInt16] = ["a": 0, "c": 8, "v": 9]
            let command = title.lowercased().hasPrefix("cmd+") ? letters[String(title.lowercased().dropFirst(4))] : nil
            if let (chars, code) = keys[title] ?? command.map({ (String(title.lowercased().dropFirst(4)), $0) }) {
                // A real key event, so it reaches whatever view (or sheet) has focus.
                // Straight to the window: NSApp routes keys to the key window, and there's
                // none while tern is in the background.
                let target = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
                if let window = target,
                   let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command == nil ? [] : .command, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
                }
            } else if let command = commands().first(where: { $0.title == title }) {
                command.action()
            } else {
                NSLog("tern debug: no command named %@", title)
            }
        }
    }

    private static func on(_ sig: Int32, _ body: @escaping () -> Void) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: body)
        source.resume()
        sources.append(source)
    }

    private static func snapshot(to dir: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 50 }
        for (i, window) in windows.enumerated() {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window-\(i).png"))
        }
        NSLog("tern debug: saved %d window snapshot(s)", windows.count)
    }
}
