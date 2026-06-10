import AppKit
import CoreImage

/// The wizard's step content + its small vocabulary (flag pill, watching row,
/// QR reward, phone peek, buttons). Pure views — state lives in the dialog.
extension OnboardingDialogView {

    func buildStepView() -> NSView {
        switch step {
        case .welcome: return welcomeStep()
        case .claude: return claudeStep()
        case .tmux: return tmuxStep()
        case .tailscale: return tailscaleStep()
        case .exit: return exitStep()
        }
    }

    // MARK: Steps

    private func welcomeStep() -> NSView {
        let mark = BrandMarkView(size: 52)
        if report.machineReady {
            let col = stepColumn([
                mark,
                wizardTitle("Everything's ready on this Mac.", large: true),
                wizardBody([("Claude Code, tmux, and remote access are all set. There's nothing to install — your canvas is waiting.", false)]),
                readyLine(),
            ])
            col.setCustomSpacing(18, after: mark)
            return col
        }
        let col = stepColumn([
            mark,
            wizardTitle("A quiet place for your agents.", large: true),
            wizardBody([
                ("Spawn coding agents into folders and watch them on one infinite canvas. ", false),
                ("Zoom out to see them all — the one that needs you will glow.", true),
                (" Three quick things first.", false),
            ]),
        ])
        col.setCustomSpacing(18, after: mark)
        return col
    }

    private func claudeStep() -> NSView {
        // The official installer — a copyable command, same gesture as tmux's.
        let chip = CopyChip(command: "curl -fsSL https://claude.ai/install.sh | bash", large: true)
        let watching = WatchingRow(color: Theme.colors.statusBlocked)
        watching.isHidden = !reaching.contains(.claude) || escalated.contains(.claude)
        chip.onActivate = { [weak self, weak watching] in
            self?.beginWatching(.claude)
            watching?.reveal()
        }
        // Title names the stake, not the state — the same grammar as tmux's
        // "Agents stop when you quit the app."
        var rows: [NSView] = [
            FlagPill(word: "Required", color: Theme.colors.statusBlocked),
            wizardTitle("Nothing to supervise yet.", large: false),
            wizardBody([
                ("Every card is a live ", false), ("Claude Code", true),
                (" agent in a folder you choose. Installing it is one command:", false),
            ]),
            actionsRow([chip]),
            terminalHint(),
            watching,
        ]
        if escalated.contains(.claude) {
            rows.append(escalationView(
                color: Theme.colors.statusBlocked,
                text: "Still watching. If Terminal shows an error, the install didn't land.",
                help: ("Open the install page", URL(string: "https://claude.com/claude-code")!)))
        }
        return stepColumn(rows)
    }

    private func tmuxStep() -> NSView {
        // `brew install tmux` is only a real offer when Homebrew exists —
        // otherwise it's a guaranteed Terminal error, so the step sends the
        // user to Homebrew first and swaps to the command once the probe
        // finds brew.
        let action: Chip
        var caption: NSTextField?
        if report.brewFound {
            action = CopyChip(command: "brew install tmux", large: true)
        } else {
            action = LinkChip(title: "Get Homebrew",
                              url: URL(string: "https://brew.sh")!,
                              large: true, tint: Theme.colors.statusStalled)
            caption = wizardBody([
                ("tmux installs through ", false), ("Homebrew", true),
                (", which isn't on this Mac yet. Install it first; this step picks up from there.", false),
            ], size: 12)
        }
        let watching = WatchingRow(color: Theme.colors.statusStalled)
        watching.isHidden = !reaching.contains(.tmux) || escalated.contains(.tmux)
        action.onActivate = { [weak self, weak watching] in
            self?.beginWatching(.tmux)
            watching?.reveal()
        }
        var rows: [NSView] = [
            FlagPill(word: "Recommended", color: Theme.colors.statusStalled),
            wizardTitle("Agents stop when you quit the app.", large: false),
            wizardBody([
                ("With ", false), ("tmux", true),
                (", they keep working through restarts and crashes — the canvas becomes a window onto them, not their life support.", false),
            ]),
        ]
        if let caption { rows.append(caption) }
        rows.append(actionsRow([action]))
        if report.brewFound { rows.append(terminalHint()) }
        rows.append(watching)
        if escalated.contains(.tmux) {
            rows.append(escalationView(
                color: Theme.colors.statusStalled,
                text: report.brewFound
                    ? "Still watching. Homebrew can take a few minutes; an error in Terminal means it didn't land."
                    : "Still watching for Homebrew. Its installer takes a few minutes in Terminal."))
        }
        return stepColumn(rows)
    }

