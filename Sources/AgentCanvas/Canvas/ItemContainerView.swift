import AppKit

/// The shared chrome for any on-canvas item (cards + diff objects): a draggable
/// title bar (folder/name + ✕ delete) over a content view, with a status-colored
/// accent border (+ glow when loud).
///
/// **Layout contract (important):** this view is positioned by the *canvas* via its
/// `frame` (it lives in the document view). Everything *inside* it is laid out with
/// Auto Layout constraints — we never set inner subview frames or call `sizeToFit`.
/// Manually framing the constraint-backed AppKit controls in here, inside the
/// magnified document, is what caused the "more layout passes than views" crashes.
final class ItemContainerView: NSView {
    override var isFlipped: Bool { true }

    private let borderInset: CGFloat = 3
    private let titleBarHeight: CGFloat = 44

    /// Breathing room between the window edges and the content (e.g. a card's
    /// terminal). Default 0 — the diff object fills edge-to-edge. Applied as the
    /// content's constraint constants.
    var contentInset: CGFloat = 0 { didSet { updateContentInsets() } }

    private let titleBar = DragBarView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private let placeholder = NSTextField(labelWithString: "")
    private(set) var content: NSView?
    private var contentConstraints: [NSLayoutConstraint] = []

    var onMoved: ((NSPoint) -> Void)?
    var onDelete: (() -> Void)?

    // Current accent, remembered so it can be re-resolved when the appearance flips
    // (layer colors are frozen `.cgColor`s — see Theme.swift).
    private var accentColor: NSColor = Theme.colors.neutralBorder
    private var accentLoud = false

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        titleBar.wantsLayer = true
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.onMovedEnd = { [weak self] origin in self?.onMoved?(origin) }
        addSubview(titleBar)

        titleLabel.stringValue = title
        titleLabel.font = Theme.fonts.itemTitle
        titleLabel.textColor = Theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleLabel)

        deleteButton.title = "✕"
        deleteButton.isBordered = false
        deleteButton.font = Theme.fonts.controlGlyph
        deleteButton.contentTintColor = Theme.colors.textControl
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(deleteButton)

        placeholder.alignment = .center
        placeholder.font = Theme.fonts.placeholder
        placeholder.textColor = Theme.colors.textMuted
        placeholder.isEditable = false; placeholder.isBordered = false; placeholder.drawsBackground = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        // A guide spanning the content area (below the title bar) — used to center
        // the placeholder; content is pinned here too (in setContent).
        let contentGuide = NSLayoutGuide()
        addLayoutGuide(contentGuide)

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor, constant: borderInset),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: borderInset),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -borderInset),
            titleBar.heightAnchor.constraint(equalToConstant: titleBarHeight),

            deleteButton.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 32),
            deleteButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),

            contentGuide.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: contentGuide.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentGuide.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])

        applySurfaceColors()   // both layers exist now
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func deleteTapped() { onDelete?() }

    /// Install the item's live content (terminal, diff view, …), pinned to the content
    /// area (below the title bar) with `contentInset` breathing room — via constraints.
    func setContent(_ view: NSView) {
        NSLayoutConstraint.deactivate(contentConstraints)
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: titleBar) // title bar stays on top
        contentConstraints = [
            view.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: contentInset),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: borderInset + contentInset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(borderInset + contentInset)),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(borderInset + contentInset)),
        ]
        NSLayoutConstraint.activate(contentConstraints)
        placeholder.isHidden = true
    }

    private func updateContentInsets() {
        guard contentConstraints.count == 4 else { return }
        contentConstraints[0].constant = contentInset
        contentConstraints[1].constant = borderInset + contentInset
        contentConstraints[2].constant = -(borderInset + contentInset)
        contentConstraints[3].constant = -(borderInset + contentInset)
    }

    func setPlaceholder(_ text: String) { placeholder.stringValue = text }

    /// Update the title-bar text (e.g. a diff object showing its live diffstat).
    func setTitle(_ text: String) { titleLabel.stringValue = text }

    /// Accent the border by status; loud states add a pulsing glow.
    func setAccent(color: NSColor, loud: Bool) {
        accentColor = color
        accentLoud = loud
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

    /// Push the (dynamic) surface + accent colors into the layers for the *current*
    /// appearance. Layer `.cgColor`s don't auto-adapt, so we re-resolve on every flip.
    private func applySurfaceColors() {
        layer?.backgroundColor = Theme.colors.itemChrome.cgColor
        titleBar.layer?.backgroundColor = Theme.colors.titleBar.cgColor
        setAccent(color: accentColor, loud: accentLoud)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applySurfaceColors() }
    }
}
