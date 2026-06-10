// Renders the app icon: a lo-fi dusk canvas with three agent cards — one calm,
// one running (teal), one blocked (gold glow) — the god-view in miniature.
// Run:  swift Packaging/make-icon.swift   (writes AppIcon.iconset + AppIcon.icns
// next to itself via iconutil). Regenerate whenever the theme shifts; the .icns
// is committed so packaging never depends on this script.
import AppKit

// MARK: Palette (mirrors Theme's dark "lo-fi dusk" tokens)
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let duskTop = rgb(0x2B2545), duskBottom = rgb(0x14111F)
let cardBody = rgb(0x1B1827), cardBar = rgb(0x282339), cardBorder = rgb(0x453F5C)
let teal = rgb(0x48C0C1), gold = rgb(0xFBB636), idleGray = rgb(0x807E90)
let textLine = NSColor(white: 1, alpha: 0.10)

// MARK: One card (y-up coordinates, 1024 canvas)
func drawCard(_ rect: NSRect, bead: NSColor, glow: NSColor?, lines: Int) {
    let radius: CGFloat = 26
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.55)
    drop.shadowBlurRadius = 34
    drop.shadowOffset = NSSize(width: 0, height: -16)
    drop.set()
    cardBody.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Title bar (clipped to the card's rounded top)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let barH: CGFloat = rect.height * 0.30
    cardBar.setFill()
    NSRect(x: rect.minX, y: rect.maxY - barH, width: rect.width, height: barH).fill()
    // Faint "terminal text" lines in the body
    textLine.setFill()
    let lineH: CGFloat = 13, inset: CGFloat = 34
    for i in 0..<lines {
        let y = rect.maxY - barH - 44 - CGFloat(i) * 36
        let w = rect.width - inset * 2 - CGFloat((i * 53) % 90)
        NSBezierPath(roundedRect: NSRect(x: rect.minX + inset, y: y, width: w, height: lineH),
                     xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Border — glowing for loud/running cards
    NSGraphicsContext.saveGraphicsState()
    if let glow {
        let halo = NSShadow()
        halo.shadowColor = glow.withAlphaComponent(0.9)
        halo.shadowBlurRadius = 46
        halo.shadowOffset = .zero
        halo.set()
        glow.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 7
    } else {
        cardBorder.setStroke()
        path.lineWidth = 5
    }
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Status bead in the bar
    let beadR: CGFloat = 17
    let beadRect = NSRect(x: rect.minX + 30, y: rect.maxY - barH / 2 - beadR,
                          width: beadR * 2, height: beadR * 2)
    NSGraphicsContext.saveGraphicsState()
    let beadGlow = NSShadow()
    beadGlow.shadowColor = bead
    beadGlow.shadowBlurRadius = 26
    beadGlow.shadowOffset = .zero
    beadGlow.set()
    bead.setFill()
    NSBezierPath(ovalIn: beadRect).fill()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: Full 1024 composition
func drawIcon() {
    // macOS squircle on the Apple grid: 824×824 centered, radius ~185.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.30)
    drop.shadowBlurRadius = 24
    drop.shadowOffset = NSSize(width: 0, height: -10)
    drop.set()
    NSGradient(starting: duskTop, ending: duskBottom)!.draw(in: squircle, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // The canvas dot grid, faint, slightly offset like a panned viewport.
    NSColor(white: 1, alpha: 0.045).setFill()
    var y: CGFloat = 150
    while y < 920 {
        var x: CGFloat = 138
        while x < 920 {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 9, height: 9)).fill()
            x += 96
        }
        y += 96
    }

    // Three cards: calm in back, running mid, blocked front-and-biggest —
    // the attention hierarchy is the icon.
    drawCard(NSRect(x: 175, y: 545, width: 270, height: 195), bead: idleGray, glow: nil, lines: 2)
    drawCard(NSRect(x: 560, y: 480, width: 280, height: 200), bead: teal, glow: teal, lines: 2)
    drawCard(NSRect(x: 290, y: 200, width: 400, height: 270), bead: gold, glow: gold, lines: 3)

    NSGraphicsContext.restoreGraphicsState()
}

// MARK: Render at every iconset size
func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    NSAffineTransform(transform: AffineTransform(scale: scale)).concat()
    drawIcon()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
