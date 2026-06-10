import AppKit

/// The first-run wizard (design handoff: "Beads") — a fixed-frame dialog over a
/// dimmed canvas. Three header beads carry progress in the app's own status
/// language; steps slide inside a stable content well; claude/tmux complete
/// themselves when the environment probe finds them (installing IS the
/// completion), tailscale rewards with the QR and waits for Continue.
///
/// Severity decides the buttons: claude gates (no per-step skip), tmux warns
/// (visible skip + cost line), tailscale invites (prominent skip). One word,
/// one meaning: "Skip for now" always advances past this step; "Exit setup"
/// (links, ×, Esc) always leaves the whole wizard for the empty state's
/// readiness rows. Every exit is deliberate; a scrim click only pulses the
/// dialog (one stray click must never bury the wizard behind the once-ever
/// completed flag).
enum WizardStep: Int, CaseIterable {
    case welcome, claude, tmux, tailscale, exit
}

// MARK: - Overlay (scrim + centering)

/// Hosts the scrim and centers the dialog over the whole canvas view. The scrim
/// blocks interaction with the canvas (events stop at it); clicking it pulses
/// the dialog instead of dismissing — the sheet convention.
final class OnboardingOverlayView: NSView {
    let dialog: OnboardingDialogView
    private let scrim = ScrimView()

    init(dialog: OnboardingDialogView) {
        self.dialog = dialog
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.onClick = { [weak dialog] in dialog?.pulseForAttention() }
        addSubview(scrim)
        addSubview(dialog)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dialog.centerXAnchor.constraint(equalTo: centerXAnchor),
            dialog.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Fade in on presentation (single shared fade — the dialog rides along).
    func present() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Theme.motion.softEase
            animator().alphaValue = 1
        }
    }

    /// One shared exit: overlay fade + the dialog's settle-down transform.
    func dismissAnimated(completion: @escaping () -> Void) {
        dialog.playExitTransform()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Theme.motion.softEase
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            completion()
        })
    }
}

/// The dim layer behind the dialog. Swallows clicks (the dialog pulses; only
/// ×, Esc, and the skip links dismiss) and, by sitting over the scroll view,
/// naturally blocks canvas scroll/zoom while the wizard is up.
private final class ScrimView: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func applyColors() {
        layer?.backgroundColor = Theme.colors.dialogScrim.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Dialog

final class OnboardingDialogView: NSView {
    /// `firstRun` walks all steps; `remoteOnly` is the "Set Up Remote Access…"
    /// re-entry — just the tailscale chapter, no beads, Done/Maybe-later exits.
    enum Mode { case firstRun, remoteOnly }

    /// Leave the wizard (×, scrim, skip-setup links, Later, remoteOnly's exits).
    var onDismiss: (() -> Void)?
    /// The exit-step primary — the dialog's dismissal and ⌘N are the same event.
    var onChooseFolder: (() -> Void)?

    private let mode: Mode
    /// Read lazily — the remote server binds asynchronously at launch, so the
    /// port may not exist yet when the dialog is created.
    private let remotePort: () -> UInt16
    private(set) var report: Readiness.Report
    private(set) var step: WizardStep
    private var skipped = Set<WizardStep>()
    /// Steps whose install action was clicked — show "watching for it…".
    var reaching = Set<WizardStep>()
    private var autoAdvanced = Set<WizardStep>()
    /// Distinguishes the tailscale stations so apply() only rebuilds on change.
    private var renderedSignature = ""
    /// Steps whose watch has outlasted a normal install — the row escalates to
    /// a named likely snag instead of pulsing forever (an eternal "watching
    /// for it…" over a failed curl would be the wizard lying by omission).
    private(set) var escalated = Set<WizardStep>()
    private var watchStarted: [WizardStep: Date] = [:]
    private var watchTimer: Timer?
    private var portTimer: Timer?
    /// Wired by the controller: ask for a fresh readiness probe (the result
    /// arrives through `apply`). Lets the wizard poll while the user works in
    /// Terminal beside it — completion must not require an app switch.
    var onRequestProbe: (() -> Void)?
    private weak var primaryButton: WizardButton?

    private static let probeInterval: TimeInterval = 4
    private static let escalateAfter: TimeInterval = 60

    private let wellHost = NSView()
    private let footerHost = NSView()
    private let beadRow = NSStackView()
    private var beads: [WizardStep: WizardBeadView] = [:]
    /// The three bead chapters, in header order.
    private static let chapters: [WizardStep] = [.claude, .tmux, .tailscale]

