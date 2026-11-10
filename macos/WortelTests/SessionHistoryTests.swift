import XCTest

/// Back and Forward through the sessions you've been on. Every way it can be
/// wrong is silent: an arrow that is lit and does nothing when pressed, or a
/// step that lands on a session that was just closed. Ids are plain Ints and
/// "open" is a set, so each case reads as the sidebar it stands for.
final class SessionHistoryTests: XCTestCase {
    private typealias History = SessionHistory<Int>

    /// The sessions still open, as the manager's `isOpen` answers.
    private var open: Set<Int> = []
    private func isOpen(_ id: Int) -> Bool { open.contains(id) }

    /// Walks `path` as selections you made: each step is a visit from the one
    /// before. Returns the history and the session you end on.
    private func walk(_ path: [Int]) -> (History, Int?) {
        var history = History()
        var current: Int?
        for id in path {
            history.visit(from: current, isOpen: isOpen)
            current = id
        }
        return (history, current)
    }

    // MARK: - Visits

    func testVisitPushesOntoBackAndClearsForward() {
        open = [1, 2, 3, 4]
        var (history, current) = walk([1, 2, 3])
        XCTAssertEqual(history.back, [1, 2])
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 2)
        XCTAssertEqual(history.forward, [3])

        history.visit(from: current, isOpen: isOpen)
        XCTAssertEqual(history.back, [1, 2], "what you left goes on Back")
        XCTAssertEqual(history.forward, [], "a visit after going back drops Forward, as a browser does")
    }

    func testVisitFromNothingRecordsNothing() {
        open = [1]
        var history = History()
        history.visit(from: nil, isOpen: isOpen)
        XCTAssertEqual(history, History())
    }

    func testVisitFromAClosedSessionRecordsNothing() {
        open = [2]
        var history = History()
        history.visit(from: 1, isOpen: isOpen)
        XCTAssertEqual(history.back, [], "closing the selected session moves the selection; that isn't a place to go back to")
    }

    func testVisitingTwiceFromTheSameSessionRecordsItOnce() {
        open = [1, 2]
        var history = History()
        history.visit(from: 1, isOpen: isOpen)
        history.visit(from: 1, isOpen: isOpen)
        XCTAssertEqual(history.back, [1])
    }

    func testARepeatedVisitFurtherBackIsKeptSoBackRetracesThePath() {
        open = [1, 2]
        let (history, _) = walk([1, 2, 1, 2])
        XCTAssertEqual(history.back, [1, 2, 1], "not moved to the front, as ⌘P's recent list is")
    }

    func testTheCapDropsTheOldestEntries() {
        open = Set(0..<150)
        var history = History()
        for id in 0..<150 { history.visit(from: id, isOpen: isOpen) }
        XCTAssertEqual(history.back.count, History.limit)
        XCTAssertEqual(History.limit, 100)
        XCTAssertEqual(history.back.first, 50, "the oldest fifty went")
        XCTAssertEqual(history.back.last, 149)
    }

    // MARK: - Steps

    func testBackThenForwardReturnsToWhereYouWere() {
        open = [1, 2, 3]
        var (history, current) = walk([1, 2, 3])

        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 2)
        XCTAssertEqual(history.back, [1])
        XCTAssertEqual(history.forward, [3], "Back leaves where you were on Forward")

        current = history.step(.forward, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 3)
        XCTAssertEqual(history.back, [1, 2], "Forward leaves where you were on Back")
        XCTAssertEqual(history.forward, [])
    }

    func testBackTwiceThenForwardTwiceRetracesThePath() {
        open = [1, 2, 3]
        var (history, current) = walk([1, 2, 3])
        current = history.step(.back, from: current, isOpen: isOpen)
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 1)
        XCTAssertEqual(history.forward, [3, 2], "nearest last")
        current = history.step(.forward, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 2)
        current = history.step(.forward, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 3)
        XCTAssertEqual(history.back, [1, 2])
        XCTAssertEqual(history.forward, [])
    }

    func testClosedSessionsAreSteppedOverAndDropped() {
        open = [1, 2, 3, 4]
        var (history, current) = walk([1, 2, 3, 4])
        open = [1, 4]
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 1, "2 and 3 closed")
        XCTAssertEqual(history.back, [])
        XCTAssertEqual(history.forward, [4], "only where you were, not what was stepped over")
    }

    func testClosedSessionsAreSteppedOverGoingForwardToo() {
        open = [1, 2, 3, 4]
        var (history, current) = walk([1, 2, 3, 4])
        for _ in 0..<3 { current = history.step(.back, from: current, isOpen: isOpen) }
        XCTAssertEqual(current, 1)
        XCTAssertEqual(history.forward, [4, 3, 2])
        open = [1, 4]
        current = history.step(.forward, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 4)
        XCTAssertEqual(history.forward, [])
        XCTAssertEqual(history.back, [1])
    }

    func testAStepWithNowhereToGoStillDropsTheDeadEntries() {
        open = [1, 2, 3]
        var (history, current) = walk([1, 2, 3])
        open = [3]
        XCTAssertNil(history.step(.back, from: current, isOpen: isOpen))
        XCTAssertEqual(history.back, [], "closed sessions are never coming back")
        XCTAssertEqual(history.forward, [], "nothing moved, so where you are isn't put on Forward")
        current = 3
        XCTAssertFalse(history.canStep(.back, from: current, isOpen: isOpen))
    }

    func testAStepFromNoSelectionPutsNothingOnTheOtherSide() {
        open = [1, 2]
        var history = History()
        history.visit(from: 1, isOpen: isOpen)
        XCTAssertEqual(history.step(.back, from: nil, isOpen: isOpen), 1)
        XCTAssertEqual(history.forward, [])
    }

    // MARK: - The bug: lit with nowhere to go

    /// Visit 1, then 2, then close 2: the selection lands back on 1, and 1 is
    /// all Back holds. It used to stay lit, and pressing it did nothing.
    func testBackIsNotLitWhenItHoldsOnlyTheCurrentSession() {
        open = [1]
        var history = History()
        history.visit(from: 1, isOpen: isOpen)
        history.forget(2)
        XCTAssertEqual(history.back, [1])

        XCTAssertFalse(history.canStep(.back, from: 1, isOpen: isOpen))
        XCTAssertNil(history.step(.back, from: 1, isOpen: isOpen))
    }

    /// The maintainer's manual check, as values: go back, go Forward again,
    /// close the session you went Forward to, and land on the one Back holds.
    func testClosingTheSessionYouWentForwardToDimsBack() {
        open = [1, 2]
        var (history, current) = walk([1, 2])
        current = history.step(.back, from: current, isOpen: isOpen)
        current = history.step(.forward, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 2)
        XCTAssertEqual(history.back, [1])

        open = [1]
        history.forget(2)
        current = 1
        XCTAssertFalse(history.canStep(.back, from: current, isOpen: isOpen))
        XCTAssertFalse(history.canStep(.forward, from: current, isOpen: isOpen))
    }

    func testCanStepLooksPastTheCurrentSession() {
        open = [1, 2]
        var history = History()
        history.visit(from: 2, isOpen: isOpen)
        history.visit(from: 1, isOpen: isOpen)
        XCTAssertEqual(history.back, [2, 1])
        XCTAssertTrue(history.canStep(.back, from: 1, isOpen: isOpen))
        XCTAssertEqual(history.step(.back, from: 1, isOpen: isOpen), 2)
    }

    func testCanStepIgnoresClosedSessions() {
        open = [1, 2, 3]
        let (history, current) = walk([1, 2, 3])
        open = [3]
        XCTAssertFalse(history.canStep(.back, from: current, isOpen: isOpen))
    }

    func testCanStepAgreesWithStep() {
        open = [1, 2, 3, 4]
        var (history, current) = walk([1, 2, 3, 2, 4])
        open = [2, 4]
        for direction in [History.Direction.back, .forward, .back, .back, .forward, .forward] {
            let could = history.canStep(direction, from: current, isOpen: isOpen)
            let next = history.step(direction, from: current, isOpen: isOpen)
            XCTAssertEqual(could, next != nil, "\(direction) from \(String(describing: current))")
            if let next { current = next }
        }
    }

    func testCanStepIsFalseOnEmptyLists() {
        open = [1]
        let history = History()
        XCTAssertFalse(history.canStep(.back, from: 1, isOpen: isOpen))
        XCTAssertFalse(history.canStep(.forward, from: 1, isOpen: isOpen))
        XCTAssertFalse(history.canStep(.back, from: nil, isOpen: isOpen))
    }

    func testAStepOnEmptyListsChangesNothing() {
        open = [1]
        var history = History()
        XCTAssertNil(history.step(.back, from: 1, isOpen: isOpen))
        XCTAssertNil(history.step(.forward, from: 1, isOpen: isOpen))
        XCTAssertEqual(history, History(), "the manager writes the history back only when it changed")
    }

    // MARK: - Forget

    func testForgetRemovesTheSessionFromBothLists() {
        open = [1, 2, 3, 4]
        var (history, current) = walk([1, 2, 1, 3, 2, 4])
        current = history.step(.back, from: current, isOpen: isOpen)
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 3)
        XCTAssertEqual(history.back, [1, 2, 1])
        XCTAssertEqual(history.forward, [4, 2])

        history.forget(2)
        XCTAssertEqual(history.back, [1, 1], "every entry for it, not only the last")
        XCTAssertEqual(history.forward, [4])
    }

    func testForgettingASessionNotInEitherListChangesNothing() {
        open = [1, 2]
        var (history, _) = walk([1, 2])
        let before = history
        history.forget(9)
        XCTAssertEqual(history, before)
    }
}
