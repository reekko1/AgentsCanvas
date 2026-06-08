import AppKit

/// Which edges of the target a resize handle moves: one edge is a side strip, an X
/// edge + a Y edge is a corner. Geometry is the **flipped document space** (the
/// canvas surface is flipped), so `minY` is the *visual top* and `maxY` the bottom.
///
/// The set is general (sides *and* corners) so the math + cursors cover every case,
/// but v1 instantiates `.bottomRight` only — one thick corner grip per item.
struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let minX = ResizeEdges(rawValue: 1 << 0)   // left
    static let maxX = ResizeEdges(rawValue: 1 << 1)   // right
    static let minY = ResizeEdges(rawValue: 1 << 2)   // top    (flipped)
    static let maxY = ResizeEdges(rawValue: 1 << 3)   // bottom

    static let topLeft:     ResizeEdges = [.minY, .minX]
    static let topRight:    ResizeEdges = [.minY, .maxX]
    static let bottomLeft:  ResizeEdges = [.maxY, .minX]
    static let bottomRight: ResizeEdges = [.maxY, .maxX]

    var isCorner: Bool {
        (contains(.minX) || contains(.maxX)) && (contains(.minY) || contains(.maxY))
    }

    /// The frame produced by moving *my* edges of `start` by `delta` (in document
    /// space), never letting either dimension drop below `min`. The clamp pins the
    /// moving edge so the opposite (anchored) edge stays put.
    func resized(_ start: NSRect, by delta: NSSize, min: NSSize) -> NSRect {
        var x = start.minX, y = start.minY, w = start.width, h = start.height
        if contains(.minX) { x += delta.width;  w -= delta.width }
        if contains(.maxX) { w += delta.width }
        if contains(.minY) { y += delta.height; h -= delta.height }
        if contains(.maxY) { h += delta.height }
        if w < min.width  { if contains(.minX) { x -= (min.width  - w) }; w = min.width }
        if h < min.height { if contains(.minY) { y -= (min.height - h) }; h = min.height }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// The pointer to show over this handle.
    var cursor: NSCursor {
        if isCorner {
            let rising = (contains(.minY) && contains(.maxX)) || (contains(.maxY) && contains(.minX))
            return ResizeEdges.diagonalCursor(rising: rising)
        }
        return (contains(.minX) || contains(.maxX)) ? .resizeLeftRight : .resizeUpDown
    }

    /// AppKit ships no *public* diagonal resize cursor; use its private one when the
    /// selector is present, else fall back to a crosshair. (Local dev tool, not MAS.)
    private static func diagonalCursor(rising: Bool) -> NSCursor {
        let sel = NSSelectorFromString(rising ? "_windowResizeNorthEastSouthWestCursor"
                                              : "_windowResizeNorthWestSouthEastCursor")
        let cls: AnyObject = NSCursor.self
        if cls.responds(to: sel), let c = cls.perform(sel)?.takeUnretainedValue() as? NSCursor { return c }
        return .crosshair
    }
}

/// A reusable resize affordance — the **sibling of `DragBarView`**. A pass-through
/// overlay pinned over a host view, carrying a thick corner grip (bottom-right in
/// v1). Dragging the grip mutates the **host's outer `frame`** (the only geometry
/// the canvas owns) in document space, so it's zoom-correct and never touches the
/// host's internal Auto Layout — the exact contract a move follows.
///
/// **Layout contract:** the overlay and its handle are positioned by *constraints*
/// (pinned to the host edge/corner). The only frame this code writes is the host's
/// outer frame, which is the canvas's job — triggered by the grip instead of a drag.
///
/// The grip's bracket traces the host's own corner radius (`cornerRadius`), so it
/// reads as part of the chrome. It reveals on hover and passes every other hit
/// straight through, so the host's content (terminal, diff list, drag bar) is
/// unaffected.
final class ResizeHandlesView: NSView {
    override var isFlipped: Bool { true }

    /// Fired continuously while dragging (the host frame is already updated live).
    var onResize: ((NSRect) -> Void)?
    /// Fired once on mouse-up — the commit point (update the model + persist).
    var onCommit: ((NSRect) -> Void)?

    var minSize: NSSize { didSet { handles.forEach { $0.minSize = minSize } } }

