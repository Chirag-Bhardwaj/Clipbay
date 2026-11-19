import AppKit
import SwiftUI

enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case text, link, image, file, color

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        }
    }

    var filterLabel: String {
        switch self {
        case .text: return "Text"
        case .link: return "Links"
        case .image: return "Images"
        case .file: return "Files"
        case .color: return "Colors"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }
}

struct ClipItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ClipKind
    /// Last time this content was copied (history is ordered by this).
    var date = Date()
    var created = Date()
    var title: String?
    /// Plain-text representation (file paths for files).
    var text: String?
    var isRich = false
    var url: String?
    var linkTitle: String?
    var hasLinkImage = false
    var hasThumbnail = false
    var colorHex: String?
    var fileURLs: [String]?
    var imageWidth: Int?
    var imageHeight: Int?
    var ocrText: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var device: String?
    var pinboardID: UUID?
    var pinOrder: Double?
    /// Pasteboard type -> blob file name inside the item's blob folder.
    var reps: [String: String] = [:]
    var hash: String
    /// Bundle id of apps this item was pasted into -> count (drives Suggestions).
    var pasteTargets: [String: Int]?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .link: return linkTitle?.isEmpty == false ? linkTitle! : "Link"
        case .file:
            let n = fileURLs?.count ?? 0
            return n > 1 ? "\(n) Files" : "File"
        default: return kind.label
        }
    }

    var hasCustomTitle: Bool { !(title ?? "").isEmpty }

    var metaLine: String {
        switch kind {
        case .text:
            let n = text?.count ?? 0
            return "\(n.formatted()) character\(n == 1 ? "" : "s")"
        case .link:
            if let u = url, let host = URL(string: u)?.host { return host.replacingOccurrences(of: "www.", with: "") }
            return url ?? ""
        case .image:
            if let w = imageWidth, let h = imageHeight { return "\(w) × \(h)" }
            return "Image"
        case .file:
            guard let urls = fileURLs else { return "" }
            if urls.count == 1 {
                let u = URL(fileURLWithPath: urls[0])
                if let size = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int64,
                   !(u.hasDirectoryPath) {
                    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                }
                return u.pathExtension.isEmpty ? "Folder" : u.pathExtension.uppercased()
            }
            return "\(urls.count) items"
        case .color:
            return colorHex ?? ""
        }
    }

    var fileNames: [String] { (fileURLs ?? []).map { URL(fileURLWithPath: $0).lastPathComponent } }

    /// Text used for search matching.
    var searchBlob: String {
        [title, text, linkTitle, url, ocrText, sourceAppName, colorHex, fileNames.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var isTextLike: Bool { kind == .text || kind == .link || kind == .color }
}

struct Pinboard: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color: Int
    var order: Double
}

enum Palette {
    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
        .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown, .systemGray,
    ]
    static func color(_ i: Int) -> Color { Color(nsColor: colors[((i % colors.count) + colors.count) % colors.count]) }
}

enum DateFilter: String, CaseIterable, Codable, Identifiable {
    case today, yesterday, week, month, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        case .year: return "Last 12 Months"
        }
    }
    func contains(_ d: Date) -> Bool {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today: return cal.isDateInToday(d)
        case .yesterday: return cal.isDateInYesterday(d)
        case .week: return d > now.addingTimeInterval(-7 * 86400)
        case .month: return d > now.addingTimeInterval(-30 * 86400)
        case .year: return d > now.addingTimeInterval(-365 * 86400)
        }
    }
}

enum Retention: String, CaseIterable, Codable, Identifiable {
    case day, week, month, year, forever
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .year: return "1 Year"
        case .forever: return "Forever"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        case .year: return 365 * 86400
        case .forever: return nil
        }
    }
}

enum Detect {
    static func link(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 4000, !t.contains(where: { $0.isWhitespace }) else { return nil }
        var candidate = t
        if t.lowercased().hasPrefix("www.") { candidate = "https://" + t }
        guard let u = URL(string: candidate), let scheme = u.scheme?.lowercased() else { return nil }
        if ["http", "https", "ftp"].contains(scheme), let host = u.host, host.contains(".") || host == "localhost" { return t }
        if scheme == "mailto" { return t }
        return nil
    }

    /// Six-digit hex is a color if it has a leading # or at least one A–F letter (so "235442" stays text).
    static func color(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHash = t.hasPrefix("#")
        let body = hasHash ? String(t.dropFirst()) : t
        guard body.count == 6, body.allSatisfy({ $0.isHexDigit }) else { return nil }
        if !hasHash && !body.contains(where: { "abcdefABCDEF".contains($0) }) { return nil }
        return "#" + body.uppercased()
    }

    static func nsColor(hex: String) -> NSColor {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(body, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func looksLikeCode(_ s: String) -> Bool {
        let sample = s.prefix(800)
        let markers = ["{", "}", ";", "=>", "()", "</", "func ", "def ", "const ", "import ", "$ ", "#!/"]
        let hits = markers.filter { sample.contains($0) }.count
        return hits >= 2 || sample.hasPrefix("    ") || sample.hasPrefix("\t")
    }
}

extension NSColor {
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}
