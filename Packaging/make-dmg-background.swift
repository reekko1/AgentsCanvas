// Renders the DMG window background: dusk gradient, faint canvas dots, the
// wordmark, and a drag arrow between where create-dmg pins the app icon (150,185)
// and the Applications link (450,185) in a 600×400 window. Outputs a combined
// 1x+2x HiDPI TIFF (what create-dmg wants for retina).
// Run:  swift Packaging/make-dmg-background.swift
import AppKit

let W: CGFloat = 600, H: CGFloat = 400

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw() {
    // Dusk wall
    NSGradient(starting: rgb(0x2B2545), ending: rgb(0x13111C))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Faint dot grid (the canvas)
    rgb(0xFFFFFF, 0.05).setFill()
    var y: CGFloat = 22
    while y < H {
        var x: CGFloat = 30
        while x < W { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 4, height: 4)).fill(); x += 48 }
        y += 48
    }

    // Wordmark, top center (y-up: near H)
    let title = "Agent Canvas"
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
        .foregroundColor: rgb(0xEEE9DF),
        .kern: 0.5,
    ]
    let tSize = title.size(withAttributes: titleAttrs)
    title.draw(at: NSPoint(x: (W - tSize.width) / 2, y: H - 64), withAttributes: titleAttrs)

    let sub = "supervise your agent fleet"
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: rgb(0x92909F),
    ]
    let sSize = sub.size(withAttributes: subAttrs)
    sub.draw(at: NSPoint(x: (W - sSize.width) / 2, y: H - 86), withAttributes: subAttrs)

    // Drag arrow between the icon slots. create-dmg pins icons at (150,185) and
    // (450,185) measured from the window's top-left; in y-up that row's center is
    // H − 185 = 215. Icons are 128pt, so leave clearance: arrow spans x 240→360.
    let rowY: CGFloat = H - 185
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 245, y: rowY))
    arrow.line(to: NSPoint(x: 345, y: rowY))
    arrow.move(to: NSPoint(x: 327, y: rowY + 12))
    arrow.line(to: NSPoint(x: 345, y: rowY))
    arrow.line(to: NSPoint(x: 327, y: rowY - 12))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    rgb(0xFBB636, 0.85).setStroke()   // the "needs you" gold — the one warm accent
    arrow.stroke()

    let hint = "drag to install"
    let hintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
        .foregroundColor: rgb(0x92909F),
    ]
    let hSize = hint.size(withAttributes: hintAttrs)
    hint.draw(at: NSPoint(x: (W - hSize.width) / 2, y: rowY - 44), withAttributes: hintAttrs)
}

func render(scale: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAffineTransform(transform: AffineTransform(scale: CGFloat(scale))).concat()
    draw()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let png1 = dir.appendingPathComponent("dmg-bg-1x.png")
let png2 = dir.appendingPathComponent("dmg-bg-2x.png")
try render(scale: 1).write(to: png1)
try render(scale: 2).write(to: png2)

// Stitch into a HiDPI-aware TIFF; Finder picks the right representation.
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", png1.path, png2.path,
                      "-out", dir.appendingPathComponent("dmg-background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
try? FileManager.default.removeItem(at: png1)
try? FileManager.default.removeItem(at: png2)
print(tiffutil.terminationStatus == 0 ? "dmg-background.tiff written" : "tiffutil failed")
