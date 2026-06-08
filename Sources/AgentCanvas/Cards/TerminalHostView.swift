import AppKit
import SwiftTerm

/// Hosts a card's terminal with interior padding so the CLI text has breathing room
/// from the window edges. SwiftTerm draws its cells from the origin and has no
/// native text inset, so we inset the terminal *view* inside a backing painted with
/// the terminal's own background color — the padding then reads as part of the CLI,
/// not as a chrome-colored frame.
final class TerminalHostView: NSView {
    private let terminal: LocalProcessTerminalView
    private let padding: CGFloat

    init(terminal: LocalProcessTerminalView, padding: CGFloat) {
        self.terminal = terminal
        self.padding = padding
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminal)
        applyBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Match the backing to the terminal's background so the padding is seamless.
    /// `nativeBackgroundColor` is dynamic (adapts to appearance); its `.cgColor`
    /// freezes, so re-apply on appearance change.
    private func applyBackground() {
        layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    override func layout() {
        super.layout()
        terminal.frame = bounds.insetBy(dx: padding, dy: padding)
    }
}
