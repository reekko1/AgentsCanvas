import AppKit

/// The diff object's **compact** representation, shown when the item is small/far
/// on the canvas (the decided LOD exception for diffs — see `design-reference`).
/// Just a quiet file list: change-type letter + path + ± counts. Selecting / acting
/// happens in the full `DiffContentView` once you fly in.
final class DiffCompactView: NSView {
    override var isFlipped: Bool { true }

    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let maxRows = 18

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        emptyLabel.font = Theme.fonts.listStat
        emptyLabel.textColor = Theme.colors.textMuted
        emptyLabel.alignment = .center
        emptyLabel.isEditable = false; emptyLabel.isBordered = false; emptyLabel.drawsBackground = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ snapshot: GitSnapshot) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard snapshot.isRepo else { showEmpty("not a git repository"); return }
        guard !snapshot.changes.isEmpty else { showEmpty("✓ clean working tree"); return }
        emptyLabel.isHidden = true
        for change in snapshot.changes.prefix(maxRows) {
            let r = row(for: change)
            stack.addArrangedSubview(r)
            // Width must be constrained AFTER the row joins the stack's hierarchy,
            // else the anchors share no common ancestor (the crash).
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        let overflow = snapshot.changes.count - maxRows
        if overflow > 0 { stack.addArrangedSubview(moreRow(overflow)) }
    }

    private func showEmpty(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    private func row(for c: GitChange) -> NSView {
        let letter = NSTextField(labelWithString: c.status.letter)
        letter.font = Theme.fonts.mono(11, .semibold)
        letter.textColor = c.status.color
        letter.alignment = .center
        letter.isEditable = false; letter.isBordered = false; letter.drawsBackground = false
        letter.setContentHuggingPriority(.required, for: .horizontal)

        let path = NSTextField(labelWithString: (c.path as NSString).lastPathComponent)
        path.font = Theme.fonts.monoPath
        path.textColor = Theme.colors.textPrimary
        path.lineBreakMode = .byTruncatingMiddle
        path.isEditable = false; path.isBordered = false; path.drawsBackground = false
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let counts = NSTextField(labelWithString: "")
        counts.attributedStringValue = countString(added: c.added, removed: c.removed)
        counts.isEditable = false; counts.isBordered = false; counts.drawsBackground = false
        counts.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [letter, path, counts])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.distribution = .fill
        letter.widthAnchor.constraint(equalToConstant: 13).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false
        // Width is pinned to the stack by the caller, after the row is added.
        return row
    }

    private func moreRow(_ n: Int) -> NSView {
        let l = NSTextField(labelWithString: "+\(n) more")
        l.font = Theme.fonts.listStat
        l.textColor = Theme.colors.textMuted
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        return l
    }

    private func countString(added: Int, removed: Int) -> NSAttributedString {
        let font = Theme.fonts.listStat
        let s = NSMutableAttributedString()
        if added > 0 {
            s.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: Theme.colors.diffAdded, .font: font]))
        }
        if removed > 0 {
            if s.length > 0 { s.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            s.append(NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: Theme.colors.diffRemoved, .font: font]))
        }
        return s
    }

    private func applyBackground() {
        layer?.backgroundColor = Theme.colors.fileListBg.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }
}
