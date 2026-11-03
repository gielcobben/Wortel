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
///
/// Claude also goes quiet after work nobody asked for. On 2.1.314 a long
/// conversation is compacted while idle, 54 minutes after its last activity so
/// the summary is written before the prompt cache expires, and that runs for
/// half a minute or more with the same spinner and `9;4` edges as a turn. It
/// adds no assistant entry. What it does add is a summary, a `user` entry with
/// `isCompactSummary`, then the restored files, then a `system` entry,
/// `informational`, saying so. Both are needed: the note can land more than a
/// second after the summary, past the settle window, and the restored files
/// can run past `tailBytes`, leaving only the note. The `compact_boundary`
/// beside the summary is no help for the same reason.
///
/// The screen tier can be wrong the same way, and for reasons that have nothing
/// to do with Claude: anything that repaints an idle session for a few seconds
/// looks like a short turn to it, most of all after a relaunch, before the
/// session has said anything to show it speaks for itself. Measured on
/// 2026-10-30: three sessions idle for hours got "Finished, your move" in the
/// same second. A real turn writes to the transcript, so a guess with nothing
/// written behind it was no turn.
enum ClaudeTranscriptTail {
    enum Verdict: Equatable {
        /// The turn ended on an API error; the associated text is Claude's
        /// message without its "API Error: " prefix, shortened.
        case apiError(String)
        /// Claude asked the user something (`AskUserQuestion`) and is waiting.
        case question
        /// Claude finished planning (`ExitPlanMode`) and is waiting for approval.
        case plan
        /// No turn at all, and nothing new to read or answer: Claude compacted
        /// the conversation on its own while idle, or the screen tier guessed
        /// at a turn that left nothing in the transcript.
        case noTurn
    }

    /// How much of the end of a transcript is worth reading: a turn's last
    /// entries, with room for a long final message. A transcript runs to tens
    /// of megabytes; this is all that is ever read.
    static let tailBytes = 256 * 1024

    /// Longest error text carried into a notification.
    static let messageLimit = 140

    /// How the note an idle compaction leaves begins (2.1.314). Not its
    /// sibling, "Compacted using a summary written while you were away": that
    /// one is written inside a real turn, by the prompt that found a summary
    /// ready. Should the wording change, the session gets its dot back, which
    /// is the safe way round: a missed turn would cost more than a stray dot.
    static let idleCompactionNote = "Compacted while idle"

