import AppKit
import Observation

enum ListID: Hashable {
    case clipboard, suggestions
    case pinboard(UUID)
}

enum Modal: Equatable {
    case edit(UUID)
    case rename(UUID)
    case newItem
    case newPinboard(pinning: [UUID])
    case editPinboard(UUID)
    case deletePinboard(UUID)
}

struct Filters: Equatable {
    var kinds: Set<ClipKind> = []
    var apps: Set<String> = []
    var date: DateFilter?
    var isEmpty: Bool { kinds.isEmpty && apps.isEmpty && date == nil }
}

enum FilterToken: Hashable, Identifiable {
    case kind(ClipKind), app(String, String), date(DateFilter)
    var id: String {
        switch self {
        case .kind(let k): return "k:" + k.rawValue
        case .app(let b, _): return "a:" + b
        case .date(let d): return "d:" + d.rawValue
        }
    }
    var label: String {
        switch self {
        case .kind(let k): return k.filterLabel
        case .app(_, let n): return n
        case .date(let d): return d.label
        }
    }
    var symbol: String {
        switch self {
        case .kind(let k): return k.symbol
        case .app: return "app"
        case .date: return "calendar"
        }
    }
}

@MainActor @Observable
final class ShelfState {
    static let shared = ShelfState()

    var list: ListID = .clipboard
    var query = ""
    var filters = Filters()
    var selection: [UUID] = []
    var anchor: UUID?
    var cmdHeld = false
    var modal: Modal?
    var previewing = false
    var scrollTarget: UUID?
    var scrollNonce = 0
    var resultsFocused = false
    var showFilterMenu = false
    var isVisible = false
    /// App that was frontmost when the shelf opened (paste target).
    @ObservationIgnored var targetApp: NSRunningApplication?

