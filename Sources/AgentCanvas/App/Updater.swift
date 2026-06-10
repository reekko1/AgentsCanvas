import AppKit
import Sparkle

/// Sparkle auto-updates, armed only when running as a packaged app. The feed URL
/// and EdDSA public key are stamped into Info.plist by `Packaging/package.sh`
/// (`SUFeedURL` / `SUPublicEDKey`) — a dev build via `swift run` has neither, so
/// the updater stays dormant and the menu item disables itself.
///
/// Update flow is Sparkle-standard: check the appcast (Sparkle prompts the user
/// once for permission to check automatically), download the release zip, verify
/// BOTH the EdDSA signature and Apple's notarized code signature, swap on
/// relaunch. Thanks to the tmux substrate, that relaunch detaches and reattaches
/// the fleet — the canvas can update itself mid-supervision without killing work.
enum Updater {
    /// True when this build carries update metadata (i.e. it's a packaged app).
    static let isArmed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    static let controller = SPUStandardUpdaterController(
        startingUpdater: isArmed,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// "Check for Updates…" menu item, wired to Sparkle's standard action
    /// (Sparkle's own validation grays it out while a check runs or when the
    /// updater never started).
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…",
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }
}
