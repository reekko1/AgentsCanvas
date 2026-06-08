import AppKit

/// The window toolbar (unified style). Holds the canvas's create actions today
/// (new agent card, new diff object) and is the natural home for future actions.
/// Keeps toolbar boilerplate out of the controller — the controller just wires the
/// callbacks and assigns `make()` to its window.
final class CanvasToolbar: NSObject, NSToolbarDelegate {
    var onNewCard: (() -> Void)?
    var onNewDiff: (() -> Void)?

    private let newCardId = NSToolbarItem.Identifier("newCard")
    private let newDiffId = NSToolbarItem.Identifier("newDiff")

    func make() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "AgentCanvasToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [newCardId, newDiffId]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [newCardId, newDiffId, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case newCardId:
            return item(id, label: "New Agent", symbol: "plus.rectangle.on.rectangle",
                        action: #selector(newCardTapped))
        case newDiffId:
            return item(id, label: "New Diff", symbol: "arrow.triangle.branch",
                        action: #selector(newDiffTapped))
        default:
            return nil
        }
    }

    private func item(_ id: NSToolbarItem.Identifier, label: String, symbol: String,
                      action: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        it.label = label
        it.toolTip = label
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        it.target = self
        it.action = action
        it.isBordered = true
        return it
    }

    @objc private func newCardTapped() { onNewCard?() }
    @objc private func newDiffTapped() { onNewDiff?() }
}
