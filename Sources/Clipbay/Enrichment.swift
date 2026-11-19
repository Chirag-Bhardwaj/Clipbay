import AppKit
import Network
import Vision
import LinkPresentation
import QuickLookThumbnailing

/// Background work that makes items richer after capture: OCR, link previews, file thumbnails.
@MainActor
enum Enrichment {
    static func process(_ item: ClipItem) {
        switch item.kind {
        case .image: ocr(item)
        case .link: linkPreview(item)
        case .file: fileThumbnail(item)
        default: break
        }
    }

    static func ocr(_ item: ClipItem) {
        guard Settings.shared.ocrEnabled, let data = ClipStore.shared.fullImageData(item) else { return }
        let id = item.id
        Task.detached(priority: .utility) {
            guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            await MainActor.run { ClipStore.shared.update(id) { $0.ocrText = text } }
        }
    }

    static func linkPreview(_ item: ClipItem) {
        guard Settings.shared.fetchLinkPreviews, let s = item.url,
              let url = URL(string: s.lowercased().hasPrefix("www.") ? "https://" + s : s),
              URLSafety.isPublicWebURL(url) else { return }
        let id = item.id
        Task { @MainActor in
            guard await URLSafety.resolvesPublic(url) else { return }
            fetchMetadata(url, id: id)
        }
    }

    private static func fetchMetadata(_ url: URL, id: UUID) {
        let provider = LPMetadataProvider()
        provider.timeout = 12
        provider.startFetchingMetadata(for: url) { meta, _ in
            guard let meta else { return }
            let title = meta.title
            let imageProvider = meta.imageProvider ?? meta.iconProvider
            DispatchQueue.main.async {
                if let title, !title.isEmpty { ClipStore.shared.update(id) { $0.linkTitle = title } }
            }
            imageProvider?.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage, let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = ClipboardMonitor.makeThumbnail(rep, maxSide: 640) else { return }
                DispatchQueue.main.async {
                    ClipStore.shared.writeBlob(id, "linkimage.png", png)
                    ClipStore.shared.update(id) { $0.hasLinkImage = true }
                    ClipStore.shared.blobRevision += 1
                }
            }
        }
    }

    static func fileThumbnail(_ item: ClipItem) {
        guard let first = item.fileURLs?.first else { return }
        let id = item.id
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: first),
                                               size: CGSize(width: 320, height: 320), scale: 2,
                                               representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let cg = rep?.cgImage, let png = ClipboardMonitor.makeThumbnail(cg, maxSide: 640) else { return }
            DispatchQueue.main.async {
                ClipStore.shared.writeBlob(id, "thumb.png", png)
                ClipStore.shared.update(id) { $0.hasThumbnail = true }
                ClipStore.shared.blobRevision += 1
            }
        }
    }
}

/// App icons and their dominant colors (used for card headers).
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: NSColor] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let b = bundleID else { return nil }
        if let i = icons[b] { return i }
        if b == "mcp" {
            let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            icons[b] = img
            return img
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        icons[b] = img
        return img
    }

    static func color(_ bundleID: String?) -> NSColor {
        guard let b = bundleID else { return .systemGray }
        if let c = colors[b] { return c }
        let c = icon(b).flatMap(dominantColor) ?? NSColor.systemGray
        colors[b] = c
        return c
    }

    static func dominantColor(_ image: NSImage) -> NSColor? {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: rect)
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        // Hue buckets weighted by saturation; fall back to average if the icon is grayscale.
        var buckets = [(r: Double, g: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: 12)
        var avg = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        for i in 0..<(size * size) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(px[i * 4]) / 255 / a, g = Double(px[i * 4 + 1]) / 255 / a, b = Double(px[i * 4 + 2]) / 255 / a
            avg.r += r; avg.g += g; avg.b += b; avg.n += 1
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let sat = Double(c.saturationComponent), bri = Double(c.brightnessComponent)
            guard sat > 0.25, bri > 0.2 else { continue }
            let idx = min(11, Int(Double(c.hueComponent) * 12))
            let w = sat * bri
            buckets[idx].r += r * w; buckets[idx].g += g * w; buckets[idx].b += b * w; buckets[idx].w += w
        }
        if let best = buckets.max(by: { $0.w < $1.w }), best.w > 6 {
            let c = NSColor(srgbRed: best.r / best.w, green: best.g / best.w, blue: best.b / best.w, alpha: 1)
            return c.blended(withFraction: 0.08, of: .black) ?? c
        }
        guard avg.n > 0 else { return nil }
        let c = NSColor(srgbRed: avg.r / avg.n, green: avg.g / avg.n, blue: avg.b / avg.n, alpha: 1)
        return c.luminance > 0.85 ? NSColor(white: 0.55, alpha: 1) : c
    }
}

/// Simple in-memory image cache for thumbnails and link images.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL, revision: Int) -> NSImage? {
        let key = "\(url.path)#\(revision)" as NSString
        if let i = cache.object(forKey: key) { return i }
        guard let i = NSImage(contentsOf: url) else { return nil }
        cache.setObject(i, forKey: key)
        return i
    }
}

/// Keeps automatic fetches (link previews, Quick Look pages) away from local/private network hosts.
enum URLSafety {
    static func isPublicWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if let v6 = IPv6Address(host) { return isPublic(v6) }
        if let v4 = IPv4Address(host), host.split(separator: ".").count == 4 { return isPublic(v4) }
        // Anything numeric-looking that isn't a plain dotted quad (e.g. 2130706433, 0x7f.1, 127.1) is rejected.
        let labels = host.split(separator: ".")
        if labels.last.map({ $0.allSatisfy { $0.isNumber } || $0.hasPrefix("0x") }) ?? true { return false }
        if host == "localhost" || !host.contains(".") { return false }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"] where host.hasSuffix(suffix) {
            return false
        }
        return true
    }

    /// Resolves the host (off the main thread) and requires every address it maps to be public.
    /// Not proof against DNS rebinding, but stops names that simply point at local machines.
    static func resolvesPublic(_ url: URL) async -> Bool {
        guard isPublicWebURL(url), let host = url.host else { return false }
        return await Task.detached(priority: .utility) { () -> Bool in
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
            defer { freeaddrinfo(first) }
            var any = false
            var p: UnsafeMutablePointer<addrinfo>? = first
            while let ai = p {
                if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                    let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    let bytes = withUnsafeBytes(of: addr) { Data($0) }
                    guard let v4 = IPv4Address(bytes), isPublic(v4) else { return false }
                    any = true
                } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                    let addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: addr) { Data($0) }
                    guard let v6 = IPv6Address(bytes), isPublic(v6) else { return false }
                    any = true
                }
                p = ai.pointee.ai_next
            }
            return any
        }.value
    }

    static func isPublic(_ a: IPv4Address) -> Bool {
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
        case (172, 16...31), (100, 64...127), (198, 18...19): return false
        case (224...239, _): return false
        default: return !(b[0] == 192 && b[1] == 0 && b[2] == 0)
        }
    }

    static func isPublic(_ a: IPv6Address) -> Bool {
        let b = [UInt8](a.rawValue)
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return false } // :: and ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false } // link-local fe80::/10
        if (b[0] & 0xfe) == 0xfc { return false }                  // unique local fc00::/7
        if b[0] == 0xff { return false }                           // multicast
        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d): judge the embedded IPv4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)),
           let v4 = IPv4Address(Data(b[12..<16])) { return isPublic(v4) }
        return true
    }
}
