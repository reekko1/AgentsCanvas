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
final class GlyphButton: NSButton {
    private let handler: () -> Void
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }

    init(symbol: String, size: CGFloat = 28, corner: CGFloat = 7, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = corner
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size >= 38 ? 19 : 13, weight: .medium))
        contentTintColor = Theme.colors.glyph
        target = self; action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    private func refresh() {
        layer?.backgroundColor = (hovering && isEnabled ? Theme.colors.controlHover : .clear).cgColor
        contentTintColor = (hovering && isEnabled) ? Theme.colors.textPrimary : Theme.colors.glyph
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
