import AppKit

// Bootstrap a plain AppKit app (no @main, no storyboard) so the whole spike
// lives in readable source files and runs straight from `swift run`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
