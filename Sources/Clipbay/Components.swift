import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Search field

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byClipping
        SearchFieldRef.field = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        if f.placeholderString != placeholder { f.placeholderString = placeholder }
        SearchFieldRef.field = f
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            // Backspace on an empty field removes the last filter token.
            if sel == #selector(NSResponder.deleteBackward(_:)), parent.text.isEmpty {
                MainActor.assumeIsolated {
                    if let last = ShelfState.shared.tokens.last { ShelfState.shared.remove(last) }
                }
                return true
            }
            return false
        }
    }
}

// MARK: Rich text editor

final class EditorBox {
    weak var textView: NSTextView?
}

struct RichTextEditor: NSViewRepresentable {
    let initial: NSAttributedString
    let rich: Bool
    let box: EditorBox

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = rich
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .labelColor
        tv.textStorage?.setAttributedString(initial)
        if !rich {
            tv.font = .systemFont(ofSize: 13)
            tv.textColor = .labelColor
        }
        box.textView = tv
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {}
}

// MARK: Modals inside the shelf

struct ModalView: View {
    let modal: Modal
    var body: some View {
        Group {
            switch modal {
            case .edit(let id): EditModal(id: id)
            case .newItem: NewItemModal()
            case .rename(let id): RenameModal(id: id)
            case .newPinboard(let pinning): PinboardModal(editing: nil, pinning: pinning)
            case .editPinboard(let id): PinboardModal(editing: id, pinning: [])
            case .deletePinboard(let id): DeletePinboardModal(id: id)
            }
        }
        .fixedSize()
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(radius: 20)
    }
}

struct EditModal: View {
    let id: UUID
    let box = EditorBox()
    var body: some View {
        let store = ClipStore.shared
        let item = store.item(id)
        let rich = item?.isRich == true
        let initial: NSAttributedString = {
            if rich, let item, let rtf = store.data(item, type: NSPasteboard.PasteboardType.rtf.rawValue),
               let a = NSAttributedString(rtf: rtf, documentAttributes: nil) { return a }
            if rich, let item, let html = store.data(item, type: NSPasteboard.PasteboardType.html.rawValue),
               let a = NSAttributedString(html: html, documentAttributes: nil) { return a }
            return NSAttributedString(string: item?.text ?? "", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edit \(item?.displayTitle ?? "Item")").font(.headline)
                Spacer()
                if rich { Text("Formatting kept").font(.caption).foregroundStyle(.secondary) }
            }
            RichTextEditor(initial: initial, rich: rich, box: box)
                .frame(width: 560)
                .frame(minHeight: 120, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button("Cancel") { ShelfState.shared.modal = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save(rich: rich) }.keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    func save(rich: Bool) {
        guard let tv = box.textView else { return }
        let text = tv.string
        var rtf: Data?
        if rich, let storage = tv.textStorage {
            rtf = storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [:])
        }
        ClipStore.shared.replaceContent(id, text: text, rtf: rtf)
        if let item = ClipStore.shared.item(id), item.kind == .link { Enrichment.process(item) }
        ShelfState.shared.modal = nil
    }
}

struct NewItemModal: View {
    let box = EditorBox()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Text Item").font(.headline)
            RichTextEditor(initial: NSAttributedString(string: ""), rich: false, box: box)
                .frame(width: 560, height: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Text(ShelfState.shared.list == .clipboard || ShelfState.shared.list == .suggestions ? "Adds to Clipboard" : "Adds to \(ShelfState.shared.listName)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { ShelfState.shared.modal = nil }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let t = box.textView?.string ?? ""
                    ShelfState.shared.modal = nil
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ShelfController.shared.newItemInCurrentList(text: t)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct RenameModal: View {
    let id: UUID
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Text("Leave empty to use the default title").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { ShelfState.shared.modal = nil }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            name = ClipStore.shared.item(id)?.title ?? ""
            DispatchQueue.main.async { focused = true }
        }
    }
    func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        ClipStore.shared.update(id) { $0.title = n.isEmpty ? nil : n }
        ShelfState.shared.modal = nil
    }
}

struct PinboardModal: View {
    let editing: UUID?
    let pinning: [UUID]
    @State private var name = ""
    @State private var color = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New Pinboard" : "Edit Pinboard").font(.headline)
            TextField("Pinboard name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: 8) {
                ForEach(0..<Palette.colors.count, id: \.self) { i in
                    Circle().fill(Palette.color(i))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: color == i ? 2.5 : 0).padding(-3))
                        .onTapGesture { color = i }
                }
            }
            .padding(.vertical, 2)
            HStack {
                Spacer()
                Button("Cancel") { ShelfState.shared.modal = nil }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            let store = ClipStore.shared
            if let editing, let b = store.pinboards.first(where: { $0.id == editing }) {
                name = b.name; color = b.color
            } else {
                color = store.pinboards.count % Palette.colors.count
            }
            DispatchQueue.main.async { focused = true }
        }
    }

    func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let store = ClipStore.shared
        if let editing {
            store.updatePinboard(editing, name: n, color: color)
        } else {
            let b = store.addPinboard(name: n, color: color)
            if !pinning.isEmpty {
                store.pin(pinning, to: b.id)
                Toast.show("Pinned to \(b.name)")
            } else {
                ShelfState.shared.switchList(.pinboard(b.id))
            }
        }
        ShelfState.shared.modal = nil
    }
}

