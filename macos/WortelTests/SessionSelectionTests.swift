import XCTest

/// The sidebar's selection of several sessions, which is the input to a bulk
/// Close. As with the git panel's, every way it can be wrong is silent: the
/// rows it picked are the rows it draws and the rows Close takes. The rule it
/// adds is the lead: the session on screen, owned by the manager, always
/// selected and never moved by a modifier click.
final class SessionSelectionTests: XCTestCase {
    /// Rows as drawn, across sections: Pinned, then a folder, then another.
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private var rows: [UUID] { [a, b, c, d, e] }

    func testRestingSelectionIsTheLeadAlone() {
        let selection = SessionSelection()
        XCTAssertFalse(selection.isMultiple)
        XCTAssertEqual(selection.members(lead: b), [b])
        XCTAssertTrue(selection.contains(b, lead: b))
        XCTAssertFalse(selection.contains(c, lead: b))
    }

    // MARK: - Command-click

    func testCommandClickAddsWithoutMovingTheLead() {
        var selection = SessionSelection()
        selection.collapse(to: b)
        let lead = selection.toggle(d, lead: b, in: rows)
        XCTAssertEqual(lead, b, "adding a row is not looking at it")
        XCTAssertEqual(selection.members(lead: lead), [b, d])
        XCTAssertTrue(selection.isMultiple)
    }

    func testCommandClickRemovesARow() {
        var selection = SessionSelection()
        selection.collapse(to: b)
        _ = selection.toggle(d, lead: b, in: rows)
        _ = selection.toggle(e, lead: b, in: rows)
        let lead = selection.toggle(d, lead: b, in: rows)
        XCTAssertEqual(lead, b)
        XCTAssertEqual(selection.members(lead: b), [b, e])
    }

    func testRemovingTheLeadHandsItToTheNearestSelectedRow() {
        var selection = SessionSelection()
        selection.collapse(to: c)
        _ = selection.toggle(a, lead: c, in: rows)
        _ = selection.toggle(d, lead: c, in: rows)
        let lead = selection.toggle(c, lead: c, in: rows)
        XCTAssertEqual(lead, d, "below first, as the git panel's does")
        XCTAssertEqual(selection.members(lead: lead), [a, d])
    }

    func testRemovingDownToOneRowIsTheRestingState() {
        var selection = SessionSelection()
        selection.collapse(to: b)
        _ = selection.toggle(d, lead: b, in: rows)
        let lead = selection.toggle(d, lead: b, in: rows)
        XCTAssertEqual(lead, b)
        XCTAssertFalse(selection.isMultiple)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testCommandClickOnTheOnlySelectedRowDoesNothing() {
        var selection = SessionSelection()
        selection.collapse(to: b)
        let lead = selection.toggle(b, lead: b, in: rows)
        XCTAssertEqual(lead, b, "there is always a session on screen")
        XCTAssertEqual(selection.members(lead: lead), [b])
    }

    // MARK: - Shift-click

    func testShiftClickTakesTheRangeFromTheAnchorAcrossSections() {
        var selection = SessionSelection()
        selection.collapse(to: b)
        selection.extend(to: e, lead: b, in: rows)
        XCTAssertEqual(selection.ordered(in: rows, lead: b), [b, c, d, e])
    }

    func testShiftClickAgainShrinksFromTheSameAnchor() {
        var selection = SessionSelection()
        selection.collapse(to: b)
        selection.extend(to: e, lead: b, in: rows)
        selection.extend(to: c, lead: b, in: rows)
        XCTAssertEqual(selection.ordered(in: rows, lead: b), [b, c])
        selection.extend(to: a, lead: b, in: rows)
        XCTAssertEqual(selection.ordered(in: rows, lead: b), [a, b], "the anchor stayed on b")
    }

    func testShiftClickKeepsTheLeadOutsideTheRange() {
        var selection = SessionSelection()
        selection.collapse(to: a)
        _ = selection.toggle(c, lead: a, in: rows)   // anchor moves to c
        selection.extend(to: e, lead: a, in: rows)
        XCTAssertEqual(selection.ordered(in: rows, lead: a), [a, c, d, e])
    }

    func testShiftClickWithAnAnchorNoLongerDrawnMeasuresFromTheLead() {
        var selection = SessionSelection()
        selection.collapse(to: a)
        _ = selection.toggle(b, lead: a, in: rows)   // anchor b
        selection.extend(to: d, lead: a, in: [a, c, d, e])  // b folded away
        XCTAssertEqual(selection.ordered(in: rows, lead: a), [a, c, d])
        XCTAssertEqual(selection.anchor, a)
    }

    func testShiftClickOnTheLeadIsOneRow() {
        var selection = SessionSelection()
        selection.collapse(to: c)
        selection.extend(to: c, lead: c, in: rows)
        XCTAssertFalse(selection.isMultiple)
    }

    // MARK: - Collapse and prune

    func testCollapseMovesTheAnchorToTheLead() {
        var selection = SessionSelection()
        selection.collapse(to: a)
        _ = selection.toggle(c, lead: a, in: rows)
        selection.collapse(to: e)   // ⌘5, say
        XCTAssertFalse(selection.isMultiple)
        selection.extend(to: d, lead: e, in: rows)
        XCTAssertEqual(selection.ordered(in: rows, lead: e), [d, e], "measured from where you are")
    }

    func testPruneDropsRowsThatAreGoneAndKeepsTheLead() {
        var selection = SessionSelection()
        selection.collapse(to: a)
        selection.extend(to: d, lead: a, in: rows)
        selection.prune(to: [a, b, e], lead: a)
        XCTAssertEqual(selection.ordered(in: rows, lead: a), [a, b])
    }

    func testPruneDownToTheLeadIsTheRestingState() {
        var selection = SessionSelection()
        selection.collapse(to: a)
        _ = selection.toggle(d, lead: a, in: rows)
        selection.prune(to: [a, b, c], lead: a)
        XCTAssertFalse(selection.isMultiple)
    }

    func testOrderedFollowsTheDrawnOrderNotTheClickOrder() {
        var selection = SessionSelection()
        selection.collapse(to: e)
        _ = selection.toggle(a, lead: e, in: rows)
        _ = selection.toggle(c, lead: e, in: rows)
        XCTAssertEqual(selection.ordered(in: rows, lead: e), [a, c, e])
    }
}
