import XCTest

/// The sidebar outline's root level by index. Every way it's wrong is silent:
/// the outline draws the wrong row, or a drop files a session in the wrong
/// section, which renames it.
final class SidebarRootTests: XCTestCase {
    private func slots(_ root: SidebarRoot) -> [SidebarRoot.Slot?] {
        (0..<root.count).map(root.slot(at:))
    }

    func testEverythingThereInOrder() {
        let root = SidebarRoot(pinned: true, folders: 2, loose: true, looseShown: 3)
        XCTAssertEqual(root.count, 7)
        XCTAssertEqual(slots(root), [.pinnedHeader, .folder(0), .folder(1), .looseHeader,
                                     .loose(0), .loose(1), .loose(2)])
        XCTAssertEqual(root.looseHeader, 3)
        XCTAssertEqual(root.looseRows, 4..<7)
        XCTAssertNil(root.slot(at: 7))
        XCTAssertNil(root.slot(at: -1))
    }

    func testNoPinned() {
        let root = SidebarRoot(pinned: false, folders: 1, loose: true, looseShown: 1)
        XCTAssertEqual(slots(root), [.folder(0), .looseHeader, .loose(0)])
        XCTAssertEqual(root.rootIndex(ofFolder: 0), 0)
        XCTAssertEqual(root.rootIndex(ofLoose: 0), 2)
    }

    func testSessionsFoldedKeepsItsHeader() {
        let root = SidebarRoot(pinned: true, folders: 1, loose: true, looseShown: 0)
        XCTAssertEqual(slots(root), [.pinnedHeader, .folder(0), .looseHeader])
        XCTAssertEqual(root.looseRows, 3..<3)
    }

    func testNoFolderlessSessions() {
        let root = SidebarRoot(pinned: true, folders: 2, loose: false, looseShown: 0)
        XCTAssertEqual(slots(root), [.pinnedHeader, .folder(0), .folder(1)])
        XCTAssertNil(root.looseHeader)
        XCTAssertEqual(root.firstLoose, 3, "a drop at the end makes the first folderless session")
    }

    func testOnlyFolderlessSessions() {
        let root = SidebarRoot(pinned: false, folders: 0, loose: true, looseShown: 2)
        XCTAssertEqual(slots(root), [.looseHeader, .loose(0), .loose(1)])
    }

    func testEmpty() {
        let root = SidebarRoot(pinned: false, folders: 0, loose: false, looseShown: 0)
        XCTAssertEqual(root.count, 0)
        XCTAssertNil(root.slot(at: 0))
    }

    func testAFolderDropLandsBetweenFoldersOnly() {
        let root = SidebarRoot(pinned: true, folders: 3, loose: true, looseShown: 2)
        XCTAssertEqual(root.folderIndex(forDrop: 0), 0, "never above Pinned")
        XCTAssertEqual(root.folderIndex(forDrop: 1), 0)
        XCTAssertEqual(root.folderIndex(forDrop: 3), 2)
        XCTAssertEqual(root.folderIndex(forDrop: 4), 3, "over the Sessions header: after the last folder")
        XCTAssertEqual(root.folderIndex(forDrop: 7), 3, "never among the folderless rows")
        for i in 0...3 { XCTAssertEqual(root.folderIndex(forDrop: root.rootIndex(ofFolder: i)), i) }
    }

    func testASessionDropAmongTheFolderlessRows() {
        let root = SidebarRoot(pinned: true, folders: 2, loose: true, looseShown: 2)
        XCTAssertEqual(root.looseIndex(forDrop: root.firstLoose), 0)
        XCTAssertEqual(root.looseIndex(forDrop: root.count), 2, "after the last row")
        XCTAssertEqual(root.looseIndex(forDrop: 0), 0)
        XCTAssertEqual(root.looseIndex(forDrop: 99), 2)
        for i in 0...2 { XCTAssertEqual(root.looseIndex(forDrop: root.rootIndex(ofLoose: i)), i) }
    }
}
