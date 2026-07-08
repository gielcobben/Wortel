import AppKit

// Programmatic entry point (no storyboard). The shell is SwiftUI hosted in an
// AppKit window; see AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
