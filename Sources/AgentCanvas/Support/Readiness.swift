import Foundation

/// First-run environment probe: is `claude` reachable, is the tmux substrate on?
/// Drives the empty state's readiness rows — the calm alternative to a setup
/// wizard. Checked off-main (the claude probe spawns a login shell, the same way
/// a card will, so the answer is exactly what spawning would find).
enum Readiness {
    struct Report: Equatable {
        let claudeFound: Bool
        let tmuxFound: Bool
        var allGood: Bool { claudeFound && tmuxFound }
    }

    /// Probe and deliver on the main thread. Cheap enough to re-run whenever the
    /// app becomes active — installing a tool in another window and switching
    /// back makes the matching row disappear, which IS the feedback.
    static func check(_ completion: @escaping (Report) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-lc", "command -v claude"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            var claude = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                claude = p.terminationStatus == 0
            }
            let report = Report(claudeFound: claude, tmuxFound: Tmux.binary != nil)
            DispatchQueue.main.async { completion(report) }
        }
    }
}
