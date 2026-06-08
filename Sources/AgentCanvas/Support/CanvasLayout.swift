import AppKit

/// Shared geometry constants for the canvas. Centralized so view, store, and
/// controller agree on sizes without passing them around.
enum CanvasLayout {
    /// On-canvas size of a card (document units == terminal native px → crisp when framed).
    static let cardSize = NSSize(width: 960, height: 640)
    /// On-canvas size of a diff object — a touch wider than a card for its two-pane split.
    static let diffSize = NSSize(width: 1100, height: 720)
    /// Interior padding around a card's terminal (within the terminal's own
    /// background), so the CLI text has breathing room from the window edges.
    static let terminalPadding: CGFloat = 12
    /// Breathing room added around content when computing the "fit all" bounds.
    static let margin: CGFloat = 120
    /// The fixed (large) document size — big enough to feel infinite.
    static let canvasSize: CGFloat = 16000
    static var canvasCenter: NSPoint { NSPoint(x: canvasSize / 2, y: canvasSize / 2) }
}
