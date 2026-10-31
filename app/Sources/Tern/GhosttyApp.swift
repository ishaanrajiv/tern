import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Owns the libghostty app instance and routes its runtime callbacks.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    /// The theme the config was built with.
    private(set) var theme: Theme = .graphite
    var themeID: String { theme.id }
    private(set) var diagnostics = ""

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        let config = makeConfig()
        self.config = config
        ThemeStore.shared.set(theme)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        // Wakeup comes from any thread. The rest come from ghostty_app_tick and surface
        // calls, which tern makes on the main thread (Ghostty's own app relies on this too).
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { GhosttyApp.shared.tick() }
        }
        runtime.action_cb = { app, target, action in
            MainActor.assumeIsolated { GhosttyApp.shared.handle(target: target, action: action) }
        }
        runtime.read_clipboard_cb = { userdata, location, state, mimes, count, list in
            MainActor.assumeIsolated { GhosttyApp.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count, list: list) }
        }
        runtime.confirm_read_clipboard_cb = { userdata, confirm, state, request in
            MainActor.assumeIsolated {
                GhosttyApp.confirmClipboard(userdata, confirm: confirm, state: state, request: request)
            }
        }
        runtime.write_clipboard_cb = { _, location, content, len, _ in
            MainActor.assumeIsolated { GhosttyApp.writeClipboard(location: location, content: content, len: len) }
        }
        runtime.close_surface_cb = { userdata, _ in
            MainActor.assumeIsolated {
                guard let view = TerminalView.from(userdata) else { return }
                DispatchQueue.main.async { view.surfaceClosed() }
            }
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app
    }

    /// Breathing room around the text; Ghostty's own default is 2pt.
    private static let defaultsFile: URL = {
        let url = Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("ghostty-defaults")
        let text = """
        # Written by tern on every launch. Override these in your Ghostty config.
        window-padding-x = 12
        window-padding-y = 8
        window-padding-balance = true

        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    /// The user's Ghostty config (font, keys, ...) with tern's theme on top. Load order: tern's
    /// defaults, which the user's config overrides, then the theme's colours, which win.
    private func makeConfig() -> ghostty_config_t? {
        let id = ThemeStore.selectedID
        let chosen = Theme.builtIn.first { $0.id == id }
        let config = ghostty_config_new()
        Self.defaultsFile.path.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_load_default_files(config)
        if let text = chosen?.ghosttyConfig {
            let url = Self.defaultsFile.deletingLastPathComponent().appendingPathComponent("ghostty-theme")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        // Only what tern's config file sets overrides your Ghostty config.
        if !TerminalPreferences.given.isEmpty {
            let overrides = Self.defaultsFile.deletingLastPathComponent().appendingPathComponent("terminal-overrides")
            try? TerminalPreferences.current.ghostty(TerminalPreferences.given).write(to: overrides, atomically: true, encoding: .utf8)
            overrides.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)
        diagnostics = (0..<ghostty_config_diagnostics_count(config)).compactMap {
            ghostty_config_get_diagnostic(config, $0).message.map { String(cString: $0) }
        }.joined(separator: "\n")
        theme = chosen ?? .ghostty(
            background: Self.color("background", in: config) ?? NSColor(calibratedWhite: 0.1, alpha: 1),
            foreground: Self.color("foreground", in: config) ?? .white)
        return config
    }

    /// The chrome tern builds around the user's own Ghostty colours, for the Settings preview.
    lazy var userTheme: Theme = {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        defer { ghostty_config_free(config) }
        return .ghostty(background: Self.color("background", in: config) ?? NSColor(calibratedWhite: 0.1, alpha: 1),
                        foreground: Self.color("foreground", in: config) ?? .white)
    }()

    /// Rebuilds the config for the theme setting and hands it to every terminal.
    func applyTheme() {
        guard let app, let new = makeConfig() else { return }
        ghostty_app_update_config(app, new)
        for view in TerminalView.all.allObjects {
            if let surface = view.surface { ghostty_surface_update_config(surface, new) }
        }
        // The old config stays allocated: surfaces may still point into it, and a theme change is rare.
        config = new
    }

    private static func color(_ key: String, in config: ghostty_config_t?) -> NSColor? {
        guard let config else { return nil }
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: TerminalView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? TerminalView.from(ghostty_surface_userdata(target.target.surface))
            : nil

        switch action.tag {
        case GHOSTTY_ACTION_SELECTION_CHANGED:
            if let view { NSAccessibility.post(element: view, notification: .selectedTextChanged) }
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            guard NSApp.isActive else { return false }
            switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: if !SecureKeyboard.shared.enabled { SecureKeyboard.shared.toggle() }
            case GHOSTTY_SECURE_INPUT_OFF: SecureKeyboard.shared.disable()
            default: SecureKeyboard.shared.toggle()
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            guard let ptr = action.action.set_title.title else { return true }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view?.titleChanged(title) }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            DispatchQueue.main.async { view?.onSearch?(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            DispatchQueue.main.async { view?.onEndSearch?() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let value = action.action.search_total.total
            DispatchQueue.main.async { view?.onSearchTotal?(value) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let value = action.action.search_selected.selected
            DispatchQueue.main.async { view?.onSearchSelected?(value) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let link = action.action.open_url
            guard let ptr = link.url else { return false }
            let text = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(link.len)), as: UTF8.self)
            guard let url = TerminalLink.url(text) else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            DispatchQueue.main.async { self.applyTheme() }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // Ghostty owns hit testing; AppKit supplies the native cursor.
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { (shape == GHOSTTY_MOUSE_SHAPE_POINTER ? NSCursor.pointingHand : NSCursor.iBeam).set() }
            return true
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // `tern attach` ended abnormally. Rather than Ghostty's "press any key", the
            // tab closes if its session is gone, or attaches again if it isn't.
            DispatchQueue.main.async { view?.surfaceClosed() }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { NSSound.beep() }
            return true
        default:
            return false
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = TerminalView.from(userdata), let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let board = NSPasteboard.general
        var contents: [(mime: String, data: Data)] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<count {
                guard let pointer = mimes[i] else { continue }
                let mime = String(cString: pointer)
                guard seen.insert(mime).inserted else { continue }
                if mime == "text/plain", let text = pasteText(board) {
                    contents.append((mime, Data(text.utf8)))
                } else if let type = UTType(mimeType: mime), let bytes = board.data(forType: NSPasteboard.PasteboardType(type.identifier)) {
                    contents.append((mime, bytes))
                } else if mime == "image/png", let bytes = board.data(forType: .tiff), let image = NSBitmapImageRep(data: bytes), let png = image.representation(using: .png, properties: [:]) {
                    contents.append((mime, png))
                }
            }
        }
        let available = list ? Array(Set((board.types ?? []).compactMap { type -> String? in
            if type == .string { return "text/plain" }
            if type == .tiff { return "image/png" }
            return UTType(type.rawValue)?.preferredMIMEType
        })).sorted() : []
        guard !contents.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: available, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// What a paste types. Files copied in Finder carry their name as text; paste their full
    /// paths instead, quoted for the shell, as dropping them does.
    static func pasteText(_ board: NSPasteboard) -> String? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { quoteShell($0.path) }.joined(separator: " ")
        }
        return board.string(forType: .string)
    }

    /// Ghostty asks before a paste that could run commands (newlines, and the program hasn't
    /// turned on bracketed paste) and before a program reads the clipboard. The request stays
    /// open until it's completed as confirmed or denied.
    private static func confirmClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalView.from(userdata), let confirm else { return }
        // Borrowed for this call only: copy before asking.
        let contents: [(mime: String, data: Data)] = (0..<confirm.pointee.contents_len).compactMap { i in
            let item = confirm.pointee.contents[i]
            guard let mime = item.mime, let data = item.data else { return nil }
            return (String(cString: mime), Data(bytes: data, count: item.len))
        }
        let available = (0..<confirm.pointee.available_len).compactMap { i in confirm.pointee.available[i].map { String(cString: $0) } }
        let text = contents.first { $0.mime == "text/plain" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        DispatchQueue.main.async {
            askClipboard(text: text, request: request, in: view.window) { allowed in
                guard let surface = view.surface else { return }
                guard allowed else { return ghostty_surface_deny_clipboard_request(surface, state) }
                complete(surface, contents: contents, available: available, state: state)
            }
        }
    }

    private static func askClipboard(text: String, request: ghostty_clipboard_request_e, in window: NSWindow?,
                                     answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let preview = lines.prefix(6).map { $0.count > 80 ? $0.prefix(80) + "…" : $0 }.joined(separator: "\n")
            alert.messageText = lines.count > 1 ? "Paste \(lines.count) lines?" : "Paste this?"
            alert.informativeText = "The program in this tab hasn't turned on bracketed paste, so each line may run "
                + "as a command.\n\n\(preview)\(lines.count > 6 ? "\n…" : "")"
            alert.addButton(withTitle: "Paste")
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            alert.messageText = "Let this tab set the clipboard?"
            alert.informativeText = "A program in this tab wants to replace what's on the clipboard."
            alert.addButton(withTitle: "Allow")
        default:
            alert.messageText = "Let this tab read the clipboard?"
            alert.informativeText = "A program in this tab asked for what's on the clipboard."
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")
        guard let window, window.attachedSheet == nil else {
            return answer(alert.runModal() == .alertFirstButtonReturn)
        }
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    private static func complete(_ surface: ghostty_surface_t, contents: [(mime: String, data: Data)],
                                 available: [String] = [], state: UnsafeMutableRawPointer?, confirmed: Bool = true) {
        // Pointers into these copies live only for the call.
        let mimes = contents.map { strdup($0.mime)! }
        let datas = contents.map { item -> UnsafeMutablePointer<CChar> in
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: max(item.data.count, 1))
            _ = item.data.withUnsafeBytes { raw in raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: p, count: item.data.count)) }
            return p
        }
        defer {
            mimes.forEach { free($0) }
            datas.forEach { $0.deallocate() }
        }
        let items = contents.indices.map { i in
            ghostty_clipboard_content_s(mime: mimes[i], data: datas[i], len: contents[i].data.count)
        }
        let types = available.map { strdup($0)! }
        defer { types.forEach { free($0) } }
        let typePointers = types.map { Optional(UnsafePointer($0)) }
        typePointers.withUnsafeBufferPointer { typesBuffer in
            items.withUnsafeBufferPointer { buf in
                var done = ghostty_clipboard_complete_s(
                    contents: buf.baseAddress, contents_len: buf.count,
                    available: typesBuffer.baseAddress, available_len: typesBuffer.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        let values: [(NSPasteboard.PasteboardType, Data)] = (0..<len).compactMap { index in
            let item = content[index]
            guard let raw = item.mime, let pointer = item.data else { return nil }
            let mime = String(cString: raw)
            guard let type = mime == "text/plain" ? NSPasteboard.PasteboardType.string : UTType(mimeType: mime).map({ NSPasteboard.PasteboardType($0.identifier) }) else { return nil }
            return (type, Data(bytes: pointer, count: item.len))
        }
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        for (type, data) in values { NSPasteboard.general.setData(data, forType: type) }
    }
}