    private func tailscaleStep() -> NSView {
        let serving = report.tailscaleFound && report.tailscaleServing
        if serving { return tailscaleReward() }

        let action: Chip?
        let caption: NSTextField
        if report.tailscaleFound {
            if remotePanelPort == 0 {
                // The remote server hasn't bound yet — a copyable command now
                // would read `localhost:0`. Hold the chip; watchForPortBind
                // rebuilds this step with the real port the moment it exists.
                action = nil
                caption = wizardBody([
                    ("Installed. The remote panel is still starting up; the serve command appears here in a moment.", false),
                ], size: 12)
                watchForPortBind()
            } else {
                action = CopyChip(command: serveCommand, large: true)
                caption = wizardBody([
                    ("Installed. Now ", false), ("serve the page", true),
                    (" over your tailnet: run the filled-in command in Terminal.", false),
                ], size: 12)
            }
        } else {
            action = LinkChip(title: "Get Tailscale",
                              url: URL(string: "https://tailscale.com/download")!,
                              large: true, tint: Theme.colors.statusIdle)
            caption = wizardBody([("First, install Tailscale on this Mac.", false)], size: 12)
        }
        caption.preferredMaxLayoutWidth = 230   // the column beside the phone
        let watching = WatchingRow(color: Theme.colors.statusIdle)
        watching.isHidden = !reaching.contains(.tailscale) || escalated.contains(.tailscale)
        action?.onActivate = { [weak self, weak watching] in
            self?.beginWatching(.tailscale)
            watching?.reveal()
        }

        let peek = NSStackView(views: [PhonePeekView(), caption])
        peek.orientation = .horizontal
        peek.alignment = .centerY
        peek.spacing = 16

        var rows: [NSView] = [
            FlagPill(word: "Optional", color: Theme.colors.statusIdle),
            wizardTitle("Your fleet, from anywhere.", large: false),
            wizardBody([
                ("The canvas serves a phone-sized supervision page — fleet statuses, the live feed, and ", false),
                ("Allow / Deny", true), (" for agents waiting on you.", false),
            ]),
            peek,
        ]
        if let action { rows.append(actionsRow([action])) }
        rows.append(watching)
        if escalated.contains(.tailscale) {
            rows.append(escalationView(
                color: Theme.colors.statusIdle,
                text: report.tailscaleFound
                    ? "Still watching. Check that Tailscale is running and signed in, then run the command again."
                    : "Still watching. Finish the Tailscale install and sign in; this step notices on its own."))
        }
        let col = stepColumn(rows)
        col.setCustomSpacing(16, after: peek)
        return col
    }

    /// The payoff: the panel is live on the tailnet — QR straight to the phone.
    private func tailscaleReward() -> NSView {
        let url = report.tailnetURL ?? "https://…"
        let col = stepColumn([
            FlagPill(word: "Live", color: Theme.colors.statusDone),
            wizardTitle("Your fleet is on your phone.", large: false),
            RewardPanel(url: url),
            warnLine(),
        ])
        return col
    }

    private func exitStep() -> NSView {
        // The button carries the spawn verb (same label and action as the
        // ready-welcome's primary), so the title states the arrival instead
        // of repeating the instruction.
        stepColumn([
            eyebrow("All set"),
            wizardTitle("Your canvas is ready.", large: true),
            wizardBody([("Pick a folder and a Claude Code agent appears on the canvas. The dialog closes as your first card lands.", false)]),
        ])
    }

    // MARK: Step furniture

    private func stepColumn(_ views: [NSView]) -> NSStackView {
        let col = NSStackView(views: views)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 9
        for v in views {
            if v is FlagPill { col.setCustomSpacing(14, after: v) }
            if v is WatchingRow { /* last row */ }
        }
        // Actions sit a bit lower than prose; watching a bit below actions.
        for (i, v) in views.enumerated() where v is NSStackView && i > 0 {
            col.setCustomSpacing(18, after: views[i - 1])
        }
        return col
    }

