import AppKit

/// The scrollable/zoomable document surface. Flipped (top-left origin). Clicking
/// empty canvas makes it first responder so keyboard shortcuts work after typing
/// in a terminal. Item dragging/deleting is handled by each item's title bar;
/// double-click-to-frame is handled by the controller's mouse monitor.
final class DocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}
