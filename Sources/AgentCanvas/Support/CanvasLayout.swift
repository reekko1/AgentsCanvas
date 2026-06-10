import AppKit

/// Shared geometry constants for the canvas. Centralized so view, store, and
/// controller agree on sizes without passing them around.
enum CanvasLayout {
    /// On-canvas size of a card (document units == terminal native px → crisp when framed).
    static let cardSize = NSSize(width: 960, height: 640)
    /// On-canvas size of a diff object — a touch wider than a card for its two-pane split.
    static let diffSize = NSSize(width: 1100, height: 720)
    /// Default on-canvas size of a new frame — big enough to drop a cluster of cards into.
    static let frameSize = NSSize(width: 1060, height: 780)
    /// Smallest a card / diff may be resized to (keeps a terminal or two-pane usable).
    static let minItemSize = NSSize(width: 360, height: 240)
    /// Smallest a frame may be resized to.
    static let minFrameSize = NSSize(width: 260, height: 200)
    /// Interior padding around a card's terminal (within the terminal's own
    /// background), so the CLI text has breathing room from the window edges.
    static let terminalPadding: CGFloat = 12
    /// Below this magnification an agent card shows its poster face instead of
    /// the live terminal (terminal glyphs are unreadable mush by here). Keyed on
    /// magnification, not on-screen size, so a fly-in (capped at 1.0) always
    /// lands on the terminal regardless of how small the card was resized.
    static let posterMagnification: CGFloat = 0.55
    /// Interior padding of the poster face (scaled with the poster's type).
    static let posterPadding: CGFloat = 26
    /// Ceiling on the poster's zoom compensation: past this the type stops
    /// growing (the card itself is vanishing; chasing 1/mag forever would just
    /// crop a single word).
    static let posterMaxScale: CGFloat = 3.5
    /// Quantization step for the zoom compensation (~20% increments) — a camera
    /// fly re-layouts the poster a handful of times, not every frame.
    static let posterScaleStep: CGFloat = 1.2
    /// Document-unit height of the poster's irreducible core (status + two
    /// headline lines + padding) at scale 1 — caps the scale on short cards so
    /// the core always fits.
    static let posterCoreHeight: CGFloat = 180
    /// Poster simplification tiers, as zoom-compensation scale cutoffs: past
    /// `posterDenseCutoff` line caps tighten and the checklist shrinks; past
    /// `posterBodyCutoff` the body line goes; past `posterTodosCutoff` only
    /// status + headline remain.
    static let posterDenseCutoff: CGFloat = 1.5
    static let posterBodyCutoff: CGFloat = 2.2
    static let posterTodosCutoff: CGFloat = 3.0
    /// Checklist row budgets per tier (below dense / below body / above) —
    /// `.dense` is the most rows the poster ever shows, so it also sizes the
    /// label pool.
    static let posterRowBudgets = (dense: 7, mid: 5, tight: 4)
    /// Breathing room added around content when computing the "fit all" bounds.
    static let margin: CGFloat = 120
    /// The fixed (large) document size — big enough to feel infinite.
    static let canvasSize: CGFloat = 16000
    static var canvasCenter: NSPoint { NSPoint(x: canvasSize / 2, y: canvasSize / 2) }
}
