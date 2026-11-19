import SwiftUI
import AppKit
import Observation
import Carbon.HIToolbox

struct StackEntry: Identifiable, Equatable {
    let id = UUID()
    let item: ClipItem
}

/// A temporary ordered queue: everything copied goes in, each ⌘V pastes the top item and removes it.
@MainActor @Observable
final class PasteStack {
    static let shared = PasteStack()

    var entries: [StackEntry] = []
    var isActive = false
    var plainText = false
    var reversed = false
    @ObservationIgnored private var undoStack: [(StackEntry, Int)] = []
    @ObservationIgnored private var panel: KeyPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var advancing = false

    var canUndo: Bool { !undoStack.isEmpty }

    func hotKeyPressed() {
        if ShelfController.shared.isVisible {
            let sel = ShelfState.shared.selectedItems
            ShelfController.shared.hide()
            add(sel)
        } else if isActive {
            // Copy the current selection in the frontmost app into the stack.
            copySelectionFromFrontApp()
        } else {
            start(captureSelection: true)
        }
    }

    func start(captureSelection: Bool) {
        if !isActive {
            isActive = true
            entries = []
            undoStack = []
            ClipboardMonitor.shared.onCapture = { [weak self] item in self?.captured(item) }
            installKeyMonitor()
            HotKeys.reload()
        }
        showPanel()
        if captureSelection { copySelectionFromFrontApp() }
    }

    private func copySelectionFromFrontApp() {
        guard Paster.ensureAccessibility() else {
            Toast.show("Allow Accessibility so the stack can copy and paste")
            return
        }
        Paster.sendKey(UInt16(kVK_ANSI_C))
    }

    func add(_ items: [ClipItem]) {
        guard !items.isEmpty else { return }
        if !isActive { start(captureSelection: false) }
        for it in items { insert(StackEntry(item: it)) }
        loadTop()
        showPanel()
    }

    private func insert(_ e: StackEntry) {
        if reversed { entries.insert(e, at: 0) } else { entries.append(e) }
    }

    private func captured(_ item: ClipItem) {
        guard isActive else { return }
        insert(StackEntry(item: item))
        loadTop()
        resizePanel()
    }

    /// Keep the top of the stack on the system clipboard so the next ⌘V pastes it.
    func loadTop() {
        guard let top = entries.first else { return }
        Paster.write([top.item], plain: plainText || Settings.shared.alwaysPlainText)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command, e.charactersIgnoringModifiers?.lowercased() == "v" else { return }
            DispatchQueue.main.async { PasteStack.shared.userPasted() }
        }
    }

    /// The user pressed ⌘V in another app: drop the top item once the paste has been read.
    private func userPasted() {
        guard isActive, !entries.isEmpty, !advancing,
              Date().timeIntervalSince(Paster.lastSynthetic) > 0.5 else { return }
        advancing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            advancing = false
            guard !entries.isEmpty else { return }
            let e = entries.removeFirst()
            undoStack.append((e, 0))
            ClipStore.shared.bump([e.item.id], target: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            if entries.isEmpty { finish() } else { loadTop(); resizePanel() }
        }
    }

    func pasteNow(_ entry: StackEntry) {
        guard let idx = entries.firstIndex(of: entry) else { return }
        entries.remove(at: idx)
        undoStack.append((entry, idx))
        Paster.write([entry.item], plain: plainText || Settings.shared.alwaysPlainText)
        if Paster.ensureAccessibility() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Paster.sendKey(UInt16(kVK_ANSI_V)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            if entries.isEmpty { finish() } else { loadTop(); resizePanel() }
        }
    }

    func pasteAll() {
        guard isActive, !entries.isEmpty else { return }
        let items = entries.map(\.item)
        let plain = plainText || Settings.shared.alwaysPlainText
        if items.allSatisfy({ $0.isTextLike }) || plain {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(items.compactMap(\.text).joined(separator: "\n"), forType: .string)
            ClipboardMonitor.shared.markOwnChange()
        } else {
            Paster.write(items, plain: false)
        }
        entries = []
        if Paster.ensureAccessibility() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.sendKey(UInt16(kVK_ANSI_V)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.finish() }
    }

    func remove(_ entry: StackEntry) {
        guard let idx = entries.firstIndex(of: entry) else { return }
        entries.remove(at: idx)
        undoStack.append((entry, idx))
        if idx == 0 { loadTop() }
        resizePanel()
    }

    func undo() {
        guard let (e, idx) = undoStack.popLast() else { return }
        entries.insert(e, at: min(idx, entries.count))
        if !isActive { start(captureSelection: false) }
        loadTop()
        resizePanel()
    }

    func move(from: IndexSet, to: Int) {
        entries.move(fromOffsets: from, toOffset: to)
        loadTop()
    }

    func reverse() {
        entries.reverse()
        reversed.toggle()
        loadTop()
    }

    func togglePlain() {
        plainText.toggle()
        loadTop()
    }

    func finish() {
        isActive = false
        entries = []
        ClipboardMonitor.shared.onCapture = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        HotKeys.reload()
        panel?.orderOut(nil)
    }

    // MARK: Panel

    func showPanel() {
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
            p.allowKey = false
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: StackView())
            panel = p
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let vf = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 320, y: vf.maxY - 16))
        }
        resizePanel()
        panel?.orderFrontRegardless()
    }

    private func resizePanel() {
        guard let panel else { return }
        let rows = max(1, entries.count)
        let h = min(520, CGFloat(48 + rows * 64 + 12))
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - h, width: 300, height: h), display: true, animate: false)
    }
}

