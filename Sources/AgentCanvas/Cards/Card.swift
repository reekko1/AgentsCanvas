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

    init(id: String, title: String, frame: NSRect, folder: URL) {
        self.id = id
        self.title = title
        self.frame = frame
        self.folder = folder
        containerView = ItemContainerView(title: title)
        containerView.frame = frame
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
}