    init(mode: Mode, report: Readiness.Report, remotePort: @escaping () -> UInt16) {
        self.mode = mode
        self.report = report
        self.remotePort = remotePort
        self.step = mode == .remoteOnly ? .tailscale : .welcome
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        layer?.shadowRadius = 30

        buildChrome()
        applyColors()
        render(slide: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    var serveCommand: String { "tailscale serve --bg localhost:\(remotePort())" }
    /// Exposed for the step builders: 0 means the remote server hasn't bound
    /// yet, and the serve command would be a dead `localhost:0`.
    var remotePanelPort: UInt16 { remotePort() }

    // MARK: Probe results

    /// New probe results (presentation, then every app activation). Beads update
    /// immediately; content rebuilds only when what it shows actually changed
    /// (welcome's ready variant, tailscale's stations); a freshly-satisfied
    /// claude/tmux step pauses a beat, then advances itself.
    func apply(_ newReport: Readiness.Report) {
        guard newReport != report else { return }
        report = newReport
        for s in reaching where satisfied(s) {
            reaching.remove(s)
            escalated.remove(s)
            watchStarted[s] = nil
        }
        stopWatchingIfIdle()
        updateBeads()
        if contentSignature() != renderedSignature { render(slide: true) }
        scheduleAutoAdvance()
    }

    func satisfied(_ s: WizardStep) -> Bool {
        switch s {
        case .claude: return report.claudeFound
        case .tmux: return report.tmuxFound || skipped.contains(.tmux)
        case .tailscale: return (report.tailscaleFound && report.tailscaleServing) || skipped.contains(.tailscale)
        default: return true
        }
    }

    // MARK: Watching

    /// An install action was fired: remember it ("watching for it…" shows) and
    /// start polling the environment. Activation probes still run, but the user
    /// working in Terminal *beside* the canvas would otherwise never trigger
    /// one — the watch must be real, not contingent on an app switch.
    func beginWatching(_ s: WizardStep) {
        reaching.insert(s)
        if watchStarted[s] == nil { watchStarted[s] = Date() }
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
            self?.watchTick()
        }
    }

    private func watchTick() {
        onRequestProbe?()
        var changedCurrent = false
        for s in reaching where !satisfied(s) && !escalated.contains(s) {
            guard let started = watchStarted[s],
                  Date().timeIntervalSince(started) > Self.escalateAfter else { continue }
            escalated.insert(s)
            if s == step { changedCurrent = true }
        }
        if changedCurrent, contentSignature() != renderedSignature { render(slide: true) }
        stopWatchingIfIdle()
    }

    private func stopWatchingIfIdle() {
        guard reaching.allSatisfy({ satisfied($0) }) else { return }
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// The remote server binds asynchronously at launch; until it has, the
    /// serve command would read `localhost:0`. Watch briefly for the bind and
    /// rebuild the step with the real command — never hand out a dead port.
    func watchForPortBind() {
        guard portTimer == nil, remotePort() == 0 else { return }
        var ticks = 0
        portTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            guard self.remotePort() != 0 || ticks > 60 else { return }
            t.invalidate()
            self.portTimer = nil
            if self.contentSignature() != self.renderedSignature { self.render(slide: true) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            watchTimer?.invalidate(); watchTimer = nil
            portTimer?.invalidate(); portTimer = nil
        }
    }

    // MARK: Navigation

    func advance() {
        guard mode == .firstRun else { onDismiss?(); return }
        var next = step.rawValue + 1
        // Skip steps the machine already satisfies — never show "isn't
        // installed" for something that is. A serving tailscale still shows
        // (the reward is worth seeing); a *skipped* one doesn't resurface.
        while let s = WizardStep(rawValue: next), s != .exit {
            let alreadyFine = (s == .claude && report.claudeFound)
                || (s == .tmux && (report.tmuxFound || skipped.contains(.tmux)))
                || (s == .tailscale && skipped.contains(.tailscale))
            if !alreadyFine { break }
            next += 1
        }
        setStep(WizardStep(rawValue: next) ?? .exit)
    }

    func skip(_ s: WizardStep) {
        skipped.insert(s)
        advance()
    }

    func setStep(_ s: WizardStep) {
        guard s != step else { return }
        step = s
        render(slide: true)
        scheduleAutoAdvance()
        // The whole content well just swapped (auto-advance does it unprompted)
        // — say so, or a screen-reader user is silently teleported.
        if mode == .firstRun {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: progressDescription(),
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// claude/tmux complete themselves: ~650ms after the probe finds the tool
    /// (long enough to watch the bead turn), the well slides forward on its own.
    private func scheduleAutoAdvance() {
        guard mode == .firstRun, step == .claude || step == .tmux,
              satisfied(step), !autoAdvanced.contains(step) else { return }
        autoAdvanced.insert(step)
        let s = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.step == s else { return }
            self.advance()
        }
    }

    // MARK: Chrome

    private let separator = NSView()

    private func buildChrome() {
        // Header: wordmark + beads ··· × — no icon up here; the welcome step
        // already carries the mark, and once wouldn't be true twice.
        let word = NSTextField(labelWithString: "Agent Canvas")
        word.font = Theme.fonts.ui(13.5, .semibold)
        word.textColor = Theme.colors.textPrimary

        beadRow.orientation = .horizontal
        beadRow.spacing = 7
        for s in Self.chapters {
            let bead = WizardBeadView(color: Self.severityColor(s))
            bead.toolTip = Self.chapterName(s)
            beads[s] = bead
            beadRow.addArrangedSubview(bead)
        }
        beadRow.isHidden = mode == .remoteOnly
        beadRow.setAccessibilityRole(.progressIndicator)
        beadRow.setAccessibilityLabel("Setup progress")

        let close = WizardCloseButton { [weak self] in self?.onDismiss?() }

        let header = NSStackView(views: [word, beadRow, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 16)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true

        header.translatesAutoresizingMaskIntoConstraints = false
        wellHost.translatesAutoresizingMaskIntoConstraints = false
        footerHost.translatesAutoresizingMaskIntoConstraints = false

        // Sections pinned edge-to-edge explicitly — the hosts have no intrinsic
        // width, and a stack's `.width` alignment left their x under-constrained
        // (the well drifted right). Nothing here is left to ambiguity.
        addSubview(header)
        addSubview(separator)
        addSubview(wellHost)
        addSubview(footerHost)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 432),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            wellHost.topAnchor.constraint(equalTo: separator.bottomAnchor),
            wellHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            wellHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            wellHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 268),
            footerHost.topAnchor.constraint(equalTo: wellHost.bottomAnchor),
            footerHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBeads()
    }

    static func severityColor(_ s: WizardStep) -> NSColor {
        switch s {
        case .claude: return Theme.colors.statusBlocked    // gates
        case .tmux: return Theme.colors.statusStalled      // warns
        default: return Theme.colors.statusIdle            // invites
        }
    }

    static func chapterName(_ s: WizardStep) -> String {
        switch s {
        case .claude: return "Claude Code"
        case .tmux: return "tmux"
        default: return "Remote access"
        }
    }

    /// "Step 2 of 3" while walking the chapters; bookends for welcome/exit.
    private func progressDescription() -> String {
        if let i = Self.chapters.firstIndex(of: step) { return "Step \(i + 1) of 3" }
        return step == .exit ? "Setup complete" : "3 steps"
    }

    private func updateBeads() {
        for (s, bead) in beads {
            let state: WizardBeadView.State
            if satisfied(s) && step != s { state = .done }
            else if step == s { state = satisfied(s) ? .done : .current }
            else if s.rawValue < step.rawValue { state = .done }
            else { state = .pending }
            bead.set(state)
        }
        beadRow.setAccessibilityValue(progressDescription())
    }

    // MARK: Rendering

    /// What the current step's content depends on — rebuild only when it moves.
    private func contentSignature() -> String {
        switch step {
        case .welcome: return "welcome-\(report.machineReady)"
        case .claude: return "claude-\(escalated.contains(.claude))"
        case .tmux: return "tmux-\(report.brewFound)-\(escalated.contains(.tmux))"
        case .tailscale:
            if satisfied(.tailscale) && !skipped.contains(.tailscale) { return "ts-reward" }
            if report.tailscaleFound {
                return "ts-serve-\(remotePort() != 0)-\(escalated.contains(.tailscale))"
            }
            return "ts-install-\(escalated.contains(.tailscale))"
        default: return "step-\(step.rawValue)"
        }
    }

    private func render(slide: Bool) {
        renderedSignature = contentSignature()
        // Footer rides the same slide as the content — the step arrives as one
        // piece, never a snapped row under gliding prose.
        setHosted(buildStepView(), in: wellHost,
                  insets: NSEdgeInsets(top: 26, left: 24, bottom: 8, right: 24),
                  slide: slide, exactBottom: false)
        setHosted(buildFooterView(), in: footerHost,
                  insets: NSEdgeInsets(top: 16, left: 24, bottom: 20, right: 24),
                  slide: slide, exactBottom: true)
        updateBeads()
        // Steps differ in height (the tailscale chapter is tall); glide the
        // frame change instead of letting the dialog jump.
        if slide, superview != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = Theme.motion.softEase
                ctx.allowsImplicitAnimation = true
                superview?.layoutSubtreeIfNeeded()
            }
        }
    }

