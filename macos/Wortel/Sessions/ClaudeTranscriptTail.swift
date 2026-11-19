import Foundation

/// The end of a Claude Code conversation, read for what Claude last said: the
/// words a finished turn is announced with (`SessionManager.announceFinishedTurn`).
/// Observation only, like `AgentConversation`: reading the file Claude already
/// writes, never configuring it.
///
/// It used to be read for a verdict as well (was that an API error, a question,
/// an idle compaction, a turn at all), because Claude's terminal signals looked
/// the same whichever it was. Claude Code says all of that itself now, in its
/// status reports (`ProgramStatus`), and the verdict is gone with the guessing
/// it corrected.
///
/// Layout, verified against Claude Code 2.1.299 transcripts on 2026-10-14:
/// one JSON object per line; `type` is `assistant` or `user` for the
/// conversation and something else (`attachment`, `system`, `last-prompt`,
/// `ai-title`, …) for bookkeeping written around it. A tool call is written
/// the moment it is made. Subagent traffic is marked `isSidechain` and is not
/// the turn the user is looking at.
enum ClaudeTranscriptTail {
    /// How much of the end of a transcript is worth reading: a turn's last
    /// entries, with room for a long final message. A transcript runs to tens
    /// of megabytes; this is all that is ever read.
    static let tailBytes = 256 * 1024

    /// The start of Claude's last answer, for the notification body
    /// (`AgentAnswer`): the first paragraph of prose in its final message,
    /// the question it is waiting on (`AskUserQuestion`'s first), or the
    /// plan it wants approved (`ExitPlanMode`). nil when the turn that started
    /// at `since` ended in nothing worth quoting: an API error, a tool call still waiting on permission or running, a prompt or
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

    /// The last `tailBytes` of the transcript at `url`, or nil when it can't be
    /// read. Blocking file IO: call off the main thread.
    static func readTail(of url: URL) -> Data? {
        AgentFiles.tail(of: url, maxBytes: tailBytes)?.data
    }
}
