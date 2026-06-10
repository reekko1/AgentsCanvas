import AppKit

/// A diff object (PRD §4.2): the git diff + changed-file list for a folder, as its
/// own floating canvas item — deliberately *not* bolted to a card. Read-only: it
/// observes git via `DiffWatcher`/`GitDiff` and never mutates the repo.
///
/// Unlike a card it is live immediately (no lazy spawn): rendering git output is
/// cheap. Its title bar carries the diffstat so there's an at-distance cue when the
/// two-pane body is too small to read at god-view.
final class DiffObject: CanvasItem {
    let id: String
    let folder: URL
    var frame: NSRect
    let containerView: ItemContainerView
    let kind = "diff"

    private let name: String
    private let diffView: DiffContentView
    private let watcher: DiffWatcher

    init(id: String, frame: NSRect, folder: URL) {
        self.id = id
        self.frame = frame
        self.folder = folder
        self.name = folder.lastPathComponent
        containerView = ItemContainerView(title: name)
        containerView.frame = frame
        containerView.bodyColor = Theme.colors.diffSurface
        diffView = DiffContentView(folder: folder)
        watcher = DiffWatcher(folder: folder)
        containerView.setContent(diffView)
        // Calm, neutral accent + no bead — status colors belong to agent cards, not diffs.
        containerView.setBead(visible: false)
        containerView.setAccent(color: Theme.colors.neutralBorder, glow: .none)
        containerView.enableResize(minSize: CanvasLayout.minItemSize)

        watcher.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.diffView.apply(snapshot)
            self.containerView.setTrailing(self.diffstat(for: snapshot))
        }
        diffView.onMutated = { [weak self] in self?.watcher.poke() }  // refresh right after a git action
    }

    func start() { watcher.start() }
    func stop() { watcher.stop() }

    /// The trailing diffstat shown in the title bar (an at-distance cue).
    private func diffstat(for s: GitSnapshot) -> NSAttributedString {
        let font = Theme.fonts.listStat
        guard s.isRepo else {
            return NSAttributedString(string: "not a repo",
                                      attributes: [.foregroundColor: Theme.colors.textMuted, .font: font])
        }
        guard !s.changes.isEmpty else {
            return NSAttributedString(string: "✓ clean",
                                      attributes: [.foregroundColor: Theme.colors.statusDone, .font: font])
        }
        let r = NSMutableAttributedString()
        r.append(NSAttributedString(string: "+\(s.totalAdded)",
                                    attributes: [.foregroundColor: Theme.colors.diffAdded, .font: font]))
        r.append(NSAttributedString(string: "  −\(s.totalRemoved)",
                                    attributes: [.foregroundColor: Theme.colors.diffRemoved, .font: font]))
        return r
    }

    func record() -> Workspace.Item {
        Workspace.Item(kind: kind, id: id, title: name,
                       x: frame.minX, y: frame.minY, w: frame.width, h: frame.height,
                       folder: folder.path)
    }
}
