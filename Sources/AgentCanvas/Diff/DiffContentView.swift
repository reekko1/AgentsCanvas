import AppKit

/// A per-file git action. Reversible ones (stage/unstage) run immediately; `discard`
/// is destructive and is gated by a confirmation in `DiffContentView`.
enum DiffAction { case stage, unstage, discard }

/// The diff object's content: a two-pane view — a changed-file list on the left and
/// the selected file's colored unified diff on the right — plus a footer with git
/// actions (stage/unstage/discard per file via hover, commit + bulk in the footer).
/// Reads via `GitDiff`; mutates via `GitActions` (destructive actions confirmed).
///
/// **Layout:** entirely Auto Layout — no `layout()` override, no manual `.frame`/
/// `sizeToFit` on controls. Manually framing these constraint-backed controls inside
/// the magnified canvas is what caused the window layout-loop crashes.
final class DiffContentView: NSView {
    private let folder: URL

    private let table = NSTableView()
    private let textView = NSTextView()
    private let tableScroll = NSScrollView()
    private let textScroll = NSScrollView()
    private let diffQueue = DispatchQueue(label: "agentcanvas.filediff", qos: .userInitiated)

    // Footer (git actions).
    private let footer = NSView()
    private let stageAllButton = NSButton()
    private let discardAllButton = NSButton()
    private let messageField = NSTextField()
    private let commitButton = NSButton()
    private let footerHeight: CGFloat = 40

    /// Called after any successful mutation so the owner can refresh the snapshot.
    var onMutated: (() -> Void)?

    /// Fraction of the width given to the file list (left pane).
    private let listFraction: CGFloat = 0.32

    private var changes: [GitChange] = []
    private var selectedPath: String?
    private var isRepo = true
    /// True while we set the selection programmatically, so the selection-change
    /// delegate doesn't double-render (we render once, explicitly, in `apply`).
    private var isApplying = false