    /// Entrance is transform-only (a 13px settle) so the resting state is always
    /// fully visible — per the prototype's visible-end-state fix.
    /// `exactBottom: false` lets the host grow past its content (the well's 268
    /// floor) while a high-priority snug constraint keeps it hugging otherwise.
    private func setHosted(_ v: NSView, in host: NSView, insets: NSEdgeInsets,
                           slide: Bool, exactBottom: Bool) {
        host.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        let bottom = v.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -insets.bottom)
        if !exactBottom { bottom.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: host.topAnchor, constant: insets.top),
            v.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -insets.bottom),
            bottom,
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: insets.left),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -insets.right),
        ])
        if slide, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            host.layoutSubtreeIfNeeded()
            v.wantsLayer = true
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = 13
            a.toValue = 0
            a.duration = 0.22
            a.timingFunction = Theme.motion.softEase
            v.layer?.add(a, forKey: "stepin")
        }
    }

    /// A scrim click lands here: acknowledge without dismissing — a centered
    /// scale pulse (the sheet convention); a border flash under reduced motion
    /// so the cue survives without movement.
    func pulseForAttention() {
        guard let layer else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let flash = CABasicAnimation(keyPath: "borderColor")
            flash.fromValue = Theme.colors.textMuted.cgColor
            flash.toValue = Theme.colors.border.cgColor
            flash.duration = 0.4
            layer.add(flash, forKey: "attention")
            return
        }
        func centered(_ scale: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [CATransform3DIdentity, centered(1.018), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        a.keyTimes = [0, 0.4, 1]
        a.duration = 0.28
        a.timingFunction = Theme.motion.softEase
        layer.add(a, forKey: "attention")
    }

    /// The dialog's half of the shared exit fade: a slight settle-down.
    func playExitTransform() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let scale = CABasicAnimation(keyPath: "transform")
        var t = CATransform3DMakeScale(0.975, 0.975, 1)
        t = CATransform3DTranslate(t, 0, -6, 0)
        scale.toValue = NSValue(caTransform3D: t)
        scale.duration = 0.3
        scale.timingFunction = Theme.motion.softEase
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer.add(scale, forKey: "exit")
    }

    // MARK: Colors

    private func applyColors() {
        layer?.backgroundColor = Theme.colors.itemBody.cgColor
        layer?.borderColor = Theme.colors.border.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.55
        separator.layer?.backgroundColor = Theme.colors.borderSoft.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
        render(slide: false)   // step views carry frozen layer colors; rebuild in the new appearance
    }

    // MARK: Footers

    /// One footer grammar, every step: the LEFT slot is forward motion (or the
    /// status line explaining why there isn't any); the RIGHT corner is the
    /// step's single quiet escape, as a link — except the claude gate, which
    /// has no escape at all. Never two escapes on one row, and the vocabulary
    /// is fixed — "Skip for now" passes this step, "Exit setup" leaves the
    /// wizard (so do × and Esc).
    private func buildFooterView() -> NSView {
        primaryButton = nil
        if mode == .remoteOnly {
            let serving = report.tailscaleFound && report.tailscaleServing
            if serving {
                return footerRow([asPrimary(WizardButton(title: "Done", style: .primary) { [weak self] in
                    self?.onDismiss?()
                }), NSView()])
            }
            return footerRow([NSView(), dismissLink("Maybe later")])
        }
        switch step {
        case .welcome:
            if report.machineReady {
                let go = asPrimary(WizardButton(title: "Spawn your first agent", style: .primary, kbd: "⌘N") { [weak self] in
                    self?.onChooseFolder?()
                })
                return footerRow([go, NSView(), dismissLink("Later")])
            }
            let setUp = asPrimary(WizardButton(title: "Set up", style: .primary, arrow: true) { [weak self] in
                self?.advance()
            })
            let estimate = footnote("about a minute")
            return footerRow([setUp, estimate, NSView(), dismissLink("I'll figure it out")])
        case .claude:
            // The gate offers no footer escape: claude is the product's one
            // hard requirement, so the step's only forward motion is
            // install-and-watch. × and Esc stay as the emergency exits.
            return footerRow([footnote("Required to continue."), NSView()])
        case .tmux:
            // The cost sits beside the skip it justifies, not on its own line.
            let cost = NSTextField(wrappingLabelWithString: "Skip it and your agents will live and die with this window.")
            cost.font = NSFontManager.shared.convert(Theme.fonts.ui(11), toHaveTrait: .italicFontMask)
            cost.textColor = Theme.colors.textMuted
            cost.isEditable = false; cost.isBordered = false; cost.drawsBackground = false
            cost.preferredMaxLayoutWidth = 235
            let skipL = WizardButton(title: "Skip for now", style: .link) { [weak self] in
                self?.skip(.tmux)
            }
            return footerRow([cost, NSView(), skipL])
        case .tailscale:
            let serving = report.tailscaleFound && report.tailscaleServing
            if serving {
                return footerRow([asPrimary(WizardButton(title: "Continue", style: .primary, arrow: true) { [weak self] in
                    self?.advance()
                }), NSView()])
            }
            let skipL = WizardButton(title: "Skip for now", style: .link) { [weak self] in
                self?.skip(.tailscale)
            }
            return footerRow([NSView(), skipL])
        case .exit:
            let go = asPrimary(WizardButton(title: "Spawn your first agent", style: .primary, kbd: "⌘N") { [weak self] in
                self?.onChooseFolder?()
            })
            return footerRow([go, NSView()])
        }
    }

    /// Remember the step's primary so Return can fire it from anywhere — the
    /// default-button convention without an NSButton.
    private func asPrimary(_ b: WizardButton) -> WizardButton {
        primaryButton = b
        return b
    }

    @discardableResult
    func performPrimary() -> Bool {
        guard let primaryButton, primaryButton.window != nil else { return false }
        primaryButton.press()
        return true
    }

    private func footerRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        // Text-only footers keep the height a button row would have — the
        // dialog's bottom edge never wanders between steps.
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return row
    }

    private func dismissLink(_ title: String) -> WizardButton {
        WizardButton(title: title, style: .link) { [weak self] in self?.onDismiss?() }
    }

    private func footnote(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.fonts.ui(12)
        l.textColor = Theme.colors.textMuted
        return l
    }
}

