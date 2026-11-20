import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

@MainActor
enum DragState {
    static var itemID: UUID?
    static var pinboardID: UUID?
    static var started = Date.distantPast
    static var activeItem: UUID? { Date().timeIntervalSince(started) < 120 ? itemID : nil }
    static var activePinboard: UUID? { Date().timeIntervalSince(started) < 120 ? pinboardID : nil }
    static func reset() { itemID = nil; pinboardID = nil }
}

let dropTypes: [UTType] = [.fileURL, .png, .tiff, .image, .url, .utf8PlainText, .plainText]

struct ShelfView: View {
    @Bindable var state = ShelfState.shared
    var store = ClipStore.shared
    var settings = Settings.shared

    var body: some View {
        let items = state.visibleItems
        let h = CGFloat(settings.shelfHeight)
        ZStack {
            VStack(spacing: 0) {
                ResizeHandle()
                TopBar(items: items)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                CardsRow(items: items, height: max(120, h - 44 - 10 - 28))
            }
            if let modal = state.modal {
                Color.black.opacity(0.25).onTapGesture { state.modal = nil }
                ModalView(modal: modal)
            }
        }
        .background(VisualEffect(material: .hudWindow).overlay(Color(nsColor: .windowBackgroundColor).opacity(0.35)))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .onChange(of: state.query) { _, _ in
            state.selection = []
            state.ensureSelection(state.visibleItems)
            if let f = state.selection.first { state.scrollTarget = f; state.scrollNonce += 1 }
        }
        .onChange(of: state.filters) { _, _ in
            state.selection = []
            state.ensureSelection(state.visibleItems)
        }
        .onChange(of: store.items.count) { _, _ in
            state.ensureSelection(state.visibleItems)
        }
        .onChange(of: state.selection) { _, _ in
            if state.previewing { PreviewController.shared.refresh() }
        }
    }
}

struct ResizeHandle: View {
    @State private var startHeight: CGFloat?
    @State private var startY: CGFloat = 0
    var body: some View {
        ZStack {
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { _ in
                let y = NSEvent.mouseLocation.y
                if startHeight == nil { startHeight = CGFloat(Settings.shared.shelfHeight); startY = y }
                ShelfController.shared.resize(to: (startHeight ?? 330) + (y - startY))
            }
            .onEnded { _ in startHeight = nil })
    }
}

// MARK: Top bar

struct TopBar: View {
    @Bindable var state = ShelfState.shared
    var store = ClipStore.shared
    var settings = Settings.shared
    let items: [ClipItem]

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                SearchBar()
                    .frame(maxWidth: state.searchActive ? 520 : 300)
                Spacer()
                if settings.isPaused {
                    Button { settings.resume() } label: {
                        Label("Paused", systemImage: "pause.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Clipbay is paused. Click to resume.")
                }
                if ClipbayStack.shared.isActive {
                    Button { ClipbayStack.shared.showPanel() } label: {
                        Label("\(ClipbayStack.shared.entries.count)", systemImage: "square.stack.3d.up.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                MoreMenu()
            }
            ListTabs()
                .opacity(state.searchActive ? 0.35 : 1)
                .allowsHitTesting(!state.searchActive)
        }
    }
}

struct SearchBar: View {
    @Bindable var state = ShelfState.shared
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            ForEach(state.tokens) { t in
                TokenChip(token: t, removable: true) { state.remove(t) }
            }
            SearchField(text: $state.query, placeholder: state.tokens.isEmpty ? "Search \(state.listName)" : "")
                .frame(minWidth: 60)
            ForEach(state.tokenSuggestions) { t in
                Button {
                    state.apply(t)
                    state.query = ""
                } label: {
                    TokenChip(token: t, removable: false, suggestion: true) {}
                }
                .buttonStyle(.plain)
            }
            FilterMenu()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }
}

struct TokenChip: View {
    let token: FilterToken
    var removable: Bool
    var suggestion = false
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: token.symbol).font(.system(size: 9, weight: .semibold))
            Text(token.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if removable {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(suggestion ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.85)))
        .foregroundStyle(suggestion ? Color.primary : Color.white)
        .overlay(suggestion ? Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])) : nil)
    }
}

