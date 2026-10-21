import AppKit
import GhosttyKit

/// Owns the libghostty app instance and routes its runtime callbacks.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    /// The theme the config was built with.
    private(set) var theme: Theme = .graphite
    var themeID: String { theme.id }

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
        ghostty_config_finalize(config)
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
