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
    /// Poster material accumulated from the spine: the most recent action line
    /// ("Bash: npm test"), the last turn's closing message, and the agent's
    /// self-published plan (TaskCreate/TaskUpdate deltas, TodoWrite replaces).
    private(set) var lastDetail: String?
    private(set) var lastSummary: String?
    private(set) var todos: [AgentTodo] = []
    /// The CLI session currently running in this card. Persisted (unlike status)
    /// because a tmux session outlives the app: it keys the re-hydration of the
    /// plan from the CLI's own task store on reattach.
    private(set) var sessionId: String?

    /// The far-zoom LOD face. Lives alongside the terminal; `updateLOD` swaps
    /// which of the two occupies the container's content area — and the
    /// container's `content` is the single source of truth for which is shown.
    private let poster = CardPosterView()
    private var posterIsShowing: Bool { containerView.content === poster }

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
        if let d = e.detail { lastDetail = d }
        if let s = e.summary { lastSummary = s }
        if let change = e.todoChange { applyTodoChange(change) }

        var changed = false
        if let s = e.status, s != status {
            status = s
            statusSince = Date()
            changed = true
            canvasLog("\(title): \(s)")
        }
        applyVisual(status)
        containerView.setSubtitle(metaText())
        refreshPoster()
        return changed
    }

    /// Record which CLI session this card is running. Returns true when it
    /// changed — the controller's cue to re-hydrate the plan from the CLI's
    /// task store (events only carry deltas; the store has the whole list).
    @discardableResult
    func noteSession(_ id: String) -> Bool {
        guard id != sessionId else { return false }
        sessionId = id
        return true
    }

    /// Replace the plan with the CLI's stored list (reattach/restart path).
    func hydrateTodos(_ list: [AgentTodo]) {
        todos = list
        refreshPoster()
    }

    /// Fold a plan delta into the accumulated task list. The CLI streams the
    /// plan incrementally (create/update by id); the card is where it adds up.
    private func applyTodoChange(_ change: TodoChange) {
        switch change {
        case .replace(let list):
            todos = list
        case .add(let todo):
            todos.removeAll { $0.id == todo.id }   // re-created id → replace, don't duplicate
            todos.append(todo)
        case .update(let id, let status, let content, let activeForm):
            if status == "deleted" { todos.removeAll { $0.id == id }; return }
            guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
            if let status { todos[i].status = status }
            if let content { todos[i].content = content }
            if let activeForm { todos[i].activeForm = activeForm }
        case .clear:
            todos = []
        }
    }

    // MARK: Poster LOD

    /// The canvas resized this card — re-pin the poster's wrapping width.
    func noteFrameChanged() { refreshPoster() }

    /// Level-of-detail for the current magnification: terminal when focused,
    /// poster when far — with the poster's type zoom-compensated (≈1/mag) so it
    /// holds a constant on-screen size as the camera pulls back. Only a spawned
    /// agent card swaps — a dormant card's placeholder and a shell's terminal
    /// stay put. Detaching the terminal at far zoom is also a perf win: an
    /// off-LOD terminal stops compositing (the PTY keeps streaming regardless).
    func updateLOD(magnification: CGFloat) {
        guard role == .agent, let terminal else { return }
        if magnification >= CanvasLayout.posterMagnification {
            if posterIsShowing { containerView.setContent(terminal) }
        } else {
            poster.setScale(posterScale(for: magnification))   // before the swap → first layout is right
            if !posterIsShowing {
                containerView.setContent(poster)
                refreshPoster()   // render now that it's visible (off-LOD renders are skipped)
            }
        }
    }

    /// Zoom compensation for the poster's type: 1/mag for constant on-screen
    /// size, capped globally (`posterMaxScale`) and by this card's height (the
    /// status + headline core must fit), and quantized to ~20% steps so a camera
    /// fly re-layouts the poster a handful of times, not every frame.
    private func posterScale(for magnification: CGFloat) -> CGFloat {
        let raw = min(1 / magnification,
                      CanvasLayout.posterMaxScale,
                      frame.height / CanvasLayout.posterCoreHeight)
        guard raw > 1 else { return 1 }
        let step = CanvasLayout.posterScaleStep
        return pow(step, (log(raw) / log(step)).rounded())
    }

    /// Push current spine state into the poster's labels — only while the poster
    /// is actually on screen. Off-LOD (terminal showing) this is a no-op; the
    /// swap-in path in `updateLOD` re-renders, so nothing is ever stale.
    private func refreshPoster() {
        guard posterIsShowing else { return }
        poster.setLayoutWidth(frame.width - 2 * CanvasLayout.terminalPadding)
        poster.render(posterModel())
    }

    /// Shape the poster by state: what a glance needs differs completely between
    /// a card mid-work (plan + live action), one that finished (the payoff line),
    /// and one that's asking (what it wants).
    private func posterModel() -> PosterModel {
        var statusLine = statusWordWithDebt(status)
        if subagentCount > 0 { statusLine = "✦\(subagentCount) · " + statusLine }

        let headline = taskLabel ?? title

        let body: String?
        var bodyColor = Theme.colors.termMuted
        switch status {
        case .done:
            body = lastSummary ?? "Finished — waiting for you"
            bodyColor = Theme.colors.termText        // the payoff line earns full ink
        case .blocked, .error:
            body = lastDetail
            bodyColor = status.color
        default:
            body = lastDetail
        }
        // The whole plan rides along — the poster collapses it to its row budget
        // (titles when they fit, "✓ n done / … n more" when they don't).
        return PosterModel(statusLine: statusLine, statusColor: status.color,
                           headline: headline, todos: todos,
                           body: body, bodyColor: bodyColor)
    }

    /// The stall watchdog's verdict: a running card gone silent. Returns true if
    /// it actually flipped (so the controller records it once, not every tick).
    func markStalled() -> Bool {
        guard role == .agent, status == .running else { return false }
        status = .stalled
        statusSince = Date()
        applyVisual(status)
        refreshPoster()
        canvasLog("\(title): stalled (no events)")
        return true
    }

    /// Periodic tick from the controller's clock: keep the "· 14m" attention-debt
    /// suffix current on cards that carry one.
    func tick() {
        guard role == .agent, status.isLoud || status == .stalled else { return }
        applyVisual(status)
        refreshPoster()
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

    /// "BLOCKED · 14m" — the status word plus, for states that accumulate
    /// attention debt, how long it's been in that state. The one formatting
    /// rule shared by the title bar and the poster.
    private func statusWordWithDebt(_ s: CardStatus) -> String {
        var word = s.word.uppercased()
        if s.isLoud || s == .stalled {
            let mins = Int(Date().timeIntervalSince(statusSince) / 60)
            if mins >= 1 { word += " · \(mins)m" }
        }
        return word
    }

    /// "✦2 · BLOCKED · 14m" — subagent count + the status-with-debt word.
    private func trailingText(for s: CardStatus) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = Theme.fonts.statusWord
        if subagentCount > 0 {
            result.append(NSAttributedString(string: "✦\(subagentCount) · ", attributes: [
                .foregroundColor: Theme.colors.textMuted, .font: font,
            ]))
        }
        result.append(NSAttributedString(string: statusWordWithDebt(s), attributes: [
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
                       folder: folder.path, session: sessionId)
    }
}
