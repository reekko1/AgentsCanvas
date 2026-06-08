import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundledFonts()   // before any view reads Theme.fonts

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
}
