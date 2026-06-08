import AppKit
import QuartzCore

/// The validated zoom/pan engine. Operates on an NSScrollView: single-track
/// fly-to (interpolates focal point + magnification together so there's no
/// top-left round trip), content-relative zoom-out floor, and fixed-magnification
/// framing. Emits `onChange` whenever the viewport moves (for backdrop tracking).
final class Viewport {
    private let scrollView: NSScrollView

    /// How much of the viewport a framed item fills (the rest is breathing-room margin).
    var framingFill: CGFloat = 0.92
    /// Never upscale past this when framing — keeps terminals/text crisp (≤1.0 = 1:1).
    var framingMaxMagnification: CGFloat = 1.0
    /// Lower = can zoom out further (more margin around content).
    var maxZoomOutFactor: CGFloat = 0.4

    var onChange: (() -> Void)?
    private var flyTimer: Timer?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }
    deinit { flyTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() { onChange?() }

    var size: NSSize { scrollView.contentView.frame.size }
    var magnification: CGFloat { scrollView.magnification }
    var center: NSPoint {
        let b = scrollView.contentView.bounds
        return NSPoint(x: b.midX, y: b.midY)
    }

    /// Cap zoom-out relative to content: pulling back further than "all items + margin" feels lost.
    func updateLimits(contentBounds: NSRect) {
        let vp = size
        guard vp.width > 0, vp.height > 0, contentBounds.width > 0, contentBounds.height > 0 else { return }
        let fit = min(vp.width / contentBounds.width, vp.height / contentBounds.height)
        scrollView.minMagnification = max(0.02, fit * maxZoomOutFactor)
    }

    func applyZoom(center c: NSPoint, mag m: CGFloat) {
        let vp = size
        let visW = vp.width / m, visH = vp.height / m
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.magnification = m
        scrollView.contentView.setBoundsOrigin(NSPoint(x: c.x - visW / 2, y: c.y - visH / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        CATransaction.commit()
    }

    func animateZoom(toCenter c1: NSPoint, mag m1: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        flyTimer?.invalidate()
        let m0 = scrollView.magnification
        let vp = size
        let o0 = scrollView.contentView.bounds.origin
        let c0 = NSPoint(x: o0.x + (vp.width / m0) / 2, y: o0.y + (vp.height / m0) / 2)
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = CGFloat(min(1.0, (CACurrentMediaTime() - start) / duration))
            let t = Self.easeInOut(raw)
            let m = m0 * pow(m1 / m0, t)
            let cx = c0.x + (c1.x - c0.x) * t
            let cy = c0.y + (c1.y - c0.y) * t
            self.applyZoom(center: NSPoint(x: cx, y: cy), mag: m)
            if raw >= 1.0 { timer.invalidate(); self.flyTimer = nil; completion?() }
        }
        RunLoop.current.add(timer, forMode: .common)
        flyTimer = timer
    }

    /// Fly to frame a single item so it fills the viewport (minus margin), sized to
    /// the item — so a card and a wider diff both land comfortably large, not at a
    /// fixed zoom. Capped at `framingMaxMagnification` so terminals stay crisp.
    func frame(rect: NSRect, completion: (() -> Void)? = nil) {
        let vp = size
        guard vp.width > 0, vp.height > 0, rect.width > 0, rect.height > 0 else { return }
        let fit = min(vp.width / rect.width, vp.height / rect.height) * framingFill
        let m = max(scrollView.minMagnification, min(framingMaxMagnification, fit))
        animateZoom(toCenter: NSPoint(x: rect.midX, y: rect.midY), mag: m, duration: 0.42, completion: completion)
    }

    /// Fit all content (capped at 1.0 so we never upscale-blur).
    func fitAll(contentBounds: NSRect, animated: Bool) {
        let vp = size
        guard contentBounds.width > 0, vp.width > 0 else { return }
        var m = min(vp.width / contentBounds.width, vp.height / contentBounds.height)
        m = max(scrollView.minMagnification, min(1.0, m))
        let c = NSPoint(x: contentBounds.midX, y: contentBounds.midY)
        if animated {
            animateZoom(toCenter: c, mag: m, duration: 0.42)
        } else {
            flyTimer?.invalidate(); flyTimer = nil
            applyZoom(center: c, mag: m)
        }
    }

    func zoomBy(_ factor: CGFloat) {
        let c = center
        var m = scrollView.magnification * factor
        m = max(scrollView.minMagnification, min(scrollView.maxMagnification, m))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            scrollView.animator().setMagnification(m, centeredAt: c)
        }
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
