import Foundation

/// Environment probe: is `claude` reachable, is the tmux substrate on, and is
/// the remote panel reachable over the tailnet? Drives both the empty state's
/// readiness rows and the first-run wizard's self-completing steps. Checked
/// off-main (the claude probe spawns a login shell, the same way a card will,
/// so the answer is exactly what spawning would find).
enum Readiness {
    struct Report: Equatable {
        let claudeFound: Bool
        let tmuxFound: Bool
        /// Homebrew exists — decides whether `brew install tmux` is a real
        /// offer or a guaranteed failure (the wizard swaps its tmux action).
        let brewFound: Bool
        /// The tailscale CLI exists on this Mac.
        let tailscaleFound: Bool
        /// `tailscale serve` is currently proxying the remote panel's port.
        let tailscaleServing: Bool
        /// The tailnet HTTPS URL serving the panel (nil unless serving).
        let tailnetURL: String?

        /// The core flow is healthy (what the empty state cares about).
        var allGood: Bool { claudeFound && tmuxFound }
        /// Every wizard step is already satisfied — the one-screen welcome.
        var machineReady: Bool { claudeFound && tmuxFound && tailscaleFound && tailscaleServing }
    }

    /// Where the tailscale CLI actually lands: the Mac app's bundled binary,
    /// Homebrew (either arch), MacPorts, Nix — probed directly because a GUI
    /// app's PATH has none of them.
    private static let tailscalePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/opt/local/bin/tailscale",
        "/run/current-system/sw/bin/tailscale",
        NSHomeDirectory() + "/.nix-profile/bin/tailscale",
    ]

    /// Homebrew's two install homes (Apple silicon, Intel) — probed directly
    /// for the same PATH reason as tailscale.
    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// Probe and deliver on the main thread. Cheap enough to re-run whenever the
    /// app becomes active — installing a tool in another window and switching
    /// back makes the matching row (or wizard step) complete itself, which IS
    /// the feedback. `remotePort` is the remote panel's bound port (nil/0 →
    /// serve status can't be attributed, reported as not serving).
    static func check(remotePort: UInt16?, _ completion: @escaping (Report) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let claude = probeClaude()
            let tailscale = tailscalePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            let serve = tailscale.flatMap { probeServe(binary: $0, port: remotePort) }
            let report = Report(claudeFound: claude,
                                tmuxFound: Tmux.binary != nil,
                                brewFound: brewPaths.contains { FileManager.default.isExecutableFile(atPath: $0) },
                                tailscaleFound: tailscale != nil,
                                tailscaleServing: serve != nil,
                                tailnetURL: serve)
            DispatchQueue.main.async { completion(report) }
        }
    }

    /// Spawns the user's login shell — the exact way a card spawns the agent —
    /// so the answer matches what launching would actually find.
    private static func probeClaude() -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v claude"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Is `tailscale serve` proxying our remote port? Returns the tailnet HTTPS
    /// URL when it is, nil otherwise. `serve status` prints the public URL line
    /// followed by its proxy target — we require both: a URL with no matching
    /// `:port` proxy is someone else's route.
    private static func probeServe(binary: String, port: UInt16?) -> String? {
        guard let port, port != 0 else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["serve", "status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              text.contains(":\(port)") else { return nil }
        let url = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .first { $0.hasPrefix("https://") }
        return url.map(String.init)
    }
}
