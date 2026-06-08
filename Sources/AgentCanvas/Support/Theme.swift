import AppKit

/// The app's visual theme — every color and font in one place, named by *role*.
/// Direction: **"lo-fi dusk studio"** (per the design handoff in `design-reference/`):
/// a warm plum-indigo night and a warm-paper day, calm by default and loud only
/// when it matters.
///
/// Colors are **appearance-adaptive**: each token is a dynamic `NSColor` that
/// resolves its dark/light sRGB value via `NSAppearance`. Values were converted
/// once from the design's OKLCH tokens to sRGB (see `design-reference` +
/// the conversion in the build notes).
///
/// ⚠️ Dynamic colors adapt automatically only when used *as `NSColor`* (text,
/// `backgroundColor`, fills in `draw(_:)`). Pushed into a layer as `.cgColor` they
/// freeze to the appearance at assignment time — those views must re-apply on
/// `viewDidChangeEffectiveAppearance()`. See `ItemContainerView`, `DiffContentView`,
/// `GridBackdropView`, and the diff file-list cell.
///
/// - **Design tokens** are the canonical names (`itemBody`, `glyph`, `primary`…).
/// - **Legacy aliases** (`itemChrome`, `titleBar`, `textControl`…) are kept as
///   computed pass-throughs so existing call sites keep compiling.
///
/// Geometry/sizing lives in `CanvasLayout`; motion constants in `Theme.motion`.
enum Theme {
    static let colors = Palette()
    static let fonts = Typography()
    static let motion = Motion()
}

// MARK: - Colors

extension Theme {
    struct Palette {
        // ---- Surfaces ----
        let canvasBackground = dyn(d: (0.0759, 0.0648, 0.1110), l: (0.9341, 0.9129, 0.8756))
        let canvasWarm       = dyn(d: (0.1440, 0.0854, 0.1384), l: (0.9940, 0.9462, 0.8941)) // centre vignette glow
        let itemBody         = dyn(d: (0.1259, 0.1206, 0.1662), l: (0.9886, 0.9794, 0.9632))
        let itemBar          = dyn(d: (0.1635, 0.1569, 0.2129), l: (0.9588, 0.9391, 0.9042))
        let terminalBg       = dyn(d: (0.0459, 0.0425, 0.0795), l: (0.0883, 0.0848, 0.1284)) // stays dark in light mode
        let diffSurface      = dyn(d: (0.0897, 0.0850, 0.1246), l: (0.9886, 0.9794, 0.9632))
        let fileListBg       = dyn(d: (0.1167, 0.1120, 0.1530), l: (0.9561, 0.9394, 0.9099))

        // ---- Text & glyphs ----
        let textPrimary      = dyn(d: (0.9336, 0.9135, 0.8726), l: (0.1781, 0.1728, 0.2208))
        let textMuted        = dyn(d: (0.5708, 0.5654, 0.6241), l: (0.4092, 0.4040, 0.4592))
        let glyph            = dyn(d: (0.7414, 0.7365, 0.7925), l: (0.3216, 0.3164, 0.3693))

        // ---- Lines / interaction ----
        let border           = dyn(d: (0.2227, 0.2174, 0.2672), l: (0.8425, 0.8232, 0.7892))
        let borderSoft       = dyn(d: (0.1781, 0.1735, 0.2171), l: (0.8860, 0.8681, 0.8364))
        let hover            = dyn(d: (0.1877, 0.1812, 0.2384), l: (0.9081, 0.8871, 0.8499))
        let selection        = dyn(d: (0.2092, 0.2064, 0.3077), l: (0.8586, 0.8601, 0.9609))
        let gridDot          = dyn(d: (0.1781, 0.1735, 0.2171), l: (0.8425, 0.8232, 0.7892))

        // ---- Agent status (cool+quiet calm / warm+bright loud) ----
        let statusIdle       = dyn(d: (0.5000, 0.4929, 0.5657), l: (0.5705, 0.5640, 0.6333))
        let statusRunning    = dyn(d: (0.2808, 0.7500, 0.7544), l: (0.0000, 0.6292, 0.6571))
        let statusDone       = dyn(d: (0.4609, 0.8056, 0.5974), l: (0.1943, 0.6132, 0.4100))
        let statusBlocked    = dyn(d: (0.9825, 0.7131, 0.2129), l: (0.8965, 0.5585, 0.0000))
        let statusError      = dyn(d: (0.9524, 0.2467, 0.2999), l: (0.8666, 0.1469, 0.2040))

        // ---- Unified-diff syntax ----
        let diffAdded        = dyn(d: (0.4458, 0.8123, 0.5552), l: (0.0752, 0.4913, 0.2551))
        let diffAddedBg      = dynA(d: (0.1541, 0.3232, 0.2059, 0.22), l: (0.6452, 0.8884, 0.7065, 0.55))
        let diffRemoved      = dyn(d: (0.9473, 0.4414, 0.4245), l: (0.7565, 0.2333, 0.2402))
        let diffRemovedBg    = dynA(d: (0.4804, 0.2015, 0.1934, 0.22), l: (1.0000, 0.7443, 0.7194, 0.55))
        let diffHunk         = dyn(d: (0.5714, 0.6341, 0.8569), l: (0.3655, 0.4278, 0.6744))
        let diffMeta         = dyn(d: (0.4774, 0.4727, 0.5243), l: (0.5005, 0.4957, 0.5478))
        let diffText         = dyn(d: (0.6190, 0.6146, 0.6634), l: (0.3325, 0.3284, 0.3720))

