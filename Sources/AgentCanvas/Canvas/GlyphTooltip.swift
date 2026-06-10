import AppKit

/// A lightweight, themed replacement for AppKit's native tooltip, used by
/// `GlyphButton` across the overlays.
///
/// One shared label is parked in the key window's *content view* (not inside the
/// overlay panel, whose rounded `masksToBounds` would clip it) and repositioned
/// next to whichever button is hovered. The overlays are window chrome — not on the
/// magnified canvas — so positioning by `.frame` here is correct (and the
/// no-manual-layout-inside-the-transform rule doesn't apply).
final class GlyphTooltip {
    static let shared = GlyphTooltip()

    private let container = NSView()
    private let label = NSTextField(labelWithString: "")
    private weak var anchor: NSView?

    private init() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1
        container.layer?.masksToBounds = false   // let the drop shadow spill past the corners
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.28
        container.layer?.shadowRadius = 10
        container.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.alphaValue = 0
        container.isHidden = true

        label.font = Theme.fonts.ui(12.5, .medium)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        container.addSubview(label)
    }

    /// Show `text` next to `view` immediately on hover.
    func show(_ text: String, for view: NSView) {
        guard view.window != nil else { return }
        present(text, for: view)
    }

    /// Fade out if `view` is the one currently shown.
    func dismiss(for view: NSView) {
        guard anchor === view else { return }
        anchor = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.anchor == nil { self?.container.isHidden = true }
        })
    }

    private func present(_ text: String, for view: NSView) {
        guard let content = view.window?.contentView else { return }
        anchor = view

        // Colors freeze when pushed to a layer, so resolve them in the current
        // appearance every time we show (handles light/dark switches for free).
        (view.window?.effectiveAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = Theme.colors.itemBar.cgColor
            container.layer?.borderColor = Theme.colors.border.cgColor
            label.textColor = Theme.colors.textPrimary
        }

        // Let the label compute its own rendered size (accounts for NSTextField's
        // internal cell padding); measuring the raw string or intrinsicContentSize
        // under-reports it and clips the last glyph.
        label.stringValue = text
        label.sizeToFit()
        let ls = label.frame.size
        let padX: CGFloat = 10, padY: CGFloat = 6
        let w = ceil(ls.width) + padX * 2, h = ceil(ls.height) + padY * 2
        label.frame = NSRect(x: padX, y: padY, width: ceil(ls.width), height: ls.height)

        container.removeFromSuperview()
        content.addSubview(container)

        // Place to the button's right (works for the left dock and bottom HUD);
        // flip to the left if it would overflow the window, and clamp vertically.
        let r = view.convert(view.bounds, to: content)
        let gap: CGFloat = 8, margin: CGFloat = 6
        var x = r.maxX + gap
        if x + w > content.bounds.maxX - margin { x = r.minX - gap - w }
        let y = max(margin, min(r.midY - h / 2, content.bounds.maxY - h - margin))
        container.frame = NSRect(x: round(x), y: round(y), width: w, height: h)

        container.isHidden = false
        container.alphaValue = 1   // appear instantly on hover, no fade-in
    }
}
