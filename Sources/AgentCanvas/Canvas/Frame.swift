import AppKit

/// A frame: a calm, labeled grouping boundary drawn *behind* a cluster of cards
/// (PRD §3.4-style spatial structure). It is NOT a `CanvasItem` — it has no window
/// chrome, isn't double-clicked to fly into, and is purely a backdrop you drop
/// cards onto. Membership is geometric (which cards sit inside its rect), so cards
/// aren't "trapped": drag one out and it simply leaves the group.
final class Frame {
    let id: String
    var name: String
    var rect: NSRect { didSet { view.frame = rect } }
    let view: FrameView
    let kind = "frame"

    init(id: String, name: String, rect: NSRect) {
        self.id = id
        self.name = name
        self.rect = rect
        view = FrameView()
        view.frame = rect
        view.configure(name: name)
    }

    /// Cards whose center sits inside this frame are its members.
    func members(in cards: [Card]) -> [Card] {
        cards.filter { rect.contains(NSPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    func record() -> Workspace.Item {
        Workspace.Item(kind: kind, id: id, title: name,
                       x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                       folder: nil)
    }
}
