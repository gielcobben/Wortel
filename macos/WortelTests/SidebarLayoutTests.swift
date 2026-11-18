import XCTest

/// How the sidebar groups sessions, in what order, and where a dragged folder
/// or session lands. Every way it can be wrong is silent: a session filed in
/// the wrong folder is also renamed (its folder is its name before the last
/// slash), and the manager saves that. These pin what the code does today.
final class SidebarLayoutTests: XCTestCase {
    private typealias Row = SidebarLayout.Row<Int>
    private typealias Group = SidebarLayout.Group<Int>

    private func row(_ id: Int, _ folder: String? = nil) -> Row { Row(id: id, folder: folder) }

    private func groups(_ rows: [Row], pinned: [Int] = [], folderOrder: [String] = [],
                        declared: [String] = []) -> [Group] {
        SidebarLayout.groups(rows: rows, pinned: pinned, folderOrder: folderOrder,
                             declaredFolders: declared)
    }

    // MARK: - groups

    func testPinnedComeFirstInPinnedOrderAndLeaveTheirFolders() {
        let result = groups([row(1), row(2, "a"), row(3, "a"), row(4)],
                            pinned: [3, 1], folderOrder: ["a"])
        XCTAssertEqual(result, [
            Group(folder: nil, ids: [3, 1], isPinned: true),
            Group(folder: nil, ids: [4]),
            Group(folder: "a", ids: [2]),
        ])
    }

    func testPinnedIDWithNoRowIsSkipped() {
        XCTAssertEqual(groups([row(1), row(2)], pinned: [9, 2]), [
            Group(folder: nil, ids: [2], isPinned: true),
            Group(folder: nil, ids: [1]),
        ])
        XCTAssertEqual(groups([row(1), row(2)], pinned: [9]), [
            Group(folder: nil, ids: [1, 2]),
        ], "no Pinned section when none of its ids has a row")
    }

    // Pins current behaviour; possibly unintended: a duplicated pinned id is
    // drawn twice in Pinned. Nothing is known to write one.
    func testDuplicatePinnedIDIsKept() {
        XCTAssertEqual(groups([row(1), row(2)], pinned: [1, 1]), [
            Group(folder: nil, ids: [1, 1], isPinned: true),
            Group(folder: nil, ids: [2]),
        ])
    }

    func testTopLevelGroupOnlyWhenItHasRows() {
        XCTAssertEqual(groups([row(1, "a")], folderOrder: ["a"]), [
            Group(folder: "a", ids: [1]),
        ])
        XCTAssertEqual(groups([row(1), row(2, "a")], pinned: [1], folderOrder: ["a"]), [
            Group(folder: nil, ids: [1], isPinned: true),
            Group(folder: "a", ids: [2]),
        ], "a top level whose only rows are pinned isn't drawn empty")
    }

    func testNoRowsNoGroups() {
        XCTAssertEqual(groups([], pinned: [1], folderOrder: ["a"]), [])
    }

    func testFoldersFollowFolderOrder() {
        let result = groups([row(1, "a"), row(2, "b"), row(3, "c")], folderOrder: ["c", "a", "b"])
        XCTAssertEqual(result.map(\.folder), ["c", "a", "b"])
    }

    func testUntrackedFolderFollowsByFirstAppearanceAmongRows() {
        let result = groups([row(1, "b"), row(2, "x"), row(3, "a"), row(4, "y"), row(5, "x")],
                            folderOrder: ["a", "b"])
        XCTAssertEqual(result, [
            Group(folder: "a", ids: [3]),
            Group(folder: "b", ids: [1]),
            Group(folder: "x", ids: [2, 5]),
            Group(folder: "y", ids: [4]),
        ])
    }

    func testFolderInFolderOrderThatDoesNotExistIsSkipped() {
        XCTAssertEqual(groups([row(1, "a")], folderOrder: ["gone", "a"]), [
            Group(folder: "a", ids: [1]),
        ])
    }

    /// The likeliest slip: emitting declared folders before the rows' folders.
    /// "e" is declared before "b" here, and must still come after it.
    func testDeclaredEmptyFolderAppearsLast() {
        XCTAssertEqual(groups([row(1, "a"), row(2, "b")], declared: ["e", "b"]), [
            Group(folder: "a", ids: [1]),
            Group(folder: "b", ids: [2]),
            Group(folder: "e", ids: []),
        ])
    }

    func testDeclaredEmptyFolderInFolderOrderKeepsItsPlaceOnce() {
        XCTAssertEqual(groups([row(1, "a"), row(2, "b")], folderOrder: ["e", "a"], declared: ["e"]), [
            Group(folder: "e", ids: []),
            Group(folder: "a", ids: [1]),
            Group(folder: "b", ids: [2]),
        ])
    }

