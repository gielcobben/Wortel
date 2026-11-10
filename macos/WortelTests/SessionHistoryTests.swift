import XCTest

/// Back and Forward through the places you've been. Every way it can be
/// wrong is silent: an arrow that is lit and does nothing when pressed, or a
/// step that lands on a session that was just closed. The rules are over any
/// id, so most cases use plain Ints and "open" is a set, each reading as the
/// sidebar it stands for; the last ones walk real `WorkspacePlace`s.
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

    func testForgetWhereDropsEveryMatchFromBothListsAndKeepsTheRestInOrder() {
        open = [1, 2, 3, 4, 5, 6]
        var (history, current) = walk([1, 2, 3, 4, 5, 6])
        current = history.step(.back, from: current, isOpen: isOpen)
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, 4)
        XCTAssertEqual(history.back, [1, 2, 3])
        XCTAssertEqual(history.forward, [6, 5])

        history.forget(where: { $0.isMultiple(of: 2) })
        XCTAssertEqual(history.back, [1, 3])
        XCTAssertEqual(history.forward, [5])
    }

    // MARK: - Places: a session and its tab

    /// Two sessions, a few tabs in each, and the trail through them as
    /// `WorkspacePlace`s: what the manager keeps. "Open" is a place whose
    /// session is open and whose tab is still in one of its rows.
    private let a = UUID(), b = UUID()
    private var openPlaces: Set<WorkspacePlace> = []
    private func isOpen(_ place: WorkspacePlace) -> Bool { openPlaces.contains(place) }

    private var aFiles: WorkspacePlace { WorkspacePlace(session: a, tab: .pane(.files)) }
    private var aChanges: WorkspacePlace { WorkspacePlace(session: a, tab: .pane(.changes)) }
    private var aReadme: WorkspacePlace { WorkspacePlace(session: a, tab: .file("/repo/README.md")) }
    private var bTerminal: WorkspacePlace { WorkspacePlace(session: b, tab: .session) }
    private var bShell: WorkspacePlace { WorkspacePlace(session: b, tab: .terminal(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) }

    /// B's terminal, a side shell in B, then over to A: Files, Changes, the
    /// README. You end on the README.
    private func walkPlaces() -> (SessionHistory<WorkspacePlace>, WorkspacePlace?) {
        openPlaces = [aFiles, aChanges, aReadme, bTerminal, bShell]
        var history = SessionHistory<WorkspacePlace>()
        var current: WorkspacePlace?
        for place in [bTerminal, bShell, aFiles, aChanges, aReadme] {
            history.visit(from: current, isOpen: isOpen)
            current = place
        }
        return (history, current)
    }

    func testBackWalksTheTabsThenIntoTheOtherSessionOnTheTabYouLeft() {
        var (history, current) = walkPlaces()
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, aChanges)
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, aFiles)
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, bShell, "the other session, on the tab you left it on")

        for expected in [aFiles, aChanges, aReadme] {
            current = history.step(.forward, from: current, isOpen: isOpen)
            XCTAssertEqual(current, expected)
        }
        XCTAssertFalse(history.canStep(.forward, from: current, isOpen: isOpen))
    }

    func testAClosedTabIsSteppedOver() {
        var (history, current) = walkPlaces()
        openPlaces.remove(aChanges)
        XCTAssertTrue(history.canStep(.back, from: current, isOpen: isOpen))
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, aFiles, "Changes was closed")
        XCTAssertEqual(history.forward, [aReadme])
    }

    func testBackIsDimWhenOnlyClosedPlacesRemain() {
        var (history, current) = walkPlaces()
        current = history.step(.back, from: current, isOpen: isOpen)
        current = history.step(.back, from: current, isOpen: isOpen)
        XCTAssertEqual(current, aFiles)
        XCTAssertEqual(history.back, [bTerminal, bShell])

        // B closes: its places are forgotten and none of them is open.
        openPlaces = openPlaces.filter { $0.session != b }
        history.forget(where: { $0.session == b })
        XCTAssertEqual(history.back, [])
        XCTAssertFalse(history.canStep(.back, from: current, isOpen: isOpen))

        // A tab closing leaves its place in the list, but never one to go to.
        openPlaces.remove(aChanges)
        openPlaces.remove(aReadme)
        XCTAssertEqual(history.forward, [aReadme, aChanges])
        XCTAssertFalse(history.canStep(.forward, from: current, isOpen: isOpen))
        XCTAssertNil(history.step(.forward, from: current, isOpen: isOpen))
        XCTAssertEqual(history.forward, [], "the dead entries went")
    }

    func testTheSameTabInAnotherSessionIsAnotherPlace() {
        openPlaces = [aFiles, WorkspacePlace(session: b, tab: .pane(.files))]
        var history = SessionHistory<WorkspacePlace>()
        history.visit(from: aFiles, isOpen: isOpen)
        let bFiles = WorkspacePlace(session: b, tab: .pane(.files))
        XCTAssertTrue(history.canStep(.back, from: bFiles, isOpen: isOpen))
        XCTAssertEqual(history.step(.back, from: bFiles, isOpen: isOpen), aFiles)
    }
}
