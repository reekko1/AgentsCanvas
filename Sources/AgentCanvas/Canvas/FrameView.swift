import AppKit

/// A frame's on-canvas body: a calm dashed rounded boundary drawn *behind* a cluster
/// of cards. The body passes pans through (only the resize grip is interactive); the
/// frame's **label is a separate constant-size overlay** (`FrameLabelOverlay`) that
/// floats above the cards, so it stays legible at any zoom and is never occluded.
/// The frame never glows.
final class FrameView: NSView {
    override var isFlipped: Bool { true }

    static let cornerRadius: CGFloat = 22

    private let resizeHandles = ResizeHandlesView(edges: [.bottomRight], minSize: CanvasLayout.minFrameSize,
                                                  cornerRadius: FrameView.cornerRadius)
    /// Fired when a resize gesture commits, carrying the frame's new rect.
    var onResized: ((NSRect) -> Void)?

    /// Current canvas magnification — used to keep the hairline + dashes a readable
    /// size on screen even when zoomed far out (the god-view altitude that matters).
    private var scale: CGFloat = 1

    /// Lit while a card is being dragged over this frame — the live "drop here to
    /// join" cue. Driven by the controller during a card move.
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
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

    func setScale(_ s: CGFloat) {
        let clamped = max(0.01, s)
        if abs(clamped - scale) > 0.0005 { scale = clamped; needsDisplay = true }
    }

    /// Only the resize grip is interactive; the body falls through (the label lives
    /// in a separate overlay now).
    override func hitTest(_ point: NSPoint) -> NSView? {
        resizeHandles.hitTest(convert(point, from: superview))
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        // Calm by default; lights up in the accent when a card is being dragged in.
        let tint = isHighlighted ? Theme.colors.primary : Theme.colors.textPrimary
        tint.withAlphaComponent(isHighlighted ? 0.10 : 0.03).setFill()
        path.fill()
        // Compensate for zoom so the boundary reads on screen at any magnification.
        path.lineWidth = isHighlighted ? max(2.5, 3.0 / scale) : max(1.5, 2.0 / scale)
        path.setLineDash([7 / scale, 6 / scale], count: 2, phase: 0)
        tint.withAlphaComponent(isHighlighted ? 0.85 : 0.20).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The frame's label — a **constant-size chip** that lives in a screen-space overlay
/// host (not the magnified canvas), positioned to track the frame's top-left corner.
/// Drag it to move the frame, click (no drag) to fit the camera to the group,
/// right-click → Rename / Delete. Because it's above the cards and never scales, it
/// stays readable and reachable at every zoom.
final class FrameLabelOverlay: NSView {
    override var isFlipped: Bool { true }

    private let glyph = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let flag = NSTextField(labelWithString: "")

    /// The document view (to convert doc↔screen) and the frame body this drives.
    weak var documentView: NSView?
    weak var frameView: FrameView?

    var onClick: (() -> Void)?
    var onMoveBegan: (() -> Void)?         // first drag movement — snapshot children before the frame moves
    var onMoving: ((NSRect) -> Void)?      // each drag tick — the frame's live rect (drag children along)
    var onMovedEnd: ((NSRect) -> Void)?
    var onRequestRename: (() -> Void)?
    var onDelete: (() -> Void)?

    private var grab: NSPoint = .zero
    private var downLoc: NSPoint = .zero
    private var moved = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.masksToBounds = false

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

        let stack = NSStackView(views: [glyph, nameLabel, countLabel, flag])
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

        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Rename…", action: #selector(renameAction), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Delete Frame", action: #selector(deleteAction), keyEquivalent: ""))
        m.items.forEach { $0.target = self }
        menu = m

        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func renameAction() { onRequestRename?() }
    @objc private func deleteAction() { onDelete?() }

    func setName(_ name: String) { nameLabel.stringValue = name; sizeToContent() }

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
        sizeToContent()
    }

    private func sizeToContent() {
        layoutSubtreeIfNeeded()
        setFrameSize(fittingSize)
    }

    /// Reposition the chip to hang at the frame's on-screen top-left — but clamped to
    /// the viewport so it stays readable + reachable when you pan into a big frame and
    /// its true corner scrolls off. When the frame is fully off-screen the chip hides
    /// (the notification panel carries an off-screen "needs you"). Size is kept current
    /// by `setName`/`update`, so this is just an origin move — cheap per pan/zoom frame.
    func syncPosition() {
        guard let doc = documentView, let fv = frameView, let host = superview else { return }
        let onScreen = doc.convert(fv.frame, to: host)
        let visible = host.bounds
        let clip = onScreen.intersection(visible)
        if clip.isEmpty { isHidden = true; return }   // frame fully off-screen → drop the chip
        isHidden = false
        let pad: CGFloat = 8
        var x = clip.minX + 12
        var y = clip.minY + 12
        x = min(max(x, visible.minX + pad), max(visible.minX + pad, visible.maxX - bounds.width - pad))
        y = min(max(y, visible.minY + pad), max(visible.minY + pad, visible.maxY - bounds.height - pad))
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Colors
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

    // MARK: Hit-testing & cursor
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self   // whole chip is one target (drag / click / menu)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func cursorUpdate(with event: NSEvent) {
        (moved ? NSCursor.closedHand : NSCursor.openHand).set()   // the whole chip is draggable
    }

    // MARK: Drag-to-move (in document space) vs click-to-fit
    override func mouseDown(with e: NSEvent) {
        moved = false
        downLoc = e.locationInWindow
        guard let fv = frameView, let doc = fv.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        grab = NSPoint(x: p.x - fv.frame.minX, y: p.y - fv.frame.minY)
    }
    override func mouseDragged(with e: NSEvent) {
        if !moved {
            if hypot(e.locationInWindow.x - downLoc.x, e.locationInWindow.y - downLoc.y) < 4 { return }
            moved = true
            NSCursor.closedHand.set()   // grab feedback once the drag actually starts
            onMoveBegan?()              // snapshot children at the pre-move position
        }
        guard let fv = frameView, let doc = fv.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        fv.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
        syncPosition()        // keep the chip glued to the moving frame
        onMoving?(fv.frame)   // …and drag the frame's children with it
    }
    override func mouseUp(with e: NSEvent) {
        if moved, let fv = frameView {
            onMovedEnd?(fv.frame)
            NSCursor.openHand.set()   // dropped — cursor is still over the chip
        } else {
            onClick?()
        }
    }
}

/// A flipped, full-window host for the frame label overlays. It sits above the
/// canvas (so labels float over the cards) but passes every hit on its empty areas
/// straight through to the canvas beneath — only the label chips are interactive.
final class FrameOverlayHost: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A transparent, window-space capture layer for *drawing* a new frame by dragging a
/// rectangle (the Figma/Sketch gesture). Hidden until the Frame tool is armed; while
/// shown it grabs canvas drags, paints a live rubber-band, and on mouse-up reports the
/// drawn rect in its own (screen) coords for the controller to convert into document
/// space. A too-small drag — or a bare click — reports nil, i.e. just cancel.
final class FrameDrawOverlay: NSView {
    /// Drawn rect (overlay-local) on a committed drag; nil if the drag was negligible.
    var onCommit: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var rubber: NSRect = .zero
    private var armed = false
    private var cursorTracking: NSTrackingArea?

