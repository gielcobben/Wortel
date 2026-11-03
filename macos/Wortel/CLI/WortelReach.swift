import Foundation

/// What `list`, `read`, `send` and `wait` share between the two ends: how a
/// session is described, how one is named on the command line, and how the
/// text on a screen is tidied and searched.
///
/// **Why the reach exists at all.** Every other verb acts on the session it was
/// run in. These four act on *any* session, which is what lets one agent start
/// another, hand it a prompt, wait for it to finish and read what it said:
/// the shape bb gives its agents, built from the same parts a person uses
/// (the screen, a paste, the Return key) rather than from a protocol each agent
/// would have to speak.
///
/// Pure Foundation, compiled into the app, the CLI and the tests: the CLI
/// formats what the app describes, and the rules for naming a session and
/// matching text are the kind of thing that fails silently (the wrong session
/// typed into, a wait that never ends), so they are pinned without a socket.

/// One open session as `wortel list` describes it. The JSON field names are
/// the scripting contract: add fields, never rename one.
struct WortelSessionInfo: Codable, Equatable {
    /// What the session is doing, read from the attention and busy tracking
    /// the sidebar's dots already use (`SessionManager.activity(of:)`).
    enum State: String, Codable, CaseIterable {
        /// A command or an agent's turn is running.
        case working
        /// It's asking for you: a permission, a question, a bell.
        case needsYou = "needs-you"
        /// Its last turn or long command ended cleanly. Your move.
        case finished
        /// Its last turn or long command ended in an error.
        case failed
        /// Nothing running and nothing said since.
        case idle
        /// Its worktree is still being made; there is no terminal yet.
        case preparing
    }

    var id: String
    /// The full name, folder included (`Lijn/css rules`).
    var name: String
    /// The sidebar folder it's filed in, nil at the top level.
    var folder: String?
    /// Where its shell is now.
    var directory: String?
    /// The branch its worktree is on, when it's in one.
    var branch: String?
    /// The worktree's own folder, when it's in one.
    var worktree: String?
    /// The agent running in it (`claude`, `codex`), nil for a plain shell.
    var agent: String?
    var state: State
    /// The row selected in the sidebar.
    var selected: Bool
    /// The session the command was run in.
    var caller: Bool

    /// The first block of the id: what the table prints and what `<session>`
    /// accepts, the way a short commit hash stands in for a long one.
    var shortID: String { String(id.prefix(8)) }

    /// A compact table for a person: one line per session, columns aligned,
    /// a `*` on the selected row and "(you)" after the caller's name. A blank
    /// cell is `-` so the columns still split on whitespace.
    static func table(_ sessions: [WortelSessionInfo], home: String = NSHomeDirectory()) -> String {
        let header = ["", "ID", "NAME", "STATE", "AGENT", "BRANCH", "DIRECTORY"]
        let rows = sessions.map { session -> [String] in
            [session.selected ? "*" : "",
             session.shortID,
             session.name + (session.caller ? " (you)" : ""),
             session.state.rawValue,
             session.agent ?? "-",
             session.branch ?? "-",
             session.directory.map { abbreviate($0, home: home) } ?? "-"]
        }
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.indices.map { column in
                // The last column isn't padded: trailing spaces on every line
                // are noise in a terminal and a trap in a script.
                column == row.count - 1 ? row[column]
                    : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What `wortel read` answers with: whose screen, and the text on it.
struct WortelScreen: Codable, Equatable {
    var id: String
    var name: String
    var text: String
}

/// `<session>` on the command line: an id, or a name.
///
/// The order is from the most deliberate spelling to the most convenient:
/// a whole id; a name exactly as written (the full `Folder/leaf` or just the
/// leaf the sidebar shows); the same, ignoring case; and finally a prefix,
/// case-insensitive, of a name or of the id, the way `wortel list` prints
/// it. Each tier is tried only when the one before found nothing, and a tier
/// that finds two sessions is an error naming both, never a pick: typing a
/// prompt into the wrong agent is not a mistake anyone can take back.
enum WortelSessionAddress {
    struct Candidate: Equatable {
        let id: UUID
        let name: String
        let leaf: String

        init(id: UUID, name: String, leaf: String? = nil) {
            self.id = id
            self.name = name
            self.leaf = leaf ?? name
        }
    }

    enum Resolution: Equatable {
        case found(UUID)
        case none
        /// Two or more matched at the first tier that matched anything.
        case ambiguous([Candidate])
    }

    static func resolve(_ query: String, among candidates: [Candidate]) -> Resolution {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return .none }
        if let uuid = UUID(uuidString: query), candidates.contains(where: { $0.id == uuid }) {
            return .found(uuid)
        }
        let lowered = query.lowercased()
        let tiers: [(Candidate) -> Bool] = [
            { $0.name == query || $0.leaf == query },
            { $0.name.lowercased() == lowered || $0.leaf.lowercased() == lowered },
            {
                $0.name.lowercased().hasPrefix(lowered) || $0.leaf.lowercased().hasPrefix(lowered)
                    // An id prefix only from four characters on: "a" or "3f"
                    // would match half the list and mean nothing.
                    || (lowered.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(lowered))
            },
        ]
        for matches in tiers {
            let found = candidates.filter(matches)
            if found.count == 1 { return .found(found[0].id) }
            if found.count > 1 { return .ambiguous(found) }
        }
        return .none
    }
}

/// The text read off a terminal, made fit to hand to a script.
enum ScreenText {
    /// Trailing whitespace off every line and blank lines off the end: a
    /// terminal is a grid, and the empty rows under a prompt and the spaces
    /// after each line are the grid, not the output. `lastLines` keeps only
    /// the last that many, counted after the trim, so `--lines 5` means the
    /// last five lines with something on them at the bottom.
    static func tidy(_ raw: String, lastLines: Int? = nil) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var line = line
            while let last = line.last, last.isWhitespace { line.removeLast() }
            return line
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        if let lastLines { lines = Array(lines.suffix(max(0, lastLines))) }
        return lines.joined(separator: "\n")
    }

    /// How many times `needle` appears, not overlapping. What `wait --for`
    /// compares against where it started: a count that goes up is the text
    /// appearing again, wherever on the screen it lands.
    static func occurrences<S: StringProtocol>(of needle: String, in haystack: S) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// `read --lines`: the last `count` lines with something on them, from
    /// the active screen when it holds more than that, else from `whole`,
    /// which reads the scrollback too. More than, not as many: the top row
    /// of the active screen can be the tail of a line wrapped from above it.
    static func lastLines(_ count: Int, active: String?, whole: () -> String?) -> String? {
        let count = min(max(1, count), WortelCLI.maximumReadLines)
        if let active {
            let lines = tidy(active).split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > count { return lines.suffix(count).joined(separator: "\n") }
        }
        return whole().map { tidy($0, lastLines: count) }
    }
}

/// What `wait --for` keeps between two looks at a terminal, so that the look
/// costs what's on screen and not what's in the scrollback.
///
/// The old rule was a count over everything, scrollback included, compared
/// with the count when the wait began: right, and a read of up to the whole
/// scrollback (10 MB by default) on the main thread twice a second while
/// output flowed, under the lock the terminal's own IO thread needs. Now a
/// look reads only the **active screen**, and lines it up with the previous
/// look (`shift`) to know how many rows scrolled out of its top: text counts
/// as new when the screen has more of it than the previous screen's rows
/// that are still on it had. Rows that scrolled out went into the
/// scrollback, unread, and don't count either way.
///
/// That only works while some of the previous screen is still on the new
/// one. When none is (more than a screenful went by between two looks, or
/// the screen was redrawn whole: a resize, a `clear`, a full-screen program)
/// text may have scrolled past unseen, and the next look is at the whole
/// terminal, counted as before against `total`, which is the whole count
/// as of the last such read. Text appearing on the active screen ends the
/// wait at once, so `total` never needs raising in between; it is lowered
/// when a whole read finds fewer (a `clear`, scrollback trimmed at its limit)
/// so text printed after that still counts. A needle of several lines can't
/// be found a line at a time and always takes the whole read.
struct NewTextWatch: Equatable {
    let needle: String
    /// The active screen at the last look, a line per row, trailing spaces
    /// off and nothing else: a row's place is what lines two looks up.
    private(set) var screen: [String]
    /// How many times the needle was in the whole terminal at the last
    /// whole read (0 with `--from-start`, which counts what's there).
    private(set) var total: Int
    /// Text may have gone by unseen since the last look: read it all.
    private(set) var needsWholeRead: Bool

