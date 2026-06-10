import AppKit

/// The shared chrome for any on-canvas item (cards + diff objects): a draggable
/// title bar (bead + name + trailing label + ✕) over a content view, with a
/// status-driven **glow halo** + rounded body — the "lo-fi dusk" item shell.
///
/// **Layout contract (LOAD-BEARING):** this view is positioned by the *canvas* via
/// its `frame` (it lives in the document view). Everything *inside* it is laid out
/// with Auto Layout constraints — never manual subview frames / `sizeToFit` /
/// `layout()` overrides. The title-bar row is an `NSStackView` (sanctioned for
/// show/hide). The only manual geometry is on **layers** (corner radius / shadow),
/// which don't touch the constraint engine.
///
/// Structure: `self` (rounded body + glow, unclipped so the shadow shows) → `clip`
/// (rounded, masked, so children corners round) → titleBar + content.
final class ItemContainerView: NSView {
    override var isFlipped: Bool { true }

    /// How the border + glow read for the current status.
    enum Glow {
        case none                       // diff objects: neutral, no colored glow
        case calm(breathe: TimeInterval?)  // running (breathing) / done (steady)
        case loud(breathe: TimeInterval?)  // blocked (breathing) / error (steady)
    }

    private let cornerRadius: CGFloat = 16
    private let clipInset: CGFloat = 1.5      // border ring thickness
    private let titleBarHeight: CGFloat = 44

    /// Breathing room between the content area and the body edges (a card's terminal
    /// gets some; the diff fills edge-to-edge). Applied as constraint constants.
    var contentInset: CGFloat = 0 { didSet { updateContentInsets() } }

    /// Background painted behind the content (shows in the inset gaps). A card sets
    /// this to the dark terminal color so the gap reads as a screen bezel.
    var bodyColor: NSColor = Theme.colors.itemBody { didSet { applySurfaceColors() } }

    private let clip = FlippedView()
    private let titleBar = DragBarView()
    private let bead = BeadView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private let placeholder = NSTextField(labelWithString: "")
    private(set) var content: NSView?
    private var contentConstraints: [NSLayoutConstraint] = []

    /// When true, a subtle CRT screen texture is painted over the content (cards
    /// set this for the lo-fi terminal look; diffs don't).
    var showsScreenTexture = false
    private var screenTexture: ScreenTextureView?

    /// Fired continuously while the title bar drags the item (each mouse-move), for
    /// live feedback (e.g. frame join highlighting). `onMoved` still fires once on drop.
    var onMoving: ((NSPoint) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var onDelete: (() -> Void)?
    /// Fired when a resize gesture commits (mouse-up), carrying the new outer frame.
    /// Nil until `enableResize` is called. The controller wires it like `onMoved`.
    var onResized: ((NSRect) -> Void)?
    private var resizeHandles: ResizeHandlesView?

    // Remembered accent so it can be re-resolved on appearance flips (layer colors
    // are frozen `.cgColor`s — see Theme.swift).
    private var accentColor: NSColor = Theme.colors.neutralBorder
    private var accentGlow: Glow = .none
    private var barTint: NSColor?

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = false           // let the glow shadow spill out
        layer?.shadowOffset = .zero

        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius - clipInset
        clip.layer?.masksToBounds = true       // round the children
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        titleBar.wantsLayer = true
        titleBar.movable = self
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.onMoving = { [weak self] origin in self?.onMoving?(origin) }
        titleBar.onMovedEnd = { [weak self] origin in self?.onMoved?(origin) }
        clip.addSubview(titleBar)

        titleLabel.font = Theme.fonts.itemTitle
        titleLabel.textColor = Theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureTitle(dir: nil, name: title)

        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isEditable = false; subtitleLabel.isBordered = false; subtitleLabel.drawsBackground = false
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = true

        trailingLabel.font = Theme.fonts.statusWord
        trailingLabel.textColor = Theme.colors.textMuted
        trailingLabel.isEditable = false; trailingLabel.isBordered = false; trailingLabel.drawsBackground = false
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

        deleteButton.title = "✕"
        deleteButton.isBordered = false
        deleteButton.font = Theme.fonts.controlGlyph
        deleteButton.contentTintColor = Theme.colors.glyph
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)

