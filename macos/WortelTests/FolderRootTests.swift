import XCTest

/// A sidebar folder's directory decides where every session created in it
/// starts, and the whole derivation is path-string handling — the shape of code
/// that is wrong without throwing. A bad prefix match hands one project's
/// directory to its neighbour; a bad ancestor silently moves where new sessions
/// come from. None of it needs a window, a shell or a repository.
final class FolderRootTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeStripsTrailingSlashAndRelativeSteps() {
        XCTAssertEqual(FolderRoot.normalize("/Users/me/Developer/"), "/Users/me/Developer")
        XCTAssertEqual(FolderRoot.normalize("/Users/me/Developer/wortel/.."),
                       "/Users/me/Developer")
        XCTAssertEqual(FolderRoot.normalize("/Users//me"), "/Users/me")
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
        XCTAssertTrue(FolderRoot.root("/Users/me/wortel", contains: "/Users/me/wortel"))
        XCTAssertTrue(FolderRoot.root("/Users/me/wortel", contains: "/Users/me/wortel/macos"))
        XCTAssertTrue(FolderRoot.root("/Users/me/wortel/", contains: "/Users/me/wortel/web/"))
    }

    /// The bug a plain `hasPrefix` ships: a sibling project whose name starts
    /// with another's would inherit the wrong folder's directory, and nothing
    /// about the symptom would point back here.
    func testSiblingSharingANamePrefixIsNotContained() {
        XCTAssertFalse(FolderRoot.root("/Users/me/wortel", contains: "/Users/me/wortel-web"))
        XCTAssertFalse(FolderRoot.root("/Users/me/dev", contains: "/Users/me/development"))
    }

    func testUnrelatedPathIsNotContained() {
        XCTAssertFalse(FolderRoot.root("/Users/me/wortel", contains: "/Users/me/acme"))
        XCTAssertFalse(FolderRoot.root("/Users/me/wortel/macos", contains: "/Users/me/wortel"))
    }

    // MARK: - folder(containing:)

    func testFolderContainingPicksTheDeepestRoot() {
        let roots = [
            "Wortel": "/Users/me/Developer/wortel",
            "Web": "/Users/me/Developer/wortel/web",
            "Acme": "/Users/me/Developer/acme",
        ]
        // Both Wortel and Web contain it; the folder that *is* the directory wins.
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/me/Developer/wortel/web", in: roots), "Web")
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/me/Developer/wortel/web/src", in: roots), "Web")
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/me/Developer/wortel/macos", in: roots),
            "Wortel")
        XCTAssertEqual(
            FolderRoot.folder(containing: "/Users/me/Developer/acme", in: roots), "Acme")
    }

    /// Nil is what makes ⌘O create a folder instead of filing into one, so it
    /// has to mean "genuinely nowhere" and not "no exact match".
    func testFolderContainingIsNilWhenNothingHoldsThePath() {
        let roots = ["Wortel": "/Users/me/Developer/wortel"]
        XCTAssertNil(FolderRoot.folder(containing: "/Users/me/Documents", in: roots))
        XCTAssertNil(FolderRoot.folder(containing: "/Users/me/Developer", in: roots))
    }

    func testFolderContainingIgnoresFoldersWithoutARoot() {
        XCTAssertNil(FolderRoot.folder(containing: "/Users/me/Developer/wortel", in: [:]))
    }

    // MARK: - commonAncestor

    func testCommonAncestorOfSiblings() {
        XCTAssertEqual(
            FolderRoot.commonAncestor(of: [
                "/Users/me/Developer/wortel/macos",
                "/Users/me/Developer/wortel/web",
            ]),
            "/Users/me/Developer/wortel")
    }

    func testCommonAncestorOfOnePathIsThatPath() {
        XCTAssertEqual(FolderRoot.commonAncestor(of: ["/Users/me/Developer/wortel"]),
                       "/Users/me/Developer/wortel")
    }

    /// Component-wise, never character-wise: `/a/wortel` and `/a/wortel-web`
    /// share ten characters and only one directory.
    func testCommonAncestorStopsAtComponentBoundaries() {
        XCTAssertEqual(
            FolderRoot.commonAncestor(of: ["/Users/me/wortel", "/Users/me/wortel-web"]),
            "/Users/me")
    }

    func testCommonAncestorOfNothingInCommonIsNil() {
        XCTAssertNil(FolderRoot.commonAncestor(of: ["/Users/me", "/opt/homebrew"]))
        XCTAssertNil(FolderRoot.commonAncestor(of: []))
    }

    func testCommonAncestorSkipsPathsWithoutOne() {
        XCTAssertEqual(
            FolderRoot.commonAncestor(of: ["", "/Users/me/Developer/wortel"]),
            "/Users/me/Developer/wortel")
    }

    // MARK: - derived

    private let home = "/Users/me"
    private let worktrees = ["/Users/me/.wortel/worktrees"]

    func testDerivedTakesTheProjectDirectory() {
        XCTAssertEqual(
            FolderRoot.derived(
                from: ["/Users/me/Developer/wortel", "/Users/me/Developer/wortel/macos"],
                excludingUnder: worktrees, home: home),
            "/Users/me/Developer/wortel")
    }

    /// A folder holding two unrelated projects still derives the directory that
    /// holds both — "new session here" then means `~/Developer`, which is a real
    /// answer, where the alternative is wherever the selection last wandered.
    func testDerivedAcceptsAContainerOfProjects() {
        XCTAssertEqual(
            FolderRoot.derived(
                from: ["/Users/me/Developer/acme", "/Users/me/Developer/blog"],
                excludingUnder: worktrees, home: home),
            "/Users/me/Developer")
    }

    /// Home is what unrelated sessions have in common, not a project. Adopting
    /// it would put a directory on a folder that means nothing by it.
    func testDerivedRejectsHome() {
        XCTAssertNil(FolderRoot.derived(
            from: ["/Users/me/Developer/wortel", "/Users/me/Documents/notes"],
            excludingUnder: worktrees, home: home))
        XCTAssertNil(FolderRoot.derived(
            from: ["/Users/me"], excludingUnder: worktrees, home: home))
    }

    func testDerivedRejectsFilesystemRoot() {
        XCTAssertNil(FolderRoot.derived(
            from: ["/Users/me/Developer/wortel", "/opt/homebrew"],
            excludingUnder: worktrees, home: home))
    }

    /// A branch checkout is a branch of a project, not the project. Letting one
    /// vote drags the ancestor out to whatever holds both it and the repo.
    func testDerivedIgnoresWorktreeSessions() {
        XCTAssertEqual(
            FolderRoot.derived(
                from: [
                    "/Users/me/Developer/wortel",
                    "/Users/me/.wortel/worktrees/wortel/feature-x",
                ],
                excludingUnder: worktrees, home: home),
            "/Users/me/Developer/wortel")
    }

    /// And a folder of nothing *but* branch checkouts derives nothing: their
    /// common ancestor is the directory that contains the checkouts, which is
    /// not a checkout. Such a folder stays a label, and ⌘N in it keeps
    /// inheriting the worktree the selected session was born in.
    func testDerivedIsNilForAFolderOfOnlyWorktrees() {
        XCTAssertNil(FolderRoot.derived(
            from: [
                "/Users/me/.wortel/worktrees/wortel/feature-x",
                "/Users/me/.wortel/worktrees/wortel/feature-y",
            ],
            excludingUnder: worktrees, home: home))
    }

    func testDerivedIsNilForAnEmptyFolder() {
        XCTAssertNil(FolderRoot.derived(from: [], excludingUnder: worktrees, home: home))
    }
}
