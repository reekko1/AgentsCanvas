import AppKit

/// The glyph state of an agent card (PRD §6.2). Mapping from CLI events lives in
/// the per-CLI `AgentAdapter`, not here, so this stays a pure domain type.
enum CardStatus {
    case idle, running, blocked, done, error

    var color: NSColor {
        switch self {
        case .idle:    return Theme.colors.statusIdle
        case .running: return Theme.colors.statusRunning
        case .blocked: return Theme.colors.statusBlocked
        case .done:    return Theme.colors.statusDone
        case .error:   return Theme.colors.statusError
        }
    }

    /// Only blocked/error pull the eye — "calm by default, loud only when it matters" (PRD §3.5).
    var isLoud: Bool { self == .blocked || self == .error }

    /// Lowercase display word for the title-bar status label.
    var word: String {
        switch self {
        case .idle:    return "idle"
        case .running: return "running"
        case .blocked: return "blocked"
        case .done:    return "done"
        case .error:   return "error"
        }
    }
}