    private func actionsRow(_ chips: [NSView]) -> NSStackView {
        let row = NSStackView(views: chips)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    /// Names the gesture between "copied" and "watching for it…" — without
    /// this line, a first-timer copies the command and stalls, never told the
    /// destination is Terminal or that no verify step follows.
    private func terminalHint() -> NSTextField {
        wizardBody([("Paste it into Terminal. This step completes itself when the install lands.", false)], size: 12)
    }

    /// The honest follow-up when a watch outlasts a normal install: name the
    /// likely snag and the next move. Replaces the "watching for it…" row
    /// (probes keep running — a late success still completes the step), so the
    /// dot keeps pulsing while the text steps up from muted to primary.
    private func escalationView(color: NSColor, text: String,
                                help: (title: String, url: URL)? = nil) -> NSView {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.shadowColor = color.cgColor
        dot.layer?.shadowOffset = .zero
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOpacity = 0.9
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35
            a.duration = 0.75; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = Theme.motion.softEase
            dot.layer?.add(a, forKey: "pulse")
        }
        // The dot rides a fixed holder so it centers on the label's first line.
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(dot)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.fonts.ui(12)
        label.textColor = Theme.colors.textPrimary
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        label.preferredMaxLayoutWidth = 330

        let row = NSStackView(views: [holder, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 9
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 8),
            holder.heightAnchor.constraint(equalToConstant: 16),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        guard let help else { return row }

        let chip = LinkChip(title: help.title, url: help.url, tint: color)
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 8).isActive = true
        let chipRow = NSStackView(views: [indent, chip])
        chipRow.orientation = .horizontal
        chipRow.spacing = 9

        let col = NSStackView(views: [row, chipRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        return col
    }

    /// Large = the empty-state headline's voice; regular = the app's item-title
    /// role. Semibold throughout — Hanken's bold renders a step heavier than it
    /// should and shouts.
    private func wizardTitle(_ text: String, large: Bool) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = large ? Theme.fonts.ui(22, .semibold) : Theme.fonts.itemTitle
        l.textColor = Theme.colors.textPrimary
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        l.preferredMaxLayoutWidth = 370
        return l
    }

    /// Body copy: muted with emphasized runs in the text color (the design's
    /// `<b>` inside `.ob-body`). 14pt — the empty state's body voice.
    private func wizardBody(_ segments: [(String, Bool)], size: CGFloat = 14) -> NSTextField {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3.5
        let s = NSMutableAttributedString()
        for (text, bold) in segments {
            s.append(NSAttributedString(string: text, attributes: [
                .font: Theme.fonts.ui(size, bold ? .semibold : .regular),
                .foregroundColor: bold ? Theme.colors.textPrimary : Theme.colors.textMuted,
                .paragraphStyle: para,
            ]))
        }
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = s
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        l.preferredMaxLayoutWidth = 360
        return l
    }

    private func eyebrow(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.fonts.mono(10, .semibold),   // the readiness panel's header voice
            .foregroundColor: Theme.colors.textMuted,
            .kern: 1.7,
        ])
        return l
    }

    private func readyLine() -> NSView {
        let dot = BeadView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        dot.set(color: Theme.colors.statusDone, glow: true, pulse: .none)
        let l = NSTextField(labelWithString: "claude · tmux · tailscale — all detected")
        l.font = Theme.fonts.mono(12.5)
        l.textColor = Theme.colors.textMuted
        let row = NSStackView(views: [dot, l])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// The security boundary, in the warn voice it deserves: a tinted callout
    /// in the severity grammar (ochre tint + full border, the FlagPill's
    /// language at panel scale), not a footnote. "Calm by default" must not
    /// quiet the one sentence on this step that protects the machine.
    private func warnLine() -> NSView {
        let color = Theme.colors.statusStalled
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Security")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = color
        icon.translatesAutoresizingMaskIntoConstraints = false

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2.5
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Never expose this page publicly.", attributes: [
            .font: Theme.fonts.ui(11.5, .semibold),
            .foregroundColor: Theme.colors.textPrimary,
            .paragraphStyle: para,
        ]))
        text.append(NSAttributedString(string: " The Allow button approves commands on this Mac. Tailscale serve keeps it tailnet-only.", attributes: [
            .font: Theme.fonts.ui(11.5),
            .foregroundColor: Theme.colors.glyph,
            .paragraphStyle: para,
        ]))
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        label.preferredMaxLayoutWidth = 320

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        // Frozen layer colors are fine here: the dialog rebuilds every step
        // view on appearance change.
        let callout = NSView()
        callout.wantsLayer = true
        callout.layer?.cornerRadius = 9
        callout.layer?.borderWidth = 1
        callout.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        callout.layer?.borderColor = color.withAlphaComponent(0.28).cgColor
        callout.translatesAutoresizingMaskIntoConstraints = false
        callout.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: callout.topAnchor),
            row.bottomAnchor.constraint(equalTo: callout.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: callout.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: callout.trailingAnchor),
        ])
        return callout
    }
}

