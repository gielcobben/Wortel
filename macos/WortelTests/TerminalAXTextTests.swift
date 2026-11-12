import XCTest

/// The terminal's accessibility text: AXValue, and the mapping between its
/// UTF-16 ranges and the cell grid that AXBoundsForRange and the selection
/// need.
///
/// A wrong mapping fails silently: a reader highlights the word next to the one
/// it is speaking, or the selection range points one emoji to the left. So the
/// rules are pinned here against a model of how libghostty writes cells out
/// (`FakeRow`), checked against the real binary when this was written: an empty
/// cell is held back and written as a space only when a character follows it,
/// a wide character's second cell writes nothing, and that second cell read on
/// its own answers with the character.
final class TerminalAXTextTests: XCTestCase {
    // MARK: - A row as libghostty holds it

    private enum Cell: Equatable {
        case narrow(String)
        case wide(String)
        case spacerTail
        case empty
    }

    private struct FakeRow {
        let cells: [Cell]

        /// Columns 0 through `column`, written as `ghostty_surface_read_text`
        /// writes them.
        func prefix(_ column: Int) -> String {
            var out = "", pending = 0
            for cell in cells.prefix(column + 1) {
                switch cell {
                case .empty: pending += 1
                case .spacerTail: break
                case .narrow(let s), .wide(let s):
                    out += String(repeating: " ", count: pending)
                    pending = 0
                    out += s
                }
            }
            return out
        }

        var text: String { prefix(cells.count - 1) }

        /// One cell read alone. Starting on a wide character's second cell
        /// steps back to the character.
        func cell(_ column: Int) -> String {
            switch cells[column] {
            case .empty: return ""
            case .narrow(let s), .wide(let s): return s
            case .spacerTail:
                if case .wide(let s) = cells[column - 1] { return s }
                return ""
            }
        }

        func map() -> RowCells? {
            RowCells.build(text: text, columns: cells.count,
                           prefix: { prefix($0) }, cell: { cell($0) })
        }
    }

    /// Lay `s` out across `columns` cells: CJK and emoji wide, everything else
    /// one cell per grapheme, `_` an empty (never written) cell.
    private func row(_ s: String, columns: Int = 20) -> FakeRow {
        var cells: [Cell] = []
        for character in s {
            if character == "_" {
                cells.append(.empty)
            } else if isWide(character) {
                cells.append(.wide(String(character)))
                cells.append(.spacerTail)
            } else {
                cells.append(.narrow(String(character)))
            }
        }
        while cells.count < columns { cells.append(.empty) }
        return FakeRow(cells: cells)
    }

    private func isWide(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return (0x3000...0x9FFF).contains(scalar.value) || scalar.properties.isEmojiPresentation
    }

    private func glyphs(_ map: RowCells?) -> [[Int]] {
        (map?.glyphs ?? []).map { [$0.offset, $0.length, $0.column, $0.width] }
    }

    // MARK: - Cells

    func testPlainTextIsOneCellPerCharacter() {
        let map = row("ls -la").map()
        XCTAssertEqual(glyphs(map), [[0, 1, 0, 1], [1, 1, 1, 1], [2, 1, 2, 1],
                                     [3, 1, 3, 1], [4, 1, 4, 1], [5, 1, 5, 1]])
    }

    func testWideCharactersTakeTwoCellsAndOneOffset() {
        // 日本語 hello: each CJK character is one UTF-16 unit over two cells.
        let map = row("日本語 hello").map()
        XCTAssertEqual(Array(glyphs(map).prefix(4)),
                       [[0, 1, 0, 2], [1, 1, 2, 2], [2, 1, 4, 2], [3, 1, 6, 1]])
        XCTAssertEqual(map?.column(atOffset: 4), 7) // "h"
    }

    func testEmojiIsTwoOffsetsOverTwoCells() {
        let map = row("A😀b").map()
        XCTAssertEqual(glyphs(map), [[0, 1, 0, 1], [1, 2, 1, 2], [3, 1, 3, 1]])
    }

    func testCombiningMarkStaysInItsCell() {
        let map = row("e\u{301}x").map()
        XCTAssertEqual(glyphs(map), [[0, 2, 0, 1], [2, 1, 1, 1]])
    }

    func testRepeatedWideCharactersAreTellApart() {
        // Read alone, every one of these four cells says 日; only the prefix
        // growing tells a second character from a second cell.
        let map = row("日日 aa").map()
        XCTAssertEqual(glyphs(map), [[0, 1, 0, 2], [1, 1, 2, 2], [2, 1, 4, 1],
                                     [3, 1, 5, 1], [4, 1, 6, 1]])
    }

