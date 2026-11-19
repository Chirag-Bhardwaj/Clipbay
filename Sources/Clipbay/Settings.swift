import AppKit
import Observation
import Carbon.HIToolbox

struct IgnoredApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

enum ModifierChoice: String, CaseIterable, Codable, Identifiable {
    case command, shift, option, control
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
    var label: String { symbol + " " + rawValue.capitalized }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }
}

@MainActor @Observable
final class Settings {
    static let shared = Settings()
    @ObservationIgnored private let d = UserDefaults.standard

    var retention: Retention { didSet { d.set(retention.rawValue, forKey: "retention") } }
    var alwaysPlainText: Bool { didSet { d.set(alwaysPlainText, forKey: "alwaysPlainText") } }
    var pasteToActiveApp: Bool { didSet { d.set(pasteToActiveApp, forKey: "pasteToActiveApp") } }
    var fetchLinkPreviews: Bool { didSet { d.set(fetchLinkPreviews, forKey: "fetchLinkPreviews") } }
    var ocrEnabled: Bool { didSet { d.set(ocrEnabled, forKey: "ocrEnabled") } }
    var ignoreConfidential: Bool { didSet { d.set(ignoreConfidential, forKey: "ignoreConfidential") } }
    var ignoreTransient: Bool { didSet { d.set(ignoreTransient, forKey: "ignoreTransient") } }
    var ignoredApps: [IgnoredApp] { didSet { save(ignoredApps, "ignoredApps") } }
    var shelfHeight: Double { didSet { d.set(shelfHeight, forKey: "shelfHeight") } }
    var activateHotKey: KeyCombo { didSet { save(activateHotKey, "activateHotKey"); HotKeys.reload() } }
    var stackHotKey: KeyCombo { didSet { save(stackHotKey, "stackHotKey"); HotKeys.reload() } }
    var pasteAllHotKey: KeyCombo { didSet { save(pasteAllHotKey, "pasteAllHotKey"); HotKeys.reload() } }
    var plainTextModifier: ModifierChoice { didSet { d.set(plainTextModifier.rawValue, forKey: "plainTextModifier") } }
    var quickPasteModifier: ModifierChoice { didSet { d.set(quickPasteModifier.rawValue, forKey: "quickPasteModifier") } }
    var mcpEnabled: Bool { didSet { d.set(mcpEnabled, forKey: "mcpEnabled") } }
    var suggestionsEnabled: Bool { didSet { d.set(suggestionsEnabled, forKey: "suggestionsEnabled") } }
    var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    var syncEnabled: Bool { didSet { d.set(syncEnabled, forKey: "syncEnabled"); Sync.shared.configure() } }
    var pausedUntil: Date? { didSet { d.set(pausedUntil, forKey: "pausedUntil") } }
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    static let defaultActivate = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultStack = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultPasteAll = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | controlKey))

    private init() {
        d.register(defaults: [
            "retention": Retention.month.rawValue,
            "alwaysPlainText": false,
            "pasteToActiveApp": true,
            "fetchLinkPreviews": true,
            "ocrEnabled": true,
            "ignoreConfidential": true,
            "ignoreTransient": true,
            "shelfHeight": 330.0,
            "plainTextModifier": ModifierChoice.shift.rawValue,
            "quickPasteModifier": ModifierChoice.command.rawValue,
            "mcpEnabled": false,
            "suggestionsEnabled": true,
            "soundsEnabled": false,
            "syncEnabled": false,
            "onboarded": false,
        ])
        retention = Retention(rawValue: d.string(forKey: "retention") ?? "") ?? .month
        alwaysPlainText = d.bool(forKey: "alwaysPlainText")
        pasteToActiveApp = d.bool(forKey: "pasteToActiveApp")
        fetchLinkPreviews = d.bool(forKey: "fetchLinkPreviews")
        ocrEnabled = d.bool(forKey: "ocrEnabled")
        ignoreConfidential = d.bool(forKey: "ignoreConfidential")
        ignoreTransient = d.bool(forKey: "ignoreTransient")
        shelfHeight = d.double(forKey: "shelfHeight")
        plainTextModifier = ModifierChoice(rawValue: d.string(forKey: "plainTextModifier") ?? "") ?? .shift
        quickPasteModifier = ModifierChoice(rawValue: d.string(forKey: "quickPasteModifier") ?? "") ?? .command
        mcpEnabled = d.bool(forKey: "mcpEnabled")
        suggestionsEnabled = d.bool(forKey: "suggestionsEnabled")
        soundsEnabled = d.bool(forKey: "soundsEnabled")
        syncEnabled = d.bool(forKey: "syncEnabled")
        pausedUntil = d.object(forKey: "pausedUntil") as? Date
        onboarded = d.bool(forKey: "onboarded")
        ignoredApps = Self.load("ignoredApps", d) ?? [
            IgnoredApp(bundleID: "com.apple.Passwords", name: "Passwords"),
            IgnoredApp(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        ]
        activateHotKey = Self.load("activateHotKey", d) ?? Self.defaultActivate
        stackHotKey = Self.load("stackHotKey", d) ?? Self.defaultStack
        pasteAllHotKey = Self.load("pasteAllHotKey", d) ?? Self.defaultPasteAll
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String, _ d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    var isPaused: Bool {
        guard let p = pausedUntil else { return false }
        if p < Date() { return false }
        return true
    }

    func pause(for interval: TimeInterval?) {
        pausedUntil = interval.map { Date().addingTimeInterval($0) } ?? .distantFuture
    }

    func resume() { pausedUntil = nil }

    var pauseDescription: String {
        guard let p = pausedUntil, p > Date() else { return "" }
        if p == .distantFuture || p.timeIntervalSinceNow > 86400 * 365 { return "Paused" }
        let f = DateFormatter()
        f.timeStyle = .short
        return "Paused until \(f.string(from: p))"
    }
}