        // Title column: name row + (optional) meta subtitle. NSStackView show/hide
        // is the sanctioned way to toggle the row inside the magnified canvas.
        let titleColumn = NSStackView(views: [titleLabel, subtitleLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 0
        titleColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let barStack = NSStackView(views: [bead, titleColumn, trailingLabel, deleteButton])
        barStack.orientation = .horizontal
        barStack.alignment = .centerY
        barStack.distribution = .fill           // titleColumn (low hugging) takes the slack
        barStack.spacing = 9
        barStack.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(barStack)

        placeholder.alignment = .center
        placeholder.font = Theme.fonts.placeholder
        placeholder.textColor = Theme.colors.termMuted   // sits on the dark screen bezel
        placeholder.isEditable = false; placeholder.isBordered = false; placeholder.drawsBackground = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(placeholder)

        let contentGuide = NSLayoutGuide()
        clip.addLayoutGuide(contentGuide)

        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor, constant: clipInset),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: clipInset),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -clipInset),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -clipInset),

            titleBar.topAnchor.constraint(equalTo: clip.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: titleBarHeight),

            barStack.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 14),
            barStack.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -10),
            barStack.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            bead.widthAnchor.constraint(equalToConstant: 12),
            bead.heightAnchor.constraint(equalToConstant: 12),
            deleteButton.widthAnchor.constraint(equalToConstant: 26),
            deleteButton.heightAnchor.constraint(equalToConstant: 26),

            contentGuide.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            contentGuide.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: clip.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: contentGuide.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentGuide.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: clip.leadingAnchor, constant: 12),
        ])

        applySurfaceColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func deleteTapped() { onDelete?() }

    // MARK: Resize

    /// Opt this item into resizing: install handles that drag the outer frame and
    /// report the committed frame via `onResized`. Call once from the item's init
    /// (cards + diffs do). The overlay sits *above* the clip so its handles are
    /// hittable over the body corners, and passes every other hit straight through
    /// to the title bar / content beneath. Idempotent.
    func enableResize(edges: [ResizeEdges] = [.bottomRight], minSize: NSSize) {
        guard resizeHandles == nil else { return }
        let r = ResizeHandlesView(edges: edges, minSize: minSize, cornerRadius: cornerRadius)
        r.onCommit = { [weak self] frame in self?.onResized?(frame) }
        addSubview(r)
        NSLayoutConstraint.activate([
            r.topAnchor.constraint(equalTo: topAnchor),
            r.leadingAnchor.constraint(equalTo: leadingAnchor),
            r.trailingAnchor.constraint(equalTo: trailingAnchor),
            r.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        resizeHandles = r
    }

    // MARK: Content

    func setContent(_ view: NSView) {
        NSLayoutConstraint.deactivate(contentConstraints)
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(view, positioned: .below, relativeTo: titleBar)
        contentConstraints = [
            view.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: contentInset),
            view.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: contentInset),
            view.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -contentInset),
            view.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -contentInset),
        ]
        NSLayoutConstraint.activate(contentConstraints)
        placeholder.isHidden = true
        if showsScreenTexture { installScreenTexture() }
    }

    /// Overlay the CRT texture above the content (terminal) but below the title bar.
    private func installScreenTexture() {
        let tex = screenTexture ?? ScreenTextureView()
        screenTexture = tex
        tex.removeFromSuperview()
        tex.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(tex, positioned: .below, relativeTo: titleBar)
        NSLayoutConstraint.activate([
            tex.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            tex.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            tex.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            tex.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
    }

    private func updateContentInsets() {
        guard contentConstraints.count == 4 else { return }
        contentConstraints[0].constant = contentInset
        contentConstraints[1].constant = contentInset
        contentConstraints[2].constant = -contentInset
        contentConstraints[3].constant = -contentInset
    }

    func setPlaceholder(_ text: String) { placeholder.stringValue = text }

    // MARK: Title bar pieces

    /// Set the item name with an optional muted directory prefix (e.g. `~/work/`).
    func configureTitle(dir: String?, name: String) {
        let s = NSMutableAttributedString()
        if let dir, !dir.isEmpty {
            s.append(NSAttributedString(string: dir, attributes: [
                .foregroundColor: Theme.colors.textMuted,
                .font: Theme.fonts.itemTitle,
            ]))
        }
        s.append(NSAttributedString(string: name, attributes: [
            .foregroundColor: Theme.colors.textPrimary,
            .font: Theme.fonts.itemTitle,
        ]))
        titleLabel.attributedStringValue = s
    }

    /// Plain title (kept for callers that just set a string).
    func setTitle(_ text: String) { configureTitle(dir: nil, name: text) }

    /// The meta line under the title (mode warning · model · task). Nil hides the row.
    func setSubtitle(_ attributed: NSAttributedString?) {
        if let attributed {
            subtitleLabel.attributedStringValue = attributed
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }
    }

    /// The bead at the leading edge (cards). Hidden for diffs.
    func setBead(visible: Bool, color: NSColor = Theme.colors.statusIdle,
                 glow: Bool = false, pulse: BeadView.Pulse = .none) {
        bead.isHidden = !visible
        if visible { bead.set(color: color, glow: glow, pulse: pulse) }
    }

    /// Trailing label: a card's UPPERCASE status word, or a diff's diffstat.
    func setTrailing(_ attributed: NSAttributedString?) {
        trailingLabel.attributedStringValue = attributed ?? NSAttributedString(string: "")
        trailingLabel.isHidden = (attributed == nil)
    }

    // MARK: Accent (border + glow)

    func setAccent(color: NSColor, glow: Glow, barTint: NSColor? = nil) {
        accentColor = color
        accentGlow = glow
        self.barTint = barTint
        applyAccent()
        applyBarColor()
    }

    private func applyAccent() {
        guard let layer else { return }
        switch accentGlow {
        case .none:
            layer.borderColor = accentColor.withAlphaComponent(0.9).cgColor
            layer.borderWidth = 1
            setGlow(color: Theme.colors.canvasBackground, radius: 18, opacity: 0.45, breathe: nil, offsetY: 7)
        case .calm(let breathe):
            layer.borderColor = accentColor.withAlphaComponent(0.55).cgColor
            layer.borderWidth = 1
            setGlow(color: accentColor, radius: 20, opacity: 0.5, breathe: breathe, offsetY: 0)
        case .loud(let breathe):
            layer.borderColor = accentColor.cgColor
            layer.borderWidth = 2
            setGlow(color: accentColor, radius: 30, opacity: 0.85, breathe: breathe, offsetY: 0)
        }
    }

    /// Drive the body's `layer.shadow*` as the glow. One shadow per layer, so the
    /// breathing variant animates opacity + radius for a soft pulse.
    private func setGlow(color: NSColor, radius: CGFloat, opacity: Float,
                         breathe: TimeInterval?, offsetY: CGFloat) {
        guard let layer else { return }
        layer.shadowColor = color.cgColor
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: offsetY)
        layer.removeAnimation(forKey: "glow")
        if let period = breathe {
            layer.shadowOpacity = opacity
            let op = CABasicAnimation(keyPath: "shadowOpacity")
            op.fromValue = opacity * 0.65; op.toValue = min(1, opacity * 1.12)
            let rad = CABasicAnimation(keyPath: "shadowRadius")
            rad.fromValue = radius * 0.82; rad.toValue = radius * 1.18
            let group = CAAnimationGroup()
            group.animations = [op, rad]
            group.duration = period / 2
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = Theme.motion.softEase
            layer.add(group, forKey: "glow")
        } else {
            layer.shadowOpacity = opacity
        }
    }

    // MARK: Surfaces

    private func applyBarColor() {
        let base = Theme.colors.itemBar
        if let barTint {
            titleBar.layer?.backgroundColor = blend(barTint, into: base, fraction: 0.16).cgColor
        } else {
            titleBar.layer?.backgroundColor = base.cgColor
        }
    }

    /// Push dynamic surface colors into the layers for the *current* appearance.
    private func applySurfaceColors() {
        layer?.backgroundColor = bodyColor.cgColor
        clip.layer?.backgroundColor = NSColor.clear.cgColor
        applyBarColor()
        applyAccent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applySurfaceColors() }
    }

    /// Mix `a` over `b` by `fraction` in the current appearance (for the bar tint).
    private func blend(_ a: NSColor, into b: NSColor, fraction: CGFloat) -> NSColor {
        let aa = a.usingColorSpace(.sRGB) ?? a
        let bb = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: bb.redComponent + (aa.redComponent - bb.redComponent) * fraction,
                       green: bb.greenComponent + (aa.greenComponent - bb.greenComponent) * fraction,
                       blue: bb.blueComponent + (aa.blueComponent - bb.blueComponent) * fraction,
                       alpha: 1)
    }
}