    func testEmptyCellsBetweenCharactersBecomeSpacesInTheirOwnCells() {
        // Two never-written cells between `a` and `b`, after a wide character.
        let map = row("日a__b").map()
        XCTAssertEqual(row("日a__b").text, "日a  b")
        XCTAssertEqual(glyphs(map), [[0, 1, 0, 2], [1, 1, 2, 1], [2, 1, 3, 1],
                                     [3, 1, 4, 1], [4, 1, 5, 1]])
    }

    func testLeadingEmptyCells() {
        let map = row("___x").map()
        XCTAssertEqual(glyphs(map), [[0, 1, 0, 1], [1, 1, 1, 1], [2, 1, 2, 1], [3, 1, 3, 1]])
    }

    func testWideLastCharacterIsWide() {
        XCTAssertEqual(glyphs(row("ab日").map()).last, [2, 1, 2, 2])
        XCTAssertEqual(glyphs(row("ab日", columns: 4).map()).last, [2, 1, 2, 2])
    }

    func testEmptyRow() {
        let map = row("").map()
        XCTAssertEqual(map?.glyphs, [])
        XCTAssertEqual(map?.offset(atColumn: 5), 0)
    }

    func testReadsThatDisagreeGiveNoMap() {
        // The screen changed between the row read and the cell reads.
        let fake = row("hello")
        let map = RowCells.build(text: "hellx", columns: 20,
                                 prefix: { fake.prefix($0) }, cell: { fake.cell($0) })
        XCTAssertNil(map)
    }

    // MARK: - Text

    func testHardLinesGetNewlinesAndWrappedRowsJoin() {
        let text = TerminalAXText(rows: ["one", "WWWW", "WW end", "", "x"],
                                  endsLine: [true, false, true, true, true])
        XCTAssertEqual(text.string, "one\nWWWWWW end\n\nx")
        XCTAssertEqual(text.length, 17)
        XCTAssertEqual(text.rowStarts, [0, 4, 8, 15, 16])
        XCTAssertEqual(text.rowLengths, [3, 4, 6, 0, 1])
    }

    func testLengthCountsUTF16() {
        let text = TerminalAXText(rows: ["A😀b", "日本"], endsLine: [true, true])
        XCTAssertEqual(text.length, 7)
        XCTAssertEqual((text.string as NSString).length, text.length)
    }

    func testLineForIndex() {
        let text = TerminalAXText(rows: ["one", "WWWW", "WW end", "", "x"],
                                  endsLine: [true, false, true, true, true])
        XCTAssertEqual(text.row(containing: 0), 0)
        XCTAssertEqual(text.row(containing: 3), 0) // its newline
        XCTAssertEqual(text.row(containing: 4), 1)
        XCTAssertEqual(text.row(containing: 7), 1)
        XCTAssertEqual(text.row(containing: 8), 2) // wrapped on, no newline
        XCTAssertEqual(text.row(containing: 15), 3) // the empty row's newline
        XCTAssertEqual(text.row(containing: 16), 4)
        XCTAssertEqual(text.row(containing: 17), 4) // end of text
    }

    func testRangeForLineIncludesItsNewline() {
        let text = TerminalAXText(rows: ["one", "WWWW", "WW end", "", "x"],
                                  endsLine: [true, false, true, true, true])
        XCTAssertEqual(text.lineRange(0), NSRange(location: 0, length: 4))
        XCTAssertEqual(text.lineRange(1), NSRange(location: 4, length: 4))
        XCTAssertEqual(text.lineRange(2), NSRange(location: 8, length: 7))
        XCTAssertEqual(text.lineRange(3), NSRange(location: 15, length: 1))
        XCTAssertEqual(text.lineRange(4), NSRange(location: 16, length: 1))
        XCTAssertNil(text.lineRange(5))
    }

    // MARK: - Ranges to cells

    private func layout(_ rows: [String], endsLine: [Bool], columns: Int = 20)
        -> (TerminalAXText, (Int) -> RowCells?) {
        let fakes = rows.map { row($0, columns: columns) }
        let text = TerminalAXText(rows: fakes.map(\.text), endsLine: endsLine)
        let maps = fakes.map { $0.map() }
        return (text, { maps.indices.contains($0) ? maps[$0] : nil })
    }

    func testWordAfterWideCharacters() {
        let (text, cells) = layout(["日本語 hello"], endsLine: [true])
        let word = (text.string as NSString).range(of: "hello")
        XCTAssertEqual(text.segments(for: word, cells: cells),
                       [.init(row: 0, startColumn: 7, endColumn: 12)])
    }