    func testFolderWhoseOnlySessionsArePinnedStaysEmpty() {
        XCTAssertEqual(groups([row(1, "a"), row(2, "b")], pinned: [1], folderOrder: ["a", "b"]), [
            Group(folder: nil, ids: [1], isPinned: true),
            Group(folder: "a", ids: []),
            Group(folder: "b", ids: [2]),
        ])
        // Untracked, it takes the place of its pinned row's first appearance.
        XCTAssertEqual(groups([row(2, "b"), row(1, "a")], pinned: [1]), [
            Group(folder: nil, ids: [1], isPinned: true),
            Group(folder: "b", ids: [2]),
            Group(folder: "a", ids: []),
        ])
    }

    func testRowsKeepTheirArrayOrderWithinAGroup() {
        let result = groups([row(3, "a"), row(1), row(2, "a"), row(5), row(4, "a")])
        XCTAssertEqual(result, [
            Group(folder: nil, ids: [1, 5]),
            Group(folder: "a", ids: [3, 2, 4]),
        ])
    }

    // MARK: - syncedFolderOrder

    private func synced(_ order: [String], _ rows: [Row], declared: [String] = [],
                        archived: [String] = []) -> [String] {
        SidebarLayout.syncedFolderOrder(order, rows: rows, declaredFolders: declared,
                                        archivedFolders: archived)
    }

    func testSyncDropsVanishedAndAppendsNewByFirstAppearance() {
        let rows = [row(1, "c"), row(2, "a"), row(3, "b"), row(4, "d"), row(5, "c"), row(6)]
        XCTAssertEqual(synced(["b", "gone", "a"], rows), ["b", "a", "c", "d"])
    }

    func testSyncDeduplicates() {
        XCTAssertEqual(synced(["a", "b", "a"], [row(1, "a"), row(2, "b")]), ["a", "b"])
    }

    func testSyncKeepsAFolderThatExistsOnlyInArchived() {
        XCTAssertEqual(synced(["z", "a"], [row(1, "a")], archived: ["z"]), ["z", "a"])
    }

    /// New folders are appended rows first, then declared, then archived.
    func testSyncAppendsRowsThenDeclaredThenArchived() {
        XCTAssertEqual(synced([], [row(1, "a")], declared: ["d"], archived: ["z", "a"]),
                       ["a", "d", "z"])
    }

    func testSyncReturnsAnAlreadyCorrectOrderUnchanged() {
        XCTAssertEqual(synced(["a", "b"], [row(1, "a"), row(2, "b")]), ["a", "b"])
        XCTAssertEqual(synced(["b", "a"], [row(1, "a"), row(2, "b")]), ["b", "a"],
                       "the user's arrangement wins over first appearance")
    }

    func testSyncWithNoFoldersIsEmpty() {
        XCTAssertEqual(synced(["a"], [row(1)]), [])
    }

    // MARK: - movingFolder

    private let order = ["a", "b", "c", "d"]

    /// The likeliest slip: forgetting that the drop index counted the folder's
    /// own slot. Dropped between c and d, "a" lands between c and d, not last.
    func testMovingDownPastItselfLandsWhereDropped() {
        XCTAssertEqual(SidebarLayout.movingFolder("a", to: 3, in: order), ["b", "c", "a", "d"])
    }

    func testMovingUp() {
        XCTAssertEqual(SidebarLayout.movingFolder("c", to: 0, in: order), ["c", "a", "b", "d"])
        XCTAssertEqual(SidebarLayout.movingFolder("d", to: 1, in: order), ["a", "d", "b", "c"])
    }

    func testMovingToTheEndClamps() {
        XCTAssertEqual(SidebarLayout.movingFolder("b", to: 4, in: order), ["a", "c", "d", "b"])
        XCTAssertEqual(SidebarLayout.movingFolder("a", to: 99, in: order), ["b", "c", "d", "a"])
    }

    func testANegativeIndexClampsToTheStart() {
        XCTAssertEqual(SidebarLayout.movingFolder("c", to: -5, in: order), ["c", "a", "b", "d"])
    }

    func testMovingToItsOwnPlaceReturnsTheSameOrder() {
        // Just above itself, and just below itself: both its own slot.
        XCTAssertEqual(SidebarLayout.movingFolder("b", to: 1, in: order), order)
        XCTAssertEqual(SidebarLayout.movingFolder("b", to: 2, in: order), order)
    }

    func testMovingAnUnknownFolderIsNil() {
        XCTAssertNil(SidebarLayout.movingFolder("x", to: 0, in: order))
        XCTAssertNil(SidebarLayout.movingFolder("a", to: 0, in: []))
    }

    // MARK: - insertionIndex

    private let rest = [Row(id: 1, folder: nil), Row(id: 2, folder: "a"), Row(id: 3, folder: "a"),
                        Row(id: 4, folder: "b"), Row(id: 5, folder: nil)]

    private func index(_ rest: [Row], folder: String?, before: Int? = nil,
                       pinned: Set<Int> = []) -> Int {
        SidebarLayout.insertionIndex(in: rest, folder: folder, before: before, pinned: pinned)
    }

