import Foundation

/// The attention spine: owns the HTTP sink, the remote panel, the session
/// substrate, and an `AgentAdapter`; turns raw hook payloads into
/// `(cardId, CardEvent)` updates plus held `PermissionAsk`s for the controller.
/// Transport (HTTP sink, env stamping, tmux wrapping) is generic; everything
/// CLI-specific lives in the adapter.
final class Spine {
    /// The remote supervision panel (loopback; exposed via Tailscale Serve).
    let remote = RemoteServer()

    private let sink: HookSink
    private let adapter: AgentAdapter
    private var config: SpineConfig

    /// (cardId, event) — delivered on the main thread.
    var onUpdate: ((String, CardEvent) -> Void)?
    /// A permission dialog held open for an orbit decision — main thread. The
    /// receiver owns the ask's lifetime (allow / deny / release exactly once).
    var onPermissionAsk: ((PermissionAsk) -> Void)?

    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentcanvas", isDirectory: true)

    init(adapter: AgentAdapter = ClaudeCodeAdapter()) {
        self.adapter = adapter
        // Identity (token + ports) persists across launches: tmux sessions
        // outlive the app, and their hooks must keep landing — and keep
        // authenticating — after a relaunch.
        self.config = SpineConfig.load(dir: dir)
        self.sink = HookSink(token: config.token)
    }

    func start() {
        Tmux.prepare(dir: dir)
        sink.onRequest = { [weak self] req in self?.handle(req) }
        do {
            // hooks.json embeds the sink's URL, so it's written once the port is
            // bound. Cards spawn lazily (first double-click), long after.
            try sink.start(preferredPort: config.sinkPort) { [weak self] port in
                guard let self else { return }
                self.config.sinkPort = port
                self.config.save(dir: self.dir)
                do { try self.adapter.installConfig(dir: self.dir, port: port, token: self.sink.token) }
                catch { canvasLog("hook config failed: \(error)") }
                try? String(port).write(to: URL(fileURLWithPath: "/tmp/agentcanvas.port"),
                                        atomically: true, encoding: .utf8)
                canvasLog("sink ready on 127.0.0.1:\(port)")
            }
        } catch {
            canvasLog("spine start failed: \(error)")
        }
        do {
            try remote.start(preferredPort: config.remotePort) { [weak self] port in
                guard let self else { return }
                self.config.remotePort = port
                self.config.save(dir: self.dir)
                canvasLog("remote panel on http://127.0.0.1:\(port) — expose with: tailscale serve --bg localhost:\(port)")
            }
        } catch {
            canvasLog("remote panel start failed: \(error)")
        }
    }

    // MARK: Launching (the session substrate)

    /// How a card's terminal process launches. Under tmux the terminal runs the
    /// tmux *client* — the agent lives in a session that outlives the app, and
    /// `-A` reattaches after a relaunch instead of spawning fresh. Without tmux
    /// this degrades to direct spawn (the process dies with the app, as before).
    func launch(role: CardRole, cardId: String, folder: URL) -> (executable: String, args: [String], environment: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let session = Tmux.sessionName(cardId: cardId)
        switch role {
        case .agent:
            // Login shell *inside* the session so claude resolves from the
            // user's real PATH (the GUI app's own PATH has no idea).
            let inner = "\(shell) -lc \(shellQuote(adapter.launchCommand()))"
            if let client = Tmux.clientCommand(session: session, command: inner,
                                               workdir: folder.path, cardEnv: cardId) {
                return (client.executable, client.args, env(cardId: cardId))
            }
            return (shell, ["-lc", adapter.launchCommand()], env(cardId: cardId))
        case .shell:
            if let client = Tmux.clientCommand(session: session, command: "\(shell) -l",
                                               workdir: folder.path, cardEnv: nil) {
                return (client.executable, client.args, plainEnv())
            }
            return (shell, ["-l"], plainEnv())
        }
    }

    /// End a card's tmux session (✕ delete). The terminal client SIGTERM alone
    /// would only *detach* — the agent would keep running headless, which is
    /// exactly the unsupervised state the canvas exists to prevent.
    func killSession(cardId: String) {
        let session = Tmux.sessionName(cardId: cardId)
        DispatchQueue.global(qos: .userInitiated).async { Tmux.kill(session: session) }
    }

    /// Card ids whose sessions are still alive from a previous run (background
    /// query, completion on main) — the restore path reattaches these instead of
    /// leaving them dormant behind "tap to start".
    func liveSessionCardIds(completion: @escaping (Set<String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = Set(Tmux.liveSessions().compactMap { Tmux.cardId(session: $0) })
            DispatchQueue.main.async { completion(ids) }
        }
    }

    // MARK: Hook handling

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

    // MARK: Environments

    /// Environment for a spawned agent session: the app's env + the correlation
    /// stamp (interpolated into the hook's `X-Canvas-Card` header per session).
    private func env(cardId: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["CANVAS_CARD_ID"] = cardId
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Environment for a plain shell card: the app's env, no correlation stamp
    /// (a shell isn't watched — no hooks, no status).
    private func plainEnv() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "CANVAS_CARD_ID")
        return env.map { "\($0.key)=\($0.value)" }
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
