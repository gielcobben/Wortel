import AppKit

// Read first, because the scrub below deletes it. WORTEL_NO_KEEPER opts this
// launch out of process survival (see PtyHost), and `WORTEL_` is exactly the
// prefix InheritedEnvironment throws away — so a flag read any later is always
// unset, and the escape hatch would silently do nothing.
PtyHost.readEnableFlag()

// Same reason, same order. The scrub drops any variable whose value reaches
// into the temp directory, so a DO_NOT_TRACK read afterwards is one that can
// silently never fire, and an opt-out that fails open is the worst kind there
// is. See TelemetrySettings.
TelemetrySettings.readDoNotTrack()

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
