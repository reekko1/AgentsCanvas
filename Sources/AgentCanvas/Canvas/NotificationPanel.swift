import AppKit

/// A pending permission ask as the panel renders it (a projection of the spine's
/// `PermissionAsk` — the panel never touches the live decision handle).
struct PanelApproval {
    let id: UUID
    let cardId: String
    let name: String
    let detail: String
    let created: Date
}

/// The activity center (top-right): a "needs approval" section with live
/// Allow/Deny controls (the orbit decision channel), then recent status changes,
/// newest first, loud ones flagged. Click a row → fly to that agent. Click the
/// header → collapse.
final class NotificationPanel: OverlayPanel {
    var onSelect: ((String) -> Void)?
    /// Decide a held permission ask from orbit (by ask id).
    var onAllow: ((UUID) -> Void)?
    var onDeny: ((UUID) -> Void)?

    private let countPill = NSTextField(labelWithString: "0")
    private let chevron = NSImageView()
    private let approvalsStack = NSStackView()
    private let rowsStack = NSStackView()
    private let footBox = NSView()
    private var collapsibleViews: [NSView] = []
    private var collapsed = false
    private let maxRows = 8

    init() {
        super.init(corner: 14)
        widthAnchor.constraint(equalToConstant: 286).isActive = true

        let header = makeHeader()

        approvalsStack.orientation = .vertical
        approvalsStack.alignment = .leading
        approvalsStack.spacing = 2
        approvalsStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 6)
        approvalsStack.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let foot = NSTextField(labelWithString: "Newest first · ⇥ flies to the neediest")
        foot.font = Theme.fonts.listStat
        foot.textColor = Theme.colors.textMuted
        foot.isEditable = false; foot.isBordered = false; foot.drawsBackground = false
        foot.translatesAutoresizingMaskIntoConstraints = false
        footBox.translatesAutoresizingMaskIntoConstraints = false
        footBox.addSubview(foot)
        NSLayoutConstraint.activate([
            foot.leadingAnchor.constraint(equalTo: footBox.leadingAnchor, constant: 13),
            foot.topAnchor.constraint(equalTo: footBox.topAnchor, constant: 7),
            foot.bottomAnchor.constraint(equalTo: footBox.bottomAnchor, constant: -7),
        ])

