import Foundation

/// Everything the user has typed to an agent, as the agents themselves keep
/// it, and how ⌘Y finds a prompt in it.
///
/// **Wortel stores none of it.** It keeps the first line of one prompt for
/// naming and then stops listening (`PromptTap`, `docs/session-naming.md`).
/// The history here is read on demand from the files each agent already
/// writes, never copied, indexed or cached to disk; `PromptHistoryStore` does
/// the reading. This half is pure (the formats, the ranking, what's typed), so
/// it has tests of its own: a parser that drifts doesn't throw, it silently
/// shows nothing, and a ranking that puts the prompt you meant third is a
/// failure nothing else would catch.
///
/// The three formats, verified against the agents' own files on 2026-11-02:
///
/// - **Claude Code**: `$CLAUDE_CONFIG_DIR/history.jsonl` (`~/.claude`), one
///   object per prompt: `display` (what was typed, a paste written as
///   `[Pasted text #N +M lines]`), `pastedContents` (by N: the paste's
///   `content` inline, or a `contentHash` naming `paste-cache/<hash>.txt`),
///   `project` (the directory), `timestamp` (milliseconds), `sessionId`.
/// - **Codex**: `$CODEX_HOME/history.jsonl` (`~/.codex`): `session_id`, `ts`
///   (seconds), `text`. No directory: that is in the conversation's rollout
///   (`sessions/YYYY/MM/DD/rollout-<start>-<id>.jsonl`, whose first line is
///   `session_meta` with `payload.cwd`), which the store looks up.
/// - **Pi**: no history file; each conversation is
///   `sessions/--<cwd>--/<start>_<id>.jsonl`, a `session` header with `cwd`,
///   then entries, the user's being `type: message` with `message.role: user`
///   and `message.content` a string or a list of parts (`type: text`, `text`).
///
/// Anything else on a line (a field renamed, a record of a kind not listed) is
/// skipped, never guessed at.
enum PromptHistory {
    enum Agent: String, CaseIterable, Sendable {
        case claude, codex, pi

