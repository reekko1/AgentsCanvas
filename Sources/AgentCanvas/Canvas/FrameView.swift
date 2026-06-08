import AppKit

/// A frame's on-canvas view: a calm dashed rounded boundary drawn *behind* a cluster
/// of cards, with a clickable label chip at the top-left. The **body passes pans
/// through** (hit-tests to nothing) — only the label is interactive. The frame never
/// glows; the label shows a quiet "needs you" tag only when a member is loud.
final class FrameView: NSView {
    override var isFlipped: Bool { true }

    private static let cornerRadius: CGFloat = 22

    let label = FrameLabelView()
    private let resizeHandles = ResizeHandlesView(edges: [.bottomRight], minSize: CanvasLayout.minFrameSize,
                                                  cornerRadius: FrameView.cornerRadius)

    /// Fired when a resize gesture commits, carrying the frame's new rect.
    var onResized: ((NSRect) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
        label.movableFrame = self

        resizeHandles.onCommit = { [weak self] rect in self?.onResized?(rect) }
        addSubview(resizeHandles)
        NSLayoutConstraint.activate([
            resizeHandles.topAnchor.constraint(equalTo: topAnchor),
            resizeHandles.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandles.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandles.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String) { label.setName(name) }
    func update(count: Int, loud: NSColor?) { label.update(count: count, loud: loud) }

    /// Corner handles win at the edges, then the label chip; the body falls through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inSelf = convert(point, from: superview)
        if let handle = resizeHandles.hitTest(inSelf) { return handle }
        return label.hitTest(inSelf)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        Theme.colors.textPrimary.withAlphaComponent(0.03).setFill()
        path.fill()
        path.lineWidth = 1.5
        path.setLineDash([7, 6], count: 2, phase: 0)
        Theme.colors.textPrimary.withAlphaComponent(0.20).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The frame's label chip: a glyph + name + member count + an optional "needs you"
/// tag, plus a hover-revealed ✕. Drag it to move the frame; click (no drag) to fit
/// the camera to the group.
final class FrameLabelView: NSView {
    override var isFlipped: Bool { true }

    private let glyph = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let flag = NSTextField(labelWithString: "")
    private let deleteButton: GlyphButton

    weak var movableFrame: NSView?
    var onClick: (() -> Void)?
    var onMovedEnd: ((NSPoint) -> Void)?
    var onDelete: (() -> Void)?

    private var grab: NSPoint = .zero
    private var downLoc: NSPoint = .zero
    private var moved = false
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { deleteButton.isHidden = !hovering } }

    init() {
        var del: (() -> Void)?
        deleteButton = GlyphButton(symbol: "xmark", size: 18, corner: 5) { del?() }
        super.init(frame: .zero)
        del = { [weak self] in self?.onDelete?() }

        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1

        glyph.wantsLayer = true
        glyph.layer?.cornerRadius = 4
        glyph.layer?.borderWidth = 1.6
        glyph.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Theme.fonts.mono(13, .semibold)
        nameLabel.isEditable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false

        countLabel.font = Theme.fonts.mono(10.5, .semibold)
        countLabel.alignment = .center
        countLabel.isEditable = false; countLabel.isBordered = false; countLabel.drawsBackground = false
        countLabel.wantsLayer = true
        countLabel.layer?.cornerRadius = 8
        countLabel.layer?.borderWidth = 1

        flag.font = Theme.fonts.mono(9, .semibold)
        flag.alignment = .center
        flag.isEditable = false; flag.isBordered = false; flag.drawsBackground = false
        flag.wantsLayer = true
        flag.layer?.cornerRadius = 8
        flag.layer?.borderWidth = 1
        flag.isHidden = true

        deleteButton.isHidden = true

        let stack = NSStackView(views: [glyph, nameLabel, countLabel, flag, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setName(_ name: String) { nameLabel.stringValue = name }

    func update(count: Int, loud: NSColor?) {
        countLabel.stringValue = " \(count) "
        if let loud {
            flag.isHidden = false
            flag.stringValue = " NEEDS YOU "
            flag.textColor = loud
            flag.layer?.backgroundColor = loud.withAlphaComponent(0.16).cgColor
            flag.layer?.borderColor = loud.withAlphaComponent(0.45).cgColor
        } else {
            flag.isHidden = true
        }
    }

    private func applyColors() {
        layer?.backgroundColor = Theme.colors.itemBar.cgColor
        layer?.borderColor = Theme.colors.borderSoft.cgColor
        glyph.layer?.borderColor = Theme.colors.glyph.cgColor
        nameLabel.textColor = Theme.colors.textPrimary
        countLabel.textColor = Theme.colors.textMuted
        countLabel.layer?.borderColor = Theme.colors.borderSoft.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // The whole chip drags (except the ✕ button); clicks on labels still hit the chip.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with e: NSEvent) {
        moved = false
        downLoc = e.locationInWindow
        guard let frame = movableFrame, let doc = frame.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        grab = NSPoint(x: p.x - frame.frame.minX, y: p.y - frame.frame.minY)
    }
    override func mouseDragged(with e: NSEvent) {
        // Ignore sub-threshold jitter so a click still registers as a click (fit).
        if !moved, hypot(e.locationInWindow.x - downLoc.x, e.locationInWindow.y - downLoc.y) < 4 { return }
        moved = true
        guard let frame = movableFrame, let doc = frame.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        frame.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
    }
    override func mouseUp(with e: NSEvent) {
        if moved, let frame = movableFrame { onMovedEnd?(frame.frame.origin) }
        else { onClick?() }
    }
}
