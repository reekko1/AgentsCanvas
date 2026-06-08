import AppKit

/// The collection of cards: registry, id sequencing, content bounds, and
/// (de)serialization to a `Workspace`. Pure data — it never touches the view tree
/// (the controller adds/removes `card.containerView`).
final class CardStore {
    private(set) var items: [Card] = []
    private var byId: [String: Card] = [:]
    private(set) var seq = 0

    func card(_ id: String) -> Card? { byId[id] }

    func add(_ card: Card) {
        items.append(card)
        byId[card.id] = card
    }

    func remove(_ card: Card) {
        items.removeAll { $0 === card }
        byId[card.id] = nil
    }

    func nextId() -> String {
        seq += 1
        return "card-\(seq)"
    }

    /// The bounding box of all cards (with margin) — what "fit all" targets. Falls
    /// back to a nominal home area when empty.
    var bounds: NSRect {
        guard let first = items.first else {
            let c = CanvasLayout.canvasCenter
            return NSRect(x: c.x - CanvasLayout.cardSize.width, y: c.y - CanvasLayout.cardSize.height,
                          width: CanvasLayout.cardSize.width * 2, height: CanvasLayout.cardSize.height * 2)
        }
        var u = first.frame
        for card in items.dropFirst() { u = u.union(card.frame) }
        return u.insetBy(dx: -CanvasLayout.margin, dy: -CanvasLayout.margin)
    }

    // MARK: Persistence
    func load(_ ws: Workspace) {
        seq = ws.seq
        for item in ws.items where item.kind == "card" {
            guard let folder = item.folder else { continue }
            let card = Card(id: item.id, title: item.title,
                            frame: NSRect(x: item.x, y: item.y, width: item.w, height: item.h),
                            folder: URL(fileURLWithPath: folder))
            add(card)
        }
    }

    func workspace(viewport: Workspace.Viewport) -> Workspace {
        let records = items.map {
            Workspace.Item(kind: "card", id: $0.id, title: $0.title,
                           x: $0.frame.minX, y: $0.frame.minY, w: $0.frame.width, h: $0.frame.height,
                           folder: $0.folder.path)
        }
        return Workspace(seq: seq, items: records, viewport: viewport)
    }
}
