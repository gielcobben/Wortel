import Foundation

/// The terminal's visible text as an accessibility client sees it (AXValue),
/// and the arithmetic between that string and the cell grid it was read from.
///
/// libghostty owns the grid and will only hand out text for a region, so this
/// is built from what the view can ask for: each viewport row read on its own,
/// and whether each row runs on into the next (a soft wrap) or ends a line.
/// Pure, so the mapping is pinned by `TerminalAXTextTests` with no surface in
/// sight; `SurfaceView+Accessibility` does the reading.
///
/// Every offset here is **UTF-16**, because that is what an `NSRange` from an
/// accessibility client counts. An emoji is two of them in two cells, a CJK
/// character one in two cells, `é` written as e + U+0301 two in one cell.
///
/// Soft-wrapped rows are joined with no newline, so a word the terminal broke
/// at the right margin is still one word to a reader. A *line*, for AXLineForIndex
/// and AXRangeForLine, is a visual row, as it is for a wrapped NSTextView.
struct TerminalAXText: Equatable {
    /// AXValue.
    let string: String
    /// `string`'s length in UTF-16 code units: AXNumberOfCharacters.
    let length: Int
    /// Where each row's own text starts in `string`.
    let rowStarts: [Int]
    /// Each row's own text length, without the newline after it.
    let rowLengths: [Int]

    var rowCount: Int { rowStarts.count }

    /// `rows`: each viewport row's text, top to bottom. `endsLine[r]`: row `r`
    /// ends a line (a newline follows it) rather than wrapping into `r + 1`.
    /// The last row never gets a newline after it.
    init(rows: [String], endsLine: [Bool]) {
        var string = ""
        var starts: [Int] = [], lengths: [Int] = []
        var offset = 0
        for (r, row) in rows.enumerated() {
            starts.append(offset)
            let length = row.utf16.count
            lengths.append(length)
            string += row
            offset += length
            if r < rows.count - 1, r < endsLine.count ? endsLine[r] : true {
                string += "\n"
                offset += 1
            }
        }
        self.string = string
        self.length = offset
        self.rowStarts = starts
        self.rowLengths = lengths
    }

    /// The row whose line holds `index`: a newline belongs to the row it ends,
    /// and the end of the text to the last row. nil when there are no rows.
    func row(containing index: Int) -> Int? {
        guard !rowStarts.isEmpty else { return nil }
        let index = max(0, min(index, length))
        // Last row starting at or before `index`.
        var lo = 0, hi = rowStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The whole line `row` is, newline included when it has one: what
    /// AXRangeForLine answers, as NSTextView does.
    func lineRange(_ row: Int) -> NSRange? {
        guard rowStarts.indices.contains(row) else { return nil }
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] : length
        return NSRange(location: rowStarts[row], length: end - rowStarts[row])
    }

    /// `range` clipped to `string`, or nil if it starts past the end.
    func clamped(_ range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.location <= length,
              range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }

    /// The part of a row a range covers, in cells: `[startColumn, endColumn)`.
    struct Segment: Equatable {
        let row: Int
        let startColumn: Int
        let endColumn: Int
    }

    /// The cells `range` covers, one segment per row it touches. A range that
    /// only covers a newline, or is empty, gives a zero-width segment where it
    /// sits, so a caret still has a place. `cells(row)` supplies a row's cell
    /// map on demand; a row it has no map for is skipped.
    func segments(for range: NSRange, cells: (Int) -> RowCells?) -> [Segment] {
        guard let range = clamped(range),
              let first = row(containing: range.location) else { return [] }
        let last = row(containing: max(range.location, range.location + range.length - 1)) ?? first
        var segments: [Segment] = []
        for row in first...max(first, last) {
            guard let map = cells(row) else { continue }
            let start = rowStarts[row], rowLength = rowLengths[row]
            // Row-local, clipped to the row's own text (its newline is not a cell).
            let a = max(0, min(range.location - start, rowLength))
            let b = max(a, min(range.location + range.length - start, rowLength))
            if a == b {
                let column = map.column(atOffset: a)
                segments.append(Segment(row: row, startColumn: column, endColumn: column))
            } else {
                segments.append(Segment(row: row,
                                        startColumn: map.column(atOffset: a),
                                        endColumn: map.endColumn(atOffset: b - 1)))
            }
        }
        return segments
    }

    /// The text range a run of cells covers, both ends inclusive, as the
    /// terminal selects: from the character at `start` to the end of the one
    /// at `end`. A cell past a row's text means the end of that row's text.
    func range(fromCell start: (row: Int, column: Int), toCell end: (row: Int, column: Int),
               cells: (Int) -> RowCells?) -> NSRange? {
        guard rowStarts.indices.contains(start.row), rowStarts.indices.contains(end.row),
              let startMap = cells(start.row), let endMap = cells(end.row) else { return nil }
        let from = rowStarts[start.row] + startMap.offset(atColumn: start.column)
        let to = rowStarts[end.row] + endMap.offset(afterColumn: end.column)
        guard to >= from else { return nil }
        return NSRange(location: from, length: to - from)
    }
}

