import AppKit

/// Claude Code adapter. Installs scoped HTTP hooks (via `--settings`, leaving user
/// config untouched), launches `claude` with them, and maps hook events to rich
/// `CardEvent`s. Event mapping is verified against the official hooks reference.
///
/// Transport notes (load-bearing):
/// - Hooks are `type: "http"` POSTing straight to the in-process sink — no bash
///   sender, no process fork per event. Card correlation rides the
///   `X-Canvas-Card` header, interpolated from the session's `CANVAS_CARD_ID` env
///   (each card's `claude` is launched with its own value).
/// - Telemetry hooks get a tight 5s timeout: if the canvas wedges, agents stall
///   at most 5s per event and continue (HTTP hook failures are non-blocking).
/// - `PermissionRequest` is the held decision channel (600s): the sink's response
///   body IS the allow/deny. Empty response = no decision → the native dialog
///   falls through to the terminal. The dialog does NOT appear while held.
/// - SubagentStart/Stop are installed for the live subagent *counter* only — they
///   fire out-of-sync with the main Stop, so they must never drive status.
final class ClaudeCodeAdapter: AgentAdapter {
    let name = "claude-code"
    private var settingsFile: URL?

    /// Events acked instantly (status/feed material). PermissionRequest is
    /// configured separately as the held interactive channel.
    private let telemetryEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Notification", "Elicitation",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
        "Stop", "StopFailure", "SessionEnd",
    ]

    func installConfig(dir: URL, port: UInt16, token: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = "http://127.0.0.1:\(port)/hook"
        func entry(timeout: Int, statusMessage: String? = nil) -> [String: Any] {
            var e: [String: Any] = [
                "type": "http",
                "url": url,
                "timeout": timeout,
                "headers": ["X-Canvas-Card": "$CANVAS_CARD_ID", "X-Canvas-Token": token],
                "allowedEnvVars": ["CANVAS_CARD_ID"],
            ]
            if let statusMessage { e["statusMessage"] = statusMessage }
            return e
        }
        var hooks: [String: Any] = [:]
        for e in telemetryEvents { hooks[e] = [["hooks": [entry(timeout: 5)]]] }
        hooks["PermissionRequest"] = [["hooks": [entry(timeout: 600, statusMessage: "Asking Agent Canvas…")]]]

        let file = dir.appendingPathComponent("hooks.json")
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file)
        // The file now carries the sink token — keep it owner-readable only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        settingsFile = file
        canvasLog("wrote HTTP hooks (port \(port)) → \(file.path)")
    }

    func launchCommand() -> String {
        guard let settings = settingsFile?.path else {
            return "exec claude"   // sink not ready (shouldn't happen) → unwatched session
        }
        return "exec claude --settings \(shellQuote(settings))"
    }

    func isPermissionAsk(_ name: String) -> Bool { name == "PermissionRequest" }

    func permissionAllowBody() -> Data {
        body(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                     "decision": ["behavior": "allow"]]])
    }

    func permissionDenyBody() -> Data {
        body(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                     "decision": ["behavior": "deny",
                                                  "message": "Denied from Agent Canvas",
                                                  "interrupt": false]]])
    }

    // MARK: Event mapping

    func event(_ name: String, payload: [String: Any]) -> CardEvent? {
        var ev: CardEvent?
        switch name {
        case "SessionStart":
            ev = CardEvent(status: .idle, detail: "Session started",
                           model: Self.shortModel(payload["model"] as? String),
                           resetSubagents: true, todoChange: .clear)

        case "UserPromptSubmit":
            let label = (payload["prompt"] as? String).map { Self.clip($0, 60) }
            ev = CardEvent(status: .running,
                           detail: label.map { "Working on: \($0)" },
                           taskLabel: label, resetSubagents: true)

        case "PreToolUse", "PostToolUse":
            // The plan tools are the agent publishing its own checklist — capture
            // the change itself, not just a tool name. TaskCreate/TaskUpdate only
            // count on PostToolUse (the response carries the created id, and the
            // mutation actually happened); everything else is a plain action line.
            ev = CardEvent(status: .running, detail: Self.toolDetail(payload))
            if let change = Self.todoChange(payload) { ev?.todoChange = change }

        case "PostToolUseFailure":
            // Tool failures are routine agentic life (a failing test IS the work) —
            // the agent sees the error and continues, so this stays `.running`.
            // It's feed-worthy, not card-worthy. Real session death is StopFailure.
            guard payload["is_interrupt"] as? Bool != true else { return nil }
            let err = Self.clip(payload["error"] as? String ?? "failed", 100)
            ev = CardEvent(status: .running,
                           detail: "✗ \(payload["tool_name"] as? String ?? "tool"): \(err)",
                           noteworthy: true)

        case "PermissionRequest":
            ev = CardEvent(status: .blocked, detail: Self.toolDetail(payload))

        case "Elicitation":
            // An MCP server is waiting on the user — exactly as blocked as a
            // permission prompt. Acked instantly (we never answer elicitations
            // from orbit), so the dialog shows in the terminal as normal.
            let msg = Self.clip(payload["message"] as? String ?? "input requested", 80)
            ev = CardEvent(status: .blocked, detail: "MCP input: \(msg)")

        case "Notification":
            // The DELAYED desktop nudge — kept as fallback only; PermissionRequest
            // and Elicitation are the immediate triggers.
            switch payload["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog":
                ev = CardEvent(status: .blocked, detail: payload["message"] as? String)
            case "idle_prompt":
                ev = CardEvent(status: .idle)
            default:
                return nil
            }

        case "SubagentStart": ev = CardEvent(subagentDelta: 1)
        case "SubagentStop":  ev = CardEvent(subagentDelta: -1)

        case "PreCompact":
            ev = CardEvent(status: .running, detail: "Compacting context…")
        case "PostCompact":
            // A free running summary of a long session — feed material.
            guard let s = payload["compact_summary"] as? String, !s.isEmpty else { return nil }
            ev = CardEvent(detail: "Compacted: \(Self.clip(s, 120))", noteworthy: true)

        case "Stop":
            let background = payload["background_tasks"] as? [[String: Any]] ?? []
            let summary = (payload["last_assistant_message"] as? String).map { Self.clip($0, 140) }
            if background.isEmpty {
                ev = CardEvent(status: .done, detail: summary ?? "Finished — waiting for you",
                               clearTask: true, summary: summary, resetSubagents: true)
            } else {
                // The turn ended but the session has live background work —
                // "done" would lie. Waiting, with what it's waiting on.
                let what = background.compactMap { $0["type"] as? String }.joined(separator: ", ")
                ev = CardEvent(status: .waiting,
                               detail: "Waiting on \(background.count) background task\(background.count == 1 ? "" : "s") (\(what))",
                               summary: summary)
            }

        case "StopFailure":
            // The turn died on an API error — without this hook the card would
            // glow "running" forever, the exact lie the canvas exists to prevent.
            let err = payload["error"] as? String ?? "unknown"
            if err == "rate_limit" || err == "overloaded" {
                ev = CardEvent(status: .stalled, detail: "Rate limited — turn aborted", noteworthy: true)
            } else {
                let extra = (payload["error_details"] as? String).map { " — \(Self.clip($0, 80))" } ?? ""
                ev = CardEvent(status: .error, detail: "API failure: \(err)\(extra)", noteworthy: true)
            }

        case "SessionEnd":
            ev = CardEvent(status: .idle, detail: "Session ended",
                           clearTask: true, resetSubagents: true, todoChange: .clear)

        default:
            return nil
        }
        // Permission mode and session id ride on most payloads — capture them
        // opportunistically wherever they appear.
        ev?.permissionMode = payload["permission_mode"] as? String
        ev?.sessionId = payload["session_id"] as? String
        return ev
    }

    /// Read the session's plan from the CLI's own task store:
    /// `~/.claude/tasks/<session-id>/<taskId>.json`, one file per task with
    /// `{id, subject, description, activeForm, status, …}` (empirically
    /// verified). This is the ground truth that outlives both the app and the
    /// hook stream — used to re-hydrate a reattached session's checklist.
    func currentTodos(sessionId: String) -> [AgentTodo]? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }   // no store for this session (or none yet)
        var todos: [AgentTodo] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let subject = obj["subject"] as? String else { continue }
            let status = obj["status"] as? String ?? "pending"
            guard status != "deleted" else { continue }
            todos.append(AgentTodo(id: id, content: subject, status: status,
                                   activeForm: obj["activeForm"] as? String))
        }
        // An existing-but-empty dir reads as "no data", not "empty plan": the
        // CLI creates the dir before the first task file lands, so a read in
        // that window must not wipe todos already accumulated from deltas.
        guard !todos.isEmpty else { return nil }
        // Task ids are a numeric sequence — creation order is the plan's order.
        return todos.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    // MARK: Helpers

    /// "<Tool>: <salient argument>" — the triage line that distinguishes a
    /// rubber-stamp from a think-first ("Bash: rm -rf node_modules").
    private static func toolDetail(_ payload: [String: Any]) -> String {
        let tool = payload["tool_name"] as? String ?? "tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let arg: String?
        switch tool {
        case "Bash":
            arg = input["command"] as? String
        case "Edit", "Write", "Read", "NotebookEdit":
            arg = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            arg = input["pattern"] as? String
        case "WebFetch":
            arg = input["url"] as? String
        case "WebSearch":
            arg = input["query"] as? String
        case "Agent", "Task":
            arg = input["description"] as? String ?? input["subagent_type"] as? String
        case "TaskCreate":
            arg = input["subject"] as? String
        case "TaskUpdate":
            let status = (input["status"] as? String).map { " → \($0)" } ?? ""
            arg = (input["taskId"] as? String).map { "#\($0)\(status)" }
        default:
            arg = nil
        }
        guard let arg, !arg.isEmpty else { return tool }
        return "\(tool): \(clip(arg, 80))"
    }

    /// The plan change when this payload is a plan-tool call, else nil. Shapes
    /// empirically captured from real hook payloads (claude 2.1.168):
    /// - TaskCreate: `tool_input {subject, description, activeForm}`, and the
    ///   PostToolUse `tool_response.task.id` carries the assigned id.
    /// - TaskUpdate: `tool_input {taskId, status?, subject?, activeForm?}`
    ///   (status includes "deleted"); `tool_response.statusChange.to` confirms.
    /// - TodoWrite (older CLIs): `tool_input.todos` = full
    ///   `[{content, status, activeForm}]` list, replacing the plan wholesale.
    private static func todoChange(_ payload: [String: Any]) -> TodoChange? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let response = payload["tool_response"] as? [String: Any] ?? [:]
        let isPost = payload["hook_event_name"] as? String == "PostToolUse"
        switch payload["tool_name"] as? String {
        case "TodoWrite":
            guard let raw = input["todos"] as? [[String: Any]] else { return nil }
            let todos = raw.enumerated().compactMap { i, t -> AgentTodo? in
                guard let content = t["content"] as? String else { return nil }
                return AgentTodo(id: "todo-\(i)", content: content,
                                 status: t["status"] as? String ?? "pending",
                                 activeForm: t["activeForm"] as? String)
            }
            return todos.isEmpty ? nil : .replace(todos)
        case "TaskCreate" where isPost:
            guard let subject = input["subject"] as? String,
                  let id = (response["task"] as? [String: Any])?["id"] as? String else { return nil }
            return .add(AgentTodo(id: id, content: subject, status: "pending",
                                  activeForm: input["activeForm"] as? String))
        case "TaskUpdate" where isPost:
            guard let id = input["taskId"] as? String else { return nil }
            let confirmed = (response["statusChange"] as? [String: Any])?["to"] as? String
            return .update(id: id,
                           status: confirmed ?? input["status"] as? String,
                           content: input["subject"] as? String,
                           activeForm: input["activeForm"] as? String)
        default:
            return nil
        }
    }

    /// "claude-opus-4-8" → "opus 4.8" (joins numeric parts, drops date stamps).
    private static func shortModel(_ id: String?) -> String? {
        guard var id, !id.isEmpty else { return nil }
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        var words: [String] = []
        for part in id.split(separator: "-").filter({ $0.count <= 4 }) {
            if let last = words.last, last.allSatisfy(\.isNumber), part.allSatisfy(\.isNumber) {
                words[words.count - 1] = last + "." + part
            } else {
                words.append(String(part))
            }
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    private func body(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
