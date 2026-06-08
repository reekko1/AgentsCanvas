import Foundation
import Network

/// The local event sink (PRD §6.2). A tiny TCP listener on an ephemeral port;
/// each Claude Code hook connects, writes `<card_id>\n<json-payload>`, and closes.
/// We parse the card id + `hook_event_name` and hand them to `onEvent` on the
/// main thread. PRD prefers a Unix socket; TCP on 127.0.0.1 is the accepted
/// fallback and lets the hook be dependency-free pure-bash (/dev/tcp).
final class HookSink {
    /// (cardId, hookEventName, fullPayload) — delivered on the main thread.
    var onEvent: ((String, String, [String: Any]) -> Void)?
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
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data, !data.isEmpty { buffer.append(data) }
                if isComplete || error != nil {
                    self?.process(buffer)
                    conn.cancel()
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    private func process(_ data: Data) {
        guard let nl = data.firstIndex(of: 0x0A) else { return } // first '\n' splits id | payload
        let idData = data[data.startIndex..<nl]
        let jsonData = data[data.index(after: nl)...]
        let cardId = String(decoding: idData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cardId.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(jsonData)) as? [String: Any],
              let event = obj["hook_event_name"] as? String else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(cardId, event, obj) }
    }
}
