import AppKit
import SwiftTerm

/// What a card runs.
/// - `.agent`: a Claude Code session, watched by the spine → status bead + glow.
/// - `.shell`: a bare `$SHELL` terminal — no agent, no hooks, no status. Neutral chrome.
enum CardRole { case agent, shell }

/// A card on the canvas: a terminal running in a folder. Owns its view
/// (`ItemContainerView`) and its live terminal. Agent cards mutate status as the
/// spine delivers events; shell cards stay neutral.
final class Card: CanvasItem {
    let id: String
    var title: String
    var frame: NSRect
    let folder: URL
    let role: CardRole
    private(set) var status: CardStatus = .idle
    var terminal: LocalProcessTerminalView?
    let containerView: ItemContainerView
    var kind: String { role == .shell ? "shell" : "card" }

    init(id: String, title: String, frame: NSRect, folder: URL, role: CardRole = .agent) {
        self.id = id
        self.title = title
        self.frame = frame
        self.folder = folder
        self.role = role
        containerView = ItemContainerView(title: title)
        containerView.frame = frame
        containerView.bodyColor = Theme.colors.terminalBg            // dark screen bezel in the inset gap
        containerView.showsScreenTexture = true                      // lo-fi CRT overlay on the terminal
        containerView.contentInset = CanvasLayout.terminalPadding    // breathing room for the CLI
        containerView.configureTitle(dir: Self.dirPrefix(for: folder), name: title)
        containerView.setPlaceholder(role == .shell ? "tap to open shell" : "tap to start")
        containerView.enableResize(minSize: CanvasLayout.minItemSize)
        applyVisual(status)
    }

    /// Apply a new status (agent cards only) and refresh the bead + glow.
    func apply(_ newStatus: CardStatus) {
        guard role == .agent, newStatus != status else { return }
        status = newStatus
        applyVisual(newStatus)
        canvasLog("\(title): \(newStatus)")
    }

    /// Translate a `CardStatus` into the chrome's bead + status-word + glow. A shell
    /// card ignores status entirely and shows a calm, neutral terminal chrome.
    private func applyVisual(_ s: CardStatus) {
        guard role == .agent else { applyShellVisual(); return }
        let c = s.color
        containerView.setTrailing(NSAttributedString(string: s.word.uppercased(), attributes: [
            .foregroundColor: s.isLoud ? c : Theme.colors.textMuted,
            .font: Theme.fonts.statusWord,
        ]))
        switch s {
        case .idle:
            containerView.setBead(visible: true, color: Theme.colors.statusIdle, glow: false, pulse: .none)
            containerView.setAccent(color: Theme.colors.statusIdle, glow: .none)
        case .running:
            containerView.setBead(visible: true, color: c, glow: true, pulse: .breathe(3.4))
            containerView.setAccent(color: c, glow: .calm(breathe: 3.4))
        case .done:
            containerView.setBead(visible: true, color: c, glow: true, pulse: .none)
            containerView.setAccent(color: c, glow: .calm(breathe: nil))
        case .blocked:
            containerView.setBead(visible: true, color: c, glow: true, pulse: .breathe(1.8))
            containerView.setAccent(color: c, glow: .loud(breathe: 1.8), barTint: c)
        case .error:
            containerView.setBead(visible: true, color: c, glow: true, pulse: .alarm)
            containerView.setAccent(color: c, glow: .loud(breathe: nil), barTint: c)
        }
    }

    /// Calm, neutral chrome for a plain shell: a dim bead, the shell name, no glow.
    private func applyShellVisual() {
        let shell = (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent ?? "shell"
        containerView.setBead(visible: true, color: Theme.colors.statusIdle, glow: false, pulse: .none)
        containerView.setTrailing(NSAttributedString(string: shell.uppercased(), attributes: [
            .foregroundColor: Theme.colors.textMuted,
            .font: Theme.fonts.statusWord,
        ]))
        containerView.setAccent(color: Theme.colors.neutralBorder, glow: .none)
    }

    /// A tidy directory prefix for the title (e.g. `work/`), home-abbreviated.
    private static func dirPrefix(for folder: URL) -> String? {
        let parent = folder.deletingLastPathComponent()
        let last = parent.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        return last + "/"
    }

    func record() -> Workspace.Item {
        Workspace.Item(kind: kind, id: id, title: title,
                       x: frame.minX, y: frame.minY, w: frame.width, h: frame.height,
                       folder: folder.path)
    }
}
