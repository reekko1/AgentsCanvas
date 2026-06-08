import AppKit

/// A per-file git action. Reversible ones (stage/unstage) run immediately; `discard`
/// is destructive and is gated by a confirmation in `DiffContentView`.
enum DiffAction { case stage, unstage, discard }
/// A group-level git action (hover actions on a section header).
enum DiffBulkAction { case stageAll, unstageAll, discardAll }

/// Which section a file row belongs to — decides its status letter and actions.
private enum DiffSide { case staged, unstaged }

/// All SF Symbols in the panel share one size/weight so they look consistent.
private func sfSymbol(_ name: String, size: CGFloat = 12, weight: NSFont.Weight = .medium) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

/// Outline model nodes (classes so NSOutlineView can track them by identity).
private final class GroupNode { let side: DiffSide; let title: String; var files: [FileNode] = []
    init(_ side: DiffSide, _ title: String) { self.side = side; self.title = title } }
private final class FileNode { let change: GitChange; let side: DiffSide
    init(_ change: GitChange, _ side: DiffSide) { self.change = change; self.side = side } }

/// The diff object's content, styled after VS Code's Source Control panel: a left
/// column with a commit area on top and a collapsible Staged/Changes file tree, and
/// the selected file's colored unified diff on the right.
/// Reads via `GitDiff`; mutates via `GitActions` (destructive actions confirmed).
///
/// **Layout:** entirely Auto Layout — no `layout()` override, no manual `.frame`/
/// `sizeToFit` on controls. Manually framing these constraint-backed controls inside
/// the magnified canvas is what caused the window layout-loop crashes.
final class DiffContentView: NSView {
    private let folder: URL

    // Left column.
    private let leftColumn = NSView()
    private let messageField = NSTextField()
    private let commitButton = NSButton()
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()

    // Right pane (diff).
    private let textView = NSTextView()
    private let textScroll = NSScrollView()

    private let diffQueue = DispatchQueue(label: "agentcanvas.filediff", qos: .userInitiated)

    /// Called after any successful mutation so the owner can refresh the snapshot.
    var onMutated: (() -> Void)?

    /// Fraction of the width given to the left (source-control) column.
    private let listFraction: CGFloat = 0.34

    private var groups: [GroupNode] = []
    private var changes: [GitChange] = []
    private var selectedPath: String?
    private var isRepo = true
    private var isApplying = false   // suppress selection-driven re-render during reload

    init(folder: URL) {
        self.folder = folder
        super.init(frame: .zero)
        wantsLayer = true
        buildLeftColumn()
        buildDiffPane()
        setupConstraints()
        applyBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildLeftColumn() {
        leftColumn.wantsLayer = true
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftColumn)

        messageField.placeholderString = "Message (⌘↩ to commit)"
        messageField.font = Theme.fonts.listPath
        messageField.bezelStyle = .roundedBezel
        messageField.focusRingType = .none
        messageField.delegate = self
        messageField.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.addSubview(messageField)

        commitButton.title = "Commit"
        commitButton.imagePosition = .imageLeading   // image (checkmark) set, colored, in updateCommitEnablement
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.target = self
        commitButton.action = #selector(commitTapped)
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.addSubview(commitButton)
        updateCommitEnablement()   // sets initial enabled/disabled styling

        outline.headerView = nil
        outline.backgroundColor = Theme.colors.listSurface
        outline.rowHeight = 26
        outline.indentationPerLevel = 12
        outline.autosaveTableColumns = false
        outline.selectionHighlightStyle = .regular
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = true
        outlineScroll.backgroundColor = Theme.colors.listSurface
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.addSubview(outlineScroll)
    }

