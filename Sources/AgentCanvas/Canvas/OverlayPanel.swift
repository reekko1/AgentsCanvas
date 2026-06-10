import AppKit

/// A floating, constant-size "glass" overlay that lives in the window (not on the
/// magnified canvas), so it never zooms. Base for the zoom HUD, tool dock, and
/// activity center.
///
/// It's a plain view with an `NSVisualEffectView` *background* (content is added on
/// top as siblings) — deliberately NOT an `NSVisualEffectView` subclass, so the
/// content's explicit theme colors aren't muted by vibrancy.
class OverlayPanel: NSView {
    private let blur = NSVisualEffectView()

    init(corner: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyBorder()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyBorder() { layer?.borderColor = Theme.colors.border.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBorder() }
    }
}

/// A borderless SF-Symbol button with a hover wash, used across the overlays.
///
/// Built on `NSControl` (not `NSButton`) on purpose: an `NSButton`'s `NSButtonCell`
/// imposes an asymmetric, per-glyph intrinsic size (image + bezel padding) that
/// silently overrides explicit width/height constraints inside an `NSStackView` —
/// which made the tool dock render buttons of unequal height. A plain control with a
/// centered `NSImageView` honors the required square exactly, whatever the glyph.
final class GlyphButton: NSControl {
    private let handler: () -> Void
    private let squareSize: CGFloat
    private let glyph = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }
    /// Hover-help text, shown via our themed `GlyphTooltip` (not the native one).
    var tip: String?
    /// Sticky "armed/selected" state (e.g. the Frame tool while drawing) — a persistent
    /// accent wash, distinct from the transient hover wash.
    var isActive = false { didSet { refresh() } }

    init(symbol: String, size: CGFloat = 28, corner: CGFloat = 7, tip: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        self.squareSize = size
        super.init(frame: .zero)
        self.tip = tip
        wantsLayer = true
        layer?.cornerRadius = corner
        translatesAutoresizingMaskIntoConstraints = false

        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size >= 38 ? 19 : 13, weight: .medium))
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = Theme.colors.glyph
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: squareSize, height: squareSize) }

    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        GlyphTooltip.shared.dismiss(for: self)
        if isEnabled, bounds.contains(convert(e.locationInWindow, from: nil)) { handler() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) {
        hovering = true
        if let tip { GlyphTooltip.shared.show(tip, for: self) }
    }
    override func mouseExited(with e: NSEvent) {
        hovering = false
        GlyphTooltip.shared.dismiss(for: self)
    }

    private func refresh() {
        let hot = hovering && isEnabled
        let bg: NSColor = isActive ? Theme.colors.primary.withAlphaComponent(0.20)
                        : hot       ? Theme.colors.controlHover
                        :             .clear
        layer?.backgroundColor = bg.cgColor
        glyph.contentTintColor = isActive ? Theme.colors.primary
                               : hot       ? Theme.colors.textPrimary
                               :             Theme.colors.glyph
    }
}

/// A flipped view that fires a closure on click (clickable rows / headers).
final class ClickView: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }
}
