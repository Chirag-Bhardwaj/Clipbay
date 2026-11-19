import Foundation
import Observation

/// iCloud Drive sync: the library lives in ~/iCloud Drive/Clipbay and changes made by
/// other Macs are merged in (newest edit wins, deletions tracked with tombstones).
@MainActor @Observable
final class Sync {
    static let shared = Sync()
    var status = "Off"
    @ObservationIgnored private var timer: Timer?

    func configure() {
        let store = ClipStore.shared
        let wantCloud = Settings.shared.syncEnabled && Paths.iCloudDriveAvailable
        let target = wantCloud ? Paths.cloudRoot : Paths.localRoot
        if store.root.standardizedFileURL != target.standardizedFileURL {
            store.saveNow()
            store.switchRoot(to: target, merge: true)
        }
        timer?.invalidate()
        timer = nil
        if wantCloud {
            status = "Syncing via iCloud Drive"
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { Sync.shared.check() }
            }
            check()
        } else {
            status = Settings.shared.syncEnabled ? "iCloud Drive unavailable" : "Off — stored on this Mac only"
        }
    }

    private func check() {
        let store = ClipStore.shared
        let url = store.libraryURL
        // Ask iCloud to download placeholders evicted by "Optimize Mac Storage".
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return }
        if let last = store.lastWrittenModDate, abs(mod.timeIntervalSince(last)) < 0.5 { return }
        guard let lib = store.readLibrary() else { return }
        store.mergeIn(lib)
        store.saveNow()
        let f = DateFormatter()
        f.timeStyle = .medium
        status = "Synced at \(f.string(from: Date()))"
    }
}