    init(folder: URL) {
        self.folder = folder
        super.init(frame: .zero)
        wantsLayer = true
        buildPanes()
        buildFooter()
        setupConstraints()
        applyBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildPanes() {
        // Left: file list.
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = Theme.colors.listSurface
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = Theme.colors.listSurface
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableScroll)

        // Right: diff text. The textView is the scroll view's document — sized by the
        // scroll view (NOT by our constraints), so it keeps the classic manual setup.
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

    private func buildFooter() {
        footer.wantsLayer = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        styleButton(stageAllButton, title: "Stage All", action: #selector(stageAllTapped))
        styleButton(discardAllButton, title: "Discard All", action: #selector(discardAllTapped))
        footer.addSubview(stageAllButton)
        footer.addSubview(discardAllButton)

        messageField.placeholderString = "Commit message"
        messageField.font = Theme.fonts.listPath
        messageField.bezelStyle = .roundedBezel
        messageField.focusRingType = .none
        messageField.delegate = self
        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addSubview(messageField)

        styleButton(commitButton, title: "Commit", action: #selector(commitTapped))
        commitButton.keyEquivalent = "\r"   // Return commits
        footer.addSubview(commitButton)

        updateFooterEnablement()
    }

    private func styleButton(_ b: NSButton, title: String, action: Selector) {
        b.title = title
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = Theme.fonts.listStat
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupConstraints() {
        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            // Footer pinned to the bottom, fixed height.
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight),

            // Two panes fill everything above the footer; list takes `listFraction`.
            tableScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableScroll.topAnchor.constraint(equalTo: topAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            tableScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: listFraction),

            textScroll.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 1),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: topAnchor),
            textScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            // Footer controls: bulk on the left, commit on the right, message fills the middle.
            stageAllButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: pad),
            stageAllButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            discardAllButton.leadingAnchor.constraint(equalTo: stageAllButton.trailingAnchor, constant: 6),
            discardAllButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            commitButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -pad),
            commitButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            messageField.leadingAnchor.constraint(equalTo: discardAllButton.trailingAnchor, constant: 12),
            messageField.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -8),
            messageField.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    /// The view's own layer background is a frozen `.cgColor`, so re-resolve it when
    /// the appearance flips. (The scroll/text/table backgrounds are `NSColor` and adapt.)
    private func applyBackground() {
        layer?.backgroundColor = Theme.colors.contentSurface.cgColor
        footer.layer?.backgroundColor = Theme.colors.titleBar.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    // MARK: Update

    /// Apply a new snapshot: refresh the list, keep the current selection if it
    /// still exists (else select the first file), and render its diff.
    func apply(_ snapshot: GitSnapshot) {
        isRepo = snapshot.isRepo
        changes = snapshot.changes
        table.reloadData()
        updateFooterEnablement()

        guard isRepo else { showMessage("Not a git repository."); return }
        guard !changes.isEmpty else { selectedPath = nil; showMessage("No changes — clean working tree."); return }

        let keep = selectedPath.flatMap { p in changes.firstIndex { $0.path == p } } ?? 0
        isApplying = true
        table.selectRowIndexes(IndexSet(integer: keep), byExtendingSelection: false)
        isApplying = false
        renderDiff(for: changes[keep])   // single, explicit render (the delegate stays quiet)
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
    private var anyUnstaged: Bool { changes.contains { $0.hasUnstaged } }

    private func updateFooterEnablement() {
        stageAllButton.isEnabled = anyUnstaged
        discardAllButton.isEnabled = !changes.isEmpty
        commitButton.isEnabled = anyStaged && !messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    @objc private func stageAllTapped() {
        let folder = self.folder
        runMutation { GitActions.stageAll(folder: folder) }
    }

    @objc private func discardAllTapped() {
        let folder = self.folder
        let files = changes.count
        let untracked = changes.filter { $0.status == .untracked }.count
        var body = "This will revert all \(files) changed file\(files == 1 ? "" : "s") to the last commit"
        if untracked > 0 { body += " and permanently remove \(untracked) untracked file\(untracked == 1 ? "" : "s")" }
        body += ". This cannot be undone."
        confirm(title: "Discard ALL changes?", body: body, confirmTitle: "Discard All") { [weak self] in
            self?.runMutation { GitActions.discardAll(folder: folder) }
        }
    }

    @objc private func commitTapped() {
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, anyStaged else { return }
        let folder = self.folder
        runMutation(onSuccess: { [weak self] in self?.messageField.stringValue = ""; self?.updateFooterEnablement() }) {
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
    func controlTextDidChange(_ obj: Notification) { updateFooterEnablement() }
}

// MARK: - File list

extension DiffContentView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { changes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("DiffFileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DiffFileCell) ?? DiffFileCell(id: id)
        cell.onAction = { [weak self] action, change in self?.perform(action, on: change) }
        cell.configure(with: changes[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }   // programmatic selection renders itself
        let row = table.selectedRow
        guard row >= 0, row < changes.count else { return }
        renderDiff(for: changes[row])
    }
}

/// One row in the changed-file list: a status-colored dot, the path, and `+A −R`.
/// On hover the stat is replaced by Stage/Unstage + Discard buttons. Pure Auto
/// Layout via an `NSStackView` — hidden arranged subviews collapse, so show/hide
/// needs no manual frame work (which is what caused the layout-loop crashes).
private final class DiffFileCell: NSTableCellView {
    private let dot = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private let stageButton = NSButton()
    private let discardButton = NSButton()
    private var dotColor: NSColor = .clear   // remembered to re-resolve on appearance flip
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    private var change: GitChange?
    /// Set by the table; the cell reports which action the user invoked on its change.
    var onAction: ((DiffAction, GitChange) -> Void)?

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = Theme.fonts.listPath
        pathLabel.textColor = Theme.colors.textPrimary
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statLabel.font = Theme.fonts.listStat
        statLabel.alignment = .right
        statLabel.setContentHuggingPriority(.required, for: .horizontal)

        styleAction(stageButton, action: #selector(stageTapped))
        styleAction(discardButton, action: #selector(discardTapped))

        let row = NSStackView(views: [dot, pathLabel, statLabel, stageButton, discardButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        setHoverState()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func styleAction(_ b: NSButton, action: Selector) {
        b.bezelStyle = .rounded
        b.controlSize = .mini
        b.font = Theme.fonts.listStat
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(with change: GitChange) {
        self.change = change
        dotColor = change.status.color
        dot.layer?.backgroundColor = dotColor.cgColor
        let name = change.oldPath.map { "\($0) → \(change.path)" } ?? change.path
        pathLabel.stringValue = name
        let stat = NSMutableAttributedString()
        if change.added > 0 {
            stat.append(NSAttributedString(string: "+\(change.added) ", attributes: [.foregroundColor: Theme.colors.diffAdded]))
        }
        if change.removed > 0 {
            stat.append(NSAttributedString(string: "−\(change.removed)", attributes: [.foregroundColor: Theme.colors.diffRemoved]))
        }
        statLabel.attributedStringValue = stat
        // Stage button reflects state: stage if there are unstaged changes, else unstage.
        stageButton.title = change.hasUnstaged ? "Stage" : "Unstage"
        discardButton.title = "Discard"
        setHoverState()
    }

    @objc private func stageTapped() {
        guard let change else { return }
        onAction?(change.hasUnstaged ? .stage : .unstage, change)
    }
    @objc private func discardTapped() {
        guard let change else { return }
        onAction?(.discard, change)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; setHoverState() }
    override func mouseExited(with event: NSEvent) { hovering = false; setHoverState() }

    /// Toggle visibility only — the stack view collapses hidden arranged subviews and
    /// relays out itself. No `needsLayout`, no frame math.
    private func setHoverState() {
        statLabel.isHidden = hovering
        stageButton.isHidden = !hovering
        discardButton.isHidden = !hovering
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = dotColor.cgColor
        }
    }
}
