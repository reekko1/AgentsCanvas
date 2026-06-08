import Foundation

/// The attention spine: owns the sink + the generic sender script + an
/// `AgentAdapter`, and turns raw events into `(cardId, status)` for the
/// controller. Transport (TCP sink, env stamping, sender) is generic; everything
/// CLI-specific lives in the adapter.
final class Spine {
    let sink = HookSink()
    private let adapter: AgentAdapter

    /// (cardId, status) — delivered on the main thread.
    var onStatus: ((String, CardStatus) -> Void)?

    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentcanvas", isDirectory: true)
    private var senderScript: URL { dir.appendingPathComponent("canvas-send.sh") }

    init(adapter: AgentAdapter = ClaudeCodeAdapter()) {
        self.adapter = adapter
    }

    func start() {
        do {
            try writeSender()
            try adapter.installConfig(dir: dir, senderScript: senderScript)
            sink.onEvent = { [weak self] cardId, event, payload in
                guard let self, let status = self.adapter.status(event: event, payload: payload) else { return }
                self.onStatus?(cardId, status) // sink already dispatches onEvent on main
            }
            try sink.start(onReady: { port in
                canvasLog("sink ready on 127.0.0.1:\(port)")
                try? String(port).write(to: URL(fileURLWithPath: "/tmp/agentcanvas.port"),
                                        atomically: true, encoding: .utf8)
            })
        } catch {
            canvasLog("spine start failed: \(error)")
        }
    }

    /// Environment for a spawned agent session: the app's env + correlation stamps.
    func env(cardId: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["CANVAS_CARD_ID"] = cardId
        env["CANVAS_PORT"] = String(sink.port)
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Environment for a plain shell card: the app's env, no correlation stamps
    /// (a shell isn't watched — no hooks, no status).
    func plainEnv() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "CANVAS_CARD_ID")
        env.removeValue(forKey: "CANVAS_PORT")
        return env.map { "\($0.key)=\($0.value)" }
    }

    func launchCommand(folder: URL) -> (executable: String, args: [String]) {
        adapter.launchCommand(folder: folder)
    }

    // MARK: Sender (generic — forwards "<id>\n<payload>" to the sink over loopback TCP)
    private func writeSender() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sender = """
        #!/bin/bash
        payload=$(cat)
        for attempt in 1 2 3; do
          if exec 3<>/dev/tcp/127.0.0.1/${CANVAS_PORT} 2>/dev/null; then
            printf '%s\\n%s' "${CANVAS_CARD_ID}" "$payload" >&3
            exec 3<&- 2>/dev/null
            exit 0
          fi
          sleep 0.05
        done
        exit 0
        """
        try sender.write(to: senderScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: senderScript.path)
    }
}