// MARK: - Brand mark

/// The actual app icon (bundled `AppIcon.png` — the committed iconset's 256px
/// face), not a stand-in tile: the wizard introduces the app, so it wears the
/// app's real mark. The icon ships with macOS's squircle margins baked in, so
/// it's slightly oversized to read at the intended optical size.
final class BrandMarkView: NSImageView {
    init(size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") {
            image = NSImage(contentsOf: url)
        } else {
            image = NSApp.applicationIconImage   // packaged builds carry the icns
        }
        imageScaling = .scaleProportionallyUpOrDown
        let oversize = size * 1.18   // compensate the squircle's transparent margins
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: oversize),
            heightAnchor.constraint(equalToConstant: oversize),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Flag pill

/// The severity word above a step title — REQUIRED / RECOMMENDED / OPTIONAL /
/// LIVE — in the status color it speaks for.
final class FlagPill: NSView {
    private let color: NSColor
    private let dot = NSView()

    init(word: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.masksToBounds = false

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: word.uppercased(), attributes: [
            .font: Theme.fonts.mono(10, .semibold),   // same voice as the panel headers
            .foregroundColor: color,
            .kern: 1.0,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        layer?.borderColor = color.withAlphaComponent(0.35).cgColor
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.shadowColor = color.cgColor
        dot.layer?.shadowOffset = .zero
        dot.layer?.shadowRadius = 3.5
        dot.layer?.shadowOpacity = 1
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }
}

// MARK: - Watching row

/// "watching for it…" — a pulsing severity dot. Appears once the user has
/// clicked the step's install action; the probe (re-run on app activation)
/// completes the step, so this row never needs a Verify button.
final class WatchingRow: NSView {
    private let dot = NSView()

    init(color: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.shadowColor = color.cgColor
        dot.layer?.shadowOffset = .zero
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOpacity = 0.9

        let label = NSTextField(labelWithString: "watching for it…")
        label.font = Theme.fonts.mono(11)
        label.textColor = Theme.colors.textMuted
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        startPulse()
    }
    required init?(coder: NSCoder) { fatalError() }

    func reveal() {
        guard isHidden else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isHidden = false
        } else {
            alphaValue = 0
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                animator().alphaValue = 1
            }
        }
        startPulse()
    }

    private func startPulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        dot.layer?.removeAnimation(forKey: "pulse")
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0.35
        a.duration = 0.75; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = Theme.motion.softEase
        dot.layer?.add(a, forKey: "pulse")
    }
}

// MARK: - Reward panel (QR + URL)

