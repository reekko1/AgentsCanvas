import AppKit

/// An OS-window-style title bar: grab anywhere on it to drag the parent item.
/// Converts the cursor into document coordinates so dragging tracks at any zoom.
///
/// It drags an explicit `movable` view (the on-canvas `ItemContainerView`) rather
/// than assuming `superview` — the container now nests the bar inside a rounded
/// clip view, so the bar's superview is no longer the movable item.
final class DragBarView: NSView {
    override var isFlipped: Bool { true }

    /// The canvas item this bar drags (set by `ItemContainerView`). Its `superview`
    /// is the document view, the coordinate space drags are computed in.
    weak var movable: NSView?
    var onMovedEnd: ((NSPoint) -> Void)?
    private var grab: NSPoint = .zero

    /// Let real controls (the ✕ button) receive their own clicks; every other hit
    /// on the bar — labels, the bead, empty space — drags the item.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with e: NSEvent) {
        guard let m = movable, let doc = m.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        grab = NSPoint(x: p.x - m.frame.minX, y: p.y - m.frame.minY)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let m = movable, let doc = m.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        m.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
    }
    override func mouseUp(with e: NSEvent) {
        guard let m = movable else { return }
        onMovedEnd?(m.frame.origin)
    }
}
