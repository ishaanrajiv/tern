import AppKit

/// Development aid, on only when launched with TERN_DEBUG=1:
///   kill -USR1 <pid>   saves a PNG of each window to <support>/tern/debug/window-N.png
///   kill -USR2 <pid>   runs the command named in <support>/tern/debug/command (a palette title;
///                      Escape, Return, Tab, Up or Down to press that key; Type <text>; or
///                      Button N to answer an alert sheet)
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
            // "Type <text>" enters text into whatever has focus (say, the folder picker).
            if title.hasPrefix("Type ") {
                let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
                (window?.firstResponder as? NSTextView)?.insertText(String(title.dropFirst(5)), replacementRange: NSRange(location: NSNotFound, length: 0))
                return
            }
            let arrow = { (k: Int) in String(UnicodeScalar(UInt16(k))!) }
            let keys: [String: (String, UInt16)] = [
                "Escape": ("\u{1b}", 53), "Return": ("\r", 36), "Tab": ("\t", 48),
                "Down": (arrow(NSDownArrowFunctionKey), 125), "Up": (arrow(NSUpArrowFunctionKey), 126),
            ]
            if let (chars, code) = keys[title] {
                // A real key event, so it reaches whatever view (or sheet) has focus.
                // Straight to the window: NSApp routes keys to the key window, and there's
                // none while tern is in the background.
                let target = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
                if let window = target,
                   let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
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
