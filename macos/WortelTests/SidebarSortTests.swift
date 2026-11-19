import XCTest

/// Sort Unread First, which draws a section in an order that isn't the one
/// stored. Its failures are all a row in the wrong place, or a row moving
/// while you reach for it, so the rules are pinned here over plain ids.
final class SidebarSortTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func key(_ kind: AttentionKind?, _ seconds: TimeInterval) -> SidebarSort.Key {
        .init(rank: kind?.priority ?? 0, since: t0.addingTimeInterval(seconds))
    }

    // MARK: - The sort

    func testNothingUnreadKeepsTheManualOrder() {
        XCTAssertEqual(SidebarSort.sorted([a, b, c], keys: [:]), [a, b, c])
    }

    func testUnreadComeFirstAndTheRestKeepTheirOrder() {
        let order = SidebarSort.sorted([a, b, c, d], keys: [c: key(.finished, 0)])
        XCTAssertEqual(order, [c, a, b, d])
    }

    func testLouderKindsBeforeQuieterOnes() {
        let keys = [a: key(.finished, 50), b: key(.needsInput, 0), c: key(.turnDone, 30), d: key(.failed, 10)]
        XCTAssertEqual(SidebarSort.sorted([a, b, c, d, e], keys: keys), [b, d, c, a, e])
    }

    func testAHollowRingSortsAfterEveryLiveDot() {
        let keys = [a: key(nil, 100), b: key(.finished, 0)]
        XCTAssertEqual(SidebarSort.sorted([a, b, c], keys: keys), [b, a, c])
    }

    func testMostRecentFirstAmongEquals() {
        let keys = [a: key(.turnDone, 10), b: key(.turnDone, 30), c: key(.turnDone, 20)]
        XCTAssertEqual(SidebarSort.sorted([a, b, c], keys: keys), [b, c, a])
    }

    func testManualOrderBreaksAFullTie() {
        let keys = [c: key(.turnDone, 10), a: key(.turnDone, 10)]
        XCTAssertEqual(SidebarSort.sorted([a, b, c], keys: keys), [a, c, b])
    }

    // MARK: - Holding the selected row

    func testFirstDrawIsAPlainSort() {
        let order = SidebarSort.order(manual: [a, b, c], keys: [c: key(.finished, 0)],
                                      previous: nil, holding: a, frozen: false)
        XCTAssertEqual(order, [c, a, b], "turning the sort on sorts afresh, selection or not")
    }

    func testTheSelectedRowHoldsItsPlaceOnceRead() {
        // c was unread and drawn first; selecting it read it.
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [c, a, b], keys: [c: key(.finished, 0)])
        let order = SidebarSort.order(manual: [a, b, c], keys: [:], previous: previous, holding: c, frozen: false)
        XCTAssertEqual(order, [c, a, b])
    }

    func testTheRowGoesHomeOnceSelectionLeavesIt() {
        let first = SidebarSort.Drawn(manual: [a, b, c], drawn: [c, a, b], keys: [c: key(.finished, 0)])
        let held = SidebarSort.draw(manual: [a, b, c], keys: [:], previous: first, holding: c, frozen: false)
        XCTAssertEqual(held.drawn, [c, a, b])
        let left = SidebarSort.order(manual: [a, b, c], keys: [:], previous: held, holding: a, frozen: false)
        XCTAssertEqual(left, [a, b, c], "a and b close up behind it; neither is reshuffled")
    }

    func testTheHeldRowKeepsHoldingAcrossDraws() {
        var drawn = SidebarSort.Drawn(manual: [a, b, c], drawn: [c, a, b], keys: [c: key(.turnDone, 0)])
        for _ in 0..<3 {
            drawn = SidebarSort.draw(manual: [a, b, c], keys: [:], previous: drawn, holding: c, frozen: false)
        }
        XCTAssertEqual(drawn.drawn, [c, a, b])
    }

    func testOthersStillSortAroundTheHeldRow() {
        let previous = SidebarSort.Drawn(manual: [a, b, c, d], drawn: [c, a, b, d], keys: [c: key(.turnDone, 0)])
        let order = SidebarSort.order(manual: [a, b, c, d], keys: [d: key(.needsInput, 5)],
                                      previous: previous, holding: c, frozen: false)
        XCTAssertEqual(order, [d, c, a, b], "a louder arrival goes above it, as it would anyway")
    }

    func testASessionMarkedUnreadWhileSelectedWaitsUntilYouLeave() {
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [a, b, c], keys: [:])
        let held = SidebarSort.draw(manual: [a, b, c], keys: [c: key(nil, 0)], previous: previous,
                                    holding: c, frozen: false)
        XCTAssertEqual(held.drawn, [a, b, c])
        let left = SidebarSort.order(manual: [a, b, c], keys: [c: key(nil, 0)], previous: held,
                                     holding: a, frozen: false)
        XCTAssertEqual(left, [c, a, b])
    }

    func testAHeldRowKeepsHoldingWhenARowCloses() {
        let previous = SidebarSort.Drawn(manual: [a, b, c, d], drawn: [c, a, b, d], keys: [c: key(.finished, 0)])
        let order = SidebarSort.order(manual: [b, c, d], keys: [:], previous: previous, holding: c, frozen: false)
        XCTAssertEqual(order, [c, b, d])
    }

    func testANewRowDoesNotUnholdTheSelectedOne() {
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [c, a, b], keys: [c: key(.finished, 0)])
        let order = SidebarSort.order(manual: [a, b, c, d], keys: [:], previous: previous, holding: c, frozen: false)
        XCTAssertEqual(order, [c, a, b, d])
    }

    func testADragDrawsAfresh() {
        // The user dragged a below c: the held row is drawn where the drop put it.
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [c, a, b], keys: [c: key(.finished, 0)])
        let order = SidebarSort.order(manual: [b, c, a], keys: [:], previous: previous, holding: c, frozen: false)
        XCTAssertEqual(order, [b, c, a])
    }

    // MARK: - Frozen under the pointer

    func testFrozenKeepsTheWholeSectionAsDrawn() {
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [a, b, c])
        let order = SidebarSort.order(manual: [a, b, c], keys: [c: key(.needsInput, 0)],
                                      previous: previous, holding: a, frozen: true)
        XCTAssertEqual(order, [a, b, c], "nothing moves while a click may be coming")
    }

    func testFrozenStillDrawsARowThatArrived() {
        let previous = SidebarSort.Drawn(manual: [a, b], drawn: [a, b])
        let order = SidebarSort.order(manual: [a, b, c], keys: [:], previous: previous, holding: nil, frozen: true)
        XCTAssertEqual(order, [a, b, c])
    }

    func testFrozenDoesNotHoldBackADrop() {
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [a, b, c])
        let order = SidebarSort.order(manual: [b, a, c], keys: [:], previous: previous, holding: nil, frozen: true)
        XCTAssertEqual(order, [b, a, c])
    }

    func testThawingCatchesUp() {
        let previous = SidebarSort.Drawn(manual: [a, b, c], drawn: [a, b, c])
        let order = SidebarSort.order(manual: [a, b, c], keys: [c: key(.needsInput, 0)],
                                      previous: previous, holding: a, frozen: false)
        XCTAssertEqual(order, [c, a, b])
    }

    func testAClickWhileFrozenStillHoldsOnceThawed() {
        // c unread on top; the pointer is on it and the click reads it.
        let before = SidebarSort.Drawn(manual: [a, b, c], drawn: [c, a, b], keys: [c: key(.turnDone, 0)])
        let frozen = SidebarSort.draw(manual: [a, b, c], keys: [:], previous: before, holding: c, frozen: true)
        XCTAssertEqual(frozen.drawn, [c, a, b])
        // The pointer leaves: c is still the selected row, and still holds.
        let thawed = SidebarSort.order(manual: [a, b, c], keys: [:], previous: frozen, holding: c, frozen: false)
        XCTAssertEqual(thawed, [c, a, b])
    }

    // MARK: - A section's own order beneath the band

    func testTheBandSitsOverTheSectionsOwnOrder() {
        let drawn = SidebarSort.draw(manual: [a, b, c, d], base: [d, c, b, a], keys: [b: key(.finished, 0)],
                                     previous: nil, holding: nil, frozen: false)
        XCTAssertEqual(drawn.drawn, [b, d, c, a])
    }

    func testWithNoBandTheSectionsOwnOrderIsDrawn() {
        let drawn = SidebarSort.draw(manual: [a, b, c], base: [c, a, b], keys: [:],
                                     previous: nil, holding: nil, frozen: false)
        XCTAssertEqual(drawn.drawn, [c, a, b])
    }

    /// A Return in another session moved it up while the pointer rests on a
    /// row: nothing slides under the pointer, and it catches up after.
    func testASectionsOwnOrderWaitsWhileAClickMayBeComing() {
        let before = SidebarSort.draw(manual: [a, b, c], base: [a, b, c], keys: [:],
                                      previous: nil, holding: b, frozen: false)
        let held = SidebarSort.draw(manual: [a, b, c], base: [c, a, b], keys: [:],
                                    previous: before, holding: b, frozen: true)
        XCTAssertEqual(held.drawn, [a, b, c])
        let thawed = SidebarSort.order(manual: [a, b, c], base: [c, a, b], keys: [:],
                                       previous: held, holding: b, frozen: false)
        XCTAssertEqual(thawed, [c, a, b])
    }

    /// The selected row isn't held in its own order: a Return in it moves it
    /// to the top, as sending a message moves a chat up.
    func testTheSelectedRowFollowsItsSectionsOwnOrder() {
        let before = SidebarSort.draw(manual: [a, b, c], base: [a, b, c], keys: [:],
                                      previous: nil, holding: c, frozen: false)
        let after = SidebarSort.order(manual: [a, b, c], base: [c, a, b], keys: [:],
                                      previous: before, holding: c, frozen: false)
        XCTAssertEqual(after, [c, a, b])
    }

    func testADragInAManualSectionIsDrawnAtOnceEvenFrozen() {
        let before = SidebarSort.draw(manual: [a, b, c], keys: [:], previous: nil, holding: nil, frozen: false)
        let after = SidebarSort.draw(manual: [c, a, b], keys: [:], previous: before, holding: nil, frozen: true)
        XCTAssertEqual(after.drawn, [c, a, b])
    }
}
