import AppKit
import Carbon

/// A system hotkey uses Carbon's registration API and needs no event-tap or
/// Accessibility permission. It is opt-in and disabled for private test instances.
final class TerminalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observer: NSObjectProtocol?
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
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
    }
    private func update() {
        let enabled = UserDefaults.standard.bool(forKey: "globalHotkey")
        if !enabled, let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if enabled, reference == nil {
            let id = EventHotKeyID(signature: 0x7465726e, id: 1)
            let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
            if result != noErr { NSLog("tern: global hotkey unavailable (%d)", result) }
        }
    }
    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
