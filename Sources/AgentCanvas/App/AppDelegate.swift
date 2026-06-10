import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundledFonts()   // before any view reads Theme.fonts
        NSApp.mainMenu = Self.buildMainMenu()

        let rect = NSRect(x: 0, y: 0, width: 1400, height: 900)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Canvas"
        window.contentViewController = CanvasViewController()
        // Window frame persists for free; center only on first ever launch.
        window.setFrameAutosaveName("AgentCanvasMain")
        if !window.setFrameUsingName("AgentCanvasMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Capture final layout + camera position on quit.
        (window.contentViewController as? CanvasViewController)?.saveWorkspace()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A programmatic app has no nib-provided menu bar, and without an Edit menu
    /// AppKit never routes ⌘C/⌘V/⌘A to the first responder (SwiftTerm implements
    /// copy:/paste:/selectAll:). The first submenu is always the app menu.
    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(Updater.menuItem())
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Agent Canvas", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Agent Canvas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}
