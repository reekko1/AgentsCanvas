import Foundation

/// The spine's persistent identity — the hook token and both listener ports —
/// stored at `~/.agentcanvas/spine.json`, owner-readable only.
///
/// Why this exists: tmux sessions OUTLIVE the app. A running `claude` read its
/// hook config (sink URL + token) once, at launch. If a relaunched canvas bound
/// a fresh ephemeral port or minted a fresh token, every surviving session would
/// post to a dead address — or be dropped as unauthenticated — and its card
/// would sit silent while the agent worked. Stable port + stable token is what
/// makes reattach truthful. If the preferred port is taken the sink falls back
/// to an ephemeral one (and persists it); pre-existing sessions then degrade
/// gracefully — telemetry hooks fail fast and non-blocking.
struct SpineConfig: Codable {
    var token: String
    var sinkPort: UInt16?
    var remotePort: UInt16?

    static func load(dir: URL) -> SpineConfig {
        if let data = try? Data(contentsOf: fileURL(dir: dir)),
           let cfg = try? JSONDecoder().decode(SpineConfig.self, from: data),
           !cfg.token.isEmpty {
            return cfg
        }
        return SpineConfig(token: UUID().uuidString)
    }

    func save(dir: URL) {
        let url = Self.fileURL(dir: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url)
            // Carries the sink token — same secrecy rules as hooks.json.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            canvasLog("spine config save failed: \(error)")
        }
    }

    private static func fileURL(dir: URL) -> URL { dir.appendingPathComponent("spine.json") }
}