// MARK: - Bead

/// The small status bead in a card's title bar: a colored dot with an optional
/// colored glow and a breathe/alarm pulse.
final class BeadView: NSView {
    enum Pulse { case none, breathe(TimeInterval), alarm }

    override var isFlipped: Bool { true }
    private var color: NSColor = Theme.colors.statusIdle
    private var glow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func set(color: NSColor, glow: Bool, pulse: Pulse) {
        self.color = color
        self.glow = glow
        self.currentPulse = pulse
        apply()
    }

    private func apply() {
        guard let layer else { return }
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        layer.backgroundColor = color.cgColor
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 5
        layer.shadowOpacity = glow ? 1 : 0
        layer.removeAnimation(forKey: "pulse")
        if case .breathe(let p) = currentPulse {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.55
            a.duration = p / 2; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = Theme.motion.softEase
            layer.add(a, forKey: "pulse")
        } else if case .alarm = currentPulse {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [1, 1, 0.35, 0.35, 1]
            a.keyTimes = [0, 0.4, 0.5, 0.9, 1]
            a.duration = 1.4; a.repeatCount = .infinity
            a.calculationMode = .discrete
            layer.add(a, forKey: "pulse")
        }
    }

    // Stash the requested pulse so `apply()` can re-read it after a relayout.
    private var currentPulse: Pulse = .none
}

/// A plain flipped view (top-left origin) used as the rounded clip container.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A subtle CRT screen texture (faint scanlines + an edge vignette) painted over a
/// card's terminal. Decorative and **non-interactive** — clicks pass straight
/// through to the terminal beneath.
final class ScreenTextureView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Edge vignette, anchored top-centre (matches the design's `.term::after`).
        if let g = NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 0.11)) {
            let c = NSPoint(x: bounds.midX, y: 0)
            g.draw(fromCenter: c, radius: 0, toCenter: c, radius: max(bounds.width, bounds.height) * 1.1, options: [])
        }
        // Scanlines: a faint dark line every 3pt.
        NSColor(white: 0, alpha: 0.025).setFill()
        var y: CGFloat = 0
        while y < bounds.height { NSRect(x: 0, y: y, width: bounds.width, height: 1).fill(); y += 3 }
    }
}
