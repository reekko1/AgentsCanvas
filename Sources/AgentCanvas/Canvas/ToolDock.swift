import AppKit

/// The left-edge tool dock (Photoshop-style): Frame · Agent · Terminal · Diff.
/// Clicking a tool runs its create action. Frame + Terminal are disabled until
/// Phase 2 / the plain-shell card land.
final class ToolDock: OverlayPanel {
    var onAgent: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onDiff: (() -> Void)?
    var onFrame: (() -> Void)?
    private var frameButton: GlyphButton?

    init() {
        super.init(corner: 17)
        let frame = tool(symbol: "rectangle.dashed", tip: "Frame a group — drag on the canvas") { [weak self] in self?.onFrame?() }
        let agent = tool(symbol: "circle.circle", tip: "New agent") { [weak self] in self?.onAgent?() }
        let term  = tool(symbol: "terminal", tip: "New terminal") { [weak self] in self?.onTerminal?() }
        let diff  = tool(symbol: "plusminus", tip: "New diff") { [weak self] in self?.onDiff?() }
        frameButton = frame

        let stack = NSStackView(views: [frame, agent, term, diff])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
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

    /// Reflect the Frame tool's armed state (drawing a frame) as a selected button.
    func setFrameToolActive(_ on: Bool) { frameButton?.isActive = on }

    private func tool(symbol: String, tip: String, enabled: Bool = true, handler: @escaping () -> Void) -> GlyphButton {
        let b = GlyphButton(symbol: symbol, size: 40, corner: 12, tip: tip, handler: handler)
        b.isEnabled = enabled
        b.alphaValue = enabled ? 1 : 0.35
        return b
    }
}