/// The tailscale payoff: a dark tile holding the QR (scan → fleet on the phone)
/// and the live tailnet URL.
final class RewardPanel: NSView {
    init(url: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1

        // QR on a paper tile so phone cameras lock on instantly.
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 9
        tile.layer?.backgroundColor = Theme.colors.qrPaper.cgColor
        let qr = NSImageView()
        qr.image = Self.qrImage(url)
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(qr)

        let urlLabel = NSTextField(wrappingLabelWithString: url)
        urlLabel.font = Theme.fonts.mono(12)
        urlLabel.textColor = Theme.colors.statusRunning
        urlLabel.isEditable = false; urlLabel.isBordered = false; urlLabel.drawsBackground = false
        urlLabel.preferredMaxLayoutWidth = 220

        let live = NSView()
        live.translatesAutoresizingMaskIntoConstraints = false
        live.wantsLayer = true
        live.layer?.cornerRadius = 3.5
        live.layer?.backgroundColor = Theme.colors.statusDone.cgColor
        live.layer?.shadowColor = Theme.colors.statusDone.cgColor
        live.layer?.shadowOffset = .zero
        live.layer?.shadowRadius = 4
        live.layer?.shadowOpacity = 0.9

        let sub = NSTextField(labelWithString: "serving · tailnet only")
        sub.font = Theme.fonts.mono(10.5)
        sub.textColor = Theme.colors.textMuted

        let subRow = NSStackView(views: [live, sub])
        subRow.orientation = .horizontal
        subRow.alignment = .centerY
        subRow.spacing = 6

        let right = NSStackView(views: [urlLabel, subRow])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6

        let row = NSStackView(views: [tile, right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 104),
            tile.heightAnchor.constraint(equalToConstant: 104),
            qr.topAnchor.constraint(equalTo: tile.topAnchor, constant: 9),
            qr.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -9),
            qr.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 9),
            qr.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -9),
            live.widthAnchor.constraint(equalToConstant: 7),
            live.heightAnchor.constraint(equalToConstant: 7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        layer?.backgroundColor = Theme.colors.terminalBg.cgColor
        layer?.borderColor = Theme.colors.borderSoft.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    /// A real QR for the tailnet URL — dark modules on the warm tile.
    private static func qrImage(_ string: String) -> NSImage? {
        guard let generator = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        generator.setValue(Data(string.utf8), forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard var image = generator.outputImage else { return nil }
        if let tint = CIFilter(name: "CIFalseColor"),
           let ink = CIColor(color: Theme.colors.qrInk),
           let paper = CIColor(color: Theme.colors.qrPaper) {
            tint.setValue(image, forKey: "inputImage")
            tint.setValue(ink, forKey: "inputColor0")
            tint.setValue(paper, forKey: "inputColor1")
            image = tint.outputImage ?? image
        }
        image = image.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: image)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}

// MARK: - Phone peek

/// A miniature of the remote supervision page — a static illustration drawn in
/// the app's own status palette (draw-time NSColor resolution keeps it
/// appearance-adaptive for free).
final class PhonePeekView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 116),
            heightAnchor.constraint(equalToConstant: 232),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The illustration depicts the remote page, which is always dark — so it
    /// resolves every theme token under forced dark appearance regardless of
    /// the system mode (no hand-frozen colors, no light-mode wash-out).
    override func draw(_ dirtyRect: NSRect) {
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { drawPhone() }
    }

    private func drawPhone() {
        let bezel = Theme.colors.border

        // Body + screen
        let body = NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20)
        bezel.setFill()
        body.fill()
        let screenRect = bounds.insetBy(dx: 5, dy: 5)
        let screen = NSBezierPath(roundedRect: screenRect, xRadius: 15, yRadius: 15)
        Theme.colors.canvasBackground.setFill()
        screen.fill()

        // Notch
        let notch = NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: screenRect.minY + 6, width: 36, height: 5),
                                 xRadius: 2.5, yRadius: 2.5)
        bezel.setFill()
        notch.fill()

        let left = screenRect.minX + 9
        let width = screenRect.width - 18
        var y = screenRect.minY + 20

        // Title — the count matches the rows drawn ("the status never lies",
        // even inside an illustration).
        ("Fleet · 4 agents" as NSString).draw(at: NSPoint(x: left + 2, y: y), withAttributes: [
            .font: Theme.fonts.ui(8, .bold),
            .foregroundColor: Theme.colors.textPrimary,
        ])
        y += 16

        // Fleet rows — first one loud (the page's whole point in one glance).
        let rows: [(NSColor, String, Bool)] = [
            (Theme.colors.statusBlocked, "auth-service", true),
            (Theme.colors.statusRunning, "api-gateway", false),
            (Theme.colors.statusDone, "payments", false),
            (Theme.colors.statusIdle, "docs-site", false),
        ]
        for (color, name, loud) in rows {
            let rect = NSRect(x: left, y: y, width: width, height: 22)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            if loud {
                Theme.colors.statusBlocked.withAlphaComponent(0.16).setFill()
                path.fill()
                Theme.colors.statusBlocked.withAlphaComponent(0.55).setStroke()
            } else {
                Theme.colors.itemBody.setFill()
                path.fill()
                Theme.colors.borderSoft.setStroke()
            }
            path.lineWidth = 1
            path.stroke()

            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 7, y: rect.midY - 3, width: 6, height: 6)).fill()
            (name as NSString).draw(at: NSPoint(x: rect.minX + 18, y: rect.midY - 5), withAttributes: [
                .font: Theme.fonts.mono(6.5),
                .foregroundColor: Theme.colors.textPrimary,
            ])
            y += 28
        }

        // Allow / Deny
        let btnY = screenRect.maxY - 26
        let btnW = (width - 5) / 2
        let allowRect = NSRect(x: left, y: btnY, width: btnW, height: 17)
        let denyRect = NSRect(x: left + btnW + 5, y: btnY, width: btnW, height: 17)
        Theme.colors.statusDone.setFill()
        NSBezierPath(roundedRect: allowRect, xRadius: 6, yRadius: 6).fill()
        Theme.colors.itemBar.setFill()
        let deny = NSBezierPath(roundedRect: denyRect, xRadius: 6, yRadius: 6)
        deny.fill()
        Theme.colors.border.setStroke()
        deny.lineWidth = 1
        deny.stroke()
        let btnFont = Theme.fonts.ui(7, .bold)
        let allowText = "Allow" as NSString
        let denyText = "Deny" as NSString
        let allowSize = allowText.size(withAttributes: [.font: btnFont])
        let denySize = denyText.size(withAttributes: [.font: btnFont])
        allowText.draw(at: NSPoint(x: allowRect.midX - allowSize.width / 2, y: allowRect.midY - allowSize.height / 2),
                       withAttributes: [.font: btnFont, .foregroundColor: Theme.colors.primaryInk])
        denyText.draw(at: NSPoint(x: denyRect.midX - denySize.width / 2, y: denyRect.midY - denySize.height / 2),
                      withAttributes: [.font: btnFont, .foregroundColor: Theme.colors.textMuted])
    }
}

