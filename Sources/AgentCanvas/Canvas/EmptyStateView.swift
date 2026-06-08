import AppKit

/// The empty first-run card: a warm brand mark, a calm headline, and the keys to
/// get started. Centered over the empty canvas; hidden once any item exists.
final class EmptyStateView: NSView {
    private let mark = NSView()
    private let markGradient = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // Brand mark: a rounded warm gradient tile with a + glyph.
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 18
        mark.layer?.masksToBounds = true
        markGradient.startPoint = CGPoint(x: 0.25, y: 0)
        markGradient.endPoint = CGPoint(x: 1, y: 1)
        mark.layer?.addSublayer(markGradient)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let plus = NSImageView()
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .semibold))
        plus.contentTintColor = .white
        plus.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(plus)

        let headline = NSTextField(labelWithString: "A quiet place for your agents")
        headline.font = Theme.fonts.ui(22, .bold)
        headline.textColor = Theme.colors.textPrimary
        headline.alignment = .center

        let body = NSTextField(wrappingLabelWithString:
            "Spawn a coding agent into a folder and it appears here. Zoom out to watch them all; the one that needs you will glow.")
        body.font = Theme.fonts.ui(14)
        body.textColor = Theme.colors.textMuted
        body.alignment = .center
        body.isEditable = false; body.isBordered = false; body.drawsBackground = false
        body.preferredMaxLayoutWidth = 360

        let hints = NSStackView(views: [kbd("⌘ N"), label("new agent"),
                                        dot(), kbd("double-click"), label("to fit")])
        hints.orientation = .horizontal
        hints.alignment = .centerY
        hints.spacing = 8

        let stack = NSStackView(views: [mark, headline, body, hints])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: mark)
        stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 60),
            mark.heightAnchor.constraint(equalToConstant: 60),
            plus.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyMarkColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        markGradient.frame = mark.bounds
    }

    /// A keycap chip (mono on a bordered tile).
    private func kbd(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: " \(text) ")
        l.font = Theme.fonts.mono(11.5)
        l.textColor = Theme.colors.textPrimary
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        l.wantsLayer = true
        l.layer?.cornerRadius = 6
        l.layer?.borderWidth = 1
        l.layer?.borderColor = Theme.colors.border.cgColor
        l.layer?.backgroundColor = Theme.colors.itemBar.cgColor
        return l
    }
    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.fonts.ui(13)
        l.textColor = Theme.colors.textMuted
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        return l
    }
    private func dot() -> NSTextField { let d = label("·"); d.alphaValue = 0.5; return d }

    private func applyMarkColors() {
        markGradient.colors = [
            Theme.colors.statusBlocked.cgColor,   // amber
            Theme.colors.statusError.cgColor,     // red
            Theme.colors.primary.cgColor,         // indigo
        ]
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyMarkColors() }
    }
}
