import XCTest

/// The rollup rule a collapsed folder shows on behalf of what it hides.
///
/// Its failure mode is silence, which is the worst kind here: a folder that
/// reports something calmer than the agent blocked inside it is a session
/// waiting on you that the sidebar never mentions.
final class AttentionKindTests: XCTestCase {
    /// The whole rule: maximum, never latest. A folder holding one blocked
    /// agent and three that merely finished is *blocked*.
    func testLoudestWins() {
        XCTAssertEqual(
            AttentionKind.loudest(of: [.finished, .needsInput, .turnDone, .finished]),
            .needsInput)
        XCTAssertEqual(AttentionKind.loudest(of: [.finished, .turnDone]), .turnDone)
        XCTAssertEqual(AttentionKind.loudest(of: [.finished, .failed]), .failed)
    }

    /// Order must not matter — a calmer signal arriving later cannot displace a
    /// louder one, which is exactly what "latest wins" would do.
    func testOrderDoesNotMatter() {
        let kinds: [AttentionKind] = [.needsInput, .failed, .turnDone, .finished]
        XCTAssertEqual(AttentionKind.loudest(of: kinds), .needsInput)
        XCTAssertEqual(AttentionKind.loudest(of: kinds.reversed()), .needsInput)
    }

    /// Sessions with nothing to say are holes in the sequence, not zeros.
    func testNilsAreIgnored() {
        XCTAssertEqual(AttentionKind.loudest(of: [nil, .turnDone, nil]), .turnDone)
    }

    /// A quiet folder shows nothing at all — not a dot in the lowest colour.
    func testNothingToReport() {
        XCTAssertNil(AttentionKind.loudest(of: []))
        XCTAssertNil(AttentionKind.loudest(of: [nil, nil]))
    }

    /// The priority order the rollup depends on, pinned here so a reordering
    /// has to be deliberate: blocked beats failed beats turn-done beats
    /// finished.
    func testPriorityOrder() {
        let ordered: [AttentionKind] = [.finished, .turnDone, .failed, .needsInput]
        XCTAssertEqual(ordered.map(\.priority), [1, 2, 3, 4])
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(lower.priority, higher.priority)
        }
    }
}
