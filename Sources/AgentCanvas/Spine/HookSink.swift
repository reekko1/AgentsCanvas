import Foundation
import Network

/// The local event sink (PRD §6.2): a minimal HTTP server on an ephemeral loopback
/// port. Each Claude Code HTTP hook POSTs its JSON payload here with the card id in
/// the `X-Canvas-Card` header (env-interpolated per session). Compared to the old
/// bash-sender + raw-TCP pipe this removes a process fork per lifecycle event and —
/// the structural win — makes the channel *bidirectional*: the HTTP response body
/// is a decision the hook delivers back to the agent.
///
/// Responses can be **deferred**: a request's `respond` closure may be called later
/// (the held PermissionRequest), keeping the connection open until the user decides.
/// Call it exactly once; `nil` answers 200 with an empty body ("no decision").
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
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentcanvas.sink")

    /// Starts listening. `onReady` fires (main thread) once the port is bound.
    func start(onReady: @escaping (UInt16) -> Void) throws {
        let listener = try NWListener(using: .tcp) // ephemeral port
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let p = listener.port?.rawValue else { return }
            self?.port = p
            DispatchQueue.main.async { onReady(p) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
                guard let self else { conn.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                if let parsed = Self.parseRequest(buffer) {
                    self.dispatch(parsed, conn: conn)
                } else if isComplete || error != nil {
                    conn.cancel()                       // peer gone before a full request
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    /// Returns (cardId, body) once the buffer holds a complete HTTP request, else nil.
    private static func parseRequest(_ data: Data) -> (cardId: String?, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength = 0
        var cardId: String?
        for line in head.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("x-canvas-card:") {
                cardId = String(line.dropFirst("x-canvas-card:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else { return nil }
        return (cardId, Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]))
    }

    private func dispatch(_ parsed: (cardId: String?, body: Data), conn: NWConnection) {
        let respond: (Data?) -> Void = { [queue] body in
            Self.send(body, over: conn, on: queue)
        }
        guard let cardId = parsed.cardId, !cardId.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: parsed.body) as? [String: Any],
              let event = obj["hook_event_name"] as? String else {
            respond(nil)                                // malformed → ack and move on
            return
        }
        let request = Request(cardId: cardId, event: event, payload: obj, respond: respond)
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onRequest else { respond(nil); return }
            handler(request)
        }
    }

    private static func send(_ body: Data?, over conn: NWConnection, on queue: DispatchQueue) {
        queue.async {
            let payload = body ?? Data()
            var head = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
            if !payload.isEmpty { head += "Content-Type: application/json\r\n" }
            head += "\r\n"
            var out = Data(head.utf8)
            out.append(payload)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
