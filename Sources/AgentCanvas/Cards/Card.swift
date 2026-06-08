import AppKit
import SwiftTerm

/// An agent card: a Claude Code session running in a folder, shown on the canvas.
/// Owns its view (`ItemContainerView`) and its live terminal. Status mutates as
/// the spine delivers events.
final class Card: CanvasItem {
    let id: String
    var title: String
    var frame: NSRect
    let folder: URL
    private(set) var status: CardStatus = .idle
    var terminal: LocalProcessTerminalView?
    let containerView: ItemContainerView
    let kind = "card"

    init(id: String, title: String, frame: NSRect, folder: URL) {
        self.id = id
        self.title = title
        self.frame = frame
        self.folder = folder
        containerView = ItemContainerView(title: title)
        containerView.frame = frame
        containerView.contentInset = CanvasLayout.terminalPadding   // breathing room for the CLI
        containerView.setPlaceholder("idle — double-click to start")
        containerView.setAccent(color: status.color, loud: status.isLoud)
    }

    /// Apply a new status (no-op if unchanged) and refresh the accent.
    func apply(_ newStatus: CardStatus) {
        guard newStatus != status else { return }
        status = newStatus
        containerView.setAccent(color: newStatus.color, loud: newStatus.isLoud)
        canvasLog("\(title): \(newStatus)")
    }

    func record() -> Workspace.Item {
        Workspace.Item(kind: kind, id: id, title: title,
                       x: frame.minX, y: frame.minY, w: frame.width, h: frame.height,
                       folder: folder.path)
    }
}
