import Foundation

/// The attention spine: owns the HTTP sink + an `AgentAdapter`, and turns raw hook
/// payloads into `(cardId, CardEvent)` updates plus held `PermissionAsk`s for the
/// controller. Transport (HTTP sink, env stamping) is generic; everything
/// CLI-specific lives in the adapter.
final class Spine {
    let sink = HookSink()
    private let adapter: AgentAdapter

    /// (cardId, event) — delivered on the main thread.
    var onUpdate: ((String, CardEvent) -> Void)?
    /// A permission dialog held open for an orbit decision — main thread. The
    /// receiver owns the ask's lifetime (allow / deny / release exactly once).
    var onPermissionAsk: ((PermissionAsk) -> Void)?

    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentcanvas", isDirectory: true)

    init(adapter: AgentAdapter = ClaudeCodeAdapter()) {
        self.adapter = adapter
    }

    func start() {
        sink.onRequest = { [weak self] req in self?.handle(req) }
        do {
            // hooks.json embeds the sink's URL, so it's written once the ephemeral
            // port is bound. Cards spawn lazily (first double-click), long after.
            try sink.start { [weak self] port in
                guard let self else { return }
                do { try self.adapter.installConfig(dir: self.dir, port: port) }
                catch { canvasLog("hook config failed: \(error)") }
                try? String(port).write(to: URL(fileURLWithPath: "/tmp/agentcanvas.port"),
                                        atomically: true, encoding: .utf8)
                // The bash-sender transport is gone — sweep the stale script.
                try? FileManager.default.removeItem(at: self.dir.appendingPathComponent("canvas-send.sh"))
                canvasLog("sink ready on 127.0.0.1:\(port)")
            }
        } catch {
            canvasLog("spine start failed: \(error)")
        }
    }

    private func handle(_ req: HookSink.Request) {
        if adapter.isPermissionAsk(req.event) {
            // Status first (the card goes loud), then hold the response open as
            // the decision channel. While held, the CLI's own dialog is deferred —
            // the canvas (or a fly-in release) decides what happens next.
            let event = adapter.event(req.event, payload: req.payload)
            if let event { onUpdate?(req.cardId, event) }
            let ask = PermissionAsk(cardId: req.cardId,
                                    detail: event?.detail ?? "Permission requested",
                                    allowBody: adapter.permissionAllowBody(),
                                    denyBody: adapter.permissionDenyBody(),
                                    respond: req.respond)
            if let onPermissionAsk {
                onPermissionAsk(ask)
            } else {
                ask.release()   // nobody to decide → fall through to the terminal dialog
            }
        } else {
            req.respond(nil)    // telemetry never blocks the agent
            if let event = adapter.event(req.event, payload: req.payload) {
                onUpdate?(req.cardId, event)
            }
        }
    }

    /// Environment for a spawned agent session: the app's env + the correlation
    /// stamp (interpolated into the hook's `X-Canvas-Card` header per session).
    func env(cardId: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["CANVAS_CARD_ID"] = cardId
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Environment for a plain shell card: the app's env, no correlation stamp
    /// (a shell isn't watched — no hooks, no status).
    func plainEnv() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "CANVAS_CARD_ID")
        return env.map { "\($0.key)=\($0.value)" }
    }

    func launchCommand(folder: URL) -> (executable: String, args: [String]) {
        adapter.launchCommand(folder: folder)
    }
}

/// A permission dialog held open over the spine. The hook's HTTP response is the
/// decision channel: `allow`/`deny` answer it from orbit; `release` answers with
/// no decision, so the CLI's native dialog falls through to the card's terminal
/// (the fly-in path). Exactly one of the three wins; the rest become no-ops.
/// If the canvas never answers, the hook's own timeout releases it CLI-side.
final class PermissionAsk {
    let id = UUID()
    let cardId: String
    let detail: String
    let created = Date()

    private let allowBody: Data
    private let denyBody: Data
    private var respond: ((Data?) -> Void)?

    init(cardId: String, detail: String, allowBody: Data, denyBody: Data,
         respond: @escaping (Data?) -> Void) {
        self.cardId = cardId
        self.detail = detail
        self.allowBody = allowBody
        self.denyBody = denyBody
        self.respond = respond
    }

    func allow() { finish(allowBody) }
    func deny() { finish(denyBody) }
    func release() { finish(nil) }

    private func finish(_ body: Data?) {
        respond?(body)
        respond = nil
    }

    deinit { respond?(nil) }   // never leave an agent hanging on a dropped ask
}