    private func buildDiffPane() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.colors.contentSurface
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = Theme.colors.contentSurface
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textScroll)
    }

    private func setupConstraints() {
        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            leftColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: topAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftColumn.widthAnchor.constraint(equalTo: widthAnchor, multiplier: listFraction),

            messageField.topAnchor.constraint(equalTo: leftColumn.topAnchor, constant: pad),
            messageField.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor, constant: pad),
            messageField.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: -pad),

            commitButton.topAnchor.constraint(equalTo: messageField.bottomAnchor, constant: 6),
            commitButton.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor, constant: pad),
            commitButton.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: -pad),
            commitButton.heightAnchor.constraint(equalToConstant: 28),

            outlineScroll.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 8),
            outlineScroll.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),

            textScroll.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 1),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: topAnchor),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Layer `.cgColor`s don't auto-adapt, so re-resolve on appearance flips.
    private func applyBackground() {
        layer?.backgroundColor = Theme.colors.contentSurface.cgColor
        leftColumn.layer?.backgroundColor = Theme.colors.listSurface.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    // MARK: Update

    /// Apply a new snapshot: rebuild the Staged/Changes groups, keep the current
    /// selection if its file still exists (else select the first), render its diff.
    func apply(_ snapshot: GitSnapshot) {
        isRepo = snapshot.isRepo
        changes = snapshot.changes

        let staged = GroupNode(.staged, "Staged Changes")
        staged.files = changes.filter { $0.hasStaged }.map { FileNode($0, .staged) }
        let unstaged = GroupNode(.unstaged, "Changes")
        unstaged.files = changes.filter { $0.hasUnstaged }.map { FileNode($0, .unstaged) }
        groups = [staged, unstaged].filter { !$0.files.isEmpty }

        isApplying = true
        outline.reloadData()
        groups.forEach { outline.expandItem($0) }
        isApplying = false

        updateCommitEnablement()

        guard isRepo else { showMessage("Not a git repository."); return }
        guard !groups.isEmpty else { selectedPath = nil; showMessage("No changes — clean working tree."); return }

        // Re-select the previously selected file if still present, else the first file.
        let target = firstFileRow(matching: selectedPath) ?? firstFileRow(matching: nil)
        if let (node, rowItem) = target {
            isApplying = true
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: rowItem)), byExtendingSelection: false)
            isApplying = false
            renderDiff(for: node.change)
        }
    }

    /// Find a FileNode (and the item to select) whose path matches, or the first file.
    private func firstFileRow(matching path: String?) -> (FileNode, Any)? {
        for g in groups {
            for f in g.files where path == nil || f.change.path == path {
                return (f, f)
            }
        }
        return nil
    }

    private func showMessage(_ text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: Theme.fonts.message,
            .foregroundColor: Theme.colors.textMuted,
        ]))
    }

    private func renderDiff(for change: GitChange) {
        selectedPath = change.path
        showMessage("Loading diff…")
        let folder = self.folder
        diffQueue.async { [weak self] in
            let raw = GitDiff.fileDiff(folder: folder, change: change)
            DispatchQueue.main.async {
                guard let self, self.selectedPath == change.path else { return }  // stale selection
                self.textView.textStorage?.setAttributedString(Self.colorize(raw))
            }
        }
    }

    /// Color a unified diff: green additions, red deletions, dim hunk/file headers.
    private static func colorize(_ diff: String) -> NSAttributedString {
        let font = Theme.fonts.diffMono
        let add = Theme.colors.diffAdded
        let del = Theme.colors.diffRemoved
        let hunk = Theme.colors.diffHunk
        let meta = Theme.colors.diffMeta
        let normal = Theme.colors.diffText

        let out = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let color: NSColor
            if s.hasPrefix("@@") { color = hunk }
            else if s.hasPrefix("+++") || s.hasPrefix("---") || s.hasPrefix("diff ") || s.hasPrefix("index ")
                 || s.hasPrefix("new file") || s.hasPrefix("deleted file") || s.hasPrefix("rename ") { color = meta }
            else if s.hasPrefix("+") { color = add }
            else if s.hasPrefix("-") { color = del }
            else { color = normal }
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    // MARK: Actions

    private var anyStaged: Bool { changes.contains { $0.hasStaged } }

    private func updateCommitEnablement() {
        let hasMsg = !messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabled = anyStaged && hasMsg
        let fg = enabled ? NSColor.white : Theme.colors.textMuted
        commitButton.isEnabled = enabled
        commitButton.bezelColor = enabled ? .controlAccentColor : Theme.colors.commitIdle
        // Color BOTH the title and the checkmark explicitly: on a bezel-colored button
        // neither `contentTintColor` (title) nor the control tint (image) gives white.
        commitButton.attributedTitle = NSAttributedString(string: "Commit", attributes: [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [fg]))
        commitButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    /// Per-file action from a row's hover button. Destructive (discard) is confirmed first.
    fileprivate func perform(_ action: DiffAction, on change: GitChange) {
        let folder = self.folder
        switch action {
        case .stage:   runMutation { GitActions.stage(folder: folder, path: change.path) }
        case .unstage: runMutation { GitActions.unstage(folder: folder, path: change.path) }
        case .discard:
            let what = change.status == .untracked ? "delete the untracked file" : "discard changes to"
            confirm(title: "Discard “\(change.path)”?",
                    body: "This will \(what) \(change.path). This cannot be undone.",
                    confirmTitle: "Discard") { [weak self] in
                self?.runMutation { GitActions.discard(folder: folder, change: change) }
            }
        }
    }

    fileprivate func performBulk(_ action: DiffBulkAction) {
        let folder = self.folder
        switch action {
        case .stageAll:   runMutation { GitActions.stageAll(folder: folder) }
        case .unstageAll: runMutation { GitActions.unstageAll(folder: folder) }
        case .discardAll:
            let files = changes.count
            let untracked = changes.filter { $0.status == .untracked }.count
            var body = "This will revert all \(files) changed file\(files == 1 ? "" : "s") to the last commit"
            if untracked > 0 { body += " and permanently remove \(untracked) untracked file\(untracked == 1 ? "" : "s")" }
            body += ". This cannot be undone."
            confirm(title: "Discard ALL changes?", body: body, confirmTitle: "Discard All") { [weak self] in
                self?.runMutation { GitActions.discardAll(folder: folder) }
            }
        }
    }

    @objc private func commitTapped() {
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, anyStaged else { return }
        let folder = self.folder
        runMutation(onSuccess: { [weak self] in self?.messageField.stringValue = ""; self?.updateCommitEnablement() }) {
            GitActions.commit(folder: folder, message: message)
        }
    }

    /// Run a mutation off the main thread; refresh on success, surface errors otherwise.
    private func runMutation(onSuccess: (() -> Void)? = nil, _ work: @escaping () -> GitActionResult) {
        diffQueue.async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                guard let self else { return }
                if result.ok {
                    onSuccess?()
                    self.onMutated?()
                } else {
                    self.showError(result.message)
                }
            }
        }
    }

    // MARK: Alerts (sheets on this view's window)

    private func confirm(title: String, body: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
        guard let window = self.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn { onConfirm() }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git action failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = self.window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

// MARK: - Live commit-button enablement

extension DiffContentView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { updateCommitEnablement() }
}

