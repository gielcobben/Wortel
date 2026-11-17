import AppKit

// Read first, because the scrub below deletes it. WORTEL_NO_KEEPER opts this
// launch out of process survival (see PtyHost), and `WORTEL_` is exactly the
// prefix InheritedEnvironment throws away — so a flag read any later is always
// unset, and the escape hatch would silently do nothing.
PtyHost.readEnableFlag()

// Where this launch keeps its state, read before the scrub for the same reason
// (WORTEL_DATA_DIR), and then claimed: one Wortel per data folder, settled
// before anything reads or writes one. A second copy brings the first forward
// and exits here. See InstanceLock.
_ = DataDirectory.url
InstanceLock.acquireOrHandOff()

// Same reason: WORTEL_HIBERNATE_AFTER shortens hibernation for a test.
_ = HibernationPolicy.after

// How the last run ended, read and re-armed now that this copy is the one that
// stays: a crash during launch is exactly the one worth seeing. One stat and
// one empty file, nothing on the network. See ExitMarker.
if ExitMarker.applies { ExitMarker.arm() }

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

// …and the data folder handed back, because what the scrub just removed is
// what the keeper, every shell and the `wortel` command find their sockets
// and files by. Only a custom one: the usual folder needs no variable.
if let custom = DataDirectory.custom { setenv(DataDirectory.variable, custom, 1) }

// Programmatic entry point (no storyboard). The shell is SwiftUI hosted in an
// AppKit window; see AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
