import AppKit
import GhosttyKit

/// Owns the libghostty app instance and routes its runtime callbacks.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // Reuse the user's Ghostty config (font, theme, ...) so tern looks like their terminal.
        let config = ghostty_config_new()
        // tern's defaults first, so the user's own Ghostty config overrides them.
        Self.defaultsFile.path.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { GhosttyApp.shared.tick() }
        }
        runtime.action_cb = { app, target, action in
            GhosttyApp.shared.handle(target: target, action: action)
        }
        runtime.read_clipboard_cb = { userdata, location, state, _, _, _ in
            GhosttyApp.readClipboard(userdata, location: location, state: state)
        }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, location, content, len, _ in
            GhosttyApp.writeClipboard(location: location, content: content, len: len)
        }
        runtime.close_surface_cb = { userdata, _ in
            guard let view = TerminalView.from(userdata) else { return }
            DispatchQueue.main.async { view.surfaceClosed() }
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

    /// The sidebar and other chrome: the terminal background, lifted a touch toward the text colour.
    lazy var chrome: NSColor = background.blended(withFraction: isDark ? 0.045 : 0.035, of: foreground) ?? background

    /// The terminal's background colour, so the chrome around it can match.
    lazy var background: NSColor = color("background") ?? NSColor(calibratedWhite: 0.1, alpha: 1)
    lazy var foreground: NSColor = color("foreground") ?? .textColor

    var isDark: Bool {
        guard let c = background.usingColorSpace(.sRGB) else { return true }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }

    private func color(_ key: String) -> NSColor? {
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
        case GHOSTTY_ACTION_SET_TITLE:
            guard let ptr = action.action.set_title.title else { return true }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view?.titleChanged(title) }
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
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = TerminalView.from(userdata),
              let surface = view.surface
        else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let mime = strdup("text/plain")!
        defer { free(mime) }
        text.withCString { data in
            var content = ghostty_clipboard_content_s(mime: mime, data: data, len: strlen(data))
            withUnsafePointer(to: &content) { contentPtr in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentPtr, contents_len: 1,
                    available: nil, available_len: 0,
                    confirmed: false, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { continue }
            let bytes = Data(bytes: data, count: item.len)
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }
}
