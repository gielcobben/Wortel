import XCTest

/// One row over, and the row to land on after a close, over the sidebar's
/// rows as drawn. Off by one here is the wrong session selected, silently,
/// so each case is a sidebar small enough to check by eye.
final class SidebarStepTests: XCTestCase {
    /// Rows as drawn, top to bottom.
    private let rows = ["a", "b", "c", "d"]

    // MARK: - One row over

    func testDownInTheMiddleIsTheRowBelow() {
        XCTAssertEqual(SidebarStep.neighbour(of: "b", in: rows, by: 1), "c")
    }

    func testUpInTheMiddleIsTheRowAbove() {
        XCTAssertEqual(SidebarStep.neighbour(of: "c", in: rows, by: -1), "b")
    }

    func testDownFromTheLastRowWrapsToTheFirst() {
        XCTAssertEqual(SidebarStep.neighbour(of: "d", in: rows, by: 1), "a")
    }

    func testUpFromTheFirstRowWrapsToTheLast() {
        XCTAssertEqual(SidebarStep.neighbour(of: "a", in: rows, by: -1), "d")
    }

    func testTwoRowsSwapEitherWay() {
        let two = ["a", "b"]
        XCTAssertEqual(SidebarStep.neighbour(of: "a", in: two, by: 1), "b")
        XCTAssertEqual(SidebarStep.neighbour(of: "a", in: two, by: -1), "b")
        XCTAssertEqual(SidebarStep.neighbour(of: "b", in: two, by: 1), "a")
        XCTAssertEqual(SidebarStep.neighbour(of: "b", in: two, by: -1), "a")
    }

    func testASingleRowHasNoNeighbour() {
        XCTAssertNil(SidebarStep.neighbour(of: "a", in: ["a"], by: 1))
        XCTAssertNil(SidebarStep.neighbour(of: "a", in: ["a"], by: -1))
    }

    func testNoRowsHaveNoNeighbour() {
        XCTAssertNil(SidebarStep.neighbour(of: "a", in: [String](), by: 1))
        XCTAssertNil(SidebarStep.neighbour(of: nil, in: [String](), by: -1))
    }

    func testNoSelectionStepsOntoTheFirstRowGoingDownAndTheLastGoingUp() {
        XCTAssertEqual(SidebarStep.neighbour(of: nil, in: rows, by: 1), "a")
        XCTAssertEqual(SidebarStep.neighbour(of: nil, in: rows, by: -1), "d")
    }

    func testASelectionThatIsNotDrawnStepsOntoTheFirstRowGoingDownAndTheLastGoingUp() {
        XCTAssertEqual(SidebarStep.neighbour(of: "z", in: rows, by: 1), "a")
        XCTAssertEqual(SidebarStep.neighbour(of: "z", in: rows, by: -1), "d")
    }

    func testASelectionThatIsNotDrawnStillReachesALoneRow() {
        XCTAssertEqual(SidebarStep.neighbour(of: "z", in: ["a"], by: 1), "a",
                       "the one row on screen is another row than one that isn't")
    }

    /// Sort Unread First draws "c" above "a" and "b": down from "c" is the
    /// row below it on screen, not the one after it in the stored order.
    func testItFollowsTheRowsAsGivenNotAnyOtherOrder() {
        let sorted = ["c", "a", "b", "d"]
        XCTAssertEqual(SidebarStep.neighbour(of: "c", in: sorted, by: 1), "a")
        XCTAssertEqual(SidebarStep.neighbour(of: "a", in: sorted, by: -1), "c")
    }

    // MARK: - After a close

    func testClosingInTheMiddleLandsOnTheRowAbove() {
        XCTAssertEqual(SidebarStep.afterClosing("c", in: rows), "b",
                       "⌘N then ⌘W lands back where it started")
    }

    func testClosingTheLastRowLandsOnTheRowAbove() {
        XCTAssertEqual(SidebarStep.afterClosing("d", in: rows), "c")
    }

    func testClosingTheTopRowLandsOnTheRowBelow() {
        XCTAssertEqual(SidebarStep.afterClosing("a", in: rows), "b")
    }

    func testClosingTheOnlyRowLandsNowhere() {
        XCTAssertNil(SidebarStep.afterClosing("a", in: ["a"]))
    }

    func testClosingARowThatIsNotDrawnLandsNowhere() {
        XCTAssertNil(SidebarStep.afterClosing("z", in: rows))
        XCTAssertNil(SidebarStep.afterClosing("z", in: [String]()))
    }

    func testClosingWhileSortedLandsOnTheRowAboveOnScreen() {
        let sorted = ["c", "a", "b", "d"]
        XCTAssertEqual(SidebarStep.afterClosing("a", in: sorted), "c")
    }
}
