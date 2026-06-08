import AppKit

/// The shared chrome for any on-canvas item (PRD: cards today, diff objects next):
/// a draggable title bar (folder/name + ✕ delete) over a content view, with a
/// status-colored accent border (+ glow when loud). Content-agnostic — a card
/// puts a terminal here; a diff object would put its diff view.
final class ItemContainerView: NSView {
    override var isFlipped: Bool { true }

    private let borderInset: CGFloat = 3
    private let titleBarHeight: CGFloat = 44

    private let titleBar = DragBarView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private let placeholder = NSTextField(labelWithString: "")
    private(set) var content: NSView?

    var onMoved: ((NSPoint) -> Void)?
    var onDelete: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 3

        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.20, alpha: 1).cgColor
        titleBar.onMovedEnd = { [weak self] origin in self?.onMoved?(origin) }
        addSubview(titleBar)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        titleBar.addSubview(titleLabel)

        deleteButton.title = "✕"
        deleteButton.isBordered = false
        deleteButton.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        deleteButton.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        titleBar.addSubview(deleteButton)

        placeholder.alignment = .center
        placeholder.font = NSFont.systemFont(ofSize: 22, weight: .regular)
        placeholder.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        placeholder.isEditable = false; placeholder.isBordered = false; placeholder.drawsBackground = false
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func deleteTapped() { onDelete?() }

    /// Install the item's live content (terminal, diff view, …), hiding the placeholder.
    func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        addSubview(view, positioned: .below, relativeTo: titleBar) // title bar stays on top
        placeholder.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setPlaceholder(_ text: String) { placeholder.stringValue = text }

    /// Accent the border by status; loud states add a pulsing glow.
    func setAccent(color: NSColor, loud: Bool) {
        layer?.borderColor = color.withAlphaComponent(loud ? 1 : 0.7).cgColor
        layer?.borderWidth = loud ? 6 : 3
        if loud {
            layer?.masksToBounds = false
            layer?.shadowColor = color.cgColor
            layer?.shadowRadius = 20
            layer?.shadowOffset = .zero
            if layer?.animation(forKey: "glow") == nil {
                let a = CABasicAnimation(keyPath: "shadowOpacity")
                a.fromValue = 0.2; a.toValue = 0.95
                a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
                layer?.add(a, forKey: "glow")
            }
        } else {
            layer?.removeAnimation(forKey: "glow")
            layer?.shadowOpacity = 0
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        titleBar.frame = NSRect(x: borderInset, y: borderInset, width: w - 2 * borderInset, height: titleBarHeight)
        let tbw = titleBar.bounds.width
        deleteButton.frame = NSRect(x: tbw - 40, y: (titleBarHeight - 32) / 2, width: 32, height: 32)
        titleLabel.frame = NSRect(x: 14, y: (titleBarHeight - 28) / 2, width: tbw - 60, height: 28)

        let contentY = borderInset + titleBarHeight
        content?.frame = NSRect(x: borderInset, y: contentY, width: w - 2 * borderInset, height: h - contentY - borderInset)
        placeholder.frame = NSRect(x: 8, y: contentY + (h - contentY) / 2 - 20, width: w - 16, height: 40)
    }
}
