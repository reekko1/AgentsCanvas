import AppKit
import SwiftTerm

/// What a card runs.
/// - `.agent`: a Claude Code session, watched by the spine → status bead + glow.
/// - `.shell`: a bare `$SHELL` terminal — no agent, no hooks, no status. Neutral chrome.
enum CardRole { case agent, shell }

/// A card on the canvas: a terminal running in a folder. Owns its view
/// (`ItemContainerView`) and its live terminal. Agent cards accumulate spine
/// state (status + when it changed, task label, model, permission mode, subagent
/// count); shell cards stay neutral.
final class Card: CanvasItem {
    let id: String
    var title: String
    var frame: NSRect
    let folder: URL
    let role: CardRole
    var terminal: LocalProcessTerminalView?
    let containerView: ItemContainerView
    var kind: String { role == .shell ? "shell" : "card" }

    private(set) var status: CardStatus = .idle
    /// When the current status began — attention debt ("blocked 14m") and
    /// oldest-first triage both rank on this.
    private(set) var statusSince = Date()
    /// Last spine event of any kind — the heartbeat for stall detection.
    private(set) var lastEventAt = Date()
    private(set) var taskLabel: String?
    private(set) var model: String?
    private(set) var permissionMode: String?
    private(set) var subagentCount = 0

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

    /// Apply a spine event (agent cards only). Returns true when the *status*
    /// changed — the controller's feed-worthiness signal.
    @discardableResult
    func apply(_ e: CardEvent) -> Bool {
        guard role == .agent else { return false }
        lastEventAt = Date()
        if let m = e.model { model = m }
        if let pm = e.permissionMode { permissionMode = pm }
        if e.resetSubagents { subagentCount = 0 }
        subagentCount = max(0, subagentCount + e.subagentDelta)
        if e.clearTask { taskLabel = nil }
        if let t = e.taskLabel { taskLabel = t }

        var changed = false
        if let s = e.status, s != status {
            status = s
            statusSince = Date()
            changed = true
            canvasLog("\(title): \(s)")
        }
        applyVisual(status)
        containerView.setSubtitle(metaText())
        return changed
    }

    /// The stall watchdog's verdict: a running card gone silent. Returns true if
    /// it actually flipped (so the controller records it once, not every tick).
    func markStalled() -> Bool {
        guard role == .agent, status == .running else { return false }
        status = .stalled
        statusSince = Date()
        applyVisual(status)
        canvasLog("\(title): stalled (no events)")
        return true
    }

    /// Periodic tick from the controller's clock: keep the "· 14m" attention-debt
    /// suffix current on cards that carry one.
    func tick() {
        guard role == .agent, status.isLoud || status == .stalled else { return }
        applyVisual(status)
    }

    /// Translate the status into the chrome's bead + status-word + glow. A shell
    /// card ignores status entirely and shows a calm, neutral terminal chrome.
    private func applyVisual(_ s: CardStatus) {
        guard role == .agent else { applyShellVisual(); return }
        let c = s.color
        containerView.setTrailing(trailingText(for: s))
        switch s {
        case .idle:
            containerView.setBead(visible: true, color: Theme.colors.statusIdle, glow: false, pulse: .none)
            containerView.setAccent(color: Theme.colors.statusIdle, glow: .none)
        case .running:
            containerView.setBead(visible: true, color: c, glow: true, pulse: .breathe(3.4))
            containerView.setAccent(color: c, glow: .calm(breathe: 3.4))
        case .waiting:
            // Turn over, background work alive — calmer than running, not done-green.
            containerView.setBead(visible: true, color: c, glow: true, pulse: .breathe(5.2))
            containerView.setAccent(color: c, glow: .calm(breathe: 5.2))
        case .done:
            containerView.setBead(visible: true, color: c, glow: true, pulse: .none)
            containerView.setAccent(color: c, glow: .calm(breathe: nil))
        case .stalled:
            // Deserves a look, not an alarm: steady ochre, no pulse.
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

    /// "✦2 · BLOCKED · 14m" — subagent count, status word, and (for states that
    /// accumulate attention debt) how long it's been in that state.
    private func trailingText(for s: CardStatus) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = Theme.fonts.statusWord
        if subagentCount > 0 {
            result.append(NSAttributedString(string: "✦\(subagentCount) · ", attributes: [
                .foregroundColor: Theme.colors.textMuted, .font: font,
            ]))
        }
        var word = s.word.uppercased()
        if s.isLoud || s == .stalled {
            let mins = Int(Date().timeIntervalSince(statusSince) / 60)
            if mins >= 1 { word += " · \(mins)m" }
        }
        result.append(NSAttributedString(string: word, attributes: [
            .foregroundColor: s.isLoud ? s.color : Theme.colors.textMuted,
            .font: font,
        ]))
        return result
    }

    /// The subtitle line under the title: unguarded-mode warning, model, and what
    /// the agent is working on. Nil (row hidden) until the spine has said anything.
    private func metaText() -> NSAttributedString? {
        let s = NSMutableAttributedString()
        let font = Theme.fonts.listStat
        func add(_ text: String, _ color: NSColor) {
            if s.length > 0 {
                s.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        // A card in an unguarded mode can never go loud — it never asks. That
        // absence of a possible alarm is itself supervision-critical, so flag it.
        if permissionMode == "bypassPermissions" {
            add("BYPASS", Theme.colors.statusError)
        } else if permissionMode == "dontAsk" {
            add("DON'T-ASK", Theme.colors.statusBlocked)
        }
        if let model { add(model, Theme.colors.textMuted) }
        if let taskLabel { add("· \(taskLabel)", Theme.colors.textMuted) }
        return s.length > 0 ? s : nil
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
