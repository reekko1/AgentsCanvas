import AppKit

/// The collection of on-canvas items (agent cards + diff objects today): registry,
/// id sequencing, content bounds, and (de)serialization to a `Workspace`. Pure data
/// — it never touches the view tree, and treats everything through `CanvasItem`.
/// The controller constructs concrete items (it owns their wiring) and registers them here.
final class ItemStore {
    private(set) var items: [CanvasItem] = []
    private var byId: [String: CanvasItem] = [:]
    private(set) var seq = 0

    func item(_ id: String) -> CanvasItem? { byId[id] }
    /// Typed convenience for the spine, which only routes status to agent cards.
    func card(_ id: String) -> Card? { byId[id] as? Card }

    func add(_ item: CanvasItem) {
        items.append(item)
        byId[item.id] = item
    }

    func remove(_ item: CanvasItem) {
        items.removeAll { $0 === item }
        byId[item.id] = nil
    }

    /// One shared counter across kinds; the prefix keeps ids unique (`card-3`, `diff-4`).
    func nextId(prefix: String) -> String {
        seq += 1
        return "\(prefix)-\(seq)"
    }

    func restore(seq: Int) { self.seq = seq }

    /// The bounding box of all items (with margin) — what "fit all" targets. Falls
    /// back to a nominal home area when empty. Kind-agnostic geometry.
    var bounds: NSRect {
        guard let first = items.first else {
            let c = CanvasLayout.canvasCenter
            return NSRect(x: c.x - CanvasLayout.cardSize.width, y: c.y - CanvasLayout.cardSize.height,
                          width: CanvasLayout.cardSize.width * 2, height: CanvasLayout.cardSize.height * 2)
        }
        var u = first.frame
        for item in items.dropFirst() { u = u.union(item.frame) }
        return u.insetBy(dx: -CanvasLayout.margin, dy: -CanvasLayout.margin)
    }

    // MARK: Persistence
    func workspace(viewport: Workspace.Viewport) -> Workspace {
        Workspace(seq: seq, items: items.map { $0.record() }, viewport: viewport)
    }
}
