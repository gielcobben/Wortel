import XCTest

/// The remembered project list is the only thing standing between "servers your
/// sessions left behind" and "a list of every background process on your Mac" —
/// 338 processes had `ppid == 1` under one uid on an ordinary machine, and the
/// only reason the orphan list showed two of them is that the rest were not
/// sitting in a directory Wortel had opened.
///
/// So both directions fail silently. Too broad and the feature offers to kill
/// system daemons; too narrow and a real 385 MB leftover is never mentioned.
final class ProjectRootsTests: XCTestCase {

    private let home = "/Users/giel"

    // MARK: - What counts as a project

    /// A session opened at `~` is perfectly ordinary, and remembering home as a
    /// project root would match essentially every process the user runs.
    func testHomeAndItsAncestorsAreRefused() {
        XCTAssertFalse(ProjectRoots.isSpecificEnough("/Users/giel", home: home),
                       "home matches everything, which is the same as matching nothing useful")
        XCTAssertFalse(ProjectRoots.isSpecificEnough("/Users", home: home))
        XCTAssertFalse(ProjectRoots.isSpecificEnough("/", home: home))
        XCTAssertFalse(ProjectRoots.isSpecificEnough("/Users/giel/", home: home),
                       "a trailing slash is the same directory")
    }

    func testARealProjectDirectoryIsAccepted() {
        XCTAssertTrue(ProjectRoots.isSpecificEnough("/Users/giel/Developer/wortel", home: home))
        XCTAssertTrue(ProjectRoots.isSpecificEnough("/opt/work/thing", home: home),
                      "a project need not live under home at all")
    }

    // MARK: - Merging

    func testNewestFirstAndDeduplicated() {
        let merged = ProjectRoots.merge(
            ["/Users/giel/a", "/Users/giel/b"], adding: ["/Users/giel/b"], home: home)
        XCTAssertEqual(merged, ["/Users/giel/b", "/Users/giel/a"],
                       "reopening a project moves it up, it does not add a second copy")
    }

    func testPathsAreNormalisedBeforeComparing() {
        let merged = ProjectRoots.merge(
            ["/Users/giel/a"], adding: ["/Users/giel/a/"], home: home)
        XCTAssertEqual(merged, ["/Users/giel/a"],
                       "the same directory spelled two ways is one root")
    }

    func testUnacceptableRootsAreDroppedRatherThanStored() {
        let merged = ProjectRoots.merge([], adding: ["/Users/giel", "/Users/giel/dev"], home: home)
        XCTAssertEqual(merged, ["/Users/giel/dev"])
    }

    /// A cap, so one long-lived install can't accumulate an ever-wider net.
    func testTheListIsCapped() {
        let many = (0..<100).map { "/Users/giel/p\($0)" }
        XCTAssertEqual(ProjectRoots.merge([], adding: many, limit: 40, home: home).count, 40)
    }

    func testAnEmptyMergeStaysEmpty() {
        XCTAssertTrue(ProjectRoots.merge([], adding: [], home: home).isEmpty)
    }
}
