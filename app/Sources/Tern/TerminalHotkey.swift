import AppKit
import Carbon

/// A system hotkey uses Carbon's registration API and needs no event-tap or
/// Accessibility permission. It is opt-in and disabled for private test instances.
final class TerminalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    /// What's registered now, so a change of binding re-registers.
    private var registered: KeyBinding?
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        guard ProcessInfo.processInfo.environment["TERN_RUNTIME_DIR"] == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<TerminalHotkey>.fromOpaque(context).takeUnretainedValue().action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        update()
        // The switch lives in UserDefaults; the keys can be overridden with the app shortcuts.
        observers = [UserDefaults.didChangeNotification, TerminalPreferences.didChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        }
    }
    private func update() {
        let enabled = UserDefaults.standard.bool(forKey: "globalHotkey")
        let wanted = enabled ? ShortcutRegistry.primary("app.globalHotkey") : nil
        guard wanted != registered else { return }
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        registered = nil
        guard let wanted else { return }
        guard let code = Self.keyCodes[wanted.key] else { return NSLog("tern: no key code for the global hotkey %@", wanted.label) }
        var mods = 0
        if wanted.modifiers.contains(.command) { mods |= cmdKey }
        if wanted.modifiers.contains(.shift) { mods |= shiftKey }
        if wanted.modifiers.contains(.option) { mods |= optionKey }
        if wanted.modifiers.contains(.control) { mods |= controlKey }
        let id = EventHotKeyID(signature: 0x7465726e, id: 1)
        let result = RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &reference)
        if result == noErr { registered = wanted } else { NSLog("tern: global hotkey unavailable (%d)", result) }
    }

    /// Carbon key codes (US layout positions) for the keys a hotkey may use.
    static let keyCodes: [String: Int] = {
        let letters = "asdfhgzxcv bqweryt123465=97-80]ou[ip lj'k;\\,/nm.  `"
        var codes: [String: Int] = [:]
        for (code, char) in letters.enumerated() where char != " " { codes[String(char)] = code }
        codes[" "] = kVK_Space
        codes["\r"] = kVK_Return
        codes["\t"] = kVK_Tab
        codes["\u{1b}"] = kVK_Escape
        codes[Key.left] = kVK_LeftArrow
        codes[Key.right] = kVK_RightArrow
        codes[Key.up] = kVK_UpArrow
        codes[Key.down] = kVK_DownArrow
        return codes
    }()
    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

@Observable final class SecureKeyboard {
    static let shared = SecureKeyboard()
    private(set) var enabled = false
    func toggle() {
        let status = enabled ? DisableSecureEventInput() : EnableSecureEventInput()
        if status == noErr { enabled.toggle() }
        else { NSSound.beep() }
    }
    func disable() { if enabled { _ = DisableSecureEventInput(); enabled = false } }
}