        var title: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .pi: return "Pi"
            }
        }
    }

    struct Entry: Equatable, Sendable {
        /// What was typed, pastes and all.
        var text: String
        let agent: Agent
        /// The directory the agent ran in, as it recorded it. nil when it
        /// didn't say (Codex, until its rollout is found).
        var directory: String?
        /// The project that directory belongs to: its repository's home
        /// (`GitWorktree.repositoryHome`, so every worktree of one repository
        /// is one project), else the directory. Filled in by the store, which
        /// is the half allowed to look at the disk.
        var project: String?
        let date: Date
        /// The agent's conversation id, where the directory has to be looked
        /// up by it (Codex).
        var conversation: String? = nil
    }

    // MARK: - Claude Code

    /// One line of Claude Code's `history.jsonl`. `paste` answers a
    /// `contentHash` with the paste's text (the store reads `paste-cache`);
    /// a paste nobody can answer stays as its placeholder, which is what
    /// Claude itself shows when its cache is gone.
    static func claudeEntry(_ line: Data, paste: (String) -> String? = { _ in nil }) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let display = object["display"] as? String,
              let millis = (object["timestamp"] as? NSNumber)?.doubleValue
        else { return nil }
        var text = display
        if let pasted = object["pastedContents"] as? [String: Any], !pasted.isEmpty {
            text = expandPastes(in: display) { number in
                guard let item = pasted[number] as? [String: Any] else { return nil }
                if let type = item["type"] as? String, type != "text" { return nil }
                if let content = item["content"] as? String { return content }
                return (item["contentHash"] as? String).flatMap(paste)
            }
        }
        guard isPrompt(text) else { return nil }
        return Entry(text: text, agent: .claude, directory: object["project"] as? String,
                     date: Date(timeIntervalSince1970: millis / 1000))
    }

    private static let pastePlaceholder = try! NSRegularExpression(
        pattern: #"\[Pasted text #(\d+)(?: \+\d+ lines?)?\]"#)

    /// `[Pasted text #2 +40 lines]` → what was pasted, where `content` knows.
    static func expandPastes(in display: String, content: (String) -> String?) -> String {
        let ns = display as NSString
        var result = ""
        var last = 0
        for match in pastePlaceholder.matches(in: display, range: NSRange(location: 0, length: ns.length)) {
            guard let replacement = content(ns.substring(with: match.range(at: 1))) else { continue }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += replacement
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return display }
        return result + ns.substring(from: last)
    }

    // MARK: - Codex

    /// One line of Codex's `history.jsonl`. Its directory comes later, from
    /// the conversation's rollout.
    static func codexEntry(_ line: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let text = object["text"] as? String,
              let seconds = (object["ts"] as? NSNumber)?.doubleValue,
              isPrompt(text)
        else { return nil }
        return Entry(text: text, agent: .codex, directory: nil, date: Date(timeIntervalSince1970: seconds),
                     conversation: object["session_id"] as? String)
    }

    /// The directory a Codex rollout's first line (`session_meta`) records.
    static func codexDirectory(fromRolloutHeader line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }

    // MARK: - Pi

    /// The directory a Pi conversation's header line records.
    static func piDirectory(fromHeader line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session"
        else { return nil }
        return object["cwd"] as? String
    }

    /// One line of a Pi conversation, if it's something the user typed.
    static func piEntry(_ line: Data, directory: String?) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "user"
        else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        guard isPrompt(text) else { return nil }
        let date: Date
        if let millis = (message["timestamp"] as? NSNumber)?.doubleValue {
            date = Date(timeIntervalSince1970: millis / 1000)
        } else if let stamp = object["timestamp"] as? String, let parsed = AgentFiles.date(stamp) {
            date = parsed
        } else {
            return nil
        }
        return Entry(text: text, agent: .pi, directory: directory, date: date)
    }

    // MARK: - What counts

    /// Whether a line is worth finding again: something on it, and not a bare
    /// slash command (`/clear`, `/model`), which every agent records like a
    /// prompt and which are quicker typed than searched for. `/review the
    /// diff` has words after it and stays; so does a path (`/Users/…`).
    static func isPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasPrefix("/") else { return true }
        let command = trimmed.dropFirst()
        return command.isEmpty || !command.allSatisfy { $0.isLetter || $0.isNumber || ":_-".contains($0) }
    }

    /// The lines of a JSONL file read from its middle: everything after the
    /// first newline when `fromMiddle`, since that first piece is the end of a
    /// line whose start wasn't read.
    static func lines(in data: Data, fromMiddle: Bool) -> [Data] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if fromMiddle, !lines.isEmpty, data.first != 0x0A { lines.removeFirst() }
        return lines.map { Data($0) }
    }

    /// All the agents' entries as one list: newest first, each prompt once
    /// (its newest), at most `limit`. Identical means identical once the
    /// whitespace around it is gone: the same prompt sent to Claude on
    /// Monday and to Codex on Tuesday is one row, Tuesday's.
    static func merged(_ lists: [[Entry]], limit: Int) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for entry in lists.joined().sorted(by: { $0.date > $1.date }) {
            guard seen.insert(entry.text.trimmingCharacters(in: .whitespacesAndNewlines)).inserted else { continue }
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Finding one

    /// An entry ready to be searched: its text folded once (no case, no
    /// accents) when the history is read, not on every keystroke.
    struct Searchable: Sendable {
        let entry: Entry
        let folded: String
        let projectFolded: String
    }

    /// How much of a prompt is searched. A pasted log is in the prompt, but
    /// it isn't what anyone remembers it by, and searching every byte of
    /// one would make each keystroke cost as much as the biggest paste.
    static let searchedLength = 4096

    static func index(_ entries: [Entry]) -> [Searchable] {
        entries.map { entry in
            var folded = fold(entry.text)
            if folded.utf8.count > searchedLength {
                folded = String(decoding: folded.utf8.prefix(searchedLength), as: UTF8.self)
            }
            return Searchable(entry: entry, folded: folded, projectFolded: fold(projectName(entry.project) ?? ""))
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    struct Match: Identifiable, Sendable {
        let entry: Entry
        /// From the project the session is in.
        let isHere: Bool
        let id: Int
    }

    /// The entries `query` finds, at most `limit`, in the order they're shown:
    /// this project's before the rest, and within each, those where every
    /// word was found as typed before those that needed a typo forgiven,
    /// newest first. Coarse on purpose: newest-first is what makes a history
    /// predictable, so the only things allowed to outrank it are whether
    /// it's from here and whether the match is real.
    ///
    /// Every word has to be found, in the prompt or its project's name (so
    /// "wortel" narrows to that project). A word of four letters or more may
    /// be one edit off a word in the prompt or the start of one (a missed,
    /// extra, wrong or swapped letter), eight or more two edits; never the
    /// first letter, which is rarely the one mistyped, and forgiving it made
    /// a short query match half the history.
    ///
    /// `index` is newest first, as the store gives it. `project` is the
    /// session's project, as `Entry.project` would name it. `isCancelled` is
    /// asked as it goes, since a newer keystroke makes this answer useless.
    static func rank(_ query: String, in index: [Searchable], project: String?, limit: Int,
                     isCancelled: () -> Bool = { false }) -> [Match] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        var tiers: [[Match]] = [[], [], [], []]   // here exact, here fuzzy, elsewhere exact, elsewhere fuzzy
        for (position, item) in index.enumerated() {
            if position & 255 == 0, isCancelled() { return [] }
            var fuzzy = false
            var found = true
            for word in words {
                switch find(word, in: item) {
                case .exact: continue
                case .fuzzy: fuzzy = true
                case .none: found = false
                }
                if !found { break }
            }
            guard found else { continue }
            let here = project.map { isProject(item.entry.project, inside: $0) } ?? false
            let tier = (here ? 0 : 2) + (fuzzy ? 1 : 0)
            // A tier never shows more than `limit`, so it stops collecting there.
            if tiers[tier].count < limit {
                tiers[tier].append(Match(entry: item.entry, isHere: here, id: position))
            }
        }
        return Array(tiers.joined().prefix(limit))
    }

    /// Whether an entry's project is the session's: the same, or inside it
    /// (a session outside any repository, in a folder holding the entry's).
    static func isProject(_ entry: String?, inside project: String) -> Bool {
        guard let entry else { return false }
        return entry == project || FolderRoot.root(project, contains: entry)
    }

    private enum Found { case exact, fuzzy, none }

    private static func find(_ word: [UInt8], in item: Searchable) -> Found {
        if contains(item.folded, word) || contains(item.projectFolded, word) { return .exact }
        let allowed = word.count >= 8 ? 2 : word.count >= 4 ? 1 : 0
        guard allowed > 0 else { return .none }
        let hit = item.folded.utf8.withContiguousStorageIfAvailable { text in
            nearlyContains(UnsafeBufferPointer(rebasing: text[...]), word, allowed: allowed)
        } ?? nearlyContains(Array(item.folded.utf8), word, allowed: allowed)
        return hit ? .fuzzy : .none
    }

    private static func contains(_ text: String, _ word: [UInt8]) -> Bool {
        guard !word.isEmpty else { return true }
        var text = text
        return text.withUTF8 { haystack in
            word.withUnsafeBytes { needle in
                guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
                return memmem(base, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    /// Whether some word of `text` (runs of letters and digits), or the start
    /// of one, is within `allowed` edits of `word`.
    private static func nearlyContains<C: RandomAccessCollection>(_ text: C, _ word: [UInt8], allowed: Int) -> Bool
        where C.Element == UInt8, C.Index == Int {
        var start = text.startIndex
        let end = text.endIndex
        while start < end {
            while start < end, !isWordByte(text[start]) { start += 1 }
            var stop = start
            while stop < end, isWordByte(text[stop]) { stop += 1 }
            let length = stop - start
            if length > 0, firstLetterAgrees(text, start, length, word) {
                // The whole word, or its start at the lengths an edit or two
                // away from what was typed.
                let shortest = max(1, word.count - allowed)
                let longest = min(length, word.count + allowed)
                if shortest <= longest {
                    for candidate in shortest...longest {
                        if distance(word, text, start, candidate, limit: allowed) <= allowed { return true }
                    }
                }
            }
            start = stop
        }
        return false
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte >= 0x80
    }

    /// The same first letter, or the first two swapped ("owrtel").
    private static func firstLetterAgrees<C: RandomAccessCollection>(_ text: C, _ start: Int, _ length: Int,
                                                                     _ word: [UInt8]) -> Bool
        where C.Element == UInt8, C.Index == Int {
        if text[start] == word[0] { return true }
        return length > 1 && word.count > 1 && text[start] == word[1] && text[start + 1] == word[0]
    }

    /// Optimal string alignment distance (insert, delete, substitute, swap two
    /// neighbours) between `word` and `text[start..<start+length]`, stopping
    /// at `limit + 1` once no alignment can come back under it.
    private static func distance<C: RandomAccessCollection>(_ word: [UInt8], _ text: C, _ start: Int, _ length: Int,
                                                            limit: Int) -> Int
        where C.Element == UInt8, C.Index == Int {
        let n = word.count
        var previous2 = [Int](repeating: 0, count: length + 1)
        var previous = Array(0...length)
        var current = [Int](repeating: 0, count: length + 1)
        for i in 1...n {
            current[0] = i
            var best = current[0]
            for j in 1...length {
                let cost = word[i - 1] == text[start + j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, word[i - 1] == text[start + j - 2], word[i - 2] == text[start + j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                best = min(best, value)
            }
            if best > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[length]
    }

    // MARK: - Showing one

    /// What a row shows: the first line with something on it, and how many
    /// more lines the prompt has after it.
    static func summary(_ text: String) -> (line: String, more: Int) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n",
                                                                            omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return ("", 0)
        }
        let rest = lines[(index + 1)...]
        let more = rest.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0 - index } ?? 0
        return (String(lines[index].trimmingCharacters(in: .whitespaces).prefix(300)), more)
    }

    /// A project's name for a row: its folder's, `~` for home.
    static func projectName(_ project: String?, home: String = NSHomeDirectory()) -> String? {
        guard let project, !project.isEmpty else { return nil }
        if project == home { return "~" }
        return (project as NSString).lastPathComponent
    }

    /// "now", "5m", "3h", "2d" for this week; a date after that. On the
    /// main actor, which draws the panel's rows, so its formatters need no
    /// lock (`ageFormatters`).
    @MainActor
    static func age(of date: Date, now: Date = Date(), calendar: Calendar = .current,
                    locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let template = sameYear ? "MMMd" : "MMMyyyy"
        let key = "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(template)"
        if let formatter = ageFormatters[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        ageFormatters[key] = formatter
        return formatter.string(from: date)
    }

    /// `age`'s formatters, by locale, calendar, zone and template: made once
    /// each, not once per row per redraw, since a `DateFormatter` is
    /// expensive to make and cheap to use.
    @MainActor private static var ageFormatters: [String: DateFormatter] = [:]

    // MARK: - Typing one

    /// What's typed into the terminal for a chosen prompt.
    ///
    /// The newlines at its end go, so it never looks sent and never is. And
    /// when the program in front hasn't asked for bracketed paste (`?2004`),
    /// its lines are joined with spaces: the terminal turns an unbracketed
    /// newline into Return, so a three-line prompt would arrive as three
    /// messages, the first two sent. Every agent asks for it; this is for a
    /// shell that doesn't, and for a terminal whose modes nobody recorded.
    static func insertion(_ text: String, bracketed: Bool) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while let last = text.last, last.isNewline || last == " " || last == "\t" { text.removeLast() }
        guard !bracketed, text.contains("\n") else { return text }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
