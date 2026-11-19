import SwiftUI
import AppKit
import Quartz
import WebKit

@MainActor
final class PreviewController {
    static let shared = PreviewController()
    private var panel: NSPanel?
    private weak var parent: NSWindow?

    func show(above parent: NSWindow) {
        self.parent = parent
        if panel == nil {
            let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.allowKey = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = p
        }
        refresh()
        reposition()
        if let panel, panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel?.orderFront(nil)
    }

    func refresh() {
        guard let panel, let item = ShelfState.shared.selectedItems.last else { return }
        panel.contentView = NSHostingView(rootView: PreviewView(item: item).id(item.id))
    }

    func reposition() {
        guard let panel, let parent else { return }
        let screen = parent.screen ?? NSScreen.main!
        let vf = screen.visibleFrame
        let shelfTop = parent.frame.maxY
        let w = min(820, vf.width * 0.62)
        let h = min(560, vf.maxY - shelfTop - 30)
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: shelfTop + 14, width: w, height: max(200, h)), display: true)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

struct PreviewView: View {
    let item: ClipItem
    var store: ClipStore { ClipStore.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = AppIcons.icon(item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(item.sourceAppName ?? "Unknown app") · \(item.date.formatted(date: .abbreviated, time: .shortened))\(item.device.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                actions
                Text("Space to close").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text(item.metaLine).font(.system(size: 11)).foregroundStyle(.secondary).padding(6)
        }
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder var actions: some View {
        switch item.kind {
        case .link:
            Button("Open in Browser") { ShelfController.shared.open(item) }.controlSize(.small)
        case .file:
            Button("Show in Finder") {
                ShelfController.shared.hide()
                NSWorkspace.shared.activateFileViewerSelecting((item.fileURLs ?? []).map { URL(fileURLWithPath: $0) })
            }.controlSize(.small)
        case .image:
            if let t = item.ocrText, !t.isEmpty {
                Button("Copy Text") {
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(t, forType: .string)
                    Toast.show("Text from image copied")
                }.controlSize(.small)
            }
            Button { rotate() } label: { Image(systemName: "rotate.right") }.controlSize(.small).help("Rotate")
        default:
            EmptyView()
        }
    }

    @ViewBuilder var content: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(Detect.looksLikeCode(item.text ?? "") ? .system(size: 12.5, design: .monospaced) : .system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .link:
            if let u = item.url, let url = URL(string: u.lowercased().hasPrefix("www.") ? "https://" + u : u),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                WebPreview(url: url)
            } else {
                Text(item.url ?? "").textSelection(.enabled).padding()
            }
        case .image:
            if let data = store.fullImageData(item), let img = NSImage(data: data) {
                ZStack {
                    Checkerboard()
                    Image(nsImage: img).resizable().scaledToFit().padding(12)
                }
            }
        case .file:
            if let p = item.fileURLs?.first { QuickLookPreview(url: URL(fileURLWithPath: p)) }
        case .color:
            let c = Detect.nsColor(hex: item.colorHex ?? "#000000").usingColorSpace(.sRGB) ?? .black
            HStack(spacing: 0) {
                Color(nsColor: c)
                VStack(alignment: .leading, spacing: 10) {
                    row("HEX", item.colorHex ?? "")
                    row("RGB", "\(Int(c.redComponent * 255)), \(Int(c.greenComponent * 255)), \(Int(c.blueComponent * 255))")
                    row("HSB", "\(Int(c.hueComponent * 360))°, \(Int(c.saturationComponent * 100))%, \(Int(c.brightnessComponent * 100))%")
                }
                .padding(24)
                .frame(width: 260, alignment: .leading)
            }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
        }
    }

    func rotate() {
        guard let data = store.fullImageData(item), let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return }
        let w = cg.height, h = cg.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let out = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return }
        let id = item.id
        store.writeBlob(id, Paths.safeName(NSPasteboard.PasteboardType.png.rawValue), png)
        if let thumb = ClipboardMonitor.makeThumbnail(out, maxSide: 640) { store.writeBlob(id, "thumb.png", thumb) }
        store.update(id) { item in
            item.imageWidth = w; item.imageHeight = h
            item.reps = [NSPasteboard.PasteboardType.png.rawValue: Paths.safeName(NSPasteboard.PasteboardType.png.rawValue)]
            item.hash = ClipStore.hash(png)
        }
        store.blobRevision += 1
        PreviewController.shared.refresh()
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { v.previewItem = url as NSURL }
}

struct WebPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent() // no cookies or storage kept from previews
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        if URLSafety.isPublicWebURL(url) { w.load(URLRequest(url: url)) }
        return w
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Allow redirects/subresources to public hosts only; clicks open in the real browser.
            guard let u = action.request.url, URLSafety.isPublicWebURL(u) else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                NSWorkspace.shared.open(u)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