    private let cornerRadius: CGFloat
    private var handles: [ResizeHandle] = []
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { handles.forEach { $0.revealed = hovering } } }

    /// Grab-zone size at the corner — generous, scaled to the corner radius.
    private var gripSize: CGFloat { max(2 * cornerRadius, 30) }

    init(edges: [ResizeEdges], minSize: NSSize, cornerRadius: CGFloat) {
        self.minSize = minSize
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        for e in edges { addHandle(e) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func addHandle(_ edges: ResizeEdges) {
        let h = ResizeHandle(edges: edges, cornerRadius: cornerRadius)
        h.minSize = minSize
        h.onResize = { [weak self] r in self?.onResize?(r) }
        h.onCommit = { [weak self] r in self?.onCommit?(r) }
        addSubview(h)
        handles.append(h)

        let cs = [h.widthAnchor.constraint(equalToConstant: gripSize),
                  h.heightAnchor.constraint(equalToConstant: gripSize),
                  edges.contains(.minX) ? h.leadingAnchor.constraint(equalTo: leadingAnchor)
                                        : h.trailingAnchor.constraint(equalTo: trailingAnchor),
                  edges.contains(.minY) ? h.topAnchor.constraint(equalTo: topAnchor)
                                        : h.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(cs)
    }

    /// Only the grip is interactive; the body passes straight through so the host's
    /// content and drag bar underneath still receive every other hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // Reveal the grip whenever the pointer is over the host (the calm hover cue).
    // Tracking areas fire independently of `hitTest`, so the pass-through body still
    // tracks enter/exit.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
}

// MARK: - Handle

/// One resize grip. Owns the drag gesture: it captures the host's starting frame at
/// mouse-down, then maps the cumulative cursor delta (in document space, so it's
/// correct at any zoom) into a new host frame via `ResizeEdges.resized`, applies it
/// live, and commits on mouse-up. Draws a thick rounded-corner bracket concentric
/// with the host's corner radius.
private final class ResizeHandle: NSView {
    override var isFlipped: Bool { true }

    let edges: ResizeEdges
    private let cornerRadius: CGFloat
    var minSize = NSSize(width: 80, height: 80)
    var onResize: ((NSRect) -> Void)?
    var onCommit: ((NSRect) -> Void)?
    var revealed = false { didSet { if revealed != oldValue { needsDisplay = true } } }

    private var startFrame: NSRect = .zero
    private var startGrab: NSPoint = .zero
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(edges: ResizeEdges, cornerRadius: CGFloat) {
        self.edges = edges
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The host whose frame we mutate (handle → overlay → host) and the document
    /// view its frame lives in (`host.superview`).
    private var host: NSView? { superview?.superview }

    // MARK: Gesture
    override func mouseDown(with e: NSEvent) {
        guard let host, let doc = host.superview else { return }
        startFrame = host.frame
        startGrab = doc.convert(e.locationInWindow, from: nil)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let host, let doc = host.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        let delta = NSSize(width: p.x - startGrab.x, height: p.y - startGrab.y)
        let newFrame = edges.resized(startFrame, by: delta, min: minSize)
        host.frame = newFrame
        onResize?(newFrame)
    }
    override func mouseUp(with e: NSEvent) {
        guard let host else { return }
        onCommit?(host.frame)
    }

    // MARK: Cursor
    override func cursorUpdate(with event: NSEvent) { edges.cursor.set() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.cursorUpdate, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    // MARK: Draw — a small, thick bracket hugging the host's rounded corner,
    // concentric with its radius. Two states only, by *opacity*: faint when the
    // card is hovered, full when the grip itself is hovered (drag keeps the corner
    // under the cursor, so it stays full — no separate drag treatment).
    override func draw(_ dirtyRect: NSRect) {
        guard revealed || hovering, edges.isCorner else { return }
        let thickness: CGFloat = 5                    // thick, constant
        let inset = thickness / 2 + 1                 // sit just inside the border ring
        let r = max(cornerRadius - inset, 2)          // bracket radius, concentric with the body
        let leg = cornerRadius * 0.45                 // short straight tail along each edge
        let k = r * 0.5523                            // quarter-circle cubic constant

        let right  = edges.contains(.maxX), bottom = edges.contains(.maxY)
        let dx: CGFloat = right ? -1 : 1              // inward x
        let dy: CGFloat = bottom ? -1 : 1            // inward y
        let ox = right  ? bounds.maxX - inset : bounds.minX + inset
        let oy = bottom ? bounds.maxY - inset : bounds.minY + inset
        let cx = ox + dx * r, cy = oy + dy * r        // corner-arc center

        let pv = NSPoint(x: ox, y: cy)                // tangent on the vertical edge
        let ph = NSPoint(x: cx, y: oy)                // tangent on the horizontal edge

        let path = NSBezierPath()
        path.move(to: NSPoint(x: ox, y: cy + dy * leg))   // leg down the vertical edge
        path.line(to: pv)
        path.curve(to: ph,
                   controlPoint1: NSPoint(x: ox, y: cy - dy * k),
                   controlPoint2: NSPoint(x: cx - dx * k, y: oy))
        path.line(to: NSPoint(x: cx + dx * leg, y: oy)) // leg along the horizontal edge
        path.lineWidth = thickness
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        Theme.colors.resizeGrip.withAlphaComponent(hovering ? 1.0 : 0.3).setStroke()
        path.stroke()
    }
}