// MARK: - Progress bead

/// One header bead: green when its check is done, severity-colored and
/// breathing while current, a hollow ring while pending.
final class WizardBeadView: NSView {
    enum State { case done, current, pending }
    private let severity: NSColor
    private var state: State = .pending

    init(color: NSColor) {
        self.severity = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 9),
            heightAnchor.constraint(equalToConstant: 9),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: State) {
        guard s != state else { return }
        state = s
        apply()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    private func apply() {
        guard let layer else { return }
        layer.cornerRadius = 4.5
        layer.removeAnimation(forKey: "pulse")
        switch state {
        case .done:
            layer.backgroundColor = Theme.colors.statusDone.cgColor
            layer.borderWidth = 0
            layer.shadowColor = Theme.colors.statusDone.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.8
        case .current:
            layer.backgroundColor = severity.cgColor
            layer.borderWidth = 0
            layer.shadowColor = severity.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 5
            layer.shadowOpacity = 1
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.55
                a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = Theme.motion.softEase
                layer.add(a, forKey: "pulse")
            }
        case .pending:
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 1.5
            layer.borderColor = Theme.colors.border.cgColor
            layer.shadowOpacity = 0
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { apply() }
    }
}

// MARK: - Close button

private final class WizardCloseButton: NSView {
    private let action: () -> Void
    private let label = NSTextField(labelWithString: "×")
    private var hovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = Theme.fonts.ui(17)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
        ])
        toolTip = "Exit setup"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Exit setup")
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
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { action() }   // space / return
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
    private func refresh() {
        label.textColor = hovering ? Theme.colors.textPrimary : Theme.colors.textMuted
        layer?.backgroundColor = (hovering ? Theme.colors.hover : .clear).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { refresh() }
    }
}
