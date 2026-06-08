import AppKit
import CoreText

/// Registers the app's bundled typefaces (Hanken Grotesk + IBM Plex Mono) with
/// CoreText for this process, so `NSFont(name:)` / family lookups in `Theme.fonts`
/// resolve. Call once at launch, before any view is built.
///
/// The `.ttf` files live in `Sources/AgentCanvas/Resources/Fonts` and are bundled
/// via `.copy("Resources/Fonts")` in `Package.swift`, reachable through
/// `Bundle.module`.
enum Fonts {
    static func registerBundledFonts() {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") else {
            canvasLog("Fonts: no bundled .ttf found — falling back to system fonts")
            return
        }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already-registered is benign; log anything else.
                canvasLog("Fonts: could not register \(url.lastPathComponent): \(String(describing: error))")
            }
        }
    }
}