struct FilterMenu: View {
    @Bindable var state = ShelfState.shared
    var store = ClipStore.shared
    var body: some View {
        Menu {
            Section("Type") {
                ForEach(ClipKind.allCases) { k in
                    Toggle(isOn: Binding(get: { state.filters.kinds.contains(k) },
                                         set: { on in if on { state.filters.kinds.insert(k) } else { state.filters.kinds.remove(k) } })) {
                        Label(k.filterLabel, systemImage: k.symbol)
                    }
                }
            }
            Menu("Application") {
                ForEach(store.sourceApps, id: \.bundleID) { a in
                    Toggle(a.name, isOn: Binding(get: { state.filters.apps.contains(a.bundleID) },
                                                 set: { on in if on { state.filters.apps.insert(a.bundleID) } else { state.filters.apps.remove(a.bundleID) } }))
                }
            }
            Section("Date") {
                ForEach(DateFilter.allCases) { d in
                    Toggle(d.label, isOn: Binding(get: { state.filters.date == d }, set: { state.filters.date = $0 ? d : nil }))
                }
            }
            if !state.filters.isEmpty {
                Divider()
                Button("Clear Filters") { state.filters = Filters() }
            }
        } label: {
            Image(systemName: state.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type, app, or date")
    }
}

struct ListTabs: View {
    @Bindable var state = ShelfState.shared
    var store = ClipStore.shared
    var settings = Settings.shared
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 4) {
            tab(.clipboard, title: "Clipboard", icon: "clock", color: nil)
            if settings.suggestionsEnabled {
                tab(.suggestions, title: "Suggestions", icon: "sparkles", color: nil)
            }
            ForEach(store.pinboards) { b in
                tab(.pinboard(b.id), title: b.name, icon: nil, color: Palette.color(b.color))
                    .onDrag {
                        DragState.pinboardID = b.id
                        DragState.itemID = nil
                        DragState.started = Date()
                        return NSItemProvider(object: b.name as NSString)
                    }
                    .contextMenu {
                        Button("Edit Pinboard…") { state.modal = .editPinboard(b.id) }
                        Button("Delete Pinboard…", role: .destructive) { state.modal = .deletePinboard(b.id) }
                    }
            }
            Button { state.modal = .newPinboard(pinning: []) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("New Pinboard (⇧⌘N)")
        }
    }

    @ViewBuilder
    func tab(_ id: ListID, title: String, icon: String?, color: Color?) -> some View {
        let selected = state.list == id && !state.searchActive
        let boardID: UUID? = { if case .pinboard(let b) = id { return b } else { return nil } }()
        Button { state.switchList(id) } label: {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 9, height: 9) }
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.13) : (dropTarget == boardID && boardID != nil ? Color.accentColor.opacity(0.3) : .clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDrop(of: dropTypes, isTargeted: Binding(get: { dropTarget == boardID && boardID != nil },
                                                   set: { dropTarget = $0 ? boardID : nil })) { providers in
            handleDrop(providers, on: id)
        }
    }

    func handleDrop(_ providers: [NSItemProvider], on id: ListID) -> Bool {
        if let board = DragState.activePinboard {
            if case .pinboard(let target) = id { store.movePinboard(board, before: target) }
            DragState.reset()
            return true
        }
        if let item = DragState.activeItem {
            let ids = state.selection.contains(item) ? state.selection : [item]
            switch id {
            case .pinboard(let b): store.pin(ids, to: b); Toast.show("Pinned to \(store.pinboards.first { $0.id == b }?.name ?? "")")
            case .clipboard: store.unpin(ids)
            case .suggestions: break
            }
            DragState.reset()
            return true
        }
        var pin: UUID?
        if case .pinboard(let b) = id { pin = b }
        DropImporter.importProviders(providers, pinTo: pin)
        return true
    }
}

struct MoreMenu: View {
    @Bindable var state = ShelfState.shared
    var settings = Settings.shared
    var body: some View {
        Menu {
            Button("New Text Item") { state.modal = .newItem }
            Button("New Pinboard…") { state.modal = .newPinboard(pinning: []) }
            Divider()
            Button("Open Clipbay Stack") { ShelfController.shared.hide(); ClipbayStack.shared.start(captureSelection: false) }
            if settings.isPaused {
                Button("Resume Clipbay") { settings.resume() }
            } else {
                Menu("Pause Clipbay") {
                    Button("For 15 Minutes") { settings.pause(for: 15 * 60) }
                    Button("For 1 Hour") { settings.pause(for: 3600) }
                    Button("For 8 Hours") { settings.pause(for: 8 * 3600) }
                    Button("Until Resumed") { settings.pause(for: nil) }
                }
            }
            Divider()
            Button("Settings…") { ShelfController.shared.hide(animated: false); SettingsController.shared.show() }
            Button("Quit Clipbay") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: Cards

struct CardsRow: View {
    @Bindable var state = ShelfState.shared
    var store = ClipStore.shared
    let items: [ClipItem]
    let height: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        CardView(item: item, index: idx, height: height,
                                 selected: state.selection.contains(item.id),
                                 showNumber: state.cmdHeld && idx < 9,
                                 query: state.query,
                                 revision: store.blobRevision)
                            .id(item.id)
                            .onTapGesture(count: 2) {
                                state.select(item.id, in: items)
                                ShelfController.shared.paste([item], plain: false)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                let f = NSEvent.modifierFlags
                                state.select(item.id, extend: f.contains(.shift), toggle: f.contains(.command), in: items)
                                state.resultsFocused = true
                            })
                            .onDrag {
                                DragState.itemID = item.id
                                DragState.pinboardID = nil
                                DragState.started = Date()
                                return DropImporter.provider(for: item)
                            }
                            .onDrop(of: dropTypes, isTargeted: nil) { providers in
                                dropOnCard(item, providers)
                            }
                            .contextMenu { CardMenu(item: item) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 0, maxHeight: .infinity, alignment: .leading)
            }
            .onChange(of: state.scrollNonce) { _, _ in
                if let t = state.scrollTarget {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(t) }
                }
            }
            .overlay {
                if items.isEmpty { EmptyState() }
            }
            .onDrop(of: dropTypes, isTargeted: nil) { providers in
                guard DragState.activeItem == nil else { DragState.reset(); return false }
                var pin: UUID?
                if case .pinboard(let b) = state.list { pin = b }
                DropImporter.importProviders(providers, pinTo: pin)
                return true
            }
        }
    }

    func dropOnCard(_ target: ClipItem, _ providers: [NSItemProvider]) -> Bool {
        if let id = DragState.activeItem {
            DragState.reset()
            if case .pinboard = state.list, !state.searchActive, id != target.id {
                withAnimation { store.moveInPinboard(id, before: target.id) }
                return true
            }
            return false
        }
        var pin: UUID?
        if case .pinboard(let b) = state.list { pin = b }
        DropImporter.importProviders(providers, pinTo: pin)
        return true
    }
}

