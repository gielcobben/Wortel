import XCTest

/// A sidebar folder's directory decides where every session created in it
/// starts, and the whole derivation is path-string handling — the shape of code
/// that is wrong without throwing. A bad prefix match hands one project's
/// directory to its neighbour; a bad ancestor silently moves where new sessions
/// come from. None of it needs a window, a shell or a repository.
final class FolderRootTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeStripsTrailingSlashAndRelativeSteps() {
        XCTAssertEqual(FolderRoot.normalize("/Users/giel/Developer/"), "/Users/giel/Developer")
        XCTAssertEqual(FolderRoot.normalize("/Users/giel/Developer/wortel/.."),
                       "/Users/giel/Developer")
        XCTAssertEqual(FolderRoot.normalize("/Users//giel"), "/Users/giel")
    }

    /// A session that has never reported a working directory has no path, and
    /// must not be mistaken for one rooted anywhere.
    func testNormalizeRejectsEmpty() {
        XCTAssertNil(FolderRoot.normalize(""))
    }

    func testNormalizeKeepsRoot() {
        XCTAssertEqual(FolderRoot.normalize("/"), "/")
    }

    // MARK: - containment

    func testRootContainsItselfAndDescendants() {
        XCTAssertTrue(FolderRoot.root("/Users/giel/wortel", contains: "/Users/giel/wortel"))
        XCTAssertTrue(FolderRoot.root("/Users/giel/wortel", contains: "/Users/giel/wortel/macos"))
        XCTAssertTrue(FolderRoot.root("/Users/giel/wortel/", contains: "/Users/giel/wortel/web/"))
    }

    /// The bug a plain `hasPrefix` ships: a sibling project whose name starts
    /// with another's would inherit the wrong folder's directory, and nothing
    /// about the symptom would point back here.
    func testSiblingSharingANamePrefixIsNotContained() {
        XCTAssertFalse(FolderRoot.root("/Users/giel/wortel", contains: "/Users/giel/wortel-web"))
        XCTAssertFalse(FolderRoot.root("/Users/giel/dev", contains: "/Users/giel/development"))
    }

    func testUnrelatedPathIsNotContained() {
        XCTAssertFalse(FolderRoot.root("/Users/giel/wortel", contains: "/Users/giel/gfpc"))
        XCTAssertFalse(FolderRoot.root("/Users/giel/wortel/macos", contains: "/Users/giel/wortel"))
    }

    // MARK: - folder(containing:)

    func testFolderContainingPicksTheDeepestRoot() {
        let roots = [
            "Wortel": "/Users/giel/Developer/wortel",
            "Web": "/Users/giel/Developer/wortel/web",
            "GFPC": "/Users/giel/Developer/gfpc",
        ]
        // Both Wortel and Web contain it; the folder that *is* the directory wins.
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/giel/Developer/wortel/web", in: roots), "Web")
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/giel/Developer/wortel/web/src", in: roots), "Web")
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/giel/Developer/wortel/macos", in: roots),
            "Wortel")
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/giel/Developer/gfpc", in: roots), "GFPC")
    }

    /// Nil is what makes ⌘O create a folder instead of filing into one, so it
    /// has to mean "genuinely nowhere" and not "no exact match".
    func testFolderContainingIsNilWhenNothingHoldsThePath() {
        let roots = ["Wortel": "/Users/giel/Developer/wortel"]
        XCTAssertNil(FolderRoot.folder(containing: "/Users/giel/Documents", in: roots))
        XCTAssertNil(FolderRoot.folder(containing: "/Users/giel/Developer", in: roots))
    }

    func testFolderContainingIgnoresFoldersWithoutARoot() {
        XCTAssertNil(FolderRoot.folder(containing: "/Users/giel/Developer/wortel", in: [:]))
    }

    // MARK: - commonAncestor

    func testCommonAncestorOfSiblings() {
        XCTAssertEqual(
            FolderRoot.commonAncestor(of: [
                "/Users/giel/Developer/wortel/macos",
                "/Users/giel/Developer/wortel/web",
            ]),
            "/Users/giel/Developer/wortel")
    }

    func testCommonAncestorOfOnePathIsThatPath() {
        XCTAssertEqual(FolderRoot.commonAncestor(of: ["/Users/giel/Developer/wortel"]),
                       "/Users/giel/Developer/wortel")
    }

    /// Component-wise, never character-wise: `/a/wortel` and `/a/wortel-web`
    /// share ten characters and only one directory.
    func testCommonAncestorStopsAtComponentBoundaries() {
        XCTAssertEqual(
            FolderRoot.commonAncestor(of: ["/Users/giel/wortel", "/Users/giel/wortel-web"]),
            "/Users/giel")
    }

    func testCommonAncestorOfNothingInCommonIsNil() {
        XCTAssertNil(FolderRoot.commonAncestor(of: ["/Users/giel", "/opt/homebrew"]))
        XCTAssertNil(FolderRoot.commonAncestor(of: []))
    }

    func testCommonAncestorSkipsPathsWithoutOne() {
        XCTAssertEqual(
            FolderRoot.commonAncestor(of: ["", "/Users/giel/Developer/wortel"]),
            "/Users/giel/Developer/wortel")
    }

    // MARK: - derived

    private let home = "/Users/giel"
    private let worktrees = ["/Users/giel/.wortel/worktrees"]

    func testDerivedTakesTheProjectDirectory() {
        XCTAssertEqual(
            FolderRoot.derived(
                from: ["/Users/giel/Developer/wortel", "/Users/giel/Developer/wortel/macos"],
                excludingUnder: worktrees, home: home),
            "/Users/giel/Developer/wortel")
    }

    /// A folder holding two unrelated projects still derives the directory that
    /// holds both — "new session here" then means `~/Developer`, which is a real
    /// answer, where the alternative is wherever the selection last wandered.
    func testDerivedAcceptsAContainerOfProjects() {
        XCTAssertEqual(
            FolderRoot.derived(
                from: ["/Users/giel/Developer/gfpc", "/Users/giel/Developer/pontueel"],
                excludingUnder: worktrees, home: home),
            "/Users/giel/Developer")
    }

    /// Home is what unrelated sessions have in common, not a project. Adopting
    /// it would put a directory on a folder that means nothing by it.
    func testDerivedRejectsHome() {
        XCTAssertNil(FolderRoot.derived(
            from: ["/Users/giel/Developer/wortel", "/Users/giel/Documents/notes"],
            excludingUnder: worktrees, home: home))
        XCTAssertNil(FolderRoot.derived(
            from: ["/Users/giel"], excludingUnder: worktrees, home: home))
    }

    func testDerivedRejectsFilesystemRoot() {
        XCTAssertNil(FolderRoot.derived(
            from: ["/Users/giel/Developer/wortel", "/opt/homebrew"],
            excludingUnder: worktrees, home: home))
    }

    /// A branch checkout is a branch of a project, not the project. Letting one
    /// vote drags the ancestor out to whatever holds both it and the repo.
    func testDerivedIgnoresWorktreeSessions() {
        XCTAssertEqual(
            FolderRoot.derived(
                from: [
                    "/Users/giel/Developer/wortel",
                    "/Users/giel/.wortel/worktrees/wortel/feature-x",
                ],
                excludingUnder: worktrees, home: home),
            "/Users/giel/Developer/wortel")
    }

    /// And a folder of nothing *but* branch checkouts derives nothing: their
    /// common ancestor is the directory that contains the checkouts, which is
    /// not a checkout. Such a folder stays a label, and ⌘N in it keeps
    /// inheriting the worktree the selected session was born in.
    func testDerivedIsNilForAFolderOfOnlyWorktrees() {
        XCTAssertNil(FolderRoot.derived(
            from: [
                "/Users/giel/.wortel/worktrees/wortel/feature-x",
                "/Users/giel/.wortel/worktrees/wortel/feature-y",
            ],
            excludingUnder: worktrees, home: home))
    }

    func testDerivedIsNilForAnEmptyFolder() {
        XCTAssertNil(FolderRoot.derived(from: [], excludingUnder: worktrees, home: home))
    }
}
