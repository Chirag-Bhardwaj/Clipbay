// Renders the Clipbay app icon to an .iconset folder. Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background with a warm-to-cool gradient.
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); bg.fill()
    ctx.restoreGState()
    bg.addClip()
    let grad = NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
                                   NSColor(srgbRed: 0.18, green: 0.30, blue: 0.62, alpha: 1)])!
    grad.draw(in: rect, angle: 90)

    // Three fanned cards, like a shelf of clips.
    let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.75, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.85, blue: 0.70, alpha: 1),
    ]
    let cw = rect.width * 0.36, ch = rect.width * 0.46
    for (i, c) in colors.enumerated() {
        ctx.saveGState()
        let cx = rect.midX + CGFloat(i - 1) * rect.width * 0.17
        let cy = rect.midY - rect.width * 0.02 + (i == 1 ? rect.width * 0.05 : 0)
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: CGFloat(1 - i) * 0.16)
        let card = CGRect(x: -cw / 2, y: -ch / 2, width: cw, height: ch)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        let path = NSBezierPath(roundedRect: card, xRadius: cw * 0.13, yRadius: cw * 0.13)
        NSColor.white.setFill(); path.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        path.addClip()
        c.setFill()
        NSBezierPath(rect: CGRect(x: card.minX, y: card.maxY - ch * 0.24, width: cw, height: ch * 0.24)).fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        for l in 0..<3 {
            let w = cw * (l == 2 ? 0.45 : 0.72)
            let line = CGRect(x: card.minX + cw * 0.12, y: card.maxY - ch * 0.40 - CGFloat(l) * ch * 0.14, width: w, height: ch * 0.065)
            NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()
        }
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
