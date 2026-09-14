import XCTest

/// Worktree paths, the sidebar name a branch turns into, and the listing parse
/// — the pieces of the feature that are string handling, and whose failures are
/// silent: a slug that collides puts two branches in one directory, a branch
/// dropped into a name whole invents a sidebar folder, and a stanza parsed wrong
/// hides an existing worktree so the next attempt tries to create it again.
final class GitWorktreeTests: XCTestCase {
    // MARK: - Slugs

    /// A name that is already a safe path component is used as it is — branch
    /// names are unique, so those can never collide with each other.
    func testSimpleBranchIsItsOwnSlug() {
        XCTAssertEqual(GitWorktree.slug(forBranch: "main"), "main")
        XCTAssertEqual(GitWorktree.slug(forBranch: "feature-x"), "feature-x")
    }

    /// One that had to be rewritten carries a digest of the original, because
    /// the rewrite is what destroys the distinction between two branches.
    func testRewrittenBranchKeepsAReadableStem() {
        let slug = GitWorktree.slug(forBranch: "feature/preview-window")
        XCTAssertTrue(slug.hasPrefix("feature-preview-window-"), slug)
    }

    /// The digest has to survive a relaunch, so it cannot be `hashValue`, which
    /// is seeded per process.
    func testSlugIsStableAcrossRuns() {
        XCTAssertEqual(GitWorktree.slug(forBranch: "feature/x"), "feature-x-73876a")
    }

    /// The property that matters is that different branches stay different.
    /// `feature/x` and `feature-x` can both exist, and a slug that dropped the
    /// separator would give them one directory and one checkout.
    func testDifferentBranchesGetDifferentSlugs() {
        let names = ["feature/x", "feature-x", "feature_x", "feature.x", "Feature/X"]
        let slugs = Set(names.map(GitWorktree.slug(forBranch:)))
        XCTAssertEqual(slugs.count, names.count, "two branches collapsed onto one directory")
    }

    func testAwkwardCharactersBecomeSeparators() {
        XCTAssertTrue(GitWorktree.slug(forBranch: "fix/#123 crash").hasPrefix("fix-123-crash-"))
        XCTAssertTrue(GitWorktree.slug(forBranch: "spaced   out").hasPrefix("spaced-out-"))
    }

    /// A slug is a path component, so it must not start or end with the
    /// characters that make one awkward — and must never be empty.
    func testSlugIsAlwaysAUsablePathComponent() {
        for branch in ["/leading", "trailing/", "///", "", "-dashed", "dotted."] {
            let slug = GitWorktree.slug(forBranch: branch)
            XCTAssertFalse(slug.isEmpty)
            XCTAssertFalse(slug.hasPrefix("-") || slug.hasPrefix("."), slug)
            XCTAssertFalse(slug.contains("/"), slug)
        }
    }

    // MARK: - Paths

