import AppKit

/// How a changed file relates to HEAD. Drives the list dot color.
enum GitFileStatus {
    case added, modified, deleted, renamed, untracked

    var color: NSColor {
        switch self {
        case .added, .untracked: return Theme.colors.fileAdded
        case .modified:          return Theme.colors.fileModified
        case .deleted:           return Theme.colors.fileDeleted
        case .renamed:           return Theme.colors.fileRenamed
        }
    }
    /// Single-letter badge shown in the file list.
    var letter: String {
        switch self {
        case .added:     return "A"
        case .modified:  return "M"
        case .deleted:   return "D"
        case .renamed:   return "R"
        case .untracked: return "?"
        }
    }
}

/// One changed file in the working tree relative to HEAD.
struct GitChange {
    let path: String        // current path (what we diff against)
    let oldPath: String?    // previous path, for renames
    let status: GitFileStatus
    let added: Int
    let removed: Int
    let hasStaged: Bool     // index column (X) set — there are staged changes
    let hasUnstaged: Bool   // worktree column (Y) set — there are unstaged changes (incl. untracked)
}

/// A point-in-time view of a working tree. `isRepo == false` means the folder is
/// not a git work tree; an empty `changes` with `isRepo == true` is a clean tree.
struct GitSnapshot {
    let isRepo: Bool
    let changes: [GitChange]
    let totalAdded: Int
    let totalRemoved: Int
    /// Cheap fingerprint for change-detection (porcelain + numstat raw output).
    let signature: String

    static let notRepo = GitSnapshot(isRepo: false, changes: [], totalAdded: 0, totalRemoved: 0, signature: "")
    static let clean = GitSnapshot(isRepo: true, changes: [], totalAdded: 0, totalRemoved: 0, signature: "clean")
}

/// Read-only git access — shells out to `git` and parses output. It NEVER mutates
/// the repo (observe, don't orchestrate): only `status`, `diff`, `rev-parse`.
enum GitDiff {

    /// Full working-tree snapshot vs HEAD (staged + unstaged + untracked).
    /// Runs `git` synchronously — call off the main thread.
    static func snapshot(folder: URL) -> GitSnapshot {
        let head = Git.run(["rev-parse", "--is-inside-work-tree"], in: folder)
        guard head.code == 0,
              String(decoding: head.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return .notRepo }

        let statusData = Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: folder).out
        let numstatData = Git.run(["diff", "HEAD", "--numstat", "-z"], in: folder).out
        let signature = String(decoding: statusData, as: UTF8.self) + "\u{1}" + String(decoding: numstatData, as: UTF8.self)

        let entries = parseStatus(statusData)
        if entries.isEmpty { return .clean }
        let counts = parseNumstat(numstatData)

        var changes: [GitChange] = []
        var totalAdded = 0, totalRemoved = 0
        for e in entries {
            let (a, r): (Int, Int)
            if let c = counts[e.path] {
                (a, r) = c
            } else if e.status == .untracked {
                (a, r) = (lineCount(of: folder.appendingPathComponent(e.path)), 0)
            } else {
                (a, r) = (0, 0)
            }
            totalAdded += a; totalRemoved += r
            changes.append(GitChange(path: e.path, oldPath: e.oldPath, status: e.status, added: a, removed: r,
                                     hasStaged: e.hasStaged, hasUnstaged: e.hasUnstaged))
        }
        return GitSnapshot(isRepo: true, changes: changes, totalAdded: totalAdded, totalRemoved: totalRemoved,
                           signature: signature)
    }

    /// The unified diff for a single file (rendered lazily on selection). Returns
    /// "" when there is nothing textual to show (e.g. binary).
    static func fileDiff(folder: URL, change: GitChange) -> String {
        if change.status == .untracked {
            // Untracked files have no HEAD blob; compare against /dev/null. Exit code 1 is normal here.
            return String(decoding: Git.run(["diff", "--no-index", "--", "/dev/null", change.path], in: folder).out,
                          as: UTF8.self)
        }
        return String(decoding: Git.run(["diff", "HEAD", "--", change.path], in: folder).out, as: UTF8.self)
    }

    // MARK: Parsing

    private struct Entry {
        let path: String; let oldPath: String?; let status: GitFileStatus
        let hasStaged: Bool; let hasUnstaged: Bool
    }

    /// Parse `git status --porcelain=v1 -z`: NUL-separated `XY PATH` records; a
    /// rename/copy record is followed by an extra NUL field carrying the old path.
    private static func parseStatus(_ data: Data) -> [Entry] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\u{0}", omittingEmptySubsequences: false)
        var entries: [Entry] = []
        var i = 0
        while i < fields.count {
            let field = String(fields[i]); i += 1
            guard field.count >= 4 else { continue }   // "XY P"
            let code = Array(field.prefix(2))          // [X, Y]
            let x = code[0], y = code[1]
            let path = String(field.dropFirst(3))      // skip "XY "
            let status = classify(String(code))
            // X = index/staged column, Y = worktree column ('?' = untracked → unstaged).
            let hasStaged = x != " " && x != "?"
            let hasUnstaged = y != " "
            var oldPath: String? = nil
            if (x == "R" || x == "C"), i < fields.count {
                oldPath = String(fields[i]); i += 1    // rename/copy: next field is the old path
            }
            entries.append(Entry(path: path, oldPath: oldPath, status: status,
                                 hasStaged: hasStaged, hasUnstaged: hasUnstaged))
        }
        return entries
    }

    private static func classify(_ code: String) -> GitFileStatus {
        if code.contains("?") { return .untracked }
        if code.contains("R") || code.contains("C") { return .renamed }
        if code.contains("D") { return .deleted }
        if code.contains("A") { return .added }
        return .modified
    }

    /// Parse `git diff HEAD --numstat -z` into path → (added, removed). Rename rows
    /// have an empty path field followed by old\0new; we key on the new path.
    private static func parseNumstat(_ data: Data) -> [String: (Int, Int)] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\u{0}", omittingEmptySubsequences: false)
        var counts: [String: (Int, Int)] = [:]
        var i = 0
        while i < fields.count {
            let row = String(fields[i]); i += 1
            let cols = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            let added = Int(cols[0]) ?? 0
            let removed = Int(cols[1]) ?? 0
            let pathCol = String(cols[2])
            if pathCol.isEmpty {                 // rename: old\0new follow as separate fields
                if i + 1 < fields.count {
                    let newPath = String(fields[i + 1])
                    counts[newPath] = (added, removed)
                    i += 2
                }
            } else {
                counts[pathCol] = (added, removed)
            }
        }
        return counts
    }

    private static func lineCount(of url: URL) -> Int {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        if s.isEmpty { return 0 }
        return s.hasSuffix("\n") ? s.split(separator: "\n", omittingEmptySubsequences: false).count - 1
                                 : s.split(separator: "\n").count
    }
}
