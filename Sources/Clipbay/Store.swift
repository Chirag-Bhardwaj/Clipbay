import AppKit
import Observation
import CryptoKit

struct Library: Codable {
    var items: [ClipItem] = []
    var pinboards: [Pinboard] = []
    /// Deleted ids -> deletion date (used for sync merges).
    var tombstones: [UUID: Date] = [:]
    var modified: [UUID: Date] = [:]
}

enum Paths {
    static var localRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipbay", isDirectory: true)
    }
    static var cloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Clipbay", isDirectory: true)
    }
    static var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }
    static var activeRoot: URL {
        UserDefaults.standard.bool(forKey: "syncEnabled") && iCloudDriveAvailable ? cloudRoot : localRoot
    }
    static func safeName(_ type: String) -> String {
        String(type.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

@MainActor @Observable
final class ClipStore {
    static let shared = ClipStore()

    private(set) var items: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []
    /// Bumped when blob content (thumbnails, link images) changes so views reload images.
    var blobRevision = 0

    @ObservationIgnored private(set) var root: URL = Paths.activeRoot
    @ObservationIgnored private var tombstones: [UUID: Date] = [:]
    @ObservationIgnored private var modified: [UUID: Date] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var undoStack: [[ClipItem]] = []
    @ObservationIgnored var lastWrittenModDate: Date?
    @ObservationIgnored private var hashIndex: [String: UUID] = [:]

    var libraryURL: URL { root.appendingPathComponent("library.json") }
    var blobsDir: URL { root.appendingPathComponent("Blobs", isDirectory: true) }
    var trashDir: URL { Paths.localRoot.appendingPathComponent("Trash", isDirectory: true) }
    var inboxDir: URL { Paths.localRoot.appendingPathComponent("Inbox", isDirectory: true) }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.localRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: trashDir)
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        switchRoot(to: Paths.activeRoot, merge: false)
    }

    // MARK: Persistence

    func switchRoot(to newRoot: URL, merge: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: newRoot.appendingPathComponent("Blobs"), withIntermediateDirectories: true)
        if merge {
            // Carry blobs over, then merge the destination library with what we have in memory.
            let oldBlobs = blobsDir
            let newBlobs = newRoot.appendingPathComponent("Blobs")
            for item in items {
                let src = oldBlobs.appendingPathComponent(item.id.uuidString)
                let dst = newBlobs.appendingPathComponent(item.id.uuidString)
                if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
            root = newRoot
            if let lib = readLibrary() { mergeIn(lib) }
            saveNow()
        } else {
            root = newRoot
            let lib = readLibrary() ?? Library()
            items = lib.items
            pinboards = lib.pinboards.sorted { $0.order < $1.order }
            tombstones = lib.tombstones
            modified = lib.modified
            sortItems()
        }
    }

    func readLibrary() -> Library? {
        guard let data = try? Data(contentsOf: libraryURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Library.self, from: data)
    }

    /// Merge a library written elsewhere (another Mac via iCloud Drive) into memory.
    func mergeIn(_ other: Library) {
        for (id, d) in other.tombstones where (tombstones[id] ?? .distantPast) < d { tombstones[id] = d }
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for it in other.items {
            if let mine = byID[it.id] {
                let mineMod = modified[it.id] ?? mine.date
                let theirMod = other.modified[it.id] ?? it.date
                if theirMod > mineMod { byID[it.id] = it; modified[it.id] = theirMod }
            } else {
                byID[it.id] = it
                if let m = other.modified[it.id] { modified[it.id] = m }
            }
        }
        var boards = Dictionary(uniqueKeysWithValues: pinboards.map { ($0.id, $0) })
        for b in other.pinboards {
            let mine = modified[b.id] ?? .distantPast
            let theirs = other.modified[b.id] ?? .distantPast
            if boards[b.id] == nil || theirs > mine { boards[b.id] = b; modified[b.id] = theirs }
        }
        for (id, d) in tombstones {
            if let it = byID[id], (modified[id] ?? it.date) <= d { byID[id] = nil }
            if boards[id] != nil, (modified[id] ?? .distantPast) <= d { boards[id] = nil }
        }
        // Dedupe by content hash, keeping the newest.
        var seen: [String: ClipItem] = [:]
        for it in byID.values {
            if let prev = seen[it.hash], prev.date >= it.date { continue }
            seen[it.hash] = it
        }
        items = Array(seen.values)
        pinboards = boards.values.sorted { $0.order < $1.order }
        sortItems()
        blobRevision += 1
    }

    private func sortItems() {
        items.sort { $0.date > $1.date }
        hashIndex = Dictionary(items.map { ($0.hash, $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        // Trim old tombstones.
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        tombstones = tombstones.filter { $0.value > cutoff }
        let lib = Library(items: items, pinboards: pinboards, tombstones: tombstones, modified: modified)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(lib) else { return }
        let url = libraryURL
        do {
            try data.write(to: url, options: .atomic)
            lastWrittenModDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        } catch {
            NSLog("Clipbay: save failed \(error)")
        }
    }

    // MARK: Blobs

    func blobDir(_ id: UUID) -> URL { blobsDir.appendingPathComponent(id.uuidString, isDirectory: true) }

    func blobURL(_ id: UUID, _ name: String) -> URL { blobDir(id).appendingPathComponent(name) }

    func data(_ item: ClipItem, type: String) -> Data? {
        guard let name = item.reps[type] else { return nil }
        return try? Data(contentsOf: blobURL(item.id, name))
    }

    func writeBlob(_ id: UUID, _ name: String, _ data: Data) {
        let dir = blobDir(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    func thumbnailURL(_ item: ClipItem) -> URL { blobURL(item.id, "thumb.png") }
    func linkImageURL(_ item: ClipItem) -> URL { blobURL(item.id, "linkimage.png") }

    func fullImageData(_ item: ClipItem) -> Data? {
        data(item, type: NSPasteboard.PasteboardType.png.rawValue) ?? data(item, type: NSPasteboard.PasteboardType.tiff.rawValue)
    }

    // MARK: Mutations

    func item(_ id: UUID) -> ClipItem? { items.first { $0.id == id } }

    @discardableResult
    func insert(_ new: ClipItem, blobs: [String: Data], thumbnail: Data?) -> (ClipItem, isNew: Bool) {
        if let existingID = hashIndex[new.hash], let idx = items.firstIndex(where: { $0.id == existingID }) {
            var existing = items[idx]
            existing.date = Date()
            existing.sourceBundleID = new.sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = new.sourceAppName ?? existing.sourceAppName
            items.remove(at: idx)
            items.insert(existing, at: 0)
            touch(existing.id)
            scheduleSave()
            return (existing, false)
        }
        var item = new
        var reps: [String: String] = [:]
        for (type, data) in blobs {
            let name = Paths.safeName(type)
            writeBlob(item.id, name, data)
            reps[type] = name
        }
        item.reps = reps
        if let thumbnail {
            writeBlob(item.id, "thumb.png", thumbnail)
            item.hasThumbnail = true
        }
        items.insert(item, at: 0)
        hashIndex[item.hash] = item.id
        touch(item.id)
        scheduleSave()
        return (item, true)
    }

    private func touch(_ id: UUID) { modified[id] = Date() }

    func update(_ id: UUID, _ mutate: (inout ClipItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let oldHash = items[idx].hash
        mutate(&items[idx])
        if items[idx].hash != oldHash {
            hashIndex[oldHash] = nil
            hashIndex[items[idx].hash] = id
        }
        touch(id)
        scheduleSave()
    }

    /// Move an item to the front of the history (it was just pasted/copied again).
    func bump(_ ids: [UUID], target: String?) {
        for id in ids {
            update(id) { item in
                item.date = Date()
                if let target {
                    var t = item.pasteTargets ?? [:]
                    t[target, default: 0] += 1
                    item.pasteTargets = t
                }
            }
        }
        sortItems()
    }

    func replaceContent(_ id: UUID, text: String, rtf: Data?) {
        update(id) { item in
            item.text = text
            var reps: [String: String] = [:]
            let strType = NSPasteboard.PasteboardType.string.rawValue
            writeBlob(item.id, Paths.safeName(strType), Data(text.utf8))
            reps[strType] = Paths.safeName(strType)
            if let rtf {
                let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
                writeBlob(item.id, Paths.safeName(rtfType), rtf)
                reps[rtfType] = Paths.safeName(rtfType)
            }
            item.reps = reps
            item.isRich = rtf != nil
            if let link = Detect.link(text) { item.kind = .link; item.url = link.trimmingCharacters(in: .whitespacesAndNewlines) }
            else if let hex = Detect.color(text) { item.kind = .color; item.colorHex = hex }
            else { item.kind = .text; item.url = nil; item.colorHex = nil }
            item.hash = ClipStore.hash("text:" + text)
        }
        // Avoid duplicate hashes after editing.
        if let edited = item(id), items.contains(where: { $0.id != id && $0.hash == edited.hash }) {
            update(id) { $0.hash = ClipStore.hash("text:\(text):\(id)") }
        }
    }

    func delete(_ ids: [UUID]) {
        let set = Set(ids)
        let removed = items.filter { set.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { set.contains($0.id) }
        let fm = FileManager.default
        for it in removed {
            let src = blobDir(it.id)
            let dst = trashDir.appendingPathComponent(it.id.uuidString)
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
            hashIndex[it.hash] = nil
            tombstones[it.id] = Date()
        }
        undoStack.append(removed)
        if undoStack.count > 30 { undoStack.removeFirst() }
        scheduleSave()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    @discardableResult
    func undoDelete() -> [ClipItem] {
        guard let restored = undoStack.popLast() else { return [] }
        let fm = FileManager.default
        for it in restored {
            let src = trashDir.appendingPathComponent(it.id.uuidString)
            try? fm.moveItem(at: src, to: blobDir(it.id))
            tombstones[it.id] = nil
            touch(it.id)
        }
        items.append(contentsOf: restored)
        sortItems()
        scheduleSave()
        return restored
    }

    /// Removes un-pinned history older than the retention limit. Returns count removed.
    @discardableResult
    func purge(retention: Retention, dryRun: Bool = false) -> Int {
        guard let interval = retention.interval else { return 0 }
        let cutoff = Date().addingTimeInterval(-interval)
        let old = items.filter { $0.pinboardID == nil && $0.date < cutoff }
        if !dryRun && !old.isEmpty { hardDelete(old.map(\.id)) }
        return old.count
    }

    func eraseHistory() {
        hardDelete(items.filter { $0.pinboardID == nil }.map(\.id))
    }

    private func hardDelete(_ ids: [UUID]) {
        let set = Set(ids)
        for it in items where set.contains(it.id) {
            try? FileManager.default.removeItem(at: blobDir(it.id))
            hashIndex[it.hash] = nil
            tombstones[it.id] = Date()
        }
        items.removeAll { set.contains($0.id) }
        scheduleSave()
    }

    // MARK: Pinboards

    func items(in board: UUID) -> [ClipItem] {
        items.filter { $0.pinboardID == board }.sorted { ($0.pinOrder ?? 0) < ($1.pinOrder ?? 0) }
    }

    @discardableResult
    func addPinboard(name: String, color: Int) -> Pinboard {
        let b = Pinboard(name: name, color: color, order: (pinboards.map(\.order).max() ?? 0) + 1)
        pinboards.append(b)
        touch(b.id)
        scheduleSave()
        return b
    }

    func updatePinboard(_ id: UUID, name: String, color: Int) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].name = name
        pinboards[i].color = color
        touch(id)
        scheduleSave()
    }

    func deletePinboard(_ id: UUID) {
        hardDelete(items.filter { $0.pinboardID == id }.map(\.id))
        pinboards.removeAll { $0.id == id }
        tombstones[id] = Date()
        scheduleSave()
    }

    func movePinboard(_ id: UUID, before target: UUID?) {
        guard let from = pinboards.firstIndex(where: { $0.id == id }) else { return }
        let b = pinboards.remove(at: from)
        if let target, let to = pinboards.firstIndex(where: { $0.id == target }) {
            pinboards.insert(b, at: to)
        } else {
            pinboards.append(b)
        }
        for i in pinboards.indices { pinboards[i].order = Double(i); touch(pinboards[i].id) }
        scheduleSave()
    }

    func pin(_ ids: [UUID], to board: UUID) {
        var next = (items(in: board).compactMap(\.pinOrder).max() ?? 0) + 1
        for id in ids {
            update(id) { item in
                if item.pinboardID != board {
                    item.pinboardID = board
                    item.pinOrder = next
                    next += 1
                }
            }
        }
    }

    func unpin(_ ids: [UUID]) {
        for id in ids { update(id) { $0.pinboardID = nil; $0.pinOrder = nil } }
    }

    /// Reorder within a pinboard: put `id` right before `target`.
    func moveInPinboard(_ id: UUID, before target: UUID) {
        guard let board = item(target)?.pinboardID else { return }
        var list = items(in: board).filter { $0.id != id }
        guard let moving = item(id) else { return }
        let idx = list.firstIndex { $0.id == target } ?? list.count
        list.insert(moving, at: idx)
        for (i, it) in list.enumerated() {
            update(it.id) { $0.pinboardID = board; $0.pinOrder = Double(i) }
        }
    }

    // MARK: Helpers

    static func hash(_ s: String) -> String { hash(Data(s.utf8)) }
    static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Apps that appear as sources, for filtering.
    var sourceApps: [(bundleID: String, name: String)] {
        var seen: [String: String] = [:]
        for it in items { if let b = it.sourceBundleID, seen[b] == nil { seen[b] = it.sourceAppName ?? b } }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Picks up items saved by the MCP server (which runs in a separate process).
    func importInbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            defer { try? fm.removeItem(at: f) }
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else { continue }
            var item = ClipItem(kind: .text, hash: ClipStore.hash("text:" + text))
            item.text = text
            item.title = obj["title"] as? String
            item.sourceAppName = "AI Tool"
            item.sourceBundleID = "mcp"
            if let l = Detect.link(text) { item.kind = .link; item.url = l }
            else if let c = Detect.color(text) { item.kind = .color; item.colorHex = c }
            let (saved, _) = insert(item, blobs: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)], thumbnail: nil)
            if let boardName = obj["pinboard"] as? String, !boardName.isEmpty {
                let board = pinboards.first { $0.name.caseInsensitiveCompare(boardName) == .orderedSame }
                    ?? addPinboard(name: boardName, color: pinboards.count)
                pin([saved.id], to: board.id)
            }
            Enrichment.process(saved)
        }
    }
}
