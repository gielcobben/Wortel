import OSLog

/// Signposts for Instruments. Zero cost when Instruments isn't attached, so
/// they're safe to leave in release builds. Profile session switching by
/// recording the "Points of Interest" instrument and filtering on this log.
/// Debug-level trace of the signals the sidebar's busy/attention state is
/// inferred from. Agent CLIs differ wildly in what they emit — a title spinner,
/// OSC 9;4 progress, both, or neither — so when a session's status looks wrong
/// the first question is always "what did the program actually send?".
///
/// `.debug` messages are dropped unless someone is listening, so this costs
/// nothing in a normal run. To watch it:
///
///     log stream --level debug \
///       --predicate 'subsystem == "com.gielcobben.Wortel" && category == "agent-status"'
enum AgentStatusLog {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "agent-status")

    /// `Logger` has no "is anyone listening?" query, so keep an `OSLog` twin on
    /// the same subsystem/category purely to answer it. Worth the two objects:
    /// the title trace formats scalars for a signal that fires several times a
    /// second per working agent, and that work should not happen when the log
    /// is going nowhere.
    private static let probe = OSLog(subsystem: "com.gielcobben.Wortel", category: "agent-status")

    static var isTracing: Bool { probe.isEnabled(type: .debug) }
}

enum Signposts {
    static let log = OSLog(subsystem: "com.gielcobben.Wortel", category: .pointsOfInterest)

    /// Run `body` inside a signposted interval named `name`.
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () -> T) -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return body()
    }
}
