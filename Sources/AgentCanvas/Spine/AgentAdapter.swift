import AppKit

/// One semantic update extracted from a CLI lifecycle event — the spine's unit of
/// delivery to the controller. Everything is optional: an event may carry only a
/// status flip, only metadata (model, permission mode), or only a feed line.
struct CardEvent {
    /// New status, or nil for "no status change" (e.g. a pure subagent-count tick).
    var status: CardStatus? = nil
    /// Human one-liner for the activity feed / card ("Bash: npm install", "rate limited").
    var detail: String? = nil
    /// Record in the activity feed even when the status didn't change (tool
    /// failures, compaction summaries — things worth a row, not a color).
    var noteworthy = false
    /// What the agent is working on (first line of the user's prompt).
    var taskLabel: String? = nil
    var clearTask = false
    /// The agent's final message for the turn (shown on a done card's feed row).
    var summary: String? = nil
    /// Model identifier, shortened for display ("opus 4.8").
    var model: String? = nil
    /// Current permission mode — "bypassPermissions" is supervision-critical
    /// (that card can never go loud, because it never asks).
    var permissionMode: String? = nil
    /// Live subagent count adjustment (+1 on start, −1 on stop).
    var subagentDelta: Int = 0
    var resetSubagents = false
}

/// Normalizes one agent CLI into the shared event model (PRD §6.3, §7.3). All
/// CLI-specific knowledge lives behind this seam: how to install lifecycle hooks,
/// how to launch the agent, how to map its events, and how to phrase a permission
/// decision. Add a new CLI by adding a new adapter — nothing else changes.
protocol AgentAdapter: AnyObject {
    var name: String { get }

    /// Write CLI-specific config into `dir` so a launched session POSTs its
    /// lifecycle events to the sink listening on 127.0.0.1:`port`, echoing `token`
    /// on every request (the sink drops anything without it).
    func installConfig(dir: URL, port: UInt16, token: String) throws

    /// The shell command line that starts this agent. The spine runs it under the
    /// user's login shell (so the CLI resolves from their real PATH) inside the
    /// session substrate; working directory and card env are supplied around it.
    func launchCommand() -> String

    /// Map a received event + payload to a `CardEvent`. `nil` means "ignore".
    func event(_ name: String, payload: [String: Any]) -> CardEvent?

    /// True when this event's HTTP response should be held open as an interactive
    /// decision channel (the permission-dialog event), rather than acked instantly.
    func isPermissionAsk(_ name: String) -> Bool

    /// Response bodies for a held permission request: approve / deny / no-decision
    /// is expressed by responding with `allow`, `deny`, or an empty body.
    func permissionAllowBody() -> Data
    func permissionDenyBody() -> Data
}
