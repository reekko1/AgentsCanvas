import AppKit

/// An edgeless dot grid. It lives behind the scroll view and fills the viewport,
/// drawing only the dots currently visible (≈200, viewport-bounded — not the
/// whole canvas). It tracks the scroll `offset` and `scale` so the dots appear
/// glued to the canvas and zoom with it, but the tiling never runs out — there's
/// no document edge to see. This is what makes it feel infinite rather than
/// "a big rectangle you can fall off."
final class GridBackdropView: NSView {
    override var isFlipped: Bool { true } // match the document's top-left origin

    /// Document point currently at the viewport's top-left corner.
    var offset: NSPoint = .zero { didSet { needsDisplay = true } }
    /// Current magnification.
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }

    private let baseSpacing: CGFloat = 80

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true   // re-fill with the new appearance's theme colors
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.colors.canvasBackground.setFill()
        bounds.fill()

        let spacing = baseSpacing * scale
        guard spacing >= 5 else { return } // too dense when far out — just dark, no moiré

        Theme.colors.gridDot.setFill()
        let d = max(1.0, min(6.0, 3 * scale))

        // First grid line at or before the left/top edge, in document units.
        let firstX = (offset.x / baseSpacing).rounded(.down) * baseSpacing
        let firstY = (offset.y / baseSpacing).rounded(.down) * baseSpacing

        var docX = firstX
        while (docX - offset.x) * scale < bounds.width + spacing {
            let sx = (docX - offset.x) * scale
            var docY = firstY
            while (docY - offset.y) * scale < bounds.height + spacing {
                let sy = (docY - offset.y) * scale
                NSBezierPath(ovalIn: NSRect(x: sx - d / 2, y: sy - d / 2, width: d, height: d)).fill()
                docY += baseSpacing
            }
            docX += baseSpacing
        }
    }
}
