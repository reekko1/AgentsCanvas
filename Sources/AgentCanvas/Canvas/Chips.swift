import AppKit

/// Hoverable bordered chip: label + optional SF symbol, hand cursor, hover
/// lifts border + text toward the accent. Two sizes: the empty state's compact
/// rows and the wizard's full-height actions (`large`). Shared by
/// `EmptyStateView` and the onboarding dialog — one chip vocabulary.
class Chip: NSView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    var hoverTint: NSColor { Theme.colors.primary }
    /// Fired on any successful click — the wizard uses it to start "watching".
    var onActivate: (() -> Void)?
    /// Severity tint mixed into the resting border (the design's `--gate` mix).
    private let tint: NSColor?
    private let cornerRadius: CGFloat
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }

    init(text: String, symbol: String?, mono: Bool, large: Bool = false, tint: NSColor? = nil) {
        self.tint = tint
        self.cornerRadius = large ? 9 : 6
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        if large {
            label.font = mono ? Theme.fonts.mono(12, .medium) : Theme.fonts.ui(13, .semibold)
        } else {
            label.font = mono ? Theme.fonts.mono(11.5) : Theme.fonts.ui(12, .semibold)
        }
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false

        var views: [NSView] = [label]
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: large ? 11 : 10, weight: .medium))
            views.append(icon)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = large ? 8 : 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let hPad: CGFloat = large ? 14 : 9
        let vPad: CGFloat = large ? 9 : 4
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            row.topAnchor.constraint(equalTo: topAnchor, constant: vPad),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vPad),
        ])
        if large { heightAnchor.constraint(equalToConstant: 38).isActive = true }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    /// The one activation path — mouse, Space/Return, and assistive presses all
    /// land here. Subclasses do their work in this override, never in `mouseUp`
    /// (a `.button` role whose press does nothing is a lie to the a11y tree).
    func performPress() { onActivate?() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { performPress() }
    }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { performPress() }   // space / return
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        performPress()
        return true
    }

    func refresh() {
        let resting = tint?.withAlphaComponent(0.45) ?? Theme.colors.border
        let textTint = hovering ? hoverTint : Theme.colors.glyph
        label.textColor = textTint
        icon.contentTintColor = hovering ? hoverTint : (tint ?? Theme.colors.glyph)
        layer?.borderColor = (hovering ? hoverTint : resting).cgColor
        layer?.backgroundColor = (hovering ? Theme.colors.hover : NSColor.clear).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { refresh() }
    }
}

/// Opens a URL — "Get Tailscale", "Get Homebrew".
final class LinkChip: Chip {
    private let url: URL
    init(title: String, url: URL, large: Bool = false, tint: NSColor? = nil) {
        self.url = url
        super.init(text: title, symbol: "arrow.up.right", mono: false, large: large, tint: tint)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func performPress() {
        NSWorkspace.shared.open(url)
        onActivate?()
    }
}

/// A copyable command — click puts it on the pasteboard and confirms inline.
/// Shows the command itself where space allows; a compact surface can pass a
/// short `label` ("Copy install command") while copying the same command, so
/// every surface shares one canonical install path.
final class CopyChip: Chip {
    private let command: String
    private let displayText: String
    private var revertTimer: Timer?
    override var hoverTint: NSColor { Theme.colors.statusDone }

    init(command: String, large: Bool = false, label: String? = nil) {
        self.command = command
        self.displayText = label ?? command
        super.init(text: displayText, symbol: "doc.on.doc", mono: label == nil, large: large)
        toolTip = "Copy to clipboard"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy \(command)")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { revertTimer?.invalidate() }

    override func performPress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        label.stringValue = "copied"
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        onActivate?()
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.label.stringValue = self.displayText
            self.icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            self.refresh()
        }
    }
}
