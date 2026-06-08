import AppKit

/// The glyph state of an agent card (PRD §6.2). Mapping from CLI events lives in
/// the per-CLI `AgentAdapter`, not here, so this stays a pure domain type.
enum CardStatus {
    case idle, running, blocked, done, error

    var color: NSColor {
        switch self {
        case .idle:    return NSColor(calibratedWhite: 0.50, alpha: 1)
        case .running: return NSColor.systemBlue
        case .blocked: return NSColor.systemRed
        case .done:    return NSColor.systemGreen
        case .error:   return NSColor.systemOrange
        }
    }

    /// Only blocked/error pull the eye — "calm by default, loud only when it matters" (PRD §3.5).
    var isLoud: Bool { self == .blocked || self == .error }
}