// MARK: - Buttons

/// The footer's button vocabulary: filled primary (with optional ⌘N keycap or
/// trailing arrow) and the bare text link — forward motion and quiet escape.
final class WizardButton: NSView {
    enum Style { case primary, link }

    private let style: Style
    private let action: () -> Void
    private let label = NSTextField(labelWithString: "")
    private var kbdChip: NSTextField?
    private var arrowIcon: NSImageView?
    private var hovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?

    init(title: String, style: Style, kbd: String? = nil, arrow: Bool = false, action: @escaping () -> Void) {
        self.style = style
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.stringValue = title
        var views: [NSView] = [label]

        if let kbd {
            let chip = NSTextField(labelWithString: " \(kbd) ")
            chip.font = Theme.fonts.mono(12)
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 5
            kbdChip = chip
            views.append(chip)
        }
        if arrow {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            arrowIcon = icon
            views.append(icon)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        switch style {
        case .primary:
            label.font = Theme.fonts.ui(14, .semibold)
            layer?.cornerRadius = 9
            heightAnchor.constraint(equalToConstant: 42).isActive = true
            pin(row, hPad: 20)
        case .link:
            label.font = Theme.fonts.ui(12.5, .medium)
            pin(row, hPad: 4, vPad: 6)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func pin(_ row: NSView, hPad: CGFloat, vPad: CGFloat = 0) {
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: vPad),
        ])
    }

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
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    /// The one activation path — mouse, Space/Return, assistive press, and the
    /// dialog's Return-fires-the-primary all land here.
    func press() { action() }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        let r: CGFloat = style == .primary ? 9 : 6
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { press() }   // space / return
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func refresh() {
        switch style {
        case .primary:
            layer?.backgroundColor = (hovering ? Theme.colors.primaryHover : Theme.colors.primary).cgColor
            label.textColor = Theme.colors.primaryInk
            kbdChip?.textColor = Theme.colors.primaryInk
            kbdChip?.layer?.backgroundColor = Theme.colors.primaryKeycap.cgColor
            arrowIcon?.contentTintColor = Theme.colors.primaryInk
        case .link:
            label.textColor = hovering ? Theme.colors.textPrimary : Theme.colors.textMuted
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { refresh() }
    }
}