// MARK: - Outline (Staged / Changes groups + file rows)

extension DiffContentView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        return (item as? GroupNode)?.files.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? GroupNode { return group.files[index] }
        return groups[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is GroupNode
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is FileNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? GroupNode {
            let id = NSUserInterfaceItemIdentifier("DiffGroupCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? DiffGroupCell) ?? DiffGroupCell(id: id)
            cell.onBulk = { [weak self] action in self?.performBulk(action) }
            cell.configure(group)
            return cell
        }
        let node = item as! FileNode
        let id = NSUserInterfaceItemIdentifier("DiffFileCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? DiffFileCell) ?? DiffFileCell(id: id)
        cell.onAction = { [weak self] action, change in self?.perform(action, on: change) }
        cell.configure(node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        if let node = outline.item(atRow: outline.selectedRow) as? FileNode {
            renderDiff(for: node.change)
        }
    }
}

// MARK: - Group header cell

private final class DiffGroupCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private let stageAllButton = IconButton(symbol: "plus")
    private let unstageAllButton = IconButton(symbol: "minus")
    private let discardAllButton = IconButton(symbol: "arrow.uturn.backward")
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var side: DiffSide = .unstaged

    var onBulk: ((DiffBulkAction) -> Void)?

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = Theme.colors.groupHeader
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stageAllButton.onClick = { [weak self] in self?.onBulk?(.stageAll) }
        unstageAllButton.onClick = { [weak self] in self?.onBulk?(.unstageAll) }
        discardAllButton.onClick = { [weak self] in self?.onBulk?(.discardAll) }

        let row = NSStackView(views: [titleLabel, stageAllButton, unstageAllButton, discardAllButton, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill   // title takes the slack → badge/actions sit at the right edge
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ group: GroupNode) {
        side = group.side
        titleLabel.stringValue = group.title.uppercased()
        badge.count = group.files.count
        setHoverState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta); trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; setHoverState() }
    override func mouseExited(with event: NSEvent) { hovering = false; setHoverState() }

    private func setHoverState() {
        // Staged group → unstage-all; Changes group → stage-all + discard-all.
        stageAllButton.isHidden = !(hovering && side == .unstaged)
        discardAllButton.isHidden = !(hovering && side == .unstaged)
        unstageAllButton.isHidden = !(hovering && side == .staged)
    }
}

// MARK: - File row cell

private final class DiffFileCell: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let letterLabel = NSTextField(labelWithString: "")
    private let primaryButton = IconButton(symbol: "plus")          // Stage (+) or Unstage (−), by side
    private let discardButton = IconButton(symbol: "arrow.uturn.backward")  // unstaged side only
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    private var change: GitChange?
    private var side: DiffSide = .unstaged
    private var letterStatus: GitFileStatus = .modified
    var onAction: ((DiffAction, GitChange) -> Void)?

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        icon.image = sfSymbol("doc.text", size: 13)
        icon.contentTintColor = Theme.colors.textMuted
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = Theme.fonts.listPath
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        letterLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        letterLabel.alignment = .center

        primaryButton.onClick = { [weak self] in
            guard let self, let c = self.change else { return }
            self.onAction?(self.side == .staged ? .unstage : .stage, c)
        }
        discardButton.onClick = { [weak self] in
            guard let self, let c = self.change else { return }
            self.onAction?(.discard, c)
        }

        let row = NSStackView(views: [icon, nameLabel, primaryButton, discardButton, letterLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill   // name takes the slack → letter/actions sit at the right edge
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            letterLabel.widthAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: FileNode) {
        change = node.change
        side = node.side
        letterStatus = (side == .staged ? node.change.stagedStatus : node.change.unstagedStatus) ?? node.change.status
        letterLabel.stringValue = letterStatus.letter
        // Actions per side: unstaged → Stage(+) & Discard(↩); staged → Unstage(−).
        primaryButton.setSymbol(side == .staged ? "minus" : "plus")
        applyColors()
        setHoverState()
    }

    /// On a selected (emphasized/blue) row, flip text + icons to white for contrast;
    /// otherwise use the theme colors. AppKit sets `backgroundStyle` on selection.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        guard let c = change else { return }
        let emph = backgroundStyle == .emphasized
        // Name: basename + muted parent dir (VS Code style).
        let full = c.path as NSString
        let nameColor = emph ? NSColor.white : Theme.colors.textPrimary
        let dirColor = emph ? NSColor(calibratedWhite: 0.85, alpha: 1) : Theme.colors.textMuted
        let name = NSMutableAttributedString(string: full.lastPathComponent, attributes: [.foregroundColor: nameColor])
        let dir = full.deletingLastPathComponent
        if !dir.isEmpty {
            name.append(NSAttributedString(string: "  \(dir)", attributes: [
                .foregroundColor: dirColor, .font: NSFont.systemFont(ofSize: 10),
            ]))
        }
        nameLabel.attributedStringValue = name
        letterLabel.textColor = emph ? .white : letterStatus.color
        icon.contentTintColor = emph ? .white : Theme.colors.textMuted
        primaryButton.emphasized = emph
        discardButton.emphasized = emph
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta); trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; setHoverState() }
    override func mouseExited(with event: NSEvent) { hovering = false; setHoverState() }

    private func setHoverState() {
        letterLabel.isHidden = hovering
        primaryButton.isHidden = !hovering
        discardButton.isHidden = !(hovering && side == .unstaged)
    }
}

