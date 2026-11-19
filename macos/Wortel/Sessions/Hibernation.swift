import Foundation
import os

/// What hibernation did and how long it took.
///
///     log stream --level info --predicate 'subsystem == "com.gielcobben.Wortel" && category == "hibernation"'
enum HibernationLog {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "hibernation")
}

/// When a hidden terminal gives back its memory (`SurfaceView.hibernate`).
///
/// A terminal hidden for ten minutes hibernates; when macOS says memory is
/// short, every hidden one does at once. Shown again, it wakes. One timer per
/// hidden terminal, made when it is hidden and cancelled when it is shown:
/// nothing runs for a terminal on screen, and nothing polls.
///
/// Main thread only.
final class HibernationPolicy {
    static let shared = HibernationPolicy()

    /// How long a terminal stays hidden before it hibernates. A constant, not
    /// a setting; `WORTEL_HIBERNATE_AFTER` (seconds) shortens it for a test.
    static let after: TimeInterval = {
        if let value = ProcessInfo.processInfo.environment["WORTEL_HIBERNATE_AFTER"],
           let seconds = TimeInterval(value), seconds > 0 { return seconds }
        return 10 * 60
    }()

    /// How long a terminal that has never been shown waits: one made at
    /// launch so its session's dots and resume work. Nobody is flipping to
    /// it, so nothing is lost by its going soon, and the minute leaves time
    /// for the keeper's replay and an agent's resume to land first.
    static let neverShownAfter: TimeInterval = min(after, 60)

    private var timers: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// Hidden terminals, for memory pressure. Weak: a closed session's view
    /// must not be kept alive by this.
    private var hidden = NSHashTable<SurfaceView>.weakObjects()
    private var pressure: DispatchSourceMemoryPressure?
    /// Set by `SessionManager`: macOS said memory is short, after the hidden
    /// terminals have been hibernated.
    var onMemoryPressure: (() -> Void)?

    /// Agents that may hibernate while they run. Their work shows in what
    /// they write (a title spinner, OSC 9;4, notifications), which
    /// `SignalScanner` reads without a terminal, *and* they don't wait on the
    /// terminal to answer them: with no terminal, a cursor-position query
    /// goes unanswered until the program gives up. Only Claude Code has been
    /// watched through a hibernation (2026-11-17). Codex's TUI asks for the
    /// cursor position as it draws; the rest have not been tried. Every other
    /// agent keeps its terminal while it runs. See `macos/docs/agent-signals.md`.
    static let watchableAgents: Set<String> = ["claude"]

    /// How much of what a program writes is kept for a terminal that is away:
    /// as much as the keeper keeps for a session nobody is attached to.
    /// `WORTEL_MISSED_OUTPUT_LIMIT` (bytes) shortens it for a test.
    static let missedOutputLimit: Int = {
        if let value = ProcessInfo.processInfo.environment["WORTEL_MISSED_OUTPUT_LIMIT"],
           let bytes = Int(value), bytes > 0 { return bytes }
        return Keeper.replayLimit
    }()

    private init() {
        // Snapshots of terminals that were hibernated when the app last quit.
        // Their sessions came back through the keeper's replay, as every
        // session does after a relaunch, so nothing will read these.
        try? FileManager.default.removeItem(at: DataDirectory.file("hibernated"))
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.memoryIsShort() }
        source.activate()
        pressure = source
    }

    /// The terminal went out of sight, or was made without being shown
    /// (`neverShown`, which goes sooner).
    func hidden(_ view: SurfaceView, neverShown: Bool = false) {
        guard !view.isHibernated else { return }
        hidden.add(view)
        let key = ObjectIdentifier(view)
        timers[key]?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            self?.timers[key] = nil
            guard let view, view.isHidden || view.superview == nil else { return }
            if view.mayHibernate?() ?? true {
                view.hibernate()
            } else {
                // Not now: look again after another while out of sight.
                self?.hidden(view)
            }
        }
        timers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (neverShown ? Self.neverShownAfter : Self.after),
                                      execute: work)
    }

    /// The terminal is about to be shown (or read): no timer, and awake.
    /// `onRestored` runs on the main thread once its screen is back, at once
    /// if it was never asleep.
    func shown(_ view: SurfaceView, onRestored: (() -> Void)? = nil) {
        hidden.remove(view)
        timers.removeValue(forKey: ObjectIdentifier(view))?.cancel()
        view.wake(onRestored: onRestored)
    }

    /// A hibernated terminal's program has written half of what is kept for
    /// it, or another sixteenth since this was last asked
    /// (`SurfaceView.hibernate`).
    ///
    /// An agent that was resting when its terminal went can start a turn
    /// while it is away: a task of its own finishing, a wake-up it scheduled,
    /// another session sending it something. Left alone it writes past what
    /// is kept, and the terminal that comes back is an old screen with the
    /// end of a drawing on it. So a terminal that would not be hibernated
    /// now is given back while everything it missed is still there, out of
    /// sight, and goes on the clock again for when its program rests.
    /// One that may hibernate as it is (a shell printing a log) is left: what
    /// it loses is the oldest lines, and they are lines.
    func outrunning(_ view: SurfaceView) {
        guard view.isHibernated, !(view.mayHibernate?() ?? true) else { return }
        HibernationLog.log.notice("waking a terminal out of sight: its program is writing more than is kept for it")
        timers.removeValue(forKey: ObjectIdentifier(view))?.cancel()
        view.wake()
        if view.isHidden || view.superview == nil { hidden(view) }
    }

    private func memoryIsShort() {
        let level = pressure?.data ?? []
        let views = hidden.allObjects.filter {
            !$0.isHibernated && ($0.isHidden || $0.superview == nil) && ($0.mayHibernate?() ?? true)
        }
        HibernationLog.log.notice("""
            memory pressure (\(level.contains(.critical) ? "critical" : "warning", privacy: .public)): \
            hibernating \(views.count) hidden terminals
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
