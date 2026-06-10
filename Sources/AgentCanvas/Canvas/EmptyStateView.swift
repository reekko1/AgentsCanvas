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

        // Readiness rows live below the hints: invisible when the environment is
        // complete, and each row vanishes the moment its tool appears (the probe
        // re-runs on app activation — installing IS the dismissal).
        readinessStack.orientation = .vertical
        readinessStack.alignment = .leading
        readinessStack.spacing = 0
        readinessStack.isHidden = true

        let stack = NSStackView(views: [mark, headline, body, hints, readinessStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: mark)
        stack.setCustomSpacing(18, after: body)
        stack.setCustomSpacing(26, after: hints)
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

    // MARK: Readiness

    private let readinessStack = NSStackView()
    private var lastReport: Readiness.Report?

    /// Show the setup panel when dependencies are missing — a real surface in the
    /// app's own vocabulary (solid body, border, soft shadow — like a card, not a
    /// toast), with one row per missing tool in the cards' status language:
    /// gold bead = blocking (no claude, no agents), ochre bead = worth a look
    /// (no tmux, agents die with the app). A fade covers both arrival and the
    /// disappearing act after the user installs and tabs back.
    func apply(_ report: Readiness.Report) {
        guard report != lastReport else { return }
        lastReport = report

        readinessStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = []
        if !report.claudeFound {
            rows.append(readinessRow(
                bead: Theme.colors.statusBlocked,
                title: "Claude Code is not installed",
                detail: "Agent Canvas supervises Claude Code agents.\nInstall it, then press ⌘N.",
                action: LinkChip(title: "Get Claude Code",
                                 url: URL(string: "https://claude.com/claude-code")!)))
        }
        if !report.tmuxFound {
            rows.append(readinessRow(
                bead: Theme.colors.statusStalled,
                title: "Agents stop when you quit the app",
                detail: "Install tmux and they keep working\nthrough restarts.",
                action: CopyChip(command: "brew install tmux")))
        }

        if !rows.isEmpty {
            readinessStack.addArrangedSubview(setupPanel(rows: rows))
        }
        let show = !rows.isEmpty
        guard show != !readinessStack.isHidden else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            readinessStack.isHidden = !show
            readinessStack.animator().alphaValue = show ? 1 : 0
        }
    }

    /// The panel chrome: a floating surface over the dusk, opened by a quiet mono
    /// section label (the activity panel's grammar), rows separated by hairlines.
    private func setupPanel(rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: "BEFORE YOU START")
        header.font = Theme.fonts.mono(10, .semibold)
        header.textColor = Theme.colors.statusStalled

        var content: [NSView] = [header]
        for (i, row) in rows.enumerated() {
            if i > 0 { content.append(hairline()) }
            content.append(row)
        }

        let column = NSStackView(views: content)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        column.setCustomSpacing(14, after: header)
        column.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.borderWidth = 1
        panel.layer?.masksToBounds = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: panel.topAnchor),
            column.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        stylePanel(panel)
        return panel
    }

    private func stylePanel(_ panel: NSView) {
        panel.layer?.backgroundColor = Theme.colors.itemBody.withAlphaComponent(0.96).cgColor
        panel.layer?.borderColor = Theme.colors.border.cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.45
        panel.layer?.shadowRadius = 22
        panel.layer?.shadowOffset = CGSize(width: 0, height: 8)
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.colors.borderSoft.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// One dependency: bead + (title over detail) ··· action chip, centered on
    /// the row so the chip reads as the row's verb, not an afterthought.
    private func readinessRow(bead: NSColor, title: String, detail: String, action: NSView) -> NSView {
        let dot = BeadView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        dot.set(color: bead, glow: true, pulse: .none)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.fonts.ui(13.5, .semibold)
        titleLabel.textColor = Theme.colors.textPrimary

        let detailLabel = NSTextField(labelWithString: detail)   // pre-broken lines, no wrap math
        detailLabel.font = Theme.fonts.ui(12)
        detailLabel.textColor = Theme.colors.textMuted
        detailLabel.maximumNumberOfLines = 2
        detailLabel.isEditable = false; detailLabel.isBordered = false; detailLabel.drawsBackground = false

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [dot, text, NSView(), action])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

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
        // Layer colors froze at assignment; rebuild the readiness rows in the new
        // appearance (apply() is gated on report change, so clear the cache).
        if let report = lastReport {
            lastReport = nil
            apply(report)
        }
    }
}

// MARK: - Readiness chips

/// Hoverable bordered chip base: label + optional SF symbol, hand cursor,
/// hover lifts border + text toward the accent.
private class Chip: NSView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    var hoverTint: NSColor { Theme.colors.primary }
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }

    init(text: String, symbol: String?, mono: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = mono ? Theme.fonts.mono(11.5) : Theme.fonts.ui(12, .semibold)
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false

        var views: [NSView] = [label]
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            views.append(icon)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func refresh() {
        let tint = hovering ? hoverTint : Theme.colors.glyph
        label.textColor = tint
        icon.contentTintColor = tint
        layer?.borderColor = (hovering ? hoverTint : Theme.colors.border).cgColor
        layer?.backgroundColor = (hovering ? Theme.colors.hover : NSColor.clear).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { refresh() }
    }
}

/// Opens a URL — "Get Claude Code".
private final class LinkChip: Chip {
    private let url: URL
    init(title: String, url: URL) {
        self.url = url
        super.init(text: title, symbol: "arrow.up.right", mono: false)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A copyable command — click puts it on the pasteboard and confirms inline.
private final class CopyChip: Chip {
    private let command: String
    private var revertTimer: Timer?
    override var hoverTint: NSColor { Theme.colors.statusDone }

    init(command: String) {
        self.command = command
        super.init(text: command, symbol: "doc.on.doc", mono: true)
        toolTip = "Copy to clipboard"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy \(command)")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { revertTimer?.invalidate() }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        label.stringValue = "copied"
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.label.stringValue = self.command
            self.icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            self.refresh()
        }
    }
}
