import AppKit
import AVFoundation

/// A full-bleed looping video backdrop behind the scroll view. Unlike the old dot
/// grid it is **fixed to the window** — it doesn't pan or zoom with the canvas; the
/// cards and frames glide over it like a studio wall. It carries a dark- and a
/// light-theme clip and cross-swaps on appearance change (mirroring the grid's old
/// theme awareness). Aspect-fill, muted, seamless-looped via `AVPlayerLooper`, and
/// paused whenever the window is occluded so it costs nothing when hidden.
final class VideoBackdropView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// A subtle black scrim over the video so the cards and frames read as a
    /// distinct layer above it (separation), and the footage sits back.
    private let scrim = CALayer()
    private let scrimOpacity: Float = 0.28

    /// Variant currently loaded (true = dark); nil until the first load so the
    /// initial appearance always triggers a load.
    private var isDark: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true                 // makes our backing layer the AVPlayerLayer
        player.isMuted = true
        player.actionAtItemEnd = .none    // the looper owns continuity
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        // A solid fill under the video covers the gap before the first frame decodes
        // and any aspect-fill letterbox edge cases during resize.
        playerLayer.backgroundColor = Theme.colors.canvasBackground.cgColor

        scrim.backgroundColor = NSColor.black.cgColor
        scrim.opacity = scrimOpacity
        playerLayer.addSublayer(scrim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The view's backing layer *is* the player layer, so it resizes with the view
    /// automatically — no manual frame work.
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    /// Keep the scrim covering the whole view; no implicit animation on resize.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { player.pause(); return }
        loadVariantIfNeeded()
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        playIfVisible()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        playerLayer.backgroundColor = Theme.colors.canvasBackground.cgColor
        loadVariantIfNeeded()
    }

    @objc private func occlusionChanged() { playIfVisible() }

    private func playIfVisible() {
        if window?.occlusionState.contains(.visible) == true { player.play() }
        else { player.pause() }
    }

    /// (Re)load the clip matching the current appearance, but only when the variant
    /// actually changes — avoids a needless reload + flash on every appearance ping.
    private func loadVariantIfNeeded() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard dark != isDark else { return }
        isDark = dark

        let name = dark ? "backdrop-dark" : "backdrop-light"
        guard let url = Bundle.module.url(forResource: name, withExtension: "mp4") else {
            canvasLog("VideoBackdropView: missing resource \(name).mp4")
            return
        }
        looper?.disableLooping()
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playIfVisible()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
