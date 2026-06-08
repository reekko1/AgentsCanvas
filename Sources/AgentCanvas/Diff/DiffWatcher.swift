import Foundation

/// Passively watches a folder's git working tree by polling on a background queue.
/// It recomputes a cheap signature each tick and only delivers a full snapshot
/// (on the main thread) when the working tree actually changed — so an idle repo
/// costs one `git status` per interval and nothing more.
///
/// Poll (not FSEvents) is the v1 choice for simplicity; if many diff objects are
/// live at once this is the place to add off-screen pausing (mirrors lazy-spawn).
final class DiffWatcher {
    private let folder: URL
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "agentcanvas.diffwatcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastSignature: String?

    /// Called on the main thread whenever the snapshot changes (and once on start).
    var onChange: ((GitSnapshot) -> Void)?

    init(folder: URL, interval: TimeInterval = 1.5) {
        self.folder = folder
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let snap = GitDiff.snapshot(folder: folder)
        guard snap.signature != lastSignature else { return }
        lastSignature = snap.signature
        DispatchQueue.main.async { [weak self] in self?.onChange?(snap) }
    }
}
