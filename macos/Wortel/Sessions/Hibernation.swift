import Foundation
import os

/// What dropping and restoring terminals did and how long it took.
///
///     log stream --level info --predicate 'subsystem == "com.gielcobben.Wortel" && category == "hibernation"'
enum HibernationLog {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "hibernation")
}

/// When a terminal out of sight gives back its surface (`SurfaceView.hibernate`).
///
/// A surface costs about 70 MB (its frames, its scrollback, its font atlas)
/// and holds nothing the keeper does not: the keeper keeps every session's
/// terminal, and a surface shown again is restored from it exactly. So one
/// out of sight for a minute goes, whatever its program is doing, and when
/// macOS says memory is short, every one out of sight goes at once.
///
/// One timer per hidden terminal, made when it is hidden and cancelled when
/// it is shown: nothing runs for a terminal on screen, and nothing polls.
/// Main thread only.
final class HibernationPolicy {
    static let shared = HibernationPolicy()

    /// How long a terminal stays out of sight before its surface goes. A
    /// constant, not a setting; `WORTEL_HIBERNATE_AFTER` (seconds) shortens
    /// it for a test.
    static let after: TimeInterval = {
        if let value = ProcessInfo.processInfo.environment["WORTEL_HIBERNATE_AFTER"],
           let seconds = TimeInterval(value), seconds > 0 { return seconds }
        return 60
    }()

    private var timers: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// Hidden terminals, for memory pressure. Weak: a closed session's view
    /// must not be kept alive by this.
    private var hidden = NSHashTable<SurfaceView>.weakObjects()
    private var pressure: DispatchSourceMemoryPressure?
    /// Set by `SessionManager`: macOS said memory is short, after the hidden
    /// terminals have given back their surfaces.
    var onMemoryPressure: (() -> Void)?

    private init() {
        // Screens saved by a hibernation of the app before 2026.48, which
        // nothing reads any more.
        try? FileManager.default.removeItem(at: DataDirectory.file("hibernated"))
        try? FileManager.default.removeItem(at: DataDirectory.file("saved-screens"))
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.memoryIsShort() }
        source.activate()
        pressure = source
    }

    /// The terminal went out of sight, or was made without being shown.
    func hidden(_ view: SurfaceView) {
        guard !view.isHibernated, view.keepsTerminalInKeeper else { return }
        hidden.add(view)
        let key = ObjectIdentifier(view)
        timers[key]?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            self?.timers[key] = nil
            guard let view, view.isHidden || view.superview == nil else { return }
            view.hibernate()
        }
        timers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.after, execute: work)
    }

    /// The terminal is about to be shown (or read): no timer, and its
    /// surface back. `onRestored` runs on the main thread once its screen is
    /// back, at once if it never went.
    func shown(_ view: SurfaceView, onRestored: (() -> Void)? = nil) {
        hidden.remove(view)
        timers.removeValue(forKey: ObjectIdentifier(view))?.cancel()
        view.wake(onRestored: onRestored)
    }

    private func memoryIsShort() {
        let level = pressure?.data ?? []
        let views = hidden.allObjects.filter { !$0.isHibernated && ($0.isHidden || $0.superview == nil) }
        HibernationLog.log.notice("""
            memory pressure (\(level.contains(.critical) ? "critical" : "warning", privacy: .public)): \
            dropping \(views.count) hidden terminals
            """)
        for view in views {
            timers.removeValue(forKey: ObjectIdentifier(view))?.cancel()
            view.hibernate()
        }
        // The terminals were Wortel's share. The agents are the larger one
        // (`AgentSleep`).
        onMemoryPressure?()
    }
}
