import XCTest

final class DiffSyntaxTests: XCTestCase {
    // MARK: Token folding

    func testCaptureFallsBackToLessSpecificToken() {
        XCTAssertEqual(HighlightToken.from(capture: "function.method.builtin"), .function)
        XCTAssertEqual(HighlightToken.from(capture: "keyword.control.return"), .keyword)
        XCTAssertEqual(HighlightToken.from(capture: "variable.parameter"), .variable)
        XCTAssertEqual(HighlightToken.from(capture: "punctuation.delimiter"), .punctuation)
        XCTAssertEqual(HighlightToken.from(capture: "delimiter"), .punctuation)
    }

    func testMoreSpecificMappingWinsOverItsPrefix() {
        // string.escape must resolve to escape, not fall through to string.
        XCTAssertEqual(HighlightToken.from(capture: "string.escape"), .escape)
        XCTAssertEqual(HighlightToken.from(capture: "string"), .string)
    }

    func testUnknownCaptureIsNil() {
        XCTAssertNil(HighlightToken.from(capture: "no.such.capture"))
        XCTAssertNil(HighlightToken.from(capture: "spell"))
    }

    // MARK: Hunk reconstruction

    private func line(_ id: Int, _ kind: DiffLineKind, _ text: String, path: String? = "a.swift") -> DiffLine {
        DiffLine(id: id, kind: kind, text: text, oldLine: nil, newLine: nil, path: path)
    }

    func testSegmentsSplitPreAndPostImage() {
        let lines = [
            line(1, .hunkHeader, "@@ -1,2 +1,2 @@"),
            line(2, .context, "let a = 1"),
            line(3, .deletion, "let b = 2"),
            line(4, .addition, "let b = 3"),
        ]
        let segs = DiffSyntax.segments(lines)
        XCTAssertEqual(segs.count, 2)
        let post = segs[0], pre = segs[1]

        // Post-image: context + addition; owns both.
        XCTAssertEqual(post.lineIDs, [2, 4])
        XCTAssertEqual(post.ownedIDs, [2, 4])
        XCTAssertEqual(post.text, "let a = 1\nlet b = 3")

        // Pre-image: context + deletion, but owns only the deletion (context is
        // coloured from the post-image).
        XCTAssertEqual(pre.lineIDs, [2, 3])
        XCTAssertEqual(pre.ownedIDs, [3])
    }

    func testSegmentsTrackPerFilePath() {
        let lines = [
            line(1, .hunkHeader, "@@", path: "a.swift"),
            line(2, .addition, "let a = 1", path: "a.swift"),
            line(3, .hunkHeader, "@@", path: "b.css"),
            line(4, .addition, ".x {}", path: "b.css"),
        ]
        let segs = DiffSyntax.segments(lines)
        XCTAssertEqual(segs.map(\.path), ["a.swift", "b.css"])
    }

    func testLineStartsAreUTF16Offsets() {
        let lines = [
            line(1, .hunkHeader, "@@"),
            line(2, .addition, "ab"),   // len 2, start 0
            line(3, .addition, "cde"),  // start 3 (2 + newline)
        ]
        let post = DiffSyntax.segments(lines)[0]
        XCTAssertEqual(post.lineStarts, [0, 3])
    }

    // MARK: Capture distribution

    private func segment(_ texts: [String], owned: Set<Int>) -> DiffSyntax.Segment {
        var starts: [Int] = []
        var offset = 0
        for t in texts { starts.append(offset); offset += (t as NSString).length + 1 }
        return DiffSyntax.Segment(path: "a.swift", text: texts.joined(separator: "\n"),
                                  lineStarts: starts,
                                  lineIDs: Array(1...texts.count),
                                  ownedIDs: owned)
    }

    func testSingleLineCaptureLandsOnItsLine() {
        let seg = segment(["let x = 1", "let y = 2"], owned: [1, 2])
        // "let" on the second line: starts at offset 10 (9 + newline), length 3.
        let spans = DiffSyntax.distribute([(NSRange(location: 10, length: 3), .keyword)], over: seg)
        XCTAssertEqual(spans[2], [HighlightSpan(range: NSRange(location: 0, length: 3), token: .keyword)])
        XCTAssertNil(spans[1])
    }

    func testMultiLineCaptureIsSplitPerLine() {
        // A block comment straddling the newline must become one span per line,
        // each clipped to its own line's bounds.
        let seg = segment(["abcde", "fghij"], owned: [1, 2]) // starts [0, 6], len 11
        let spans = DiffSyntax.distribute([(NSRange(location: 2, length: 7), .comment)], over: seg)
        // line 1: offsets 2..5 -> relative (2, 3)
        XCTAssertEqual(spans[1], [HighlightSpan(range: NSRange(location: 2, length: 3), token: .comment)])
        // line 2: offsets 6..9 -> relative (0, 3)
        XCTAssertEqual(spans[2], [HighlightSpan(range: NSRange(location: 0, length: 3), token: .comment)])
    }

    func testCapturesOnUnownedLinesAreDropped() {
        // Same text, but the segment owns only line 1 (e.g. a pre-image where
        // line 2 is context, coloured by the post-image instead).
        let seg = segment(["let x = 1", "let y = 2"], owned: [1])
        let spans = DiffSyntax.distribute([(NSRange(location: 10, length: 3), .keyword)], over: seg)
        XCTAssertNil(spans[2], "an unowned line must not receive spans")
    }
}
