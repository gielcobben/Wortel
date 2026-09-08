import XCTest

/// The changes list's selection, which is the input to Discard.
///
/// Every failure this type can have is silent: it selects the wrong rows, the
/// list highlights exactly what it selected, and the confirmation counts exactly
/// what it highlighted. Nothing is inconsistent, nothing throws, and the report
/// afterwards is a file the reader never pointed at. So the rules are pinned
/// here, over plain ids, with no repo or window in sight.
final class ChangeSelectionTests: XCTestCase {
    /// The list as drawn: staged section first, then the working tree — one
    /// continuous run, which is what a ⇧-click walks.
    private let rows = ["S:a", "S:b", "W:a", "W:c", "W:d"]

    // MARK: - Click

    func testPlainClickSelectsOneRow() {
        var selection = ChangeSelection()
        selection.select("W:c")
        XCTAssertEqual(selection.ids, ["W:c"])
        XCTAssertEqual(selection.lead, "W:c")
        XCTAssertEqual(selection.count, 1)
        XCTAssertFalse(selection.isMultiple)
    }

    func testPlainClickReplacesAWholeSelection() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.extend(to: "W:d", in: rows)
        XCTAssertEqual(selection.count, 5)

        selection.select("W:c")
        XCTAssertEqual(selection.ids, ["W:c"], "an unmodified click starts over")
    }

    func testSelectingNothingClearsEverything() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.select(nil)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.lead)
        XCTAssertNil(selection.anchor)
    }

    // MARK: - Command-click

    func testCommandClickAddsAndRemovesOneRow() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.toggle("W:c", in: rows)
        XCTAssertEqual(selection.ids, ["S:a", "W:c"])
        XCTAssertEqual(selection.lead, "W:c", "the row you just added is the one to show")

        selection.toggle("S:a", in: rows)
        XCTAssertEqual(selection.ids, ["W:c"])
    }

    /// The diff pane is showing the lead. Deselecting it has to hand the pane to
    /// a row that is still highlighted, or the panel shows a patch for a file
    /// that is no longer part of what the next action will take.
    func testDeselectingTheLeadMovesItToTheNearestSelectedRow() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.toggle("W:c", in: rows)
        selection.toggle("W:d", in: rows)
        XCTAssertEqual(selection.lead, "W:d")

        selection.toggle("W:d", in: rows)
        XCTAssertEqual(selection.lead, "W:c", "the nearest still-selected row, not the first")
        XCTAssertTrue(selection.contains(selection.lead!))
    }

    func testDeselectingTheLastRowEmptiesTheSelection() {
        var selection = ChangeSelection()
        selection.select("S:b")
        selection.toggle("S:b", in: rows)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.lead)
    }

    // MARK: - Shift-click

    func testShiftClickTakesTheRangeFromTheAnchorInEitherDirection() {
        var selection = ChangeSelection()
        selection.select("W:a")
        selection.extend(to: "W:d", in: rows)
        XCTAssertEqual(selection.ids, ["W:a", "W:c", "W:d"])

        selection.select("W:d")
        selection.extend(to: "W:a", in: rows)
        XCTAssertEqual(selection.ids, ["W:a", "W:c", "W:d"], "upward reads the same range")
    }

    /// The two sections are one list to a mouse dragging down it, so a range
    /// that starts in Staged Changes and ends below the divider takes the rows
    /// in between. What each row *means* stays per row; this is only about which
    /// rows are in.
    func testARangeCanSpanBothSections() {
        var selection = ChangeSelection()
        selection.select("S:b")
        selection.extend(to: "W:c", in: rows)
        XCTAssertEqual(selection.ids, ["S:b", "W:a", "W:c"])
    }

    /// The reason the anchor exists. Extending twice must measure from where the
    /// range started, not from where the last one landed, or a range can only
    /// ever grow and there is no way to take a row back off it.
    func testASecondShiftClickReMeasuresFromTheAnchorAndCanShrink() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.extend(to: "W:d", in: rows)
        XCTAssertEqual(selection.count, 5)

        selection.extend(to: "S:b", in: rows)
        XCTAssertEqual(selection.ids, ["S:a", "S:b"], "the anchor stayed at S:a")
        XCTAssertEqual(selection.anchor, "S:a")
    }

    func testShiftClickWithNoAnchorIsJustAClick() {
        var selection = ChangeSelection()
        selection.extend(to: "W:c", in: rows)
        XCTAssertEqual(selection.ids, ["W:c"])
        XCTAssertEqual(selection.anchor, "W:c")
    }

    /// ⌘-click sets the anchor, so the ⇧-click after it measures from the row
    /// the reader last touched rather than from wherever the run began.
    func testCommandClickMovesTheAnchor() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.toggle("W:a", in: rows)
        selection.extend(to: "W:d", in: rows)
        XCTAssertEqual(selection.ids, ["W:a", "W:c", "W:d"])
    }

    // MARK: - Keyboard

    func testArrowsMoveOneRowAndClampAtTheEnds() {
        var selection = ChangeSelection()
        selection.select("S:a")

        XCTAssertTrue(selection.move(by: 1, in: rows, extending: false))
        XCTAssertEqual(selection.ids, ["S:b"])
        XCTAssertTrue(selection.move(by: -1, in: rows, extending: false))
        XCTAssertEqual(selection.lead, "S:a")
        XCTAssertFalse(selection.move(by: -1, in: rows, extending: false),
                       "the top row has nowhere to go, and reports it")
    }

    func testArrowsWithNothingSelectedStartAtTheTop() {
        var selection = ChangeSelection()
        XCTAssertTrue(selection.move(by: 1, in: rows, extending: false))
        XCTAssertEqual(selection.ids, ["S:a"])
    }

    func testShiftArrowGrowsTheSelectionAndReversingShrinksItBack() {
        var selection = ChangeSelection()
        selection.select("W:a")
        selection.move(by: 1, in: rows, extending: true)
        selection.move(by: 1, in: rows, extending: true)
        XCTAssertEqual(selection.ids, ["W:a", "W:c", "W:d"])

        // The row it steps back off has to leave the selection. Adding rows as
        // you pass them instead would leave W:d selected below the lead, with
        // nothing on screen explaining why it's still highlighted.
        selection.move(by: -1, in: rows, extending: true)
        XCTAssertEqual(selection.ids, ["W:a", "W:c"])
        XCTAssertEqual(selection.lead, "W:c")
    }

    func testSelectAllTakesEveryRowAndKeepsTheLeadWhereItWas() {
        var selection = ChangeSelection()
        selection.select("W:c")
        selection.selectAll(in: rows)
        XCTAssertEqual(selection.ids, Set(rows))
        XCTAssertEqual(selection.lead, "W:c", "⌘A must not move the diff you were reading")
    }

    func testSelectAllOnAnEmptyListChangesNothing() {
        var selection = ChangeSelection()
        selection.selectAll(in: [])
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: - Ordering

    func testOrderedReportsTheSelectionInListOrder() {
        var selection = ChangeSelection()
        selection.select("W:d")
        selection.toggle("S:a", in: rows)
        selection.toggle("W:a", in: rows)
        XCTAssertEqual(selection.ordered(in: rows), ["S:a", "W:a", "W:d"])
    }

    // MARK: - Refresh

    /// Every action ends in a `git status`, and the rows it consumed come back
    /// gone. A stale id left behind is a row the *next* bulk action would take
    /// without it ever being highlighted again.
    func testPruneDropsRowsThatNoLongerExist() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.extend(to: "W:c", in: rows)
        XCTAssertEqual(selection.count, 4)

        // "S:a" and "S:b" were committed; "W:a" was discarded.
        selection.prune(to: ["W:c", "W:d"])
        XCTAssertEqual(selection.ids, ["W:c"])
        XCTAssertEqual(selection.lead, "W:c")
    }

    func testPruneMovesTheLeadToASurvivingRow() {
        var selection = ChangeSelection()
        selection.select("W:a")
        selection.toggle("W:d", in: rows)
        XCTAssertEqual(selection.lead, "W:d")

        selection.prune(to: ["S:a", "W:a"])
        XCTAssertEqual(selection.lead, "W:a")
        XCTAssertEqual(selection.anchor, "W:a", "a discarded anchor can't measure a range")
    }

    func testPruningEverythingLeavesNothingBehind() {
        var selection = ChangeSelection()
        selection.selectAll(in: rows)
        selection.prune(to: [])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.lead)
        XCTAssertNil(selection.anchor)
    }

    /// After a prune has dropped the anchor, the next ⇧-click has to measure
    /// from somewhere real rather than reviving a row that is gone.
    func testExtendingAfterAPruneMeasuresFromTheSurvivingLead() {
        var selection = ChangeSelection()
        selection.select("S:a")
        selection.extend(to: "S:b", in: rows)
        selection.prune(to: ["S:b", "W:a", "W:c"])
        XCTAssertEqual(selection.anchor, "S:b")

        selection.extend(to: "W:c", in: ["S:b", "W:a", "W:c"])
        XCTAssertEqual(selection.ids, ["S:b", "W:a", "W:c"])
    }
}