    func testWordAfterEmoji() {
        let (text, cells) = layout(["A😀b cat"], endsLine: [true])
        let word = (text.string as NSString).range(of: "cat")
        XCTAssertEqual(text.segments(for: word, cells: cells),
                       [.init(row: 0, startColumn: 5, endColumn: 8)])
        let emoji = (text.string as NSString).range(of: "😀")
        XCTAssertEqual(text.segments(for: emoji, cells: cells),
                       [.init(row: 0, startColumn: 1, endColumn: 3)])
    }

    func testWideCharacterAsAWord() {
        let (text, cells) = layout(["x 日本 y"], endsLine: [true])
        let word = (text.string as NSString).range(of: "日本")
        XCTAssertEqual(text.segments(for: word, cells: cells),
                       [.init(row: 0, startColumn: 2, endColumn: 6)])
    }

    func testWordSplitAcrossAWrapIsTwoSegments() {
        // "hello" broken at the margin of a 6-column terminal: "ab hel" / "lo".
        let (text, cells) = layout(["ab hel", "lo"], endsLine: [false, true], columns: 6)
        XCTAssertEqual(text.string, "ab hello")
        let word = (text.string as NSString).range(of: "hello")
        XCTAssertEqual(text.segments(for: word, cells: cells),
                       [.init(row: 0, startColumn: 3, endColumn: 6),
                        .init(row: 1, startColumn: 0, endColumn: 2)])
    }

    func testRangeOverANewlineCoversBothRows() {
        let (text, cells) = layout(["abc", "def"], endsLine: [true, true])
        XCTAssertEqual(text.segments(for: NSRange(location: 1, length: 5), cells: cells),
                       [.init(row: 0, startColumn: 1, endColumn: 3),
                        .init(row: 1, startColumn: 0, endColumn: 2)])
    }

    func testEmptyRangeIsACaret() {
        let (text, cells) = layout(["abc"], endsLine: [true])
        XCTAssertEqual(text.segments(for: NSRange(location: 2, length: 0), cells: cells),
                       [.init(row: 0, startColumn: 2, endColumn: 2)])
        XCTAssertEqual(text.segments(for: NSRange(location: 3, length: 0), cells: cells),
                       [.init(row: 0, startColumn: 3, endColumn: 3)])
    }

    func testRangeOfOnlyANewlineSitsAtTheEndOfItsRow() {
        let (text, cells) = layout(["abc", "d"], endsLine: [true, true])
        XCTAssertEqual(text.segments(for: NSRange(location: 3, length: 1), cells: cells),
                       [.init(row: 0, startColumn: 3, endColumn: 3)])
    }

    func testRangePastTheEndGivesNothing() {
        let (text, cells) = layout(["abc"], endsLine: [true])
        XCTAssertEqual(text.segments(for: NSRange(location: 9, length: 1), cells: cells), [])
        XCTAssertEqual(text.segments(for: NSRange(location: NSNotFound, length: 0), cells: cells), [])
    }

    // MARK: - Cells to ranges (the selection)

    func testSelectionOfAWord() {
        let (text, cells) = layout(["日本語 hello"], endsLine: [true])
        let range = text.range(fromCell: (0, 7), toCell: (0, 11), cells: cells)
        XCTAssertEqual(range.map { (text.string as NSString).substring(with: $0) }, "hello")
    }

    func testSelectionStartingOrEndingOnAWideCharactersSecondCell() {
        let (text, cells) = layout(["a日b😀c"], endsLine: [true])
        // Cells: a 0, 日 1-2, b 3, 😀 4-5, c 6. Second cell of 日 to second of 😀.
        let range = text.range(fromCell: (0, 2), toCell: (0, 5), cells: cells)
        XCTAssertEqual(range.map { (text.string as NSString).substring(with: $0) }, "日b😀")
    }

    func testSelectionPastTheEndOfARowTakesTheNewline() {
        let (text, cells) = layout(["abc", "def"], endsLine: [true, true])
        // From `b` to column 1 of the next row: a selection dragged down.
        let range = text.range(fromCell: (0, 1), toCell: (1, 1), cells: cells)
        XCTAssertEqual(range.map { (text.string as NSString).substring(with: $0) }, "bc\nde")
        // Ending in the empty part of a row stops at its text.
        let tail = text.range(fromCell: (0, 1), toCell: (0, 15), cells: cells)
        XCTAssertEqual(tail.map { (text.string as NSString).substring(with: $0) }, "bc")
    }

    func testSelectionAcrossAWrap() {
        let (text, cells) = layout(["ab hel", "lo x"], endsLine: [false, true], columns: 6)
        let range = text.range(fromCell: (0, 3), toCell: (1, 1), cells: cells)
        XCTAssertEqual(range.map { (text.string as NSString).substring(with: $0) }, "hello")
    }
}