    init(needle: String, screen: String, total: Int, needsWholeRead: Bool = false) {
        self.needle = needle
        self.screen = Self.rows(screen)
        self.total = total
        self.needsWholeRead = needsWholeRead
    }

    /// A look at the active screen. True when the needle has appeared on it
    /// since the last look.
    mutating func look(atScreen text: String) -> Bool {
        let now = Self.rows(text)
        defer { screen = now }
        guard !needle.contains(where: \.isNewline) else {
            needsWholeRead = true
            return false
        }
        guard let shift = Self.shift(from: screen, to: now) else {
            needsWholeRead = true
            return false
        }
        // Counted over the rows still on screen rather than row by row: a
        // program that inserts a line above the text moves it down a row
        // without making it new.
        let stillShown = screen[shift...].reduce(0) { $0 + ScreenText.occurrences(of: needle, in: $1) }
        let shown = now.reduce(0) { $0 + ScreenText.occurrences(of: needle, in: $1) }
        return shown > stillShown
    }

    /// A look at the whole terminal, `screen` being its active screen read
    /// just *before* it: text printed between the two reads is then in the
    /// whole count and still new to the next look at the screen, rather
    /// than in neither.
    mutating func look(atWhole whole: String, screen text: String) -> Bool {
        screen = Self.rows(text)
        needsWholeRead = false
        let count = ScreenText.occurrences(of: needle, in: whole)
        if count > total { return true }
        total = count
        return false
    }

    /// How many rows the screen scrolled up between two looks (0 when it
    /// didn't), or nil when no part of `old` can be found on `new`.
    ///
    /// The shift is the one where the most rows agree, the smallest of
    /// those, and only where most of the rows compared agree: a screen with
    /// the input box redrawn and a spinner turning still lines up, two
    /// screens with one separator line in common don't. A row that was blank
    /// isn't compared (output filling the empty rows under a prompt is not
    /// disagreement).
    static func shift(from old: [String], to new: [String]) -> Int? {
        if old == new { return 0 }
        var best: (shift: Int, agreeing: Int)?
        for shift in old.indices {
            let overlap = min(old.count - shift, new.count)
            var agreeing = 0, compared = 0
            for row in 0..<overlap where !old[row + shift].isEmpty {
                compared += 1
                if old[row + shift] == new[row] { agreeing += 1 }
            }
            guard agreeing > 0, agreeing * 2 > compared else { continue }
            if agreeing > (best?.agreeing ?? 0) { best = (shift, agreeing) }
        }
        return best?.shift
    }

    private static func rows(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { row in
            var row = row
            while let last = row.last, last.isWhitespace { row.removeLast() }
            return String(row)
        }
    }
}