struct StackView: View {
    var stack = PasteStack.shared
    @State private var hovered: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
                Text("Paste Stack").font(.system(size: 13, weight: .semibold))
                Text("\(stack.entries.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Button { stack.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).disabled(!stack.canUndo).help("Undo")
                Menu {
                    Button("Paste All  ⌃⌥⌘V") { stack.pasteAll() }.disabled(stack.entries.isEmpty)
                    Button("Reverse Order") { stack.reverse() }
                    Toggle("Paste as Plain Text", isOn: Binding(get: { stack.plainText }, set: { _ in stack.togglePlain() }))
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { stack.finish() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Close and empty the stack")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            Divider()
            if stack.entries.isEmpty {
                VStack(spacing: 4) {
                    Text("Copy items to add them").font(.system(size: 12, weight: .medium))
                    Text("Then press ⌘V to paste them one by one").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(stack.entries.enumerated()), id: \.element.id) { idx, e in
                        StackRow(entry: e, isTop: idx == 0, hovered: hovered == e.id)
                            .onHover { hovered = $0 ? e.id : nil }
                            .onTapGesture(count: 2) { stack.pasteNow(e) }
                            .contextMenu {
                                Button("Paste Now") { stack.pasteNow(e) }
                                Button("Delete") { stack.remove(e) }
                            }
                            .onDrag { DropImporter.provider(for: e.item) }
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                    .onMove { stack.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .onDrop(of: dropTypes, isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? NSString else { return }
                    DispatchQueue.main.async {
                        if let item = DropImporter.importObjects([s], pinTo: nil) { PasteStack.shared.add([item]) }
                    }
                }
            }
            return true
        }
    }
}

struct StackRow: View {
    let entry: StackEntry
    let isTop: Bool
    let hovered: Bool
    var body: some View {
        let item = entry.item
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: AppIcons.color(item.sourceBundleID)))
                if item.kind == .image, let img = ImageCache.image(ClipStore.shared.thumbnailURL(item), revision: 0) {
                    Image(nsImage: img).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 6))
                } else if item.kind == .color {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Detect.nsColor(hex: item.colorHex ?? "")))
                } else if let icon = AppIcons.icon(item.sourceBundleID) {
                    Image(nsImage: icon).resizable().padding(6)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .text || item.kind == .link ? (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : item.displayTitle)
                    .font(.system(size: 12)).lineLimit(2)
                Text(item.metaLine).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hovered {
                Button { PasteStack.shared.remove(entry) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            } else if isTop {
                Text("⌘V").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isTop ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
    }
}