struct DeletePinboardModal: View {
    let id: UUID
    var body: some View {
        let store = ClipStore.shared
        let b = store.pinboards.first { $0.id == id }
        let n = store.items(in: id).count
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete “\(b?.name ?? "")”?").font(.headline)
            Text(n == 0 ? "This pinboard is empty." : "This also deletes the \(n) item\(n == 1 ? "" : "s") pinned to it. This can’t be undone.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 340, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { ShelfState.shared.modal = nil }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if ShelfState.shared.list == .pinboard(id) { ShelfState.shared.switchList(.clipboard) }
                    store.deletePinboard(id)
                    ShelfState.shared.modal = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Drag & drop

@MainActor
enum DropImporter {
    static func provider(for item: ClipItem) -> NSItemProvider {
        let store = ClipStore.shared
        switch item.kind {
        case .file:
            if let p = item.fileURLs?.first, let prov = NSItemProvider(contentsOf: URL(fileURLWithPath: p)) { return prov }
        case .image:
            if let png = store.fullImageData(item) {
                let prov = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
                prov.suggestedName = item.hasCustomTitle ? item.title : "Image"
                return prov
            }
        case .link:
            let prov = NSItemProvider(object: (item.text ?? "") as NSString)
            if let u = URL(string: item.url ?? "") { prov.registerObject(u as NSURL, visibility: .all) }
            return prov
        default: break
        }
        return NSItemProvider(object: (item.text ?? "") as NSString)
    }

    /// Turn dropped content from other apps into new items.
    static func importProviders(_ providers: [NSItemProvider], pinTo board: UUID?) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { importObjects([url as NSURL], pinTo: board) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) && !p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage else { return }
                    DispatchQueue.main.async { importObjects([img], pinTo: board) }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? NSString else { return }
                    DispatchQueue.main.async { importObjects([s], pinTo: board) }
                }
            }
        }
    }

    @discardableResult
    static func importObjects(_ objects: [NSPasteboardWriting], pinTo board: UUID?, appName: String? = nil) -> ClipItem? {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.clipbay.import.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects(objects)
        let front = NSWorkspace.shared.frontmostApplication
        guard let cap = ClipboardMonitor.capture(pb, bundleID: front?.bundleIdentifier, appName: appName ?? front?.localizedName) else { return nil }
        let (item, isNew) = ClipStore.shared.insert(cap.item, blobs: cap.blobs, thumbnail: cap.thumbnail)
        if isNew { Enrichment.process(item) }
        if let board { ClipStore.shared.pin([item.id], to: board) }
        return item
    }
}

// MARK: Toast

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ message: String) {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.ignoresMouseEvents = true
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = p
        }
        guard let panel else { return }
        let view = NSHostingView(rootView:
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                .padding(12)
        )
        panel.contentView = view
        let size = view.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let shelfH: CGFloat = ShelfController.shared.isVisible ? CGFloat(Settings.shared.shelfHeight) : 60
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + shelfH + 12,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        work?.cancel()
        let w = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}
