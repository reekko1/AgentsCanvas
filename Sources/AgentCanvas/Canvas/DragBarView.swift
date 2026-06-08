import AppKit

/// An OS-window-style title bar: grab anywhere on it to drag the parent item.
/// Converts the cursor into document coordinates so dragging tracks at any zoom.
/// The ✕ button (a subview) handles its own click, so it never starts a drag.
final class DragBarView: NSView {
    override var isFlipped: Bool { true }
    var onMovedEnd: ((NSPoint) -> Void)?
    private var grab: NSPoint = .zero

    override func mouseDown(with e: NSEvent) {
        guard let container = superview, let doc = container.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        grab = NSPoint(x: p.x - container.frame.minX, y: p.y - container.frame.minY)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let container = superview, let doc = container.superview else { return }
        let p = doc.convert(e.locationInWindow, from: nil)
        container.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
    }
    override func mouseUp(with e: NSEvent) {
        guard let container = superview else { return }
        onMovedEnd?(container.frame.origin)
    }
}
