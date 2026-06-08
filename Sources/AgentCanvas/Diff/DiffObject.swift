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
        diffView = DiffContentView(folder: folder)
        watcher = DiffWatcher(folder: folder)
        containerView.setContent(diffView)
        // Calm, neutral accent — status colors belong to agent cards, not diffs.
        containerView.setAccent(color: Theme.colors.neutralBorder, loud: false)

        watcher.onChange = { [weak self] snapshot in
            self?.diffView.apply(snapshot)
            self?.containerView.setTitle(self?.titleText(for: snapshot) ?? "")
        }
        diffView.onMutated = { [weak self] in self?.watcher.poke() }  // refresh right after a git action
    }

    func start() { watcher.start() }
    func stop() { watcher.stop() }

    private func titleText(for snapshot: GitSnapshot) -> String {
        guard snapshot.isRepo else { return "\(name)  —  not a git repo" }
        guard !snapshot.changes.isEmpty else { return "\(name)  ✓ clean" }
        let files = snapshot.changes.count
        return "\(name)   \(files) file\(files == 1 ? "" : "s")  +\(snapshot.totalAdded) −\(snapshot.totalRemoved)"
    }

    func record() -> Workspace.Item {
        Workspace.Item(kind: kind, id: id, title: name,
                       x: frame.minX, y: frame.minY, w: frame.width, h: frame.height,
                       folder: folder.path)
    }
}