/// Where each character of one row sits in its cells.
struct RowCells: Equatable {
    struct Glyph: Equatable {
        /// UTF-16 offset in the row's text, and length.
        let offset: Int
        let length: Int
        /// First cell, and how many it takes (2 for a wide character).
        let column: Int
        let width: Int
    }

    let glyphs: [Glyph]
    /// The row's text length in UTF-16.
    let length: Int

    /// The cell a character starts in. The end of the row is the column after
    /// its last character.
    func column(atOffset offset: Int) -> Int {
        guard let glyph = glyph(atOffset: offset) else { return endColumn }
        return glyph.column
    }

    /// The column just past the character at `offset`.
    func endColumn(atOffset offset: Int) -> Int {
        guard let glyph = glyph(atOffset: offset) else { return endColumn }
        return glyph.column + glyph.width
    }

    /// The offset of the character in `column`, or the end of the text past it.
    func offset(atColumn column: Int) -> Int {
        guard let glyph = glyph(atColumn: column) else {
            return column < (glyphs.first?.column ?? 0) ? 0 : length
        }
        return glyph.offset
    }

    /// The offset just past the character in `column`, or the end of the text
    /// past it.
    func offset(afterColumn column: Int) -> Int {
        guard let glyph = glyph(atColumn: column) else {
            return column < (glyphs.first?.column ?? 0) ? 0 : length
        }
        return glyph.offset + glyph.length
    }

    private var endColumn: Int { glyphs.last.map { $0.column + $0.width } ?? 0 }

    private func glyph(atOffset offset: Int) -> Glyph? {
        // Last glyph starting at or before `offset`, if it covers it.
        var lo = 0, hi = glyphs.count - 1, found: Glyph?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if glyphs[mid].offset <= offset { found = glyphs[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let found, offset < found.offset + found.length else { return nil }
        return found
    }

    private func glyph(atColumn column: Int) -> Glyph? {
        var lo = 0, hi = glyphs.count - 1, found: Glyph?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if glyphs[mid].column <= column { found = glyphs[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let found, column < found.column + found.width else { return nil }
        return found
    }

    /// Work out a row's cells from libghostty's reads of it.
    ///
    /// `prefix(c)` is the row's text from column 0 through `c`. That grows by
    /// one character exactly at each cell that starts one, and not at all at
    /// a wide character's second cell, which is what places every character,
    /// wide or not, with no width table of our own to disagree with the
    /// renderer's. An empty cell between characters is not written until
    /// something follows it, so it arrives as a space just ahead of that
    /// character, one per cell. `cell(c)` is column `c` read alone, needed only
    /// for the row's last character: read alone, a wide character's second
    /// cell answers with the character, an empty cell with nothing.
    ///
    /// `text` is the whole row as read on its own. nil when the reads don't add
    /// up to it, which means the screen changed while we were reading.
    static func build(text: String, columns: Int,
                      prefix: (Int) -> String?, cell: (Int) -> String?) -> RowCells? {
        let target = text.utf16.count
        var glyphs: [Glyph] = []
        var previous = ""
        var previousLength = 0
        var column = 0
        while column < columns, previousLength < target {
            guard let current = prefix(column) else { return nil }
            let currentLength = current.utf16.count
            if currentLength > previousLength {
                guard current.utf16.starts(with: previous.utf16),
                      let added = String(current.utf16.dropFirst(previousLength)) else { return nil }
                let characters = Array(added)
                // The last is the character in this cell; any before it are the
                // empty cells just ahead, written out as spaces now.
                var offset = previousLength
                for (i, character) in characters.enumerated() {
                    let length = character.utf16.count
                    glyphs.append(Glyph(offset: offset, length: length,
                                        column: column - (characters.count - 1) + i, width: 1))
                    offset += length
                }
                previous = current
                previousLength = currentLength
            }
            column += 1
        }
        guard previousLength == target, text.utf16.starts(with: previous.utf16) else { return nil }
        // Width: up to the next character's cell. The last is wide when the
        // cell after it reads as it (there is no character there, or the
        // prefix would have grown).
        for i in glyphs.indices {
            let g = glyphs[i]
            let width: Int
            if i + 1 < glyphs.count {
                width = max(1, glyphs[i + 1].column - g.column)
            } else {
                let next = g.column + 1
                width = next < columns && !(cell(next) ?? "").isEmpty ? 2 : 1
            }
            glyphs[i] = Glyph(offset: g.offset, length: g.length, column: g.column, width: width)
        }
        return RowCells(glyphs: glyphs, length: target)
    }
}
