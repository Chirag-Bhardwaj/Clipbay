import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
enum Paster {
    /// Put items on the general pasteboard. Multiple text items are joined one per line.
    static func write(_ items: [ClipItem], plain: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let store = ClipStore.shared
        if items.count > 1, items.allSatisfy({ $0.isTextLike }) {
            pb.setString(items.compactMap(\.text).joined(separator: "\n"), forType: .string)
        } else {
            var objects: [NSPasteboardWriting] = []
            for item in items {
                switch item.kind {
                case .file:
                    if plain {
                        let p = NSPasteboardItem()
                        p.setString(item.text ?? "", forType: .string)
                        objects.append(p)
                    } else {
                        objects.append(contentsOf: (item.fileURLs ?? []).map { URL(fileURLWithPath: $0) as NSURL })
                    }
                default:
                    let p = NSPasteboardItem()
                    if plain, let t = item.text {
                        p.setString(t, forType: .string)
                    } else if !item.reps.isEmpty {
                        for (type, _) in item.reps {
                            if let d = store.data(item, type: type) {
                                p.setData(d, forType: NSPasteboard.PasteboardType(type))
                            }
                        }
                        if item.reps[NSPasteboard.PasteboardType.string.rawValue] == nil, let t = item.text {
                            p.setString(t, forType: .string)
                        }
                    } else if let t = item.text {
                        p.setString(t, forType: .string)
                    }
                    objects.append(p)
                }
            }
            pb.writeObjects(objects)
        }
        ClipboardMonitor.shared.markOwnChange()
    }

    static func copy(_ items: [ClipItem], plain: Bool = false) {
        guard !items.isEmpty else { return }
        write(items, plain: plain || Settings.shared.alwaysPlainText)
        ClipStore.shared.bump(items.map(\.id), target: nil)
    }

    /// Write to the pasteboard and send ⌘V to the frontmost app.
    static func paste(_ items: [ClipItem], plain: Bool, target: NSRunningApplication?) {
        guard !items.isEmpty else { return }
        let usePlain = plain || Settings.shared.alwaysPlainText
        write(items, plain: usePlain)
        ClipStore.shared.bump(items.map(\.id), target: target?.bundleIdentifier)
        guard Settings.shared.pasteToActiveApp else {
            Toast.show("Copied to clipboard")
            return
        }
        guard ensureAccessibility() else {
            Toast.show("Copied — allow Accessibility to paste directly")
            return
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { sendKey(UInt16(kVK_ANSI_V)) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { sendKey(UInt16(kVK_ANSI_V)) }
        }
        if PasteStack.shared.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PasteStack.shared.loadTop() }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Key code that produces `char` on the current layout (so ⌘V works on Dvorak, AZERTY, …).
    private static var keyCodeCache: [Character: UInt16] = [:]

    static func keyCode(for char: Character, fallback: UInt16) -> UInt16 {
        if let c = keyCodeCache[char] { return c }
        let c = lookupKeyCode(char) ?? fallback
        keyCodeCache[char] = c
        return c
    }

    private static func lookupKeyCode(_ char: Character) -> UInt16? {
        for code: UInt16 in 0..<128 where KeyNames.special[code] == nil {
            if KeyNames.name(code).lowercased() == String(char) { return code }
        }
        return nil
    }

    /// When we last synthesized a keystroke (so the Paste Stack ignores our own ⌘V).
    static var lastSynthetic = Date.distantPast

    static func sendKey(_ fallbackCode: UInt16, command: Bool = true) {
        lastSynthetic = Date()
        let char: Character = fallbackCode == UInt16(kVK_ANSI_C) ? "c" : "v"
        let code = keyCode(for: char, fallback: fallbackCode)
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                        state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = command ? .maskCommand : []
        up?.flags = command ? .maskCommand : []
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
