import AppKit

/// The glyph state of an agent card (PRD §6.2). Mapping from CLI events lives in
/// the per-CLI `AgentAdapter`, not here, so this stays a pure domain type.
///
/// - `waiting`: the turn ended but the session has live background work (a build,
///   a background subagent) — "done" would lie, "running" would over-promise.
/// - `stalled`: the session *should* be progressing but isn't — rate-limited by
///   the API, or running with no events for minutes (hung tool, dead network).
enum CardStatus {
    case idle, running, waiting, done, stalled, blocked, error

    var color: NSColor {
        switch self {
        case .idle:    return Theme.colors.statusIdle
        case .running: return Theme.colors.statusRunning
        case .waiting: return Theme.colors.statusWaiting
        case .done:    return Theme.colors.statusDone
        case .stalled: return Theme.colors.statusStalled
        case .blocked: return Theme.colors.statusBlocked
        case .error:   return Theme.colors.statusError
        }
    }

    /// Only blocked/error pull the eye — "calm by default, loud only when it matters" (PRD §3.5).
    /// Stalled is deliberately *not* loud: it deserves a look, not an alarm.
    var isLoud: Bool { self == .blocked || self == .error }

    /// Lowercase display word for the title-bar status label.
    var word: String {
        switch self {
        case .idle:    return "idle"
        case .running: return "running"
        case .waiting: return "waiting"
        case .done:    return "done"
        case .stalled: return "stalled"
        case .blocked: return "blocked"
        case .error:   return "error"
        }
    }
}
