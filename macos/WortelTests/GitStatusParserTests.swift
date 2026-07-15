import XCTest

/// Porcelain v2 is a stable, documented format, so these are unit tests against
/// fixed input rather than against a live repo — the shapes below are what git
/// prints for each situation.
final class GitStatusParserTests: XCTestCase {
    func testBranchHeaders() {
        let status = GitStatusParser.parse("""
        # branch.oid 1234567890abcdef1234567890abcdef12345678
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -2
        """)
        XCTAssertEqual(status.head, "1234567890abcdef1234567890abcdef12345678")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
        XCTAssertTrue(status.isClean)
    }

    /// HEAD drives the History pane's reload-on-commit. On a repo with no
    /// commits git prints "(initial)", which must not be mistaken for a SHA.
    func testInitialRepoHasNoHead() {
        let status = GitStatusParser.parse("""
        # branch.oid (initial)
        # branch.head main
        """)
        XCTAssertNil(status.head, "\"(initial)\" is not a commit")
        XCTAssertEqual(status.branch, "main")
    }

    func testDetachedHeadHasNoBranch() {
        let status = GitStatusParser.parse("# branch.head (detached)")
        XCTAssertNil(status.branch)
        XCTAssertTrue(status.isDetachedOrNoBranch)
    }

    /// A file staged *and* modified again is two separate rows — one per section.
    func testFileStagedAndModifiedYieldsTwoRows() {
        let status = GitStatusParser.parse(
            "1 MM N... 100644 100644 100644 aaa bbb src/app.swift")
        XCTAssertEqual(status.changes.count, 2)
        XCTAssertEqual(status.stagedChanges.map(\.path), ["src/app.swift"])
        XCTAssertEqual(status.unstagedChanges.map(\.path), ["src/app.swift"])
        XCTAssertEqual(status.stagedChanges[0].statusCode, "M")
        XCTAssertNotEqual(status.stagedChanges[0].id, status.unstagedChanges[0].id,
                          "the two rows must be independently selectable")
    }

    func testStagedOnlyAndUnstagedOnly() {
        let staged = GitStatusParser.parse("1 A. N... 000000 100644 100644 000 aaa new.txt")
        XCTAssertEqual(staged.stagedChanges.count, 1)
        XCTAssertEqual(staged.unstagedChanges.count, 0)
        XCTAssertEqual(staged.stagedChanges[0].statusCode, "A")

        let unstaged = GitStatusParser.parse("1 .D N... 100644 100644 100644 aaa aaa gone.txt")
        XCTAssertEqual(unstaged.stagedChanges.count, 0)
        XCTAssertEqual(unstaged.unstagedChanges.count, 1)
        XCTAssertTrue(unstaged.unstagedChanges[0].isDeletion)
    }

    func testRenameCarriesItsOriginalPath() {
        // Rename entries put the new path first, then a tab, then the old path.
        let status = GitStatusParser.parse(
            "2 R. N... 100644 100644 100644 aaa bbb R100 new/name.swift\told/name.swift")
        XCTAssertEqual(status.changes.count, 1)
        XCTAssertEqual(status.changes[0].path, "new/name.swift")
        XCTAssertEqual(status.changes[0].originalPath, "old/name.swift")
        XCTAssertEqual(status.changes[0].statusCode, "R")
    }

    func testUntrackedAndUnmerged() {
        let untracked = GitStatusParser.parse("? build/output.js")
        XCTAssertEqual(untracked.changes.count, 1)
        XCTAssertTrue(untracked.changes[0].untracked)
        XCTAssertFalse(untracked.changes[0].staged)

        let conflict = GitStatusParser.parse(
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.swift")
        XCTAssertEqual(conflict.changes.count, 1)
        XCTAssertEqual(conflict.changes[0].statusCode, "U")
    }

    func testPathsWithSpaces() {
        let status = GitStatusParser.parse(
            "1 .M N... 100644 100644 100644 aaa aaa some dir/a file.swift")
        XCTAssertEqual(status.changes.first?.path, "some dir/a file.swift")
    }

    func testGarbageIsIgnoredRatherThanCrashing() {
        let status = GitStatusParser.parse("""

        not a real line
        1
        # branch.head main
        """)
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.changes.isEmpty)
    }

    func testFileMetadataHelpers() {
        let change = GitFileChange(path: "a/b/img.PNG", originalPath: nil,
                                   statusCode: "M", staged: false, untracked: false)
        XCTAssertEqual(change.fileName, "img.PNG")
        XCTAssertEqual(change.directory, "a/b")
        XCTAssertTrue(change.isImage, "image detection must be case-insensitive")

        let svg = GitFileChange(path: "icon.svg", originalPath: nil,
                                statusCode: "M", staged: false, untracked: false)
        XCTAssertFalse(svg.isImage, "SVG is text and flows through the normal diff")
    }
}
