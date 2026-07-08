import OSLog

/// Signposts for Instruments. Zero cost when Instruments isn't attached, so
/// they're safe to leave in release builds. Profile session switching by
/// recording the "Points of Interest" instrument and filtering on this log.
enum Signposts {
    static let log = OSLog(subsystem: "com.gielcobben.Vellum", category: .pointsOfInterest)

    /// Run `body` inside a signposted interval named `name`.
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () -> T) -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return body()
    }
}
