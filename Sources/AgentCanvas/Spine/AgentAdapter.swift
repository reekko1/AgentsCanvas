import AppKit

/// Normalizes one agent CLI into the shared status model (PRD §6.3, §7.3). All
/// CLI-specific knowledge lives behind this seam: how to install event hooks, how
/// to launch the agent, and how to map its events to a `CardStatus`. Add a new
/// CLI by adding a new adapter — nothing else changes.
protocol AgentAdapter: AnyObject {
    var name: String { get }

    /// Write CLI-specific config into `dir` so a launched session emits events to
    /// `senderScript` (which forwards them to the sink).
    func installConfig(dir: URL, senderScript: URL) throws

    /// How to spawn this agent in `folder` (the terminal sets the cwd separately).
    func launchCommand(folder: URL) -> (executable: String, args: [String])

    /// Map a received event + payload to a status. `nil` means "ignore" (no change).
    func status(event: String, payload: [String: Any]) -> CardStatus?
}
