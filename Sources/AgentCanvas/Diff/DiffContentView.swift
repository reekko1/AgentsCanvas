import AppKit

/// The diff object's content: a two-pane view — a changed-file list on the left and
/// the selected file's colored unified diff on the right. Read-only; it only renders
/// what `GitDiff` reports. Driven by `apply(_:)` from the watcher.
final class DiffContentView: NSView {
    private let folder: URL

    private let table = NSTableView()
    private let textView = NSTextView()
    private let tableScroll = NSScrollView()
    private let textScroll = NSScrollView()
    private let diffQueue = DispatchQueue(label: "agentcanvas.filediff", qos: .userInitiated)

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

    /// The view's own layer background is a frozen `.cgColor`, so re-resolve it when
    /// the appearance flips. (The scroll/text/table backgrounds are `NSColor` and adapt.)
    private func applyBackground() {
        layer?.backgroundColor = Theme.colors.contentSurface.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    override func layout() {
        super.layout()
        // Manual two-pane split (NSSplitView's proportional resizing kept collapsing
        // the list pane). Setting subview frames here does not re-dirty our layout.
        let w = bounds.width, h = bounds.height
        let divider: CGFloat = 1
        let leftW = (w * listFraction).rounded()
        tableScroll.frame = NSRect(x: 0, y: 0, width: leftW, height: h)
        textScroll.frame = NSRect(x: leftW + divider, y: 0, width: max(0, w - leftW - divider), height: h)
    }

    // MARK: Update

    /// Apply a new snapshot: refresh the list, keep the current selection if it
    /// still exists (else select the first file), and render its diff.
    func apply(_ snapshot: GitSnapshot) {
        isRepo = snapshot.isRepo
        changes = snapshot.changes
        table.reloadData()

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
}

// MARK: - File list

extension DiffContentView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { changes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("DiffFileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DiffFileCell) ?? DiffFileCell(id: id)
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
private final class DiffFileCell: NSTableCellView {
    private let dot = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private var dotColor: NSColor = .clear   // remembered to re-resolve on appearance flip

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
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with change: GitChange) {
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
        statLabel.sizeToFit()
        let sw = max(statLabel.frame.width, 48)
        statLabel.frame = NSRect(x: bounds.width - sw - 8, y: h / 2 - 9, width: sw, height: 18)
        pathLabel.frame = NSRect(x: 24, y: h / 2 - 9, width: bounds.width - 24 - sw - 14, height: 18)
    }
}
