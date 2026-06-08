import Foundation

/// Shared `git` process runner used by both the read-only `GitDiff` and the
/// mutating `GitActions`. One place that knows how to invoke git.
enum Git {
    /// Run `git <args>` in `folder`, returning (exitCode, stdout, stderr).
    @discardableResult
    static func run(_ args: [String], in folder: URL) -> (code: Int32, out: Data, err: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = folder
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return (-1, Data(), Data("\(error)".utf8))
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, outData, errData)
    }
}

/// The result of a mutating action — `ok` plus a human-readable message (the git
/// stderr on failure) so the UI can surface it instead of failing silently.
struct GitActionResult {
    let ok: Bool
    let message: String
    static let success = GitActionResult(ok: true, message: "")
}

/// Repo MUTATIONS — the write counterpart to the read-only `GitDiff`. Every call
/// here changes the working tree or index, so these are only ever invoked from an
/// explicit, user-initiated action (and destructive ones behind a confirmation).
/// Run off the main thread.
enum GitActions {

    static func stage(folder: URL, path: String) -> GitActionResult {
        result(Git.run(["add", "--", path], in: folder))
    }

    static func unstage(folder: URL, path: String) -> GitActionResult {
        result(Git.run(["restore", "--staged", "--", path], in: folder))
    }

    /// Revert a file to its HEAD state. Tracked → restore index+worktree; untracked
    /// → delete the file (it has no HEAD version). Irreversible — confirm first.
    static func discard(folder: URL, change: GitChange) -> GitActionResult {
        if change.status == .untracked {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(change.path))
                return .success
            } catch {
                return GitActionResult(ok: false, message: "\(error.localizedDescription)")
            }
        }
        return result(Git.run(["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path], in: folder))
    }

    static func stageAll(folder: URL) -> GitActionResult {
        result(Git.run(["add", "-A"], in: folder))
    }

    /// Reset the whole working tree to a clean HEAD: revert tracked changes AND
    /// remove untracked files/dirs. Nuclear — confirm strongly first.
    static func discardAll(folder: URL) -> GitActionResult {
        let reset = Git.run(["reset", "--hard", "HEAD"], in: folder)
        guard reset.code == 0 else { return result(reset) }
        return result(Git.run(["clean", "-fd"], in: folder))
    }

    static func commit(folder: URL, message: String) -> GitActionResult {
        result(Git.run(["commit", "-m", message], in: folder))
    }

    private static func result(_ r: (code: Int32, out: Data, err: Data)) -> GitActionResult {
        if r.code == 0 { return .success }
        let err = String(decoding: r.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = err.isEmpty ? out : err
        return GitActionResult(ok: false, message: msg.isEmpty ? "git exited with code \(r.code)" : msg)
    }
}