        let outer = NSStackView(views: [header, approvalsStack, rowsStack, footBox])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: outer.widthAnchor),
            approvalsStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            rowsStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            footBox.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
        collapsibleViews = [approvalsStack, rowsStack, footBox]
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeHeader() -> NSView {
        let bell = NSImageView()
        bell.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        bell.contentTintColor = Theme.colors.glyph
        bell.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "Activity")
        title.font = Theme.fonts.ui(13, .bold)
        title.textColor = Theme.colors.textPrimary
        title.isEditable = false; title.isBordered = false; title.drawsBackground = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        countPill.font = Theme.fonts.mono(10, .semibold)
        countPill.alignment = .center
        countPill.isEditable = false; countPill.isBordered = false; countPill.drawsBackground = false
        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = 8
        countPill.isHidden = true
        countPill.setContentHuggingPriority(.required, for: .horizontal)

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = Theme.colors.glyph
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [bell, title, countPill, chevron])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let box = ClickView()
        box.onClick = { [weak self] in self?.toggleCollapse() }
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -13),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
        ])
        return box
    }

    /// Rebuild the panel: approval rows (oldest first — triage order), then the
    /// feed, then the loud badge.
    func reload(_ feed: ActivityFeed, approvals: [PanelApproval], loudCount: Int) {
        approvalsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        approvalsStack.isHidden = collapsed || approvals.isEmpty
        if !approvals.isEmpty {
            approvalsStack.addArrangedSubview(makeSectionLabel("NEEDS APPROVAL"))
            for a in approvals.sorted(by: { $0.created < $1.created }) {
                let r = makeApprovalRow(a)
                approvalsStack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: approvalsStack.widthAnchor, constant: -12).isActive = true
            }
        }

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for e in feed.events.prefix(maxRows) {
            let r = makeRow(e)
            rowsStack.addArrangedSubview(r)
            // Width pinned AFTER the row joins the stack (common-ancestor rule).
            r.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -12).isActive = true
        }

        let needsYou = loudCount + approvals.count
        if needsYou > 0 {
            countPill.isHidden = false
            countPill.stringValue = " \(needsYou) "
            countPill.textColor = Theme.colors.primaryInk
            countPill.layer?.backgroundColor = Theme.colors.statusBlocked.cgColor
        } else {
            countPill.isHidden = true
        }
    }

    /// An approval row: who + what + the live Allow/Deny decision. Clicking the
    /// body flies to the card (which releases the ask to its terminal dialog).
    private func makeApprovalRow(_ a: PanelApproval) -> NSView {
        let dot = BeadView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        dot.set(color: Theme.colors.statusBlocked, glow: true, pulse: .breathe(1.8))

        let name = NSTextField(labelWithString: a.name)
        name.font = Theme.fonts.ui(12.5, .semibold)
        name.textColor = Theme.colors.textPrimary
        name.isEditable = false; name.isBordered = false; name.drawsBackground = false

        let time = NSTextField(labelWithString: Self.rel(a.created))
        time.font = Theme.fonts.mono(10)
        time.textColor = Theme.colors.textMuted
        time.isEditable = false; time.isBordered = false; time.drawsBackground = false
        time.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = NSStackView(views: [name, time])
        nameRow.orientation = .horizontal; nameRow.alignment = .centerY; nameRow.spacing = 6

        let detail = NSTextField(labelWithString: a.detail)
        detail.font = Theme.fonts.mono(10.5)
        detail.textColor = Theme.colors.textMuted
        detail.lineBreakMode = .byTruncatingTail
        detail.isEditable = false; detail.isBordered = false; detail.drawsBackground = false

        let allow = PanelButton("Allow", accent: true)
        allow.onClick = { [weak self] in self?.onAllow?(a.id) }
        let deny = PanelButton("Deny", danger: true)
        deny.onClick = { [weak self] in self?.onDeny?(a.id) }
        let buttons = NSStackView(views: [allow, deny])
        buttons.orientation = .horizontal; buttons.spacing = 6

        let col = NSStackView(views: [nameRow, detail, buttons])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 3
        col.setContentHuggingPriority(.defaultLow, for: .horizontal)
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [dot, col])
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false

        let click = ClickView()
        click.onClick = { [weak self] in self?.onSelect?(a.cardId) }
        click.translatesAutoresizingMaskIntoConstraints = false
        click.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: click.topAnchor),
            row.bottomAnchor.constraint(equalTo: click.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: click.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: click.trailingAnchor),
        ])
        return click
    }

    private func makeSectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.fonts.mono(9.5, .semibold)
        label.textColor = Theme.colors.statusBlocked
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return box
    }

    private func makeRow(_ e: ActivityEvent) -> NSView {
        let dot = BeadView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        dot.set(color: e.status.color, glow: e.loud, pulse: .none)

        let name = NSTextField(labelWithString: e.name)
        name.font = Theme.fonts.ui(12.5, .semibold)
        name.textColor = Theme.colors.textPrimary
        name.isEditable = false; name.isBordered = false; name.drawsBackground = false

        let tag = NSTextField(labelWithString: " \(e.status.word.uppercased()) ")
        tag.font = Theme.fonts.mono(8.5, .semibold)
        tag.textColor = e.status.color
        tag.isEditable = false; tag.isBordered = false; tag.drawsBackground = false
        tag.wantsLayer = true
        tag.layer?.cornerRadius = 3
        tag.layer?.backgroundColor = e.status.color.withAlphaComponent(0.22).cgColor
        tag.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = NSStackView(views: [name, tag])
        nameRow.orientation = .horizontal; nameRow.alignment = .centerY; nameRow.spacing = 6

        let msg = NSTextField(labelWithString: e.message)
        msg.font = Theme.fonts.ui(11.5)
        msg.textColor = Theme.colors.textMuted
        msg.lineBreakMode = .byTruncatingTail
        msg.isEditable = false; msg.isBordered = false; msg.drawsBackground = false

        let col = NSStackView(views: [nameRow, msg])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
        col.setContentHuggingPriority(.defaultLow, for: .horizontal)
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let time = NSTextField(labelWithString: Self.rel(e.date))
        time.font = Theme.fonts.mono(10)
        time.textColor = Theme.colors.textMuted
        time.isEditable = false; time.isBordered = false; time.drawsBackground = false
        time.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, col, time])
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false

        let click = ClickView()
        click.onClick = { [weak self] in self?.onSelect?(e.id) }
        click.translatesAutoresizingMaskIntoConstraints = false
        click.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: click.topAnchor),
            row.bottomAnchor.constraint(equalTo: click.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: click.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: click.trailingAnchor),
        ])
        return click
    }

    private func toggleCollapse() {
        collapsed.toggle()
        collapsibleViews.forEach { $0.isHidden = collapsed }
        // The approvals section additionally hides when empty.
        if !collapsed, approvalsStack.arrangedSubviews.isEmpty { approvalsStack.isHidden = true }
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    /// Relative time string ("now" / "3m" / "2h").
    static func rel(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// A small bordered text button for the approval rows (window-space overlay, so
/// plain custom views are fine — no canvas layout constraints apply here).
private final class PanelButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let accent: Bool
    private let danger: Bool
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }
    var onClick: (() -> Void)?

    init(_ text: String, accent: Bool = false, danger: Bool = false) {
        self.accent = accent
        self.danger = danger
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        label.stringValue = text
        label.font = Theme.fonts.ui(11, .semibold)
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}   // swallow so the row's ClickView doesn't fire
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func refresh() {
        let tint: NSColor = accent ? Theme.colors.statusDone
                  : danger ? Theme.colors.statusError
                  : Theme.colors.textPrimary
        label.textColor = hovering ? tint : Theme.colors.glyph
        layer?.borderColor = (hovering ? tint : Theme.colors.border).cgColor
        layer?.backgroundColor = (hovering ? Theme.colors.hover : NSColor.clear).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { refresh() }
    }
}
