import AppKit

// Before anything can spawn a child process — a surface's shell, a `git` read —
// forget the environment of whatever launched us. See InheritedEnvironment: an
// app opened from a coding agent's shell otherwise hands that agent's session
// markers to every terminal it opens.
InheritedEnvironment.apply()

// Programmatic entry point (no storyboard). The shell is SwiftUI hosted in an
// AppKit window; see AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
