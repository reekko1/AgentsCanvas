import Foundation

/// The session substrate: every card's process runs inside a tmux session on a
/// canvas-owned tmux server (socket `agentcanvas`, config `~/.agentcanvas/tmux.conf`)
/// — the user's own tmux server and `~/.tmux.conf` are never touched.
///
/// Why: directly-spawned agents were child PTYs of the app — quit or crash the
/// canvas and the whole fleet died mid-task. Under tmux the app is a pure
/// observer: a card's terminal runs the tmux *client* (`new-session -A` creates
/// or reattaches), quitting the app merely detaches, and relaunching reattaches
/// to work still in flight. Remote interaction comes free:
/// `ssh <mac> -t tmux -L agentcanvas attach -t canvas-card-3`.
///
/// When tmux isn't installed everything degrades to direct spawn (cards die with
/// the app, exactly the old behavior) — the canvas never refuses to work.
enum Tmux {
    static let socket = "agentcanvas"

    /// Resolved tmux binary, probed once at `prepare`. Nil → substrate off.
    private(set) static var binary: String?
    private static var confPath: String?

    /// Where tmux actually lands via Homebrew (either arch), MacPorts, Nix, or a
    /// system install — probed directly because a GUI app's PATH has none of them.
    private static let probePaths = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux",
        "/usr/bin/tmux", "/run/current-system/sw/bin/tmux",
        NSHomeDirectory() + "/.nix-profile/bin/tmux",
    ]

    /// Probe the binary and write the canvas-owned config. Call once at spine start.
    static func prepare(dir: URL) {
        binary = probePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard binary != nil else {
            canvasLog("tmux not found — agents won't survive app restarts (brew install tmux)")
            return
        }
        // Minimal by intent: no status bar (the card chrome is the status bar),
        // no Esc delay (Esc is interrupt in the claude TUI), generous scrollback.
        let conf = """
        # Agent Canvas — governs only the '\(socket)' socket; your ~/.tmux.conf is untouched.
        set -g status off
        set -s escape-time 0
        set -g default-terminal "xterm-256color"
        set -g history-limit 50000
        set -g focus-events on
        """
        let url = dir.appendingPathComponent("tmux.conf")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try conf.write(to: url, atomically: true, encoding: .utf8)
            confPath = url.path
            canvasLog("tmux substrate ready (\(binary!))")
        } catch {
            canvasLog("tmux conf write failed (\(error)) — substrate off")
            binary = nil
        }
    }

    static func sessionName(cardId: String) -> String { "canvas-\(cardId)" }

    /// Card id for a canvas session name (nil for foreign sessions on our socket).
    static func cardId(session: String) -> String? {
        session.hasPrefix("canvas-") ? String(session.dropFirst("canvas-".count)) : nil
    }

    /// The invocation a card's terminal runs: the tmux client, which attaches if
    /// the session survived a previous app run and otherwise creates it running
    /// `command`. `cardEnv` is stamped into the session environment on creation
    /// (`-e`, where the hook header interpolation reads it); pass nil to blank it
    /// — sessions inherit the server's env, which belongs to whichever card
    /// started the server, so an unstamped session must be *explicitly* unstamped.
    /// Nil when tmux is unavailable.
    static func clientCommand(session: String, command: String, workdir: String,
                              cardEnv cardId: String?) -> (executable: String, args: [String])? {
        guard let binary, let confPath else { return nil }
        return (binary, ["-L", socket, "-f", confPath,
                         "new-session", "-A", "-s", session, "-c", workdir,
                         "-e", "CANVAS_CARD_ID=\(cardId ?? "")",
                         command])
    }

    /// Names of live sessions on the canvas socket (empty when no server runs).
    /// Shells out synchronously — call off the main thread.
    static func liveSessions() -> Set<String> {
        guard let binary else { return [] }
        let r = run(binary, ["-L", socket, "list-sessions", "-F", "#S"])
        guard r.code == 0 else { return [] }
        return Set(String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    /// Kill a session — the ✕-delete path, the one place the canvas ends an
    /// agent's life rather than just its view of it. Off the main thread.
    static func kill(session: String) {
        guard let binary else { return }
        // `=name` forces an exact match — a bare -t prefix-matches, so card-1
        // would happily kill card-10.
        run(binary, ["-L", socket, "kill-session", "-t", "=" + session])
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> (code: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}
