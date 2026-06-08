import AppKit

/// The app's visual theme — every color and font in one place, named by *role*
/// (not by value). Call sites read `Theme.colors.panelChrome` / `Theme.fonts.itemTitle`.
///
/// Colors are **appearance-adaptive**: each custom color is a dynamic `NSColor` that
/// resolves its dark/light value automatically via `NSAppearance`. System colors
/// (`.systemBlue` etc.) are already dynamic, so status/diff hues adapt for free.
///
/// - **Extend:** add a property to `Palette` / `Typography` and reference it.
/// - **Modify:** change the dark/light values in one place.
///
/// ⚠️ Dynamic colors adapt automatically only when used *as `NSColor`* (text colors,
/// `backgroundColor`, fills in `draw(_:)`). When a color is pushed into a layer as
/// `.cgColor` it freezes to the appearance at assignment time — those views must
/// re-apply it in `viewDidChangeEffectiveAppearance()`. See `ItemContainerView`,
/// `DiffContentView`, `GridBackdropView`, and the diff file-list cell.
///
/// Geometry/sizing intentionally lives in `CanvasLayout`, not here.
enum Theme {
    static let colors = Palette()
    static let fonts = Typography()
}

// MARK: - Colors

extension Theme {
    /// Role-named colors. Tokens that share a value today (e.g. `statusDone` and
    /// `diffAdded` are both green) are kept separate on purpose, so each can be
    /// retuned without disturbing the other.
    struct Palette {
        // Surfaces
        let canvasBackground = dynamic(dark: 0.09, light: 0.95)  // the infinite grid backdrop
        let gridDot          = dynamic(dark: 0.17, light: 0.80)  // dots on the backdrop
        let itemChrome       = dynamic(dark: 0.12, light: 0.98)  // an item window's body
        let titleBar         = dynamic(dark: 0.20, light: 0.90)  // an item's draggable title bar
        let contentSurface   = dynamic(dark: 0.10, light: 1.00)  // content backdrop (diff text area)
        let listSurface      = dynamic(dark: 0.13, light: 0.96)  // file-list backdrop

        // Text & controls
        let textPrimary      = dynamic(dark: 0.90, light: 0.15)  // titles, file paths
        let textControl      = dynamic(dark: 0.75, light: 0.35)  // glyph buttons (✕)
        let textMuted        = dynamic(dark: 0.55, light: 0.45)  // placeholders, hints, empty states
        let groupHeader      = dynamic(dark: 0.68, light: 0.40)  // "Staged Changes" / "Changes" labels
        let badgeBackground  = dynamic(dark: 0.28, light: 0.80)  // count-pill background
        let badgeText        = dynamic(dark: 0.90, light: 0.20)  // count-pill text
        let commitIdle       = dynamic(dark: 0.26, light: 0.80)  // commit button when disabled
        let controlHover     = NSColor(name: nil) { a in         // icon-button hover highlight (alpha)
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(calibratedWhite: 1, alpha: 0.14)
                                                               : NSColor(calibratedWhite: 0, alpha: 0.09)
        }

        // Item accent border (status color belongs to cards; diffs use neutral)
        let neutralBorder    = dynamic(dark: 0.40, light: 0.65)

        // Agent card status — system hues already adapt; idle is a custom gray.
        let statusIdle       = dynamic(dark: 0.50, light: 0.55)
        let statusRunning: NSColor = .systemBlue
        let statusBlocked: NSColor = .systemRed
        let statusDone:    NSColor = .systemGreen
        let statusError:   NSColor = .systemOrange

        // Unified-diff syntax
        let diffAdded:   NSColor = .systemGreen
        let diffRemoved: NSColor = .systemRed
        let diffHunk:    NSColor = .systemTeal
        let diffMeta     = dynamic(dark: 0.45, light: 0.55)      // file/index headers
        let diffText     = dynamic(dark: 0.82, light: 0.22)      // unchanged context lines

        // Changed-file status letters. Tuned per-appearance for contrast: bright on
        // the dark list, darker/saturated on the light list (system hues — esp.
        // yellow — wash out on a near-white background).
        let fileAdded    = dynamicRGB(dark: .init(srgbRed: 0.36, green: 0.78, blue: 0.45, alpha: 1),
                                      light: .init(srgbRed: 0.13, green: 0.52, blue: 0.20, alpha: 1))
        let fileModified = dynamicRGB(dark: .init(srgbRed: 0.90, green: 0.71, blue: 0.22, alpha: 1),
                                      light: .init(srgbRed: 0.60, green: 0.42, blue: 0.00, alpha: 1))
        let fileDeleted  = dynamicRGB(dark: .init(srgbRed: 0.93, green: 0.38, blue: 0.36, alpha: 1),
                                      light: .init(srgbRed: 0.74, green: 0.12, blue: 0.12, alpha: 1))
        let fileRenamed  = dynamicRGB(dark: .init(srgbRed: 0.40, green: 0.66, blue: 1.00, alpha: 1),
                                      light: .init(srgbRed: 0.10, green: 0.38, blue: 0.80, alpha: 1))
    }
}

// MARK: - Fonts

extension Theme {
    /// Role-named fonts. Fonts have no appearance variants, so these are plain.
    struct Typography {
        let itemTitle:    NSFont = .systemFont(ofSize: 22, weight: .medium)    // title-bar label
        let controlGlyph: NSFont = .systemFont(ofSize: 20, weight: .semibold)  // ✕ button
        let placeholder:  NSFont = .systemFont(ofSize: 22, weight: .regular)   // dormant-card placeholder
        let hint:         NSFont = .systemFont(ofSize: 22, weight: .medium)    // empty-canvas hint
        let diffMono:     NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)  // diff body
        let listPath:     NSFont = .systemFont(ofSize: 12)                     // file path in the list
        let listStat:     NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)  // +A −R counts
        let message:      NSFont = .systemFont(ofSize: 15)                     // diff-pane empty states
    }
}

// MARK: - Dynamic color helper

/// A calibrated-gray color that resolves to `dark` in a dark appearance and `light`
/// otherwise. Used for the app's desaturated surfaces/text.
private func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .gray(dark) : .gray(light)
    }
}

/// A color that resolves to `dark` in a dark appearance and `light` otherwise — for
/// hues that need different values per mode to keep contrast (e.g. status letters).
private func dynamicRGB(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

extension NSColor {
    /// Opaque calibrated gray.
    static func gray(_ white: CGFloat) -> NSColor { NSColor(calibratedWhite: white, alpha: 1) }
}
