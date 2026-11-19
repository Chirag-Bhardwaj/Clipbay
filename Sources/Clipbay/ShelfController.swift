import AppKit
import SwiftUI
import Carbon.HIToolbox

final class KeyPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var allowKey = true

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    /// ⌘-key presses arrive here before sendEvent; route them to the same handler.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let h = keyHandler, h(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .flagsChanged || event.type == .scrollWheel,
           let h = keyHandler, h(event) { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    static let shared = ShelfController()
    private var panel: KeyPanel!
    private let state = ShelfState.shared
    private var hiding = false

    func setup() {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 330),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) // above the Dock
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isMovable = false
        p.animationBehavior = .none
        p.delegate = self
        let host = NSHostingView(rootView: ShelfView())
        host.sizingOptions = []
        p.contentView = host
        p.keyHandler = { [weak self] e in self?.handle(e) ?? false }
        panel = p
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var window: NSWindow? { panel }

    func toggle() { isVisible ? hide() : show() }

    func show(list: ListID? = nil) {
        if panel == nil { setup() }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { state.targetApp = front }
        PreviewController.shared.hide()
        state.modal = nil
        state.previewing = false
        state.query = ""
        state.filters = Filters()
        state.resultsFocused = false
        state.cmdHeld = false
        if let list { state.list = list }
        if case .pinboard(let id) = state.list, !ClipStore.shared.pinboards.contains(where: { $0.id == id }) {
            state.list = .clipboard
        }
        if state.list == .suggestions && !Settings.shared.suggestionsEnabled { state.list = .clipboard }
        state.selection = []
        state.ensureSelection(state.visibleItems)
        state.scrollTarget = state.selection.first
        state.scrollNonce += 1

        let screen = screenForShow()
        let h = CGFloat(Settings.shared.shelfHeight)
        let f = screen.frame
        // Sit just above the Dock when it's at the bottom, spanning the full width.
        let bottom = screen.visibleFrame.minY
        let target = NSRect(x: f.minX, y: bottom, width: f.width, height: h)
        panel.setFrame(target.offsetBy(dx: 0, dy: -(h + bottom - f.minY)), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        state.isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
        DispatchQueue.main.async { SearchFieldRef.focus() }
    }

    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible, !hiding else { return }
        hiding = true
        PreviewController.shared.hide()
        state.previewing = false
        state.isVisible = false
        state.cmdHeld = false
        let f = panel.frame
        let done = { [weak self] in
            panel.orderOut(nil)
            self?.hiding = false
            if NSApp.isActive, !(SettingsController.shared.isVisible) { NSApp.hide(nil) }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(f.offsetBy(dx: 0, dy: -f.height), display: true)
            }, completionHandler: { MainActor.assumeIsolated { done() } })
        } else {
            done()
        }
    }

    func resize(to height: CGFloat) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let h = max(190, min(screen.frame.height * 0.7, height))
        Settings.shared.shelfHeight = Double(h)
        var f = panel.frame
        f.size.height = h
        panel.setFrame(f, display: true)
        PreviewController.shared.reposition()
    }

    private func screenForShow() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the shelf (like a menu).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            if let key = NSApp.keyWindow, key == self.panel || key.parent == self.panel { return }
            if NSApp.modalWindow != nil { return }
            if self.state.modal != nil, NSApp.isActive { return }
            self.hide()
        }
    }

    // MARK: Actions

    var target: NSRunningApplication? { state.targetApp }

    func paste(_ items: [ClipItem], plain: Bool) {
        guard !items.isEmpty else { return }
        hide(animated: false)
        Paster.paste(items, plain: plain, target: target)
    }

    func pasteSelection(plain: Bool) { paste(state.selectedItems, plain: plain) }

    func copySelection() {
        let items = state.selectedItems
        guard !items.isEmpty else { return }
        Paster.copy(items)
        hide()
        Toast.show(items.count > 1 ? "Copied \(items.count) items" : "Copied")
    }

    func deleteSelection() {
        let items = state.visibleItems
        let sel = state.selection
        guard !sel.isEmpty else { return }
        let lastIdx = items.lastIndex { sel.contains($0.id) } ?? 0
        let remaining = items.filter { !sel.contains($0.id) }
        ClipStore.shared.delete(sel)
        state.selection = []
        if !remaining.isEmpty {
            let next = remaining[min(max(0, lastIdx - sel.count + 1), remaining.count - 1)]
            state.select(next.id, in: remaining)
        }
    }

    func undo() {
        let restored = ClipStore.shared.undoDelete()
        if let f = restored.first { state.select(f.id, in: state.visibleItems) }
    }

    func open(_ item: ClipItem) {
        if item.kind == .link, let u = item.url, let url = URL(string: u.lowercased().hasPrefix("www.") ? "https://" + u : u) {
            hide(); NSWorkspace.shared.open(url)
        } else if item.kind == .file, let paths = item.fileURLs {
            hide(); paths.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
        }
    }

    func showInList(_ item: ClipItem) {
        let l: ListID = item.pinboardID.map { .pinboard($0) } ?? .clipboard
        state.switchList(l)
        state.select(item.id, in: state.visibleItems)
    }

    func newItemInCurrentList(text: String) {
        var item = ClipItem(kind: .text, hash: ClipStore.hash("text:" + text))
        item.text = text
        item.sourceBundleID = Bundle.main.bundleIdentifier
        item.sourceAppName = "Clipbay"
        if let l = Detect.link(text) { item.kind = .link; item.url = l.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let c = Detect.color(text) { item.kind = .color; item.colorHex = c }
        let (saved, _) = ClipStore.shared.insert(item, blobs: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)], thumbnail: nil)
        if case .pinboard(let b) = state.list { ClipStore.shared.pin([saved.id], to: b) }
        Enrichment.process(saved)
        state.select(saved.id, in: state.visibleItems)
    }

    // MARK: Keyboard

    private func handle(_ e: NSEvent) -> Bool {
        if ProcessInfo.processInfo.environment["CLIPBAY_DEBUG"] != nil || CommandLine.arguments.contains("--debug") {
            let line = "key type=\(e.type.rawValue) code=\(e.keyCode) flags=\(e.modifierFlags.rawValue)\n"
            let path = Paths.localRoot.appendingPathComponent("debug.log").path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        }
        if e.type == .flagsChanged {
            let held = e.modifierFlags.contains(Settings.shared.quickPasteModifier.flag)
            if state.cmdHeld != held { state.cmdHeld = held }
            return false
        }
        if e.type == .scrollWheel { return handleScroll(e) }
        if state.modal != nil { return false } // editor/sheets get everything
        HotKeyCenter.shared.suspended = false

        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let items = state.visibleItems
        let fieldFocused = SearchFieldRef.isFocused
        let queryEmpty = state.query.isEmpty
        let code = Int(e.keyCode)
        let plainMod = Settings.shared.plainTextModifier.flag
        let quickMod = Settings.shared.quickPasteModifier.flag

        // Quick paste: modifier + 1…9
        let digitCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypadCodes = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                           kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        if flags.contains(quickMod), let n = digitCodes.firstIndex(of: code) ?? keypadCodes.firstIndex(of: code) {
            if n < items.count {
                let plain = flags.contains(plainMod) && plainMod != quickMod
                paste([items[n]], plain: plain || (quickMod == .command && shift))
            }
            return true
        }

        switch code {
        case kVK_Escape:
            if state.previewing { togglePreview(); return true }
            if state.showFilterMenu { state.showFilterMenu = false; return true }
            if !state.query.isEmpty { state.query = ""; state.ensureSelection(state.visibleItems); return true }
            if !state.filters.isEmpty { state.filters = Filters(); state.ensureSelection(state.visibleItems); return true }
            hide(); return true
        case kVK_LeftArrow, kVK_RightArrow:
            let d = code == kVK_LeftArrow ? -1 : 1
            if cmd { state.cycleList(d); return true }
            if fieldFocused && !queryEmpty && flags.contains(.option) { return false }
            state.move(d, extend: shift, in: items)
            state.resultsFocused = true
            return true
        case kVK_UpArrow, kVK_DownArrow:
            if cmd {
                if let id = (code == kVK_UpArrow ? items.first : items.last)?.id { state.select(id, in: items) }
                return true
            }
            if code == kVK_DownArrow, let s = state.tokenSuggestions.first, fieldFocused {
                state.apply(s); state.query = ""; state.ensureSelection(state.visibleItems); return true
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if cmd && !shift { if let i = state.selectedItems.first { open(i) }; return true }
            pasteSelection(plain: flags.contains(plainMod))
            return true
        case kVK_Tab:
            if fieldFocused { SearchFieldRef.unfocus(); state.resultsFocused = true }
            else { SearchFieldRef.focus(); state.resultsFocused = false }
            return true
        case kVK_Space where !cmd:
            if queryEmpty || !fieldFocused { togglePreview(); return true }
            return false
        case kVK_Delete, kVK_ForwardDelete:
            if cmd || queryEmpty || !fieldFocused { deleteSelection(); return true }
            return false
        default: break
        }

        if cmd {
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            switch ch {
            case "c":
                if fieldFocused, let ed = panel.fieldEditor(false, for: nil) as? NSTextView, ed.selectedRange().length > 0 { return false }
                copySelection(); return true
            case "v", "x":
                return false // let the search field paste/cut
            case "a":
                if fieldFocused && !queryEmpty { return false }
                state.selection = items.map(\.id); return true
            case "f":
                if fieldFocused && state.searchActive { state.showFilterMenu.toggle() }
                SearchFieldRef.focus(); return true
            case "o":
                if let i = state.selectedItems.first { open(i) }; return true
            case "r":
                if let i = state.selectedItems.first { state.modal = .rename(i.id) }; return true
            case "e":
                if let i = state.selectedItems.first, i.kind != .image, i.kind != .file { state.modal = .edit(i.id) }; return true
            case "n":
                state.modal = shift ? .newPinboard(pinning: []) : .newItem; return true
            case "z":
                undo(); return true
            case "g":
                if let i = state.selectedItems.first, state.searchActive { showInList(i) }; return true
            case "t":
                Settings.shared.isPaused ? Settings.shared.resume() : Settings.shared.pause(for: nil)
                Toast.show(Settings.shared.isPaused ? "Clipbay paused" : "Clipbay resumed"); return true
            case "p":
                if !state.selection.isEmpty { PasteStack.shared.add(state.selectedItems); hide() }; return true
            case ",":
                hide(animated: false); SettingsController.shared.show(); return true
            case "q":
                NSApp.terminate(nil); return true
            case "w":
                hide(); return true
            default:
                return true
            }
        }

        // Typing anywhere goes to search.
        if !fieldFocused, let chars = e.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            SearchFieldRef.focus()
            state.resultsFocused = false
            state.query += chars
            return true
        }
        return false
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        // Turn mouse-wheel vertical scrolling into horizontal scrolling of the cards.
        guard state.modal == nil, !e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX),
              let cg = e.cgEvent?.copy() else { return false }
        let dy = cg.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let py = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let fy = cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        cg.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: dy)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: py)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fy)
        cg.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        guard let ne = NSEvent(cgEvent: cg) else { return false }
        panel.contentView?.hitTest(e.locationInWindow).map { view in
            var v: NSView? = view
            while let cur = v, !(cur is NSScrollView) { v = cur.superview }
            (v ?? view).scrollWheel(with: ne)
        }
        return true
    }

    func togglePreview() {
        if state.previewing {
            state.previewing = false
            PreviewController.shared.hide()
        } else if state.selectedItems.first != nil {
            state.previewing = true
            PreviewController.shared.show(above: panel)
        }
    }
}

/// Lets the controller focus the SwiftUI-hosted search field.
@MainActor
enum SearchFieldRef {
    static weak var field: NSTextField?
    static var isFocused: Bool {
        guard let f = field, let w = f.window else { return false }
        return w.firstResponder === f.currentEditor() || w.firstResponder === f
    }
    static func focus() {
        guard let f = field, let w = f.window else { return }
        if !isFocused { w.makeFirstResponder(f) }
        if let ed = f.currentEditor() { ed.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0) }
    }
    static func unfocus() { field?.window?.makeFirstResponder(nil) }
}