struct EmptyState: View {
    @Bindable var state = ShelfState.shared
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state.searchActive ? "magnifyingglass" : (state.list == .clipboard ? "doc.on.clipboard" : "pin"))
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
    }
    var title: String {
        if state.searchActive { return "No Results" }
        switch state.list {
        case .clipboard: return "Your clipboard history is empty"
        case .suggestions: return "No suggestions yet"
        case .pinboard: return "This pinboard is empty"
        }
    }
    var subtitle: String {
        if state.searchActive { return "Try a different search or remove a filter." }
        switch state.list {
        case .clipboard: return "Copy anything — text, links, images, files, colors — and it shows up here."
        case .suggestions: return "Clipbay learns what you paste into each app."
        case .pinboard: return "Drag items here, or right-click an item and choose Pin."
        }
    }
}

struct CardMenu: View {
    let item: ClipItem
    var state = ShelfState.shared
    var store = ClipStore.shared

    var targets: [ClipItem] {
        state.selection.contains(item.id) ? state.selectedItems : [item]
    }

    var body: some View {
        let appName = state.targetApp?.localizedName ?? "Active App"
        Button("Paste to \(appName)") { ShelfController.shared.paste(targets, plain: false) }
        Button("Paste as Plain Text") { ShelfController.shared.paste(targets, plain: true) }
        Button("Copy") { Paster.copy(targets); ShelfController.shared.hide(); Toast.show("Copied") }
        Divider()
        Menu("Pin") {
            ForEach(store.pinboards) { b in
                Button {
                    store.pin(targets.map(\.id), to: b.id)
                    Toast.show("Pinned to \(b.name)")
                } label: {
                    Text((item.pinboardID == b.id ? "✓ " : "") + b.name)
                }
            }
            if !store.pinboards.isEmpty { Divider() }
            Button("New Pinboard…") { state.modal = .newPinboard(pinning: targets.map(\.id)) }
        }
        if item.pinboardID != nil {
            Button("Unpin") { store.unpin(targets.map(\.id)) }
        }
        Button("Add to Clipbay Stack") { ClipbayStack.shared.add(targets); ShelfController.shared.hide() }
        Divider()
        Button("Rename…") { state.select(item.id, in: state.visibleItems); state.modal = .rename(item.id) }
        if item.kind != .image && item.kind != .file {
            Button("Edit…") { state.select(item.id, in: state.visibleItems); state.modal = .edit(item.id) }
        }
        Button("Quick Look") {
            state.select(item.id, in: state.visibleItems)
            if !state.previewing { ShelfController.shared.togglePreview() }
        }
        if item.kind == .link || item.kind == .file {
            Button("Open") { ShelfController.shared.open(item) }
        }
        if item.kind == .file, let p = item.fileURLs {
            Button("Show in Finder") {
                ShelfController.shared.hide()
                NSWorkspace.shared.activateFileViewerSelecting(p.map { URL(fileURLWithPath: $0) })
            }
        }
        if item.kind == .image, item.ocrText != nil {
            Button("Copy Text from Image") {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(item.ocrText ?? "", forType: .string)
                Toast.show("Text copied")
            }
        }
        if state.searchActive {
            Button(item.pinboardID.flatMap { id in store.pinboards.first { $0.id == id } }.map { "Show in \($0.name)" } ?? "Show in Clipboard") {
                ShelfController.shared.showInList(item)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if !state.selection.contains(item.id) { state.selection = [item.id] }
            ShelfController.shared.deleteSelection()
        }
    }
}