    func testInsertsJustBeforeANamedRow() {
        XCTAssertEqual(index(rest, folder: "a", before: 3), 2)
        XCTAssertEqual(index(rest, folder: nil, before: 1), 0)
        XCTAssertEqual(index(rest, folder: "a", before: 4), 3,
                       "the named row wins even when it is in another folder")
    }

    func testIntoAFolderGoesAfterItsLastMember() {
        XCTAssertEqual(index(rest, folder: "a"), 3)
        XCTAssertEqual(index(rest, folder: nil), 5, "the top level's last row is at the end")
    }

    func testIntoAFolderNoneOfRestIsInGoesToTheEnd() {
        XCTAssertEqual(index(rest, folder: "new"), 5)
        XCTAssertEqual(index([], folder: "a"), 0)
    }

    func testBeforeARowNotInRestFallsThroughToTheFolderRule() {
        XCTAssertEqual(index(rest, folder: "a", before: 99), 3)
        XCTAssertEqual(index(rest, folder: "new", before: 99), 5)
    }

    /// The likeliest slip: counting a pinned row as the folder's last member,
    /// which would land the moved rows after it (index 2, not 1).
    func testPinnedRowsOfTheFolderAreNotItsLastMember() {
        let rest = [row(1, "a"), row(2, "a"), row(3, "b")]
        XCTAssertEqual(index(rest, folder: "a", pinned: [2]), 1)
        XCTAssertEqual(index(rest, folder: "a", pinned: [1, 2]), 3,
                       "a folder whose rows are all pinned has no member to follow")
    }

    func testBeforeNamingAPinnedRowStillWins() {
        let rest = [row(1, "a"), row(2, "a"), row(3, "b")]
        XCTAssertEqual(index(rest, folder: "a", before: 2, pinned: [2]), 1)
    }

    // MARK: - A new session

    /// The stored order with the new row put where `indexForNew` says, then
    /// drawn: the test reads the sidebar, not an index.
    private func drawn(adding new: Int, inFolder folder: String?, to rows: [Row], selected: Int?,
                       pinned: [Int] = [], folderOrder: [String] = []) -> [Group] {
        var rows = rows
        rows.insert(row(new, folder), at: SidebarLayout.indexForNew(
            inFolder: folder, rows: rows, selected: selected, pinned: pinned))
        return groups(rows, pinned: pinned, folderOrder: folderOrder)
    }

    func testANewTopLevelSessionGoesOnTop() {
        let result = drawn(adding: 9, inFolder: nil, to: [row(1), row(2), row(3)], selected: 2)
        XCTAssertEqual(result, [Group(folder: nil, ids: [9, 1, 2, 3])],
                       "newest first, wherever the selection was")
    }

    func testANewTopLevelSessionGoesUnderPinnedAndAboveTheFolders() {
        let result = drawn(adding: 9, inFolder: nil, to: [row(1), row(2), row(3, "a")], selected: 3,
                           pinned: [1], folderOrder: ["a"])
        XCTAssertEqual(result, [
            Group(folder: nil, ids: [1], isPinned: true),
            Group(folder: nil, ids: [9, 2]),
            Group(folder: "a", ids: [3]),
        ])
    }

    func testANewSessionInAFolderGoesAfterTheSelectedRow() {
        let result = drawn(adding: 9, inFolder: "a", to: [row(1, "a"), row(2, "a"), row(3, "a")],
                           selected: 2, folderOrder: ["a"])
        XCTAssertEqual(result, [Group(folder: "a", ids: [1, 2, 9, 3])],
                       "a folder is arranged by hand: the new row sits beside the one it came from")
    }

    func testANewSessionInAnotherFolderGoesAtItsEnd() {
        let result = drawn(adding: 9, inFolder: "b", to: [row(1, "a"), row(2, "b"), row(3, "b")],
                           selected: 1, folderOrder: ["a", "b"])
        XCTAssertEqual(result, [Group(folder: "a", ids: [1]), Group(folder: "b", ids: [2, 3, 9])])
    }

    func testAPinnedSelectionIsNoAnchorInItsFolder() {
        let result = drawn(adding: 9, inFolder: "a", to: [row(1, "a"), row(2, "a"), row(3, "a")],
                           selected: 1, pinned: [1], folderOrder: ["a"])
        XCTAssertEqual(result, [
            Group(folder: nil, ids: [1], isPinned: true),
            Group(folder: "a", ids: [2, 3, 9]),
        ])
    }

    func testTheFirstSessionOfAll() {
        XCTAssertEqual(SidebarLayout.indexForNew(inFolder: nil, rows: [Row](), selected: nil, pinned: []), 0)
        XCTAssertEqual(SidebarLayout.indexForNew(inFolder: "a", rows: [Row](), selected: nil, pinned: []), 0)
    }
}