    /// The verdict for the turn that started at `since`, or nil when the turn
    /// ended in an ordinary way (or the tail says nothing newer than `since`).
    /// `guessed` says the quiet came from the screen tier rather than from
    /// Claude itself, which makes a tail with nothing newer than `since` an
    /// answer: `noTurn`.
    ///
    /// `data` may start mid-line, as a tail read does; a line that doesn't
    /// parse is skipped rather than ending the search.
    static func verdict(_ data: Data, since: Date, guessed: Bool = false) -> Verdict? {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String
            else { continue }
            if entry["isSidechain"] as? Bool == true { continue }
            // An older note still dates a tail that is all restored files, so
            // for a guess it is as good as finding nothing newer.
            if type == "system", let noted = idleCompactionDate(entry), guessed || noted >= since {
                return .noTurn
            }
            guard type == "assistant" || type == "user" else { continue }
            // Older than this turn: whatever it says belongs to a turn the
            // user has already seen end.
            if let stamp = entry["timestamp"] as? String, let date = AgentFiles.date(stamp), date < since {
                return guessed ? .noTurn : nil
            }
            // Written ahead of the note, which may not be on disk yet. Nothing
            // came after it, so no prompt is waiting and no reply was made.
            if entry["isCompactSummary"] as? Bool == true { return .noTurn }
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

    /// When the note an idle compaction leaves was written, if `entry` is one.
    /// An undated note can't be placed, so it doesn't count.
    private static func idleCompactionDate(_ entry: [String: Any]) -> Date? {
        guard entry["subtype"] as? String == "informational",
              (entry["content"] as? String)?.hasPrefix(idleCompactionNote) == true,
              let stamp = entry["timestamp"] as? String
        else { return nil }
        return AgentFiles.date(stamp)
    }

    /// Whether the conversation is mid-turn: its last entry is a tool call
    /// with no answer yet (a Bash or Edit waiting on permission, or a tool
    /// still running), a tool's answer Claude hasn't replied to, or a prompt
    /// it hasn't answered. False once Claude has had the last word, or the
    /// user interrupted it.
    ///
    /// This is what tells a finished turn from a permission prompt, which the
    /// terminal can't: Claude ends its `9;4` progress at both. `verdict` only
    /// needs the two tools that are questions; anything that quits Claude on
    /// the strength of "the turn ended" (`wortel cd`) needs every one.
    static func turnIsOpen(_ data: Data) -> Bool {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String,
                  type == "assistant" || type == "user"
            else { continue }
            // Subagent traffic, and what Claude adds around a prompt (a
            // skill's body, a command's caveat) or in place of the conversation
            // (a compaction's summary), speak for no one.
            if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true
                || entry["isCompactSummary"] as? Bool == true { continue }
            let content = (entry["message"] as? [String: Any])?["content"]
            let blocks = content as? [[String: Any]] ?? []
            if type == "assistant" {
                return blocks.contains { $0["type"] as? String == "tool_use" }
            }
            // A user entry: a tool's result or a prompt Claude owes an answer
            // to. Not the marker it writes when interrupted, nor what a slash
            // command or a `!` shell command records, which Claude answers
            // with nothing.
            let text = (content as? String)
                ?? blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            return !answeredByNothing.contains { text.hasPrefix($0) }
        }
        return false
    }

    /// The start of Claude's last answer, for the notification body
    /// (`AgentAnswer`): the first paragraph of prose in its final message,
    /// the question it is waiting on (`AskUserQuestion`'s first), or the
    /// plan it wants approved (`ExitPlanMode`). nil when the turn that started
    /// at `since` ended in nothing worth quoting: an API error (`verdict` has
    /// that), a tool call still waiting on permission or running, a prompt or
    /// a tool's result with no reply after it, an answer that is only code,
    /// or nothing newer than `since`.
    ///
    /// Claude writes each block of a message as its own entry, thinking, text
    /// and tool call one after another, so an entry with only thinking in it
    /// means the words are in the entry before.
    static func lastAnswer(_ data: Data, since: Date) -> String? {
        for entry in AgentAnswer.entries(data) {
            guard let type = entry["type"] as? String, type == "assistant" || type == "user" else { continue }
            if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true { continue }
            guard type == "assistant" else { return nil }
            if let date = AgentFiles.date(entry["timestamp"]), date < since { return nil }
            if entry["isApiErrorMessage"] as? Bool == true { return nil }
            let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if let call = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                let input = call["input"] as? [String: Any]
                switch call["name"] as? String {
                case "AskUserQuestion":
                    let first = (input?["questions"] as? [[String: Any]])?.first
                    return (first?["question"] as? String).flatMap { AgentAnswer.summary(ofMarkdown: $0) }
                case "ExitPlanMode":
                    return (input?["plan"] as? String).flatMap { AgentAnswer.summary(ofMarkdown: $0) }
                default:
                    return nil
                }
            }
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
            if text.isEmpty { continue }
            return AgentAnswer.summary(ofMarkdown: text)
        }
        return nil
    }

    /// How the user entries begin that are not owed a reply (measured on
    /// 2.1.305 transcripts): an interruption, a slash command and its output,
    /// and `!` bash mode's input and output.
    static let answeredByNothing = [
        "[Request interrupted", "<command-name>", "<local-command-", "<bash-input>",
        "<bash-stdout>", "<bash-stderr>",
    ]

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
        AgentFiles.tail(of: url, maxBytes: tailBytes)?.data
    }
}
