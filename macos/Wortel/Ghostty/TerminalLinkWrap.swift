import Foundation

/// A ⌘-click in a terminal, with the rows around it as text: what the app
/// needs to put back together a link an agent broke over several rows.
///
/// An agent's renderer wraps its own text, so a long path or URL reaches the
/// terminal as separate rows with a real line break and an indent between
/// them, never as one line the terminal wrapped:
///
///     ⏺ Edit macos/Wortel/Ghostty/GhosttyRuntimeSomethingVeryLo
///          ngName/TerminalLinkResolution.swift:42
///
/// libghostty looks for a link in the clicked row only (a line it wrapped
/// itself it does follow). So the click got half a path, which exists
/// nowhere, or nothing at all: the first half has no dot, and its link
/// pattern only takes a bare path with one. Recorded from Claude Code 2.1.331
/// and Codex 0.172 on 2026-11-24. Their *prose* links are not affected: both
/// tag a wrapped URL with one OSC 8 hyperlink across its rows, and libghostty
/// opens the whole address from either row. Claude Code's tool-call header,
/// its approval box and the echo of your own prompt are not tagged.
struct TerminalLinkClick: Equatable {
    /// The rows read around the click, top to bottom, each as read on its own.
    var rows: [String]
    /// The clicked row, an index into `rows`.
    var row: Int
    /// The clicked character in `rows[row]`, in `Character`s.
    var index: Int
    /// The terminal's width in cells, for how near a row runs to its edge.
    var columns: Int
}

/// A ⌘-click that may be on a link, as `SurfaceView` hands it on.
struct TerminalLinkRequest {
    /// What libghostty matched under the click; nil when it matched nothing.
    var link: String?
    /// The program tagged the link itself (OSC 8), so it is whole as given.
    var tagged: Bool
    /// The rows around the click; nil when the link came some other way.
    var click: TerminalLinkClick?
}

extension TerminalLink {
    /// How many rows a link is followed over, either way from the click.
    static let wrapReach = 4
    /// How far short of the terminal's edge a row may end and still be one an
    /// address was broken at (`wrappedURL`).
    static let urlEdge = 3

    /// The paths a click might mean once the rows it was broken over are put
    /// back together, longest first. Only spellings that take in at least one
    /// other row: the clicked row's own text is libghostty's to match, as it
    /// always was. Each is a guess until `resolve` finds it on disk, which is
    /// what makes guessing safe here: a join that exists is the path.
    static func wrappedPaths(_ click: TerminalLinkClick) -> [String] {
        guard let pieces = pieces(click, characters: pathCharacters, reachesEdge: { _ in true })
        else { return [] }
        var joins: [(text: String, length: Int)] = []
        for up in 0...pieces.up.count {
            for down in 0...pieces.down.count where up + down > 0 {
                let text = (pieces.up.prefix(up).reversed() + [pieces.middle] + pieces.down.prefix(down))
                    .joined()
                joins.append((text, text.count))
            }
        }
        // Longest first, and a tie in the order made: a stable sort.
        var seen = Set<String>()
        return joins.enumerated()
            .sorted { $0.element.length != $1.element.length
                ? $0.element.length > $1.element.length : $0.offset < $1.offset }
            .map(\.element.text)
            .filter { seen.insert($0).inserted }
    }

    /// The web address a click is on, put back together from the rows it was
    /// broken over; nil when it wasn't broken, or isn't an address.
    ///
    /// No disk to ask here, so a row is only followed when it was full: its
    /// text runs to within `urlEdge` cells of the terminal's edge. Claude
    /// Code breaks a long address right at its edge, a cell or two short of
    /// the terminal's (every row recorded ended within two), so a whole
    /// address that merely ends late in a row, a list of short ones, or git's
    /// `remote:` lines after a link are not glued together.
    /// The rows after the first must not start an address of their own.
    static func wrappedURL(_ click: TerminalLinkClick) -> String? {
        let full: (String) -> Bool = { row in
            row.count + urlEdge >= click.columns
        }
        guard let pieces = pieces(click, characters: urlCharacters, reachesEdge: full) else { return nil }
        // Up to the row the address starts on, and not past a comma ending a
        // row, which is a list going on rather than an address.
        var up: [String] = []
        if !pieces.middle.contains("://"), !isProse(pieces.middle, followed: pieces.middleFollowed) {
            for piece in pieces.up {
                guard !piece.hasSuffix(",") else { break }
                up.append(piece)
                if piece.contains("://") { break }
            }
        }
        // Down until a row starts an address of its own.
        var down: [String] = []
        var last = pieces.middle
        for (piece, followed) in zip(pieces.down, pieces.downFollowed) {
            guard !last.hasSuffix(","), !piece.contains("://"), !isProse(piece, followed: followed) else { break }
            down.append(piece)
            last = piece
        }
        let before = up.reversed().joined()
        let joined = before + pieces.middle + down.joined()
        // The address that covers the click: the last scheme starting at or
        // before it.
        let at = before.count + pieces.offset
        guard let start = schemeStart(in: joined, atOrBefore: at) else { return nil }
        var url = String(joined.dropFirst(start))
        // What libghostty's pattern leaves off the end of an address.
        while let tail = url.last, ".,:;".contains(tail) { url.removeLast() }
        // The click on the address itself, not on what was taken off it, and
        // another row part of it: otherwise it is libghostty's own match.
        guard at - start < url.count, start < before.count || !down.isEmpty else { return nil }
        return url
    }

