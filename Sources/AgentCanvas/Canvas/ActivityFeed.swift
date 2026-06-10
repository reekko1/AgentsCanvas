import Foundation

/// One entry in the activity center.
struct ActivityEvent {
    let id: String          // card id → fly-to target
    let name: String
    let status: CardStatus
    let message: String
    let date: Date
    var loud: Bool { status.isLoud }
}

/// In-memory log of agent status changes — the source for the activity center.
/// Newest first; capped. Not persisted (status never is — see the spine).
final class ActivityFeed {
    private(set) var events: [ActivityEvent] = []
    private let cap = 40

    /// `detail` is the spine's payload-derived line ("Bash: npm install",
    /// "API failure: rate_limit"); the per-status copy is the fallback.
    func record(id: String, name: String, status: CardStatus, detail: String?, date: Date) {
        events.insert(ActivityEvent(id: id, name: name, status: status,
                                    message: detail ?? Self.message(for: status), date: date), at: 0)
        if events.count > cap { events.removeLast(events.count - cap) }
    }

    static func message(for s: CardStatus) -> String {
        switch s {
        case .idle:    return "Went idle"
        case .running: return "Started working"
        case .waiting: return "Waiting on background work"
        case .done:    return "Finished — waiting for you"
        case .stalled: return "Stalled — no recent activity"
        case .blocked: return "Needs your permission"
        case .error:   return "Something went wrong"
        }
    }
}
