import Foundation

/// The local event sink (PRD §6.2): hook semantics over the shared `HTTPServer`.
/// Each Claude Code HTTP hook POSTs its JSON payload to `/hook` with the card id
/// in the `X-Canvas-Card` header (env-interpolated per session). The HTTP
/// response body is bidirectional: a request's `respond` closure may be called
/// later (the held PermissionRequest), keeping the connection open until the
/// user decides. Call it exactly once; `nil` answers 200 with an empty body
/// ("no decision").
///
/// The token and port come from `SpineConfig` and survive app restarts — tmux
/// sessions outlive the canvas, and their hooks must keep landing here.
final class HookSink {
    struct Request {
        let cardId: String
        let event: String
        let payload: [String: Any]
        /// Answer the hook. nil/empty = 200 no-decision; JSON = a decision body.
        let respond: (Data?) -> Void
    }

    /// Delivered on the main thread. The handler OWNS the response: it must call
    /// `respond` exactly once (immediately for telemetry, later for held asks).
    var onRequest: ((Request) -> Void)?
    var port: UInt16 { http.port }
    /// Shared secret every request must echo in `X-Canvas-Token`. It's stamped
    /// into the hooks config the adapter writes, so only sessions launched from
    /// configs we created can talk to the sink — knowing the port isn't enough.
    let token: String

    private let http = HTTPServer(label: "sink")

    init(token: String) {
        self.token = token
    }

    /// Starts listening — on the previous launch's port when possible (see
    /// `SpineConfig`). `onReady` fires (main thread) once bound.
    func start(preferredPort: UInt16?, onReady: @escaping (UInt16) -> Void) throws {
        http.onRequest = { [weak self] request, respond in self?.handle(request, respond) }
        try http.start(preferredPort: preferredPort, onReady: onReady)
    }

    private func handle(_ request: HTTPServer.Request, _ respond: @escaping (HTTPServer.Response) -> Void) {
        guard request.method == "POST", request.path == "/hook",
              request.headers["x-canvas-token"] == token else {
            // Wrong endpoint or missing/stale token: a bare 404 — an
            // unauthenticated peer learns nothing, and a hook with a stale
            // config fails fast and harmlessly (telemetry is non-blocking).
            canvasLog("sink: dropped request (\(request.path == "/hook" ? "bad token" : "\(request.method) \(request.path)"))")
            respond(.notFound)
            return
        }
        let answer: (Data?) -> Void = { body in
            respond(body.map { HTTPServer.Response.json($0) } ?? .empty)
        }
        guard let cardId = request.headers["x-canvas-card"], !cardId.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let event = obj["hook_event_name"] as? String else {
            answer(nil)                                 // malformed → ack and move on
            return
        }
        guard let onRequest else { answer(nil); return }
        onRequest(Request(cardId: cardId, event: event, payload: obj, respond: answer))
    }
}