// MARK: - Count badge

private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    var count: Int = 0 { didSet { label.stringValue = "\(count)"; applyColors() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5).priorityHigh(),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5).priorityHigh(),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        layer?.backgroundColor = Theme.colors.badgeBackground.cgColor
        label.textColor = Theme.colors.badgeText
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }
}

private extension NSLayoutConstraint {
    func priorityHigh() -> NSLayoutConstraint { priority = .defaultHigh; return self }
}

/// A borderless icon button built on a plain `NSView`. `NSButton` fights both
/// explicit sizing (its intrinsic content size conflicts with size constraints) and
/// layer backgrounds (its cell draws over them), which made the action icons render
/// at inconsistent sizes with no visible hover state. This view guarantees a fixed
/// 22×22 frame, a perfectly centered SF Symbol, and a VS Code-style rounded hover
/// highlight that actually shows.
private final class IconButton: NSView {
    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovering = false
    /// When the containing row is selected (blue), tint white for contrast.
    var emphasized = false { didSet { refreshTint() } }
    var onClick: (() -> Void)?

    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = Theme.colors.textControl
        imageView.image = sfSymbol(symbol)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) { imageView.image = sfSymbol(name) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true; refreshTint() }
    override func mouseExited(with event: NSEvent) { isHovering = false; refreshTint() }
    override func mouseDown(with event: NSEvent) {}   // swallow so we receive mouseUp
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func refreshTint() {
        layer?.backgroundColor = (isHovering ? Theme.colors.controlHover : NSColor.clear).cgColor
        imageView.contentTintColor = emphasized ? .white
            : (isHovering ? Theme.colors.textPrimary : Theme.colors.textControl)
    }
}
