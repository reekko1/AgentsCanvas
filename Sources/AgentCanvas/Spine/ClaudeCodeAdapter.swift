import AppKit

/// Claude Code adapter. Installs scoped hooks (via `--settings`, leaving user
/// config untouched), launches `claude` with them, and maps hook events to status.
/// Event mapping is verified against claude 2.1.168 + the official hooks docs.
final class ClaudeCodeAdapter: AgentAdapter {
    let name = "claude-code"
    private var settingsFile: URL?

    /// Every state-relevant hook points at the sender. PermissionRequest is the
    /// IMMEDIATE "needs you" signal (fires when the dialog appears); Notification
    /// is the DELAYED desktop nudge — kept for idle_prompt + as a fallback.
    /// SubagentStart/Stop are intentionally NOT installed (they fire out-of-sync
    /// with the main Stop and would flip a finished card back to running).
    private let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                          "PermissionRequest", "Notification", "Stop", "SessionEnd"]

    func installConfig(dir: URL, senderScript: URL) throws {
        let file = dir.appendingPathComponent("hooks.json")
        let entry: [String: Any] = ["hooks": [["type": "command", "command": senderScript.path]]]
        var hooks: [String: Any] = [:]
        for e in events { hooks[e] = [entry] }
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted])
        try data.write(to: file)
        settingsFile = file
        canvasLog("wrote hooks → \(file.path)")
    }

    func launchCommand(folder: URL) -> (executable: String, args: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let settings = settingsFile?.path ?? ""
        return (shell, ["-lc", "exec claude --settings \(shellQuote(settings))"])
    }

    func status(event: String, payload: [String: Any]) -> CardStatus? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "PostCompact":
            return .running // actively working a turn
        case "SessionStart":
            return .idle    // ready & waiting for you — calm, NOT working yet
        case "PermissionRequest":
            return .blocked // dialog shown — needs you, immediate
        case "Stop":
            return .done
        case "SessionEnd":
            return .idle
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt": return .blocked // delayed fallback for permission
            case "idle_prompt":       return .idle     // 60s idle — calm
            default:                  return nil
            }
        default:
            return nil
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
