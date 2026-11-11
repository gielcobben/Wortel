import Foundation
import os

/// How the previous run ended, from one empty file.
///
/// The file is written as the app starts and removed when it quits properly.
/// Finding it at launch therefore means the last run never got to quit: it
/// crashed, was force quit, was killed, or the Mac lost power. That is the
/// whole mechanism, and it is deliberately this dumb: no signal handler, no
/// crash reporter, nothing that runs while the app is dying, because code that
/// runs in a crashing process is how a crash becomes a hang.
///
/// **Armed from `main.swift`, before the first frame.** The cost is one stat and
/// one empty write, and arming late would miss exactly the crashes worth
/// knowing about most: the ones during launch. The telemetry rule that nothing
/// runs before the window is up is about the network and the client; this
/// touches neither, and is local state like `instance.lock` beside it.
///
/// **It exists whether reporting is on or off.** It is a fact about the app,
/// read by nothing but the launch event, and an opt-out that changed what is
/// written to the data folder would be one more thing to explain.
enum ExitMarker {
    static let fileName = "running"

    /// When the run that left a marker started (the marker's date), or nil when
    /// there was none. Also what tells a crash report about *that* run apart
    /// from an older one: see `CrashReport.latest(after:)`. Behind a lock for
    /// the same reason as `TelemetrySettings.doNotTrack`: written once at
    /// launch, read later from wherever.
    private static let foundAtLaunch = OSAllocatedUnfairLock<Date?>(initialState: nil)
    static var lastRunEndedUncleanly: Bool { foundAtLaunch.withLock { $0 != nil } }
    static var uncleanRunStartedAt: Date? { foundAtLaunch.withLock { $0 } }

    /// Only builds that report keep a marker. A build from Xcode shares the
    /// release's bundle id and data folder, and Xcode's Stop is a SIGKILL: left
    /// to arm, every debugging session would make the next real launch look
    /// like a crash.
    static var applies: Bool {
        #if DEBUG
        return false
        #else
        return !TelemetrySettings.isDevelopmentBuild
        #endif
    }

    /// Read whether the last run left its marker, then leave this run's. Once,
    /// from `main.swift`, after `InstanceLock`: a second copy that is about to
    /// hand off and exit must never touch it, or the running one would look
    /// like it crashed.
    ///
    /// Always made anew rather than left in place, because its date is this
    /// run's start: kept, it would carry the crashed run's date forward, and
    /// the next crash would match the last one's report again.
    static func arm(at url: URL = DataDirectory.file(fileName)) {
        let manager = FileManager.default
        let found: Date? = (try? manager.attributesOfItem(atPath: url.path)).map {
            ($0[.modificationDate] as? Date) ?? .distantPast
        }
        foundAtLaunch.withLock { $0 = found }
        if found != nil { try? manager.removeItem(at: url) }
        manager.createFile(atPath: url.path, contents: nil)
    }

    /// A proper quit. From `applicationWillTerminate`, which every graceful
    /// path reaches, the Sparkle relaunch included.
    static func disarm(at url: URL = DataDirectory.file(fileName)) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The reportable answer. Pure, so the four cases are tested rather than
    /// trusted. `crashReported` is whether macOS left a crash report for the
    /// run that ended uncleanly; without one, all we know is that it did not
    /// quit.
    static func previousExit(firstLaunch: Bool, markerFound: Bool, crashReported: Bool) -> PreviousExit {
        if firstLaunch { return .none }
        guard markerFound else { return .clean }
        return crashReported ? .crashed : .unclean
    }
}
