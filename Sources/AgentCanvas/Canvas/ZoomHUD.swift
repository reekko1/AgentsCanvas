import AppKit

/// The zoom HUD (bottom-left): − · level% · + · fit. Constant-size window chrome
/// wired to the `Viewport`.
final class ZoomHUD: OverlayPanel {
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFit: (() -> Void)?
    private let level = NSTextField(labelWithString: "100%")

    init() {
        super.init(corner: 16)
        let out = GlyphButton(symbol: "minus", tip: "Zoom out (−)") { [weak self] in self?.onZoomOut?() }
        let inn = GlyphButton(symbol: "plus", tip: "Zoom in (+)") { [weak self] in self?.onZoomIn?() }
        let fit = GlyphButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "Fit all (⌘0)") { [weak self] in self?.onFit?() }

        level.font = Theme.fonts.mono(11)
        level.textColor = Theme.colors.textMuted
        level.alignment = .center
        level.isEditable = false; level.isBordered = false; level.drawsBackground = false
        level.translatesAutoresizingMaskIntoConstraints = false
        level.widthAnchor.constraint(equalToConstant: 46).isActive = true

        let stack = NSStackView(views: [out, level, inn, fit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLevel(_ mag: CGFloat) { level.stringValue = "\(Int((mag * 100).rounded()))%" }
}
