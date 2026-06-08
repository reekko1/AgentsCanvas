import AppKit

/// Anything that lives on the canvas as a movable, framed window. Cards conform
/// today; the diff object (PRD §4.2) will conform next, sharing placement,
/// dragging, deletion, and the `ItemContainerView` chrome. The controller treats
/// items through this protocol for view placement and movement.
protocol CanvasItem: AnyObject {
    var id: String { get }
    var frame: NSRect { get set }
    var containerView: ItemContainerView { get }
    /// Discriminator used by persistence (`"card"`, `"diff"`, …) and the
    /// controller when restoring a workspace.
    var kind: String { get }
    /// Self-serialize to a persisted record. Each item kind decides which
    /// `Workspace.Item` fields it fills (e.g. `folder`).
    func record() -> Workspace.Item
}
