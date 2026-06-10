import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` plus macOS text-editing muscle memory, translated
/// to the shell's line-edit chords. ⌘-chords arrive via `performKeyEquivalent`
/// (sent to the whole view tree, not just the focused view), so each mapping
/// guards on first-responder to avoid one card eating another's keystroke.
final class CanvasTerminalView: LocalProcessTerminalView {
    private let deleteKeyCode: UInt16 = 51

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        // ⌘⌫ → ^U: kill the input line, the terminal twin of delete-to-line-start.
        if event.modifierFlags.contains(.command), event.keyCode == deleteKeyCode {
            send([0x15])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
