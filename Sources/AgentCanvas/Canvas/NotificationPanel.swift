import AppKit

/// The activity center (top-right): recent status changes, newest first, loud ones
/// flagged. Click a row → fly to that agent. Click the header → collapse.
final class NotificationPanel: OverlayPanel {
    var onSelect: ((String) -> Void)?

    private let countPill = NSTextField(labelWithString: "0")
    private let chevron = NSImageView()
    private let rowsStack = NSStackView()
    private let footBox = NSView()
    private var collapsibleViews: [NSView] = []
    private var collapsed = false
    private let maxRows = 8

    init() {
        super.init(corner: 14)
        widthAnchor.constraint(equalToConstant: 286).isActive = true

        let header = makeHeader()

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let foot = NSTextField(labelWithString: "Newest first")
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

        let outer = NSStackView(views: [header, rowsStack, footBox])
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
            rowsStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            footBox.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
        collapsibleViews = [rowsStack, footBox]
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

    /// Rebuild the rows from the feed and set the loud badge.
    func reload(_ feed: ActivityFeed, loudCount: Int) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for e in feed.events.prefix(maxRows) {
            let r = makeRow(e)
            rowsStack.addArrangedSubview(r)
            // Width pinned AFTER the row joins the stack (common-ancestor rule).
            r.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -12).isActive = true
        }
        if loudCount > 0 {
            countPill.isHidden = false
            countPill.stringValue = " \(loudCount) "
            countPill.textColor = Theme.colors.primaryInk
            countPill.layer?.backgroundColor = Theme.colors.statusBlocked.cgColor
        } else {
            countPill.isHidden = true
        }
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
