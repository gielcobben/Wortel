import XCTest

/// ⌘F in a preview window. It finds *lines* — the thing being searched is a
/// table of hand-drawn rows, not text — which makes it index arithmetic with
/// wraparound, and that is the one part of a find bar that can be wrong by
/// exactly one while looking almost right.
@MainActor
final class PreviewFindTests: XCTestCase {
    private func find(_ texts: [String], query: String = "") -> PreviewFind {
        let find = PreviewFind()
        find.update(lines: texts.enumerated().map {
            DiffLine(id: $0.offset, kind: .context, text: $0.element,
                     oldLine: $0.offset + 1, newLine: $0.offset + 1, path: "a.swift")
        })
        find.query = query
        return find
    }

    func testMatchesAreLineIndicesInOrder() {
        let find = find(["alpha", "beta", "alpha again", "gamma"], query: "alpha")
        XCTAssertEqual(find.matches, [0, 2])
        XCTAssertEqual(find.focusedLine, 0)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(find(["Alpha", "ALPHA", "beta"], query: "alpha").matches, [0, 1])
    }

    func testEmptyQueryFindsNothingAndSaysNothing() {
        let find = find(["alpha"], query: "alpha")
        find.query = ""
        XCTAssertEqual(find.matches, [])
        XCTAssertNil(find.focusedLine)
        XCTAssertEqual(find.summary, "", "an empty field is not a failed search")
    }

    func testNoMatchesSaysSo() {
        XCTAssertEqual(find(["alpha"], query: "zzz").summary, "No matches")
    }

    /// The counter is 1-based for the reader, 0-based underneath — the classic
    /// place to be off by one.
    func testSummaryCountsFromOne() {
        let find = find(["a", "a", "a"], query: "a")
        XCTAssertEqual(find.summary, "1 of 3")
        find.next()
        XCTAssertEqual(find.summary, "2 of 3")
    }

    func testNextWrapsPastTheEnd() {
        let find = find(["a", "b", "a"], query: "a")
        XCTAssertEqual(find.focusedLine, 0)
        find.next()
        XCTAssertEqual(find.focusedLine, 2)
        find.next()
        XCTAssertEqual(find.focusedLine, 0, "the last match wraps to the first")
    }

    func testPreviousWrapsPastTheStart() {
        let find = find(["a", "b", "a"], query: "a")
        find.previous()
        XCTAssertEqual(find.focusedLine, 2, "the first match wraps to the last")
    }

    func testWalkingWithNoMatchesIsHarmless() {
        let find = find(["a"], query: "zzz")
        find.next()
        find.previous()
        XCTAssertNil(find.focusedLine)
    }

    /// The file is being rewritten under the search, or the mode switched. Match
    /// indices from the old content point at lines that have moved, so they have
    /// to be recomputed rather than carried.
    func testContentChangingRecomputesMatches() {
        let find = find(["alpha", "beta"], query: "alpha")
        XCTAssertEqual(find.matches, [0])
        find.update(lines: [
            DiffLine(id: 0, kind: .context, text: "beta", oldLine: 1, newLine: 1, path: nil),
            DiffLine(id: 1, kind: .context, text: "alpha", oldLine: 2, newLine: 2, path: nil),
        ])
        XCTAssertEqual(find.matches, [1])
    }

    /// A rewrite that leaves fewer matches must not leave the cursor pointing
    /// past the end of the list — `focusedLine` would index out of bounds.
    func testCursorIsClampedWhenMatchesShrink() {
        let find = find(["a", "a", "a"], query: "a")
        find.next()
        find.next()
        XCTAssertEqual(find.focusedLine, 2)
        find.update(lines: [
            DiffLine(id: 0, kind: .context, text: "a", oldLine: 1, newLine: 1, path: nil),
        ])
        XCTAssertEqual(find.matches, [0])
        XCTAssertEqual(find.focusedLine, 0)
    }

    func testDismissClearsTheSearch() {
        let find = find(["alpha"], query: "alpha")
        find.isPresented = true
        find.dismiss()
        XCTAssertFalse(find.isPresented)
        XCTAssertEqual(find.query, "")
        XCTAssertNil(find.focusedLine, "a closed bar must not keep a row selected")
    }
}
