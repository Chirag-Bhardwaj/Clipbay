import SwiftUI
import AppKit

struct CardView: View {
    let item: ClipItem
    let index: Int
    let height: CGFloat
    let selected: Bool
    let showNumber: Bool
    let query: String
    let revision: Int

    var compact: Bool { height < 170 }
    var width: CGFloat { max(150, min(320, height * 0.92)) }
    var headerHeight: CGFloat { compact ? 34 : max(44, min(58, height * 0.2)) }

    var body: some View {
        let appColor = AppIcons.color(item.sourceBundleID)
        let headerText: Color = appColor.luminance > 0.62 ? .black.opacity(0.85) : .white
        VStack(spacing: 0) {
            // Header: title, time, source app icon on the app's own color.
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1)
                    if !compact {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(RelativeTime.string(item.date))
                                .font(.system(size: 11))
                                .opacity(0.8)
                        }
                    }
                }
                .foregroundStyle(headerText)
                Spacer(minLength: 0)
                if let icon = AppIcons.icon(item.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: headerHeight - 10, height: headerHeight - 10)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: headerHeight)
            .background(Color(nsColor: appColor))

            CardContent(item: item, query: query, revision: revision, compact: compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if !compact || item.kind == .text {
                HStack(spacing: 4) {
                    if let p = item.pinboardID, let b = ClipStore.shared.pinboards.first(where: { $0.id == p }) {
                        Circle().fill(Palette.color(b.color)).frame(width: 7, height: 7)
                    }
                    Text(item.metaLine)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if item.isRich && item.kind == .text {
                        Image(systemName: "textformat").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(item.kind == .color || item.kind == .image ? Color(nsColor: .textBackgroundColor) : .clear)
            }
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(4)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 3.5 : 0)
        )
        .shadow(color: .black.opacity(0.18), radius: selected ? 8 : 4, y: 2)
        .overlay(alignment: .bottomTrailing) {
            if showNumber {
                Text("\(Settings.shared.quickPasteModifier.symbol)\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .padding(10)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

struct CardContent: View {
    let item: ClipItem
    let query: String
    let revision: Int
    let compact: Bool
    var store: ClipStore { ClipStore.shared }

    var body: some View {
        switch item.kind {
        case .text:
            let t = item.text ?? ""
            let code = Detect.looksLikeCode(t)
            VStack(alignment: .leading) {
                Text(Highlight.attributed(String(t.prefix(1400)), query: query))
                    .font(code ? .system(size: 11, design: .monospaced) : .system(size: 12.5))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .padding(10)
        case .link:
            VStack(spacing: 0) {
                if item.hasLinkImage, let img = ImageCache.image(store.linkImageURL(item), revision: revision) {
                    Color.clear.overlay(Image(nsImage: img).resizable().scaledToFill()).clipped()
                } else {
                    ZStack {
                        Color.primary.opacity(0.04)
                        Image(systemName: "link").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let t = item.linkTitle, !t.isEmpty {
                        Text(t).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    }
                    Text(Highlight.attributed(item.url ?? "", query: query))
                        .font(.system(size: 11)).foregroundStyle(Color.accentColor).lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image:
            ZStack {
                Checkerboard()
                if let img = ImageCache.image(store.thumbnailURL(item), revision: revision) {
                    Image(nsImage: img).resizable().scaledToFit().padding(6)
                }
            }
        case .file:
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                if item.hasThumbnail, let img = ImageCache.image(store.thumbnailURL(item), revision: revision) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: compact ? 50 : 110)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                } else if let p = item.fileURLs?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().scaledToFit().frame(maxHeight: compact ? 50 : 90)
                }
                Text(Highlight.attributed(item.fileNames.prefix(3).joined(separator: "\n") + ((item.fileURLs?.count ?? 0) > 3 ? "\n…" : ""), query: query))
                    .font(.system(size: 11.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            .padding(8)
        case .color:
            let c = Detect.nsColor(hex: item.colorHex ?? "#000000")
            ZStack {
                Color(nsColor: c)
                Text(item.colorHex ?? "")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(c.luminance > 0.6 ? Color.black.opacity(0.8) : Color.white)
            }
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.primary.opacity(0.05)))
                }
            }
        }
    }
}

enum Highlight {
    static func attributed(_ s: String, query: String) -> AttributedString {
        var a = AttributedString(s)
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return a }
        let lower = s.lowercased()
        guard lower.count == s.count else { return a }
        for w in words {
            var searchStart = lower.startIndex
            while let r = lower.range(of: w, range: searchStart..<lower.endIndex) {
                let lo = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let len = lower.distance(from: r.lowerBound, to: r.upperBound)
                let start = a.index(a.startIndex, offsetByCharacters: lo)
                let end = a.index(start, offsetByCharacters: len)
                a[start..<end].backgroundColor = Color.yellow.opacity(0.55)
                a[start..<end].foregroundColor = .black
                searchStart = r.upperBound
            }
        }
        return a
    }
}

enum RelativeTime {
    static let f: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
    static func string(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 45 { return "Just now" }
        return f.localizedString(for: d, relativeTo: Date())
    }
}

