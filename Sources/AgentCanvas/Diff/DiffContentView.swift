import AppKit

/// A per-file git action. Reversible ones (stage/unstage) run immediately; `discard`
/// is destructive and is gated by a confirmation in `DiffContentView`.
enum DiffAction { case stage, unstage, discard }

/// The diff object's content: a two-pane view — a changed-file list on the left and
/// the selected file's colored unified diff on the right — plus a footer with git
/// actions (stage/unstage/discard per file via hover, commit + bulk in the footer).
/// Reads via `GitDiff`; mutates via `GitActions` (destructive actions confirmed).
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
        applyBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildPanes() {
        // Left: file list. Frame-based (autoresizing off) — positioned in `layout()`.
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
        tableScroll.autoresizingMask = []
        addSubview(tableScroll)

        // Right: diff text.
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
        textScroll.autoresizingMask = []
        addSubview(textScroll)
    }

    private func buildFooter() {
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.colors.titleBar.cgColor
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

    override func layout() {
        super.layout()
        // Manual layout (no Auto Layout — consistent with the rest of the app, and
        // NSSplitView's proportional resizing kept collapsing the list pane). Setting
        // subview frames here does not re-dirty our layout.
        let w = bounds.width, h = bounds.height
        let divider: CGFloat = 1

        // Footer pinned to the bottom (this view is unflipped → y=0 is the bottom).
        footer.frame = NSRect(x: 0, y: 0, width: w, height: footerHeight)
        let pad: CGFloat = 8, bh: CGFloat = 22, by = (footerHeight - bh) / 2
        stageAllButton.sizeToFit();   discardAllButton.sizeToFit();   commitButton.sizeToFit()
        let saW = stageAllButton.frame.width, daW = discardAllButton.frame.width, cW = max(70, commitButton.frame.width)
        stageAllButton.frame = NSRect(x: pad, y: by, width: saW, height: bh)
        discardAllButton.frame = NSRect(x: pad + saW + 6, y: by, width: daW, height: bh)
        commitButton.frame = NSRect(x: w - pad - cW, y: by, width: cW, height: bh)
        let msgX = pad + saW + 6 + daW + 12
        messageField.frame = NSRect(x: msgX, y: by, width: max(0, w - pad - cW - 8 - msgX), height: bh)

        // Two panes fill everything above the footer.
        let paneH = max(0, h - footerHeight)
        let leftW = (w * listFraction).rounded()
        tableScroll.frame = NSRect(x: 0, y: footerHeight, width: leftW, height: paneH)
        textScroll.frame = NSRect(x: leftW + divider, y: footerHeight, width: max(0, w - leftW - divider), height: paneH)
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
/// On hover the stat is replaced by Stage/Unstage + Discard buttons.
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
        addSubview(dot)

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = Theme.fonts.listPath
        pathLabel.textColor = Theme.colors.textPrimary
        addSubview(pathLabel)

        statLabel.font = Theme.fonts.listStat
        statLabel.alignment = .right
        addSubview(statLabel)

        styleAction(stageButton, action: #selector(stageTapped))
        styleAction(discardButton, action: #selector(discardTapped))
        stageButton.isHidden = true
        discardButton.isHidden = true
        addSubview(stageButton)
        addSubview(discardButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func styleAction(_ b: NSButton, action: Selector) {
        b.bezelStyle = .rounded
        b.controlSize = .mini
        b.font = Theme.fonts.listStat
        b.target = self
        b.action = action
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
        updateHoverVisibility()
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
    override func mouseEntered(with event: NSEvent) { hovering = true; updateHoverVisibility() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateHoverVisibility() }

    private func updateHoverVisibility() {
        stageButton.isHidden = !hovering
        discardButton.isHidden = !hovering
        statLabel.isHidden = hovering   // buttons take the stat's spot
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = dotColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.frame = NSRect(x: 8, y: h / 2 - 4, width: 8, height: 8)
        if hovering {
            discardButton.sizeToFit(); stageButton.sizeToFit()
            let dW = discardButton.frame.width, sW = stageButton.frame.width
            discardButton.frame = NSRect(x: bounds.width - dW - 8, y: h / 2 - 9, width: dW, height: 18)
            stageButton.frame = NSRect(x: bounds.width - dW - sW - 12, y: h / 2 - 9, width: sW, height: 18)
            pathLabel.frame = NSRect(x: 24, y: h / 2 - 9, width: max(0, bounds.width - 24 - dW - sW - 18), height: 18)
        } else {
            statLabel.sizeToFit()
            let sw = max(statLabel.frame.width, 48)
            statLabel.frame = NSRect(x: bounds.width - sw - 8, y: h / 2 - 9, width: sw, height: 18)
            pathLabel.frame = NSRect(x: 24, y: h / 2 - 9, width: bounds.width - 24 - sw - 14, height: 18)
        }
    }
}