    /// Grouped by repository, so two projects with a `main` branch don't land in
    /// the same directory.
    func testPathGroupsByRepository() {
        let a = GitWorktree.path(forBranch: "main", repoRoot: "/Users/x/Developer/wortel")
        let b = GitWorktree.path(forBranch: "main", repoRoot: "/Users/x/Developer/lijn")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix("/wortel/main"), a)
        XCTAssertTrue(b.hasSuffix("/lijn/main"), b)
    }

    /// Outside the repository — a worktree inside it would be committable, would
    /// confuse anything that walks the project, and would vanish with it.
    func testPathIsOutsideTheRepository() {
        let path = GitWorktree.path(forBranch: "x", repoRoot: "/Users/x/Developer/wortel")
        XCTAssertFalse(path.hasPrefix("/Users/x/Developer/wortel"))
        XCTAssertTrue(path.hasPrefix(GitWorktree.root.path))
    }

    // MARK: - Parsing

    /// The real shape of `git worktree list --porcelain`: stanzas separated by
    /// blank lines, the first being the repository's own working tree.
    func testParsesPrimaryAndLinkedWorktrees() {
        let porcelain = """
        worktree /Users/x/Developer/wortel
        HEAD 4bd0b1e0dcbaa3fbcbd0e14a72e0d7ee2ba7e0d1
        branch refs/heads/main

        worktree /Users/x/.wortel/worktrees/wortel/feature-x
        HEAD 9e1c0a1e0dcbaa3fbcbd0e14a72e0d7ee2ba7e0d
        branch refs/heads/feature/x

        """
        let trees = GitWorktree.parse(porcelain: porcelain)
        XCTAssertEqual(trees.count, 2)
        XCTAssertEqual(trees[0], GitWorktree(
            path: "/Users/x/Developer/wortel", branch: "main", isPrimary: true))
        XCTAssertEqual(trees[1].branch, "feature/x", "the branch, not its slug")
        XCTAssertFalse(trees[1].isPrimary)
    }

    /// A detached worktree has no branch line at all. It must still be listed —
    /// it occupies a directory, and forgetting it means trying to reuse one.
    func testDetachedWorktreeHasNoBranch() {
        let porcelain = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /elsewhere
        HEAD def
        detached
        """
        let trees = GitWorktree.parse(porcelain: porcelain)
        XCTAssertEqual(trees.count, 2)
        XCTAssertNil(trees[1].branch)
    }

    func testEmptyListingParsesToNothing() {
        XCTAssertTrue(GitWorktree.parse(porcelain: "").isEmpty)
    }

    /// Only the first stanza is the primary tree, however many follow.
    func testOnlyTheFirstIsPrimary() {
        let porcelain = (0..<3).map { "worktree /w\($0)\nHEAD a\nbranch refs/heads/b\($0)" }
            .joined(separator: "\n\n")
        let trees = GitWorktree.parse(porcelain: porcelain)
        XCTAssertEqual(trees.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(trees.map(\.branch), ["b0", "b1", "b2"])
    }

    // MARK: - The sidebar name a branch turns into

    /// Wortel's own namespace is on every branch it generates, so in a sidebar
    /// where every one of these rows carries it, it says nothing.
    func testGeneratedBranchLosesWortelsOwnNamespace() {
        XCTAssertEqual(
            GitWorktree.sessionLeaf(forBranch: "worktree/brave-river-1a2f"),
            "brave-river-1a2f")
    }

    /// A namespace you chose yourself is the half that says what the branch is
    /// for, so it stays — with the one slash it contains swapped for the
    /// lookalike that is not a folder separator.
    func testYourOwnNamespaceIsKeptButCannotMakeAFolder() {
        XCTAssertEqual(GitWorktree.sessionLeaf(forBranch: "fix/login"), "fix\u{2215}login")
        XCTAssertNil(SessionName.folder(of: GitWorktree.sessionLeaf(forBranch: "fix/login")))
    }

    func testBranchWithNoNamespaceIsItsOwnLeaf() {
        XCTAssertEqual(GitWorktree.sessionLeaf(forBranch: "main"), "main")
    }

    /// A branch that is nothing but the namespace has no leaf to show, and an
    /// empty sidebar row is worse than a redundant one.
    func testBareNamespaceFallsBackToTheWholeBranch() {
        XCTAssertEqual(GitWorktree.sessionLeaf(forBranch: "worktree/"), "worktree\u{2215}")
    }

    /// The whole point: what goes in a name can never be read back as a folder.
    func testNoBranchCanInventAFolder() {
        for branch in ["worktree/brave-river-1a2f", "fix/login", "a/b/c", "main", "worktree/"] {
            let name = "GFPC/" + GitWorktree.sessionLeaf(forBranch: branch)
            XCTAssertEqual(SessionName.folder(of: name), "GFPC", branch)
        }
    }

    // MARK: - Undoing the folder an earlier build invented

    /// The real thing this was written for: two sessions sitting in a folder
    /// called "GFPC/worktree" beside the GFPC they belong to.
    func testTheInventedFolderIsStrippedFromTheName() {
        XCTAssertEqual(
            GitWorktree.repairedSessionName(
                "GFPC/worktree/wakker-menubar-demo", branch: "worktree/wakker-slide"),
            "GFPC/wakker-menubar-demo")
    }

    /// A worktree session that was never in a folder ends up at the top level,
    /// not in one called "worktree".
    func testATopLevelWorktreeSessionLosesItsFolderEntirely() {
        XCTAssertEqual(
            GitWorktree.repairedSessionName("worktree/dvd-screensaver-icon",
                                            branch: "worktree/pontueel-ios-icon"),
            "dvd-screensaver-icon")
    }

    /// Only the branch's own namespace, and only off the end. A folder someone
    /// deliberately named this is somebody's project, not our bookkeeping.
    func testAnUnrelatedFolderIsLeftAlone() {
        XCTAssertNil(GitWorktree.repairedSessionName(
            "GFPC/wakker-menubar-demo", branch: "worktree/wakker-slide"))
        XCTAssertNil(GitWorktree.repairedSessionName(
            "worktree extras/thing", branch: "worktree/x"))
        XCTAssertNil(GitWorktree.repairedSessionName(
            "GFPC/worktree/thing", branch: "main"), "a branch with no namespace")
        XCTAssertNil(GitWorktree.repairedSessionName("GFPC", branch: "worktree/x"),
                     "no folder half at all")
    }

    /// Branch namespaces nest, and so does the folder one of them invented.
    func testAMultiLevelNamespaceComesOffWhole() {
        XCTAssertEqual(
            GitWorktree.repairedSessionName("GFPC/a/b/thing", branch: "a/b/c"),
            "GFPC/thing")
    }

    /// It runs on every launch, so the second one must find nothing to do.
    func testRepairIsIdempotent() {
        let once = GitWorktree.repairedSessionName(
            "GFPC/worktree/wakker-menubar-demo", branch: "worktree/wakker-slide")
        XCTAssertEqual(once, "GFPC/wakker-menubar-demo")
        XCTAssertNil(GitWorktree.repairedSessionName(once!, branch: "worktree/wakker-slide"))
    }
}
