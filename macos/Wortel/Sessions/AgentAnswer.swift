import Foundation

/// The start of what an agent last said, for the body of the notification
/// that says its turn is over.
///
/// That body used to be fixed ("Finished, your move"), which tells you a turn
/// ended and nothing about which one or how: with three agents going, the
/// banner had to be clicked to find out whether this was the one that needed
/// you. The agent's own first lines say it ("Fixed the flaky test, it was a
/// race in…", "Should I also update the docs?"), so that is what the
/// notification carries now, and the fixed text is what's left when nothing
/// readable was written.
///
/// Read from the files each agent already writes, never by asking it:
/// Claude's transcript (`ClaudeTranscriptTail.lastAnswer`), Codex's rollout
/// and Pi's session file (here), each found the way `AgentConversation` finds
/// them for resume. Only the tail of a file is read, off the main thread, by
/// the caller.
///
/// Pure, so the shaping is pinned by tests: an answer is Markdown, and a
/// banner that reads `## Summary` or `` ```swift `` is worse than the fixed
/// text it replaced.
enum AgentAnswer {
    /// About two lines of a banner, three in Notification Center.
    static let limit = 180

    // MARK: - Shaping

    /// The first paragraph of prose in `markdown`, as plain text cut to
    /// `limit`, or nil when there is none (an answer that is only code, a
    /// table or JSON), in which case the caller keeps its fixed text.
    ///
    /// Code blocks, tables, rules and JSON are skipped whole. Headings are
    /// skipped too, unless there is nothing else: a heading alone is a title,
    /// and "Summary" says nothing. List items keep their words without their
    /// markers, each made a sentence so they don't run together. Emphasis,
    /// links (their text), images (their alt text) and code spans (their
    /// contents) are unwrapped, and whitespace is collapsed.
    static func summary(ofMarkdown markdown: String, limit: Int = limit) -> String? {
        var paragraphs: [[String]] = [[]]
        var fence: String?
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
                paragraphs.append([])
                continue
            }
            if line.isEmpty {
                paragraphs.append([])
                continue
            }
            // Indented code: four spaces or a tab where a paragraph begins.
            // Further in, it is a list item's continuation.
            if paragraphs[paragraphs.count - 1].isEmpty, raw.hasPrefix("    ") || raw.hasPrefix("\t") {
                continue
            }
            paragraphs[paragraphs.count - 1].append(line)
        }

        var heading: String?
        for paragraph in paragraphs where !paragraph.isEmpty {
            if isJSON(paragraph) { continue }
            var pieces: [String] = []
            for line in paragraph {
                if let text = headingText(line) {
                    if heading == nil { heading = text }
                    continue
                }
                if line.hasPrefix("|") || isRule(line) { continue }
                if line.hasPrefix("<"), line.hasSuffix(">") { continue } // <details>, <br/>
                var text = line
                while text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
                if let item = listItemText(text) {
                    var item = item
                    if let last = item.last, !".!?:;".contains(last) { item += "." }
                    pieces.append(item)
                } else {
                    pieces.append(text)
                }
            }
            let prose = collapse(unwrapInline(pieces.joined(separator: " ")))
            if prose.contains(where: \.isLetter) { return truncate(prose, to: limit) }
        }
        return heading.map { truncate(collapse(unwrapInline($0)), to: limit) }
    }

    /// `text` cut to `limit` characters at a word boundary, with an ellipsis,
    /// or as it is when it fits.
    static func truncate(_ text: String, to limit: Int = limit) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit - 1))
        // Back to the last space, unless that throws away most of it (a URL,
        // a word with no spaces in it).
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, ",;:-([{ ".contains(last) { cut.removeLast() }
        return cut + "\u{2026}"
    }

    private static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let text = line.drop { $0 == "#" }
        // `#hashtag` is a word, not a heading.
        guard text.isEmpty || text.first == " " else { return nil }
        let title = text.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_=".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// The words of a list item without its marker (`-`, `*`, `+`, `1.`,
    /// `1)`, and a task box after any of them), or nil for a line that isn't
    /// one.
    private static func listItemText(_ line: String) -> String? {
        var rest: Substring
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            rest = line.dropFirst(2)
        } else {
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let after = line.dropFirst(digits.count)
            guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
            rest = after.dropFirst(2)
        }
        rest = rest.drop { $0 == " " }
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) { rest = rest.dropFirst(box.count) }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func isJSON(_ paragraph: [String]) -> Bool {
        guard let first = paragraph.first?.first, first == "{" || first == "[" else { return false }
        let text = paragraph.joined(separator: "\n")
        if first == "{" { return true }
        // `[` may also open a link at the start of a sentence.
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Emphasis, links, images and code spans, unwrapped to their words.
    ///
    /// Links first, over the whole text, because a code span is so often the
    /// text of one (`` [`Watcher.swift`](src/Watcher.swift) ``). Then code
    /// spans, kept as they are inside (an `a*b*` in one is not emphasis), and
    /// emphasis only between them.
    static func unwrapInline(_ text: String) -> String {
        let text = apply(links, to: text)
        let spans = codeSpan.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var out = ""
        var cursor = text.startIndex
        for span in spans {
            guard let whole = Range(span.range, in: text), let inner = Range(span.range(at: 2), in: text) else { continue }
            out += apply(emphasis, to: String(text[cursor..<whole.lowerBound]))
            out += text[inner].trimmingCharacters(in: .whitespaces)
            cursor = whole.upperBound
        }
        out += apply(emphasis, to: String(text[cursor...]))
        return out
    }

    private static let codeSpan = try! NSRegularExpression(pattern: "(`+)(.+?)\\1")

    private static let links = rules([
        ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),                       // ![alt](src)
        ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),                        // [text](url)
        ("\\[([^\\]]+)\\]\\[[^\\]]*\\]", "$1"),                      // [text][ref]
        ("<((?:https?|mailto):[^>\\s]+)>", "$1"),                   // <https://…>
    ])

    /// `**` before `*`, and `_` only at the edges of a word, so snake_case
    /// keeps its underscores.
    private static let emphasis = rules([
        ("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", "$1"),                  // **bold**
        ("(?<![\\w_])__(?=\\S)(.+?)(?<=\\S)__(?![\\w_])", "$1"),     // __bold__
        ("~~(?=\\S)(.+?)(?<=\\S)~~", "$1"),                          // ~~struck~~
        ("(?<![\\w*])\\*(?=\\S)(.+?)(?<=\\S)\\*(?![\\w*])", "$1"),   // *em*
        ("(?<![\\w_])_(?=\\S)(.+?)(?<=\\S)_(?![\\w_])", "$1"),       // _em_
    ])

    private static func rules(_ patterns: [(String, String)]) -> [(NSRegularExpression, String)] {
        patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }

    private static func apply(_ rules: [(NSRegularExpression, String)], to text: String) -> String {
        rules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }

    // MARK: - Codex

    /// The start of Codex's last answer in a rollout's tail, or nil when the
    /// turn that started at `since` left none: it was interrupted, it is
    /// waiting on something, or nothing it said is newer than `since`.
    ///
    /// Layout, from Codex 0.142 rollouts: one JSON object per line with a
    /// top-level `timestamp`, `type` and `payload`. A finished turn ends
    /// `event_msg` / `task_complete`, whose `last_agent_message` is the answer;
    /// before that, the answer is a `response_item` / `message` with role
    /// `assistant` and `output_text` blocks (also how an older Codex without
    /// `last_agent_message` leaves it).
    static func codex(_ data: Data, since: Date) -> String? {
        for entry in entries(data) {
            guard let payload = entry["payload"] as? [String: Any] else { continue }
            let kind = payload["type"] as? String
            let type = entry["type"] as? String
            if type == "event_msg", kind == "turn_aborted" || kind == "user_message" { return nil }
            var text: String?
            if type == "event_msg", kind == "task_complete" {
                text = payload["last_agent_message"] as? String
                if text == nil { continue }
            } else if type == "response_item", kind == "message" {
                guard let role = payload["role"] as? String else { continue }
                if role == "user" { return nil }
                guard role == "assistant" else { continue }
                text = (payload["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n\n")
            } else {
                continue
            }
            if let date = date(entry["timestamp"]), date < since { return nil }
            return text.flatMap { summary(ofMarkdown: $0) }
        }
        return nil
    }

    // MARK: - Pi

    /// The start of Pi's last answer in a session file's tail, or nil, on the
    /// same terms as `codex`.
    ///
    /// Layout, from Pi 0.82 session files: one JSON object per line; the
    /// conversation is `type: "message"` entries with a top-level `timestamp`
    /// and a `message` holding `role` (`user`, `assistant`, `toolResult`),
    /// `content` blocks (`text`, `thinking`, `toolCall`) and, for the
    /// assistant, a `stopReason`. An assistant message that calls a tool, or
    /// failed, is not an answer.
    static func pi(_ data: Data, since: Date) -> String? {
        for entry in entries(data) {
            guard entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { continue }
            guard role == "assistant" else { return nil }
            if let date = date(entry["timestamp"]), date < since { return nil }
            if message["stopReason"] as? String == "error" { return nil }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "toolCall" }) { return nil }
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
            // Thinking alone: the answer, if any, is in the entry before.
            if text.isEmpty { continue }
            return summary(ofMarkdown: text)
        }
        return nil
    }

    // MARK: - Reading

    /// The JSON objects in a tail, newest first. A line that doesn't parse
    /// (the first, cut mid-line by the tail read) is skipped.
    static func entries(_ data: Data) -> some Sequence<[String: Any]> {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .reversed()
            .lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// An ISO 8601 timestamp, with or without fractional seconds.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
