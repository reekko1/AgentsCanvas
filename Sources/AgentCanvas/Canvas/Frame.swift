import AppKit

/// A frame: a calm, labeled grouping boundary drawn *behind* a cluster of cards
/// (PRD §3.4-style spatial structure). It is NOT a `CanvasItem` — it has no window
/// chrome, isn't double-clicked to fly into, and is purely a backdrop you drop
/// cards onto. Membership is geometric (which cards sit inside its rect), so cards
/// aren't "trapped": drag one out and it simply leaves the group.
///
/// It owns two views: `view` (the dashed body, on the magnified canvas, behind the
/// cards) and `label` (a constant-size overlay that floats above the cards so it
/// stays readable and reachable at any zoom).
final class Frame {
    let id: String
    var name: String { didSet { label.setName(name) } }
    var rect: NSRect { didSet { view.frame = rect } }
    let view = FrameView()
    let label = FrameLabelOverlay()
    let kind = "frame"

    init(id: String, name: String, rect: NSRect) {
        self.id = id
        self.name = name
        self.rect = rect
        view.frame = rect           // didSet doesn't fire during init — set explicitly
        label.setName(name)
    }

    func update(count: Int, loud: NSColor?) { label.update(count: count, loud: loud) }

    func record() -> Workspace.Item {
        Workspace.Item(kind: kind, id: id, title: name,
                       x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                       folder: nil)
    }
}