    /// Arm/disarm from the controller. The cursor-tracking area is installed *here*,
    /// while the view is visible — not at init. A `.cursorUpdate` area registered while
    /// the overlay was still hidden never re-armed, which is why the crosshair only held
    /// during the drag (an explicit set) and not on a plain armed hover.
    func setArmed(_ on: Bool) {
        guard on != armed else { return }
        armed = on
        isHidden = !on
        if on {
            let t = NSTrackingArea(rect: bounds,
                                   options: [.cursorUpdate, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                   owner: self)
            addTrackingArea(t); cursorTracking = t
        } else if let cursorTracking {
            removeTrackingArea(cursorTracking); self.cursorTracking = nil
        }
    }

    /// Claim every hit while armed so the canvas underneath doesn't pan; pass through otherwise.
    override func hitTest(_ point: NSPoint) -> NSView? { armed ? self : nil }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        start = p
        rubber = NSRect(origin: p, size: .zero)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        NSCursor.crosshair.set()   // keep it crosshair through the rubber-band drag
        rubber = Self.rect(s, convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        defer { start = nil; rubber = .zero; needsDisplay = true }
        guard let s = start else { onCommit?(nil); return }
        let r = Self.rect(s, convert(e.locationInWindow, from: nil))
        onCommit?(hypot(r.width, r.height) < 12 ? nil : r)   // tiny drag / bare click → cancel
    }

    // Hold the crosshair across the canvas while armed. cursorUpdate is the *last* word
    // in the move→cursor sequence (after mouseMoved + cursor rects), so setting it here
    // wins; mouseMoved is belt-and-suspenders for the same.
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    private static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard start != nil, rubber.width > 1 || rubber.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rubber, xRadius: FrameView.cornerRadius, yRadius: FrameView.cornerRadius)
        Theme.colors.primary.withAlphaComponent(0.10).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash([7, 6], count: 2, phase: 0)
        Theme.colors.primary.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

