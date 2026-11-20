import AppKit
import SwiftUI

/// `Clipbay --snapshot <dir>` renders the main views offscreen to PNGs (for visual checks without the screen).
@MainActor
enum Snapshot {
    static func run(dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let state = ShelfState.shared
        state.ensureSelection(state.visibleItems)

        render(ShelfView(), size: NSSize(width: 1440, height: Settings.shared.shelfHeight), to: out.appendingPathComponent("shelf.png"))
        state.cmdHeld = true
        render(ShelfView(), size: NSSize(width: 1440, height: Settings.shared.shelfHeight), to: out.appendingPathComponent("shelf-cmd.png"))
        state.cmdHeld = false
        state.query = "mac"
        render(ShelfView(), size: NSSize(width: 1440, height: Settings.shared.shelfHeight), to: out.appendingPathComponent("shelf-search.png"))
        state.query = ""
        state.modal = .newPinboard(pinning: [])
        render(ShelfView(), size: NSSize(width: 1440, height: Settings.shared.shelfHeight), to: out.appendingPathComponent("shelf-modal.png"))
        state.modal = nil
        if let first = state.selectedItems.first {
            for it in ClipStore.shared.items.prefix(6) {
                state.selection = [it.id]
                render(PreviewView(item: it), size: NSSize(width: 760, height: 460), to: out.appendingPathComponent("preview-\(it.kind.rawValue).png"))
            }
            state.selection = [first.id]
        }
        ClipbayStack.shared.entries = ClipStore.shared.items.prefix(4).map { StackEntry(item: $0) }
        render(StackView(), size: NSSize(width: 300, height: 320), to: out.appendingPathComponent("stack.png"))
        ClipbayStack.shared.entries = []
        for t in SettingsTab.allCases {
            SettingsTabState.shared.tab = t
            render(SettingsView(), size: NSSize(width: 640, height: 500), to: out.appendingPathComponent("settings-\(t.rawValue).png"))
        }
        render(WelcomeView {}, size: NSSize(width: 520, height: 460), to: out.appendingPathComponent("welcome.png"))
    }

    static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(white: 0.5, alpha: 1)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
    }
}