    var searchActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty }

    var tokens: [FilterToken] {
        var t: [FilterToken] = filters.kinds.sorted { $0.rawValue < $1.rawValue }.map { .kind($0) }
        let apps = ClipStore.shared.sourceApps
        t += filters.apps.sorted().map { b in .app(b, apps.first { $0.bundleID == b }?.name ?? b) }
        if let d = filters.date { t.append(.date(d)) }
        return t
    }

    func remove(_ token: FilterToken) {
        switch token {
        case .kind(let k): filters.kinds.remove(k)
        case .app(let b, _): filters.apps.remove(b)
        case .date: filters.date = nil
        }
    }

    func apply(_ token: FilterToken) {
        switch token {
        case .kind(let k): filters.kinds.insert(k)
        case .app(let b, _): filters.apps.insert(b)
        case .date(let d): filters.date = d
        }
    }

    /// Filter suggestions matching what's being typed (shown inline in the search field).
    var tokenSuggestions: [FilterToken] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [FilterToken] = []
        for k in ClipKind.allCases where !filters.kinds.contains(k) {
            if k.filterLabel.lowercased().hasPrefix(q) || k.label.lowercased().hasPrefix(q) { out.append(.kind(k)) }
        }
        for d in DateFilter.allCases where filters.date != d {
            if d.label.lowercased().hasPrefix(q) || d.label.lowercased().contains(" " + q) { out.append(.date(d)) }
        }
        for a in ClipStore.shared.sourceApps where !filters.apps.contains(a.bundleID) {
            if a.name.lowercased().hasPrefix(q) || a.name.lowercased().contains(" " + q) { out.append(.app(a.bundleID, a.name)) }
        }
        return Array(out.prefix(3))
    }

    var listName: String {
        switch list {
        case .clipboard: return "Clipboard"
        case .suggestions: return "Suggestions"
        case .pinboard(let id): return ClipStore.shared.pinboards.first { $0.id == id }?.name ?? "Pinboard"
        }
    }

    var visibleItems: [ClipItem] {
        let store = ClipStore.shared
        var base: [ClipItem]
        if searchActive {
            base = store.items // search spans history and every pinboard
        } else {
            switch list {
            case .clipboard: base = store.items
            case .suggestions: base = suggestions()
            case .pinboard(let id): base = store.items(in: id)
            }
        }
        guard searchActive else { return base }
        let words = query.lowercased().split(separator: " ").map(String.init)
        return base.filter { item in
            if !filters.kinds.isEmpty && !filters.kinds.contains(item.kind) { return false }
            if !filters.apps.isEmpty && !filters.apps.contains(item.sourceBundleID ?? "") { return false }
            if let d = filters.date, !d.contains(item.date) { return false }
            if words.isEmpty { return true }
            let blob = item.searchBlob.lowercased()
            return words.allSatisfy { blob.contains($0) }
        }
    }

    /// Items most likely to be pasted into the app the shelf was opened over.
    func suggestions() -> [ClipItem] {
        let items = ClipStore.shared.items
        guard let target = targetApp?.bundleIdentifier else { return Array(items.prefix(20)) }
        let now = Date()
        let scored: [(ClipItem, Double)] = items.prefix(2000).map { item in
            var score = Double(item.pasteTargets?[target] ?? 0) * 10
            if item.sourceBundleID == target { score += 4 }
            if item.pinboardID != nil { score += 1 }
            let ageHours = now.timeIntervalSince(item.date) / 3600
            score += max(0, 3 - ageHours / 8)
            return (item, score)
        }
        let top = scored.filter { $0.1 > 1 }.sorted { $0.1 > $1.1 }.prefix(24).map(\.0)
        return top.isEmpty ? Array(items.prefix(20)) : top
    }

    var selectedItems: [ClipItem] {
        let store = ClipStore.shared
        return selection.compactMap { store.item($0) }
    }

    // MARK: Selection

    func ensureSelection(_ items: [ClipItem]) {
        let ids = Set(items.map(\.id))
        selection = selection.filter { ids.contains($0) }
        if selection.isEmpty, let first = items.first {
            selection = [first.id]
            anchor = first.id
        }
    }

    func select(_ id: UUID, extend: Bool = false, toggle: Bool = false, in items: [ClipItem]) {
        if toggle {
            if let i = selection.firstIndex(of: id) {
                if selection.count > 1 { selection.remove(at: i) }
            } else {
                selection.append(id)
            }
            anchor = id
        } else if extend, let a = anchor, let ai = items.firstIndex(where: { $0.id == a }),
                  let bi = items.firstIndex(where: { $0.id == id }) {
            let range = min(ai, bi)...max(ai, bi)
            selection = items[range].map(\.id)
        } else {
            selection = [id]
            anchor = id
        }
        scrollTarget = id
        scrollNonce += 1
    }

    func move(_ delta: Int, extend: Bool, in items: [ClipItem]) {
        guard !items.isEmpty else { return }
        let current = selection.last ?? items.first!.id
        let idx = items.firstIndex { $0.id == current } ?? 0
        let next = max(0, min(items.count - 1, idx + delta))
        let id = items[next].id
        if extend {
            if anchor == nil { anchor = current }
            select(id, extend: true, in: items)
            // keep the moving end last so further moves continue from it
            if let i = selection.firstIndex(of: id) { selection.remove(at: i); selection.append(id) }
        } else {
            select(id, in: items)
        }
    }

    func switchList(_ l: ListID) {
        list = l
        query = ""
        filters = Filters()
        selection = []
        ensureSelection(visibleItems)
        if let f = selection.first { scrollTarget = f; scrollNonce += 1 }
    }

    var allLists: [ListID] {
        var l: [ListID] = [.clipboard]
        if Settings.shared.suggestionsEnabled { l.append(.suggestions) }
        l += ClipStore.shared.pinboards.map { .pinboard($0.id) }
        return l
    }

    func cycleList(_ delta: Int) {
        let lists = allLists
        let i = lists.firstIndex(of: list) ?? 0
        switchList(lists[(i + delta + lists.count) % lists.count])
    }
}
