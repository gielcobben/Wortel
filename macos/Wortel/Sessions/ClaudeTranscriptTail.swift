import Foundation

/// What the end of a Claude Code conversation says about the turn that just
/// went quiet, for the two cases the terminal can't tell apart from a turn
/// that simply finished.
///
/// Claude's only signals under Ghostty are its `9;4` progress edges and its
/// title (`docs/agent-signals.md`), and both look the same whether the turn
/// ended with an answer, an API error, or a question it is now waiting on. The
/// transcript is where the difference is written down, so when a Claude turn
/// quiesces the caller reads its last stretch and asks this. Observation only,
/// like `AgentConversation`: reading the file Claude already writes, never
/// configuring it.
///
/// Layout, verified against Claude Code 2.1.299 transcripts on 2026-10-14:
/// one JSON object per line; `type` is `assistant` or `user` for the
/// conversation and something else (`attachment`, `system`, `last-prompt`,
/// `ai-title`, …) for bookkeeping written around it. An API failure is a
/// synthetic assistant entry with `"isApiErrorMessage": true` and the message
/// in `message.content[0].text`. A tool call is written the moment it is made,
/// so a question or a plan still waiting on the user is an assistant
/// `tool_use` with no `user` entry after it (the `tool_result` arrives only
/// once it's answered). Subagent traffic is marked `isSidechain` and is not the
/// turn the user is looking at.
enum ClaudeTranscriptTail {
    enum Verdict: Equatable {
        /// The turn ended on an API error; the associated text is Claude's
        /// message without its "API Error: " prefix, shortened.
        case apiError(String)
        /// Claude asked the user something (`AskUserQuestion`) and is waiting.
        case question
        /// Claude finished planning (`ExitPlanMode`) and is waiting for approval.
        case plan
    }

    /// How much of the end of a transcript is worth reading: a turn's last
    /// entries, with room for a long final message. A transcript runs to tens
    /// of megabytes; this is all that is ever read.
    static let tailBytes = 256 * 1024

    /// Longest error text carried into a notification.
    static let messageLimit = 140

    /// The verdict for the turn that started at `since`, or nil when the turn
    /// ended in an ordinary way (or the tail says nothing newer than `since`).
    ///
    /// `data` may start mid-line, as a tail read does; a line that doesn't
    /// parse is skipped rather than ending the search.
    static func verdict(_ data: Data, since: Date) -> Verdict? {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String,
                  type == "assistant" || type == "user"
            else { continue }
            if entry["isSidechain"] as? Bool == true { continue }
            // Older than this turn: whatever it says belongs to a turn the
            // user has already seen end.
            if let stamp = entry["timestamp"] as? String, let date = parseDate(stamp), date < since {
                return nil
            }
            // A user entry after the last assistant one means nothing is
            // pending: it's the answer to a question, or a new prompt.
            guard type == "assistant" else { return nil }
            let content = (entry["message"] as? [String: Any])?["content"]
            if entry["isApiErrorMessage"] as? Bool == true {
                return .apiError(errorText(content))
            }
            for block in (content as? [[String: Any]] ?? []).reversed()
            where block["type"] as? String == "tool_use" {
                switch block["name"] as? String {
                case "AskUserQuestion": return .question
                case "ExitPlanMode": return .plan
                default: return nil
                }
            }
            return nil
        }
        return nil
    }

    /// The message of an API error entry, cut to something a notification can
    /// carry. Some carry the prefix ("API Error: Your computer went to sleep
    /// mid-response…"), some don't ("Prompt is too long").
    static func errorText(_ content: Any?) -> String {
        var text = ""
        if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else if let string = content as? String {
            text = string
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("API Error:") {
            text = String(text.dropFirst("API Error:".count)).trimmingCharacters(in: .whitespaces)
        }
        if text.isEmpty { return "The request failed" }
        guard text.count > messageLimit else { return text }
        return String(text.prefix(messageLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The last `tailBytes` of the transcript at `url`, or nil when it can't be
    /// read. Blocking file IO: call off the main thread.
    static func readTail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