    /// A row's first run that is a plain word with more of the sentence
    /// after it ("for details."): what a word-wrapping program printed after
    /// an address that happened to end near the edge, not the address's last
    /// piece. Measured broken addresses go on with a path or query piece, or
    /// end their row. The cost: an address broken just before a last piece of
    /// letters alone, with prose after it, opens without that piece, as
    /// libghostty's own match of the row.
    private static func isProse(_ piece: String, followed: Bool) -> Bool {
        guard followed else { return false }
        var word = Substring(piece)
        while let tail = word.last, ".,:;!?".contains(tail) { word.removeLast() }
        return !word.isEmpty && word.allSatisfy(\.isLetter)
    }

    // MARK: - Rows

    /// The characters libghostty's link pattern takes in a path and in an
    /// address (`config/url.zig`, `path_chars`, `scheme_url_chars`).
    static let pathCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-.~:/?#@!$&*+;=%"))
    static let urlCharacters = pathCharacters.union(CharacterSet(charactersIn: ","))

    /// What stands before a continued row's text and is not part of it: the
    /// indent, and an agent's frame (Claude Code's approval box draws `│` down
    /// its left side, its tool results hang off `⎿`, Codex marks your own
    /// messages with `▌`).
    static func isGutter(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x2500...0x259F, 0x23BF: return true
        default: return false
        }
    }

    /// The clicked run of link characters, and the runs it continues into on
    /// the rows above (nearest first) and below. A run continues down when it
    /// ends its row (nothing after it but gutter) and the row is `full`, into
    /// the next row's first run when that row begins with one after its
    /// gutter. Up is the mirror. `offset` is the click's place in `middle`.
    /// `middleFollowed` and `downFollowed` say whether more than gutter comes
    /// after a run on its row.
    private static func pieces(_ click: TerminalLinkClick, characters set: CharacterSet,
                               reachesEdge full: (String) -> Bool)
        -> (up: [String], middle: String, middleFollowed: Bool, offset: Int,
            down: [String], downFollowed: [Bool])? {
        guard click.rows.indices.contains(click.row) else { return nil }
        let row = Array(click.rows[click.row])
        guard row.indices.contains(click.index), isLink(row[click.index], set) else { return nil }
        var start = click.index, end = click.index + 1
        while start > 0, isLink(row[start - 1], set) { start -= 1 }
        while end < row.count, isLink(row[end], set) { end += 1 }
        let middle = String(row[start..<end])

        let middleFollowed = !row[end...].allSatisfy(isGutter)
        var down: [String] = []
        var downFollowed: [Bool] = []
        var endsRow = !middleFollowed && full(click.rows[click.row])
        var next = click.row + 1
        while endsRow, down.count < wrapReach, click.rows.indices.contains(next) {
            let text = Array(click.rows[next])
            let first = text.firstIndex { !isGutter($0) } ?? text.count
            var stop = first
            while stop < text.count, isLink(text[stop], set) { stop += 1 }
            guard stop > first else { break }
            down.append(String(text[first..<stop]))
            let followed = !text[stop...].allSatisfy(isGutter)
            downFollowed.append(followed)
            endsRow = !followed && full(click.rows[next])
            next += 1
        }

        var up: [String] = []
        var startsRow = row[..<start].allSatisfy(isGutter)
        var previous = click.row - 1
        while startsRow, up.count < wrapReach, click.rows.indices.contains(previous) {
            let text = Array(click.rows[previous])
            guard full(click.rows[previous]) else { break }
            var stop = text.count
            while stop > 0, isGutter(text[stop - 1]) { stop -= 1 }
            var first = stop
            while first > 0, isLink(text[first - 1], set) { first -= 1 }
            guard stop > first else { break }
            up.append(String(text[first..<stop]))
            startsRow = text[..<first].allSatisfy(isGutter)
            previous -= 1
        }
        return (up, middle, middleFollowed, click.index - start, down, downFollowed)
    }

    private static func isLink(_ character: Character, _ set: CharacterSet) -> Bool {
        character.unicodeScalars.allSatisfy(set.contains)
    }

    /// Where the last `scheme://` that starts at or before `offset` begins.
    private static func schemeStart(in text: String, atOrBefore offset: Int) -> Int? {
        let characters = Array(text)
        var found: Int?
        var i = 0
        while i + 2 < characters.count {
            if characters[i] == ":", characters[i + 1] == "/", characters[i + 2] == "/" {
                var s = i
                while s > 0, characters[s - 1].isASCII,
                      characters[s - 1].isLetter || characters[s - 1].isNumber
                          || "+.-".contains(characters[s - 1]) { s -= 1 }
                while s < i, !characters[s].isLetter { s += 1 }
                if s < i, s <= offset { found = s }
            }
            i += 1
        }
        return found
    }
}
