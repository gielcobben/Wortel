import Foundation

/// What every reader of the agents' own files needs: the end of a file
/// without the rest of it, and their timestamps.
///
/// Shared by `ClaudeTranscriptTail`, `AgentAnswer`, `PromptHistory` and
/// `PromptHistoryStore`, which each grew a copy: three ISO 8601 parsers
/// building a formatter per call (per transcript line, in a loop) and two
/// tail reads. Foundation only, in `WortelTests` with its readers.
enum AgentFiles {
    // MARK: - Timestamps

    /// Built once and only ever read from. `ISO8601DateFormatter` is
    /// documented thread-safe, and these are configured here and never
    /// again, which is what makes sharing them safe (`TelemetryClient` builds
    /// its own per call for the opposite reason: it configures one).
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// An ISO 8601 timestamp, with or without fractional seconds: Claude and
    /// Pi write them with, Codex sometimes without.
    static func date(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }

    /// The same for a JSON value that should be one.
    static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { date($0) }
    }

    // MARK: - The end of a file

    /// The last `maxBytes` of a file, and whether that started mid-file (so
    /// its first line is probably cut). nil when it can't be read. Blocking
    /// file IO: call off the main thread.
    static func tail(of url: URL, maxBytes: Int) -> (data: Data, fromMiddle: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }
}
