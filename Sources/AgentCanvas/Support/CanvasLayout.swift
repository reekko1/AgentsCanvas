import AppKit

/// Shared geometry constants for the canvas. Centralized so view, store, and
/// controller agree on sizes without passing them around.
enum CanvasLayout {
    /// On-canvas size of a card (document units == terminal native px → crisp when framed).
    static let cardSize = NSSize(width: 960, height: 640)
    /// Breathing room added around content when computing the "fit all" bounds.
    static let margin: CGFloat = 120
    /// The fixed (large) document size — big enough to feel infinite.
    static let canvasSize: CGFloat = 16000
    static var canvasCenter: NSPoint { NSPoint(x: canvasSize / 2, y: canvasSize / 2) }
}
