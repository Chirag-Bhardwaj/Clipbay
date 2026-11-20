import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = KeyCombo.carbon(event.modifierFlags)
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(UInt16(keyCode))
    }
}

enum KeyNames {
    static let special: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    static func name(_ code: UInt16) -> String {
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ id: UInt32, _ combo: KeyCombo, _ handler: @escaping () -> Void) {
        unregister(id)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x434C4259), id: id) // 'CLBY'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        } else {
            NSLog("Clipbay: failed to register hotkey \(combo.display) (\(status))")
        }
    }

    func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        handlers[id] = nil
    }

    /// Temporarily suspend all hotkeys (used while recording a new shortcut).
    var suspended = false

    fileprivate func fire(_ id: UInt32) {
        guard !suspended else { return }
        handlers[id]?()
    }
}

@MainActor
enum HotKeys {
    static func reload() {
        let s = Settings.shared
        let c = HotKeyCenter.shared
        c.install()
        c.register(1, s.activateHotKey) { ShelfController.shared.toggle() }
        c.register(2, s.stackHotKey) { ClipbayStack.shared.hotKeyPressed() }
        // Only claim the "paste whole stack" shortcut while a stack is open.
        if ClipbayStack.shared.isActive {
            c.register(3, s.pasteAllHotKey) { ClipbayStack.shared.pasteAll() }
        } else {
            c.unregister(3)
        }
    }
}