        // ---- File change types (must read small, both modes) ----
        let fileAdded        = dyn(d: (0.4458, 0.8123, 0.5552), l: (0.0752, 0.4913, 0.2551))
        let fileModified     = dyn(d: (0.9479, 0.7279, 0.3239), l: (0.6894, 0.4437, 0.0000))
        let fileDeleted      = dyn(d: (0.9534, 0.3826, 0.3738), l: (0.7718, 0.2097, 0.2255))
        let fileRenamed      = dyn(d: (0.5731, 0.6259, 0.8916), l: (0.3572, 0.4038, 0.7042))
        let fileUntracked    = dyn(d: (0.5235, 0.5173, 0.5829), l: (0.4771, 0.4709, 0.5354))

        // ---- Accents / controls ----
        let primary          = dyn(d: (0.5730, 0.5771, 0.9285), l: (0.4108, 0.3970, 0.7874))
        let primaryInk       = dyn(d: (0.0481, 0.0472, 0.0845), l: (0.9851, 0.9855, 1.0000)) // text on primary
        let primaryDisabled  = dyn(d: (0.2732, 0.2731, 0.3434), l: (0.7870, 0.7882, 0.8449))
        let pillBg           = dyn(d: (0.1921, 0.1915, 0.2579), l: (0.8761, 0.8774, 0.9353))

        // ---- Terminal sample content (real PTY uses the configured ANSI palette) ----
        let termText         = dyn(d: (0.7635, 0.8361, 0.8393), l: (0.7635, 0.8361, 0.8393))
        let termMuted        = dyn(d: (0.4457, 0.4843, 0.5256), l: (0.4457, 0.4843, 0.5256))

        // Icon-button hover highlight — a subtle alpha wash (kept distinct from `hover`).
        let controlHover = NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(calibratedWhite: 1, alpha: 0.10)
                                                               : NSColor(calibratedWhite: 0, alpha: 0.07)
        }

        // ---- Legacy aliases (so existing call sites keep compiling) ----
        var itemChrome:      NSColor { itemBody }
        var titleBar:        NSColor { itemBar }
        var contentSurface:  NSColor { diffSurface }
        var listSurface:     NSColor { fileListBg }
        var textControl:     NSColor { glyph }
        var groupHeader:     NSColor { textMuted }
        var badgeBackground: NSColor { pillBg }
        var badgeText:       NSColor { textMuted }
        var commitIdle:      NSColor { primaryDisabled }
        var neutralBorder:   NSColor { border }
    }
}

// MARK: - Fonts

extension Theme {
    /// Hanken Grotesk (UI) + IBM Plex Mono (terminals/diffs/labels), bundled and
    /// registered at launch (`Fonts.registerBundledFonts()`). Properties are
    /// *computed* so they resolve after registration; each falls back to a system
    /// font if the bundled face is somehow unavailable.
    struct Typography {
        /// UI face (Hanken Grotesk, a variable font — weight via descriptor trait).
        func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            let desc = NSFontDescriptor(fontAttributes: [
                .family: "Hanken Grotesk",
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            return NSFont(descriptor: desc, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
        /// Mono face (IBM Plex Mono — three static weights bundled).
        func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            let name: String
            switch weight {
            case .semibold, .bold, .heavy, .black: name = "IBMPlexMono-SemiBold"
            case .medium:                          name = "IBMPlexMono-Medium"
            default:                               name = "IBMPlexMono"
            }
            return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        }

        // Role-named (used across the app; tuned for our ~960×640 chrome).
        var itemTitle:    NSFont { ui(19, .semibold) }   // title-bar item name
        var statusWord:   NSFont { mono(12, .medium) }   // UPPERCASE status word
        var controlGlyph: NSFont { ui(17, .semibold) }   // ✕ button
        var placeholder:  NSFont { ui(16, .regular) }    // dormant-card placeholder
        var hint:         NSFont { ui(16, .medium) }     // empty-canvas hint
        var diffMono:     NSFont { mono(12.5, .regular) } // diff body
        var listPath:     NSFont { ui(13, .regular) }    // commit field / generic
        var monoPath:     NSFont { mono(13, .regular) }  // file paths in the diff list
        var listStat:     NSFont { mono(11, .regular) }  // +A −R counts
        var message:      NSFont { ui(14, .regular) }    // diff-pane empty states
    }
}

// MARK: - Motion (timing + easing from the design's motion notes)

extension Theme {
    struct Motion {
        let flyTo:  CFTimeInterval = 0.64   // zoom into an item
        let fitAll: CFTimeInterval = 0.76   // zoom out to fit
        let status: CFTimeInterval = 0.30   // status colour cross-fade
        let flare:  CFTimeInterval = 0.44   // loud-state entry flare
        /// Camera fly-to easing — cubic-bezier(0.22, 1, 0.36, 1).
        var flyEase: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1) }
        /// UI / status easing — cubic-bezier(0.4, 0, 0.2, 1).
        var softEase: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1) }
    }
}

// MARK: - Dynamic sRGB helpers

/// An appearance-adaptive sRGB color: resolves to `d` in dark, `l` otherwise.
private func dyn(d: (CGFloat, CGFloat, CGFloat), l: (CGFloat, CGFloat, CGFloat)) -> NSColor {
    NSColor(name: nil) { ap in
        let c = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}

/// Same, with alpha (for translucent diff line backgrounds).
private func dynA(d: (CGFloat, CGFloat, CGFloat, CGFloat), l: (CGFloat, CGFloat, CGFloat, CGFloat)) -> NSColor {
    NSColor(name: nil) { ap in
        let c = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
    }
}
