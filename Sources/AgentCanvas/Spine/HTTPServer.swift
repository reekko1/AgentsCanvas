import Foundation
import Network

/// A minimal loopback HTTP/1.1 server — the shared transport under the spine's
/// two listeners (the hook sink and the remote panel). Just enough HTTP: one
/// request per connection, Content-Length bodies, and **deferrable responses**
/// (`respond` may be called long after the handler returns — that's the held
/// PermissionRequest keeping its connection open until the user decides).
///
/// Binds 127.0.0.1 explicitly, so the socket is never reachable from another
/// machine. Remote exposure is deliberately a proxy's job (Tailscale Serve adds
/// TLS + tailnet identity), not an open port's.
final class HTTPServer {
    struct Request {
        let method: String
        let path: String
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status = 200
        var contentType: String?
        var body = Data()

        static let empty = Response()
        static let notFound = Response(status: 404)
        static let badRequest = Response(status: 400)
        static func json(_ data: Data) -> Response { Response(contentType: "application/json", body: data) }
        static func html(_ s: String) -> Response { Response(contentType: "text/html; charset=utf-8", body: Data(s.utf8)) }
    }

    /// Delivered on the main thread. The handler OWNS the response: it must call
    /// `respond` exactly once (immediately, or later for a held request).
    var onRequest: ((Request, @escaping (Response) -> Void) -> Void)?
    private(set) var port: UInt16 = 0

    /// Requests buffer in memory until complete; a peer that grows past this is
    /// not one of ours and gets dropped.
    private static let maxRequestBytes = 1 << 20

    private var listener: NWListener?
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: "agentcanvas.http.\(label)")
    }

    /// Start listening: on `preferredPort` if it's free (port stability is what
    /// keeps surviving tmux sessions' hooks pointed somewhere real), else on an
    /// ephemeral port. `onReady` fires (main thread) once bound.
    func start(preferredPort: UInt16?, onReady: @escaping (UInt16) -> Void) throws {
        try listen(on: preferredPort, fallbackToEphemeral: preferredPort != nil, onReady: onReady)
    }

    private func listen(on port: UInt16?, fallbackToEphemeral: Bool, onReady: @escaping (UInt16) -> Void) throws {
        let params = NWParameters.tcp
        // Bind to 127.0.0.1 explicitly (not just requiredInterfaceType, which still
        // binds *:port and filters per-connection).
        let nwPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true   // rebind the preferred port right after a restart
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let p = listener.port?.rawValue else { return }
                self.port = p
                DispatchQueue.main.async { onReady(p) }
            case .failed(let error):
                listener.cancel()
                if fallbackToEphemeral {
                    canvasLog("port \(port.map(String.init) ?? "?") unavailable (\(error)) — rebinding ephemeral")
                    try? self.listen(on: nil, fallbackToEphemeral: false, onReady: onReady)
                } else {
                    canvasLog("http listener failed: \(error)")
                }
            default:
                break
            }
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
                if buffer.count > Self.maxRequestBytes {
                    conn.cancel()                       // oversized peer — not ours
                } else if let request = Self.parse(buffer) {
                    self.dispatch(request, conn: conn)
                } else if isComplete || error != nil {
                    conn.cancel()                       // peer gone before a full request
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    /// Returns a Request once the buffer holds a complete HTTP request, else nil.
    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?").first ?? parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else { return nil }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)])
        return Request(method: method, path: path, headers: headers, body: body)
    }

    private func dispatch(_ request: Request, conn: NWConnection) {
        let respond: (Response) -> Void = { [queue] response in
            Self.send(response, over: conn, on: queue)
        }
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onRequest else { respond(.notFound); return }
            handler(request, respond)
        }
    }

    private static func send(_ response: Response, over conn: NWConnection, on queue: DispatchQueue) {
        queue.async {
            let reason: String
            switch response.status {
            case 200: reason = "OK"
            case 400: reason = "Bad Request"
            case 404: reason = "Not Found"
            default:  reason = "Status"
            }
            var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
            if let type = response.contentType { head += "Content-Type: \(type)\r\n" }
            head += "\r\n"
            var out = Data(head.utf8)
            out.append(response.body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
