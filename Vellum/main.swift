import AppKit

// Programmatic entry point: no storyboard, no xib, no SwiftUI.
// Everything the first frame needs is built by hand for launch speed.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
