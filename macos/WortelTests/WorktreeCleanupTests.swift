import XCTest

/// The worktree cleanup is the one place Wortel removes a folder of the user's,
/// so each verdict is checked against real git, and so is what a removal leaves
/// behind: the folder, git's registration, and the branch.
final class WorktreeCleanupTests: XCTestCase {
    private var repo: URL!
    private var base: URL!

    override func setUp() {
        super.setUp()
        repo = GitFixture.newRepo("cleanup")
        GitFixture.commit("base", in: repo)
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-worktrees-\(UUID().uuidString)")
    }

    override func tearDown() {
        GitFixture.destroy(repo)
        GitFixture.destroy(base)
        super.tearDown()
    }

    /// A worktree on a new branch, where Wortel would put it.
    private func addWorktree(_ name: String, branch: String? = nil) -> String {
        let path = base.appendingPathComponent("repo/\(name)").path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        GitFixture.sh("git worktree add -q -b \(branch ?? "worktree/\(name)") \(GitFixture.shellQuoted(path))",
                      in: repo)
        return path
    }

    private func branches() -> [String] {
        GitFixture.sh("git branch --format='%(refname:short)'", in: repo)
            .split(separator: "\n").map(String.init)
    }

    private let delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    func testACleanWorktreeIsSafeAndRemovingItLeavesNothing() async {
        let path = addWorktree("clean")
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.verdict, .safe)
        XCTAssertEqual(report.branch, "worktree/clean")
        XCTAssertEqual(report.uniqueCommits, 0)

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(GitFixture.sh("git worktree list", in: repo).contains("repo/clean"))
        XCTAssertFalse(branches().contains("worktree/clean"))
    }

    /// Commits found only on the branch: the folder may go, the branch stays
    /// unless losing them was explicitly chosen.
    func testCommitsOnlyOnTheBranchKeepTheBranch() async {
        let path = addWorktree("ahead")
        let dir = URL(fileURLWithPath: path)
        GitFixture.commit("one", in: dir)
        GitFixture.commit("two", in: dir)

        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.verdict, .keepsCommits)
        XCTAssertEqual(report.uniqueCommits, 2)

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(branches().contains("worktree/ahead"), "its commits exist nowhere else")
    }

    /// The same commits on another branch are not at risk.
    func testCommitsAlsoOnAnotherBranchAreNotUnique() async {
        let path = addWorktree("merged")
        GitFixture.commit("one", in: URL(fileURLWithPath: path))
        GitFixture.sh("git branch keep worktree/merged", in: repo)

        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.uniqueCommits, 0)
        XCTAssertEqual(report.verdict, .safe)
    }

    // MARK: - Merged by content

    /// A branch with real work on it: two commits editing `f.txt`.
    private func branchWithWork(_ name: String) -> (path: String, dir: URL) {
        GitFixture.sh("printf 'a\\nb\\nc\\n' > f.txt && git add f.txt && git commit -q -m f", in: repo)
        let path = addWorktree(name)
        let dir = URL(fileURLWithPath: path)
        GitFixture.sh("printf 'a\\nB\\nc\\n' > f.txt && git commit -q -am one", in: dir)
        GitFixture.sh("printf 'a\\nB\\nc\\nd\\n' > f.txt && git commit -q -am two", in: dir)
        return (path, dir)
    }

    /// Squash-merged: its commits are on no other branch, but its work is in
    /// trunk, so the folder and the branch may both go.
    func testSquashMergedBranchIsSafeAndDeletable() async {
        let (path, _) = branchWithWork("squashed")
        GitFixture.sh("git merge -q --squash worktree/squashed && git commit -q -m squash", in: repo)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertNotEqual(report.uniqueCommits, 0)
        XCTAssertEqual(report.mergedInto, "main")
        XCTAssertEqual(report.verdict, .safe)
        XCTAssertTrue(report.branchIsDeletable)

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(error)
        XCTAssertFalse(branches().contains("worktree/squashed"))
    }

    /// Rebase-merged, or cherry-picked: new commits in trunk, same work.
    func testCherryPickedBranchIsMerged() async {
        let (path, _) = branchWithWork("picked")
        // Trunk moves on first, as it does, so the picks are new commits:
        // picked straight onto the commit they came from, git would recreate
        // the very same ones and the branch would simply be merged.
        GitFixture.sh("echo other > other.txt && git add other.txt && git commit -q -m other", in: repo)
        GitFixture.sh("git cherry-pick main~1..worktree/picked >/dev/null", in: repo)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.mergedInto, "main")
        XCTAssertEqual(report.verdict, .safe)
    }

    /// Trunk changed the same lines afterwards: no longer provably in, so kept.
    func testMergedThenEditedIsKept() async {
        let (path, _) = branchWithWork("edited")
        GitFixture.sh("git merge -q --squash worktree/edited && git commit -q -m squash", in: repo)
        GitFixture.sh("printf 'a\\nX\\nc\\nd\\n' > f.txt && git commit -q -am later", in: repo)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertNil(report.mergedInto)
        XCTAssertEqual(report.verdict, .keepsCommits)
        XCTAssertFalse(report.branchIsDeletable)
    }

    func testMergedThenRevertedIsKept() async {
        let (path, _) = branchWithWork("reverted")
        GitFixture.sh("git merge -q --squash worktree/reverted && git commit -q -m squash && git revert --no-edit HEAD >/dev/null",
                      in: repo)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertNil(report.mergedInto)
        XCTAssertEqual(report.verdict, .keepsCommits)
    }

    /// Merged doesn't outrank uncommitted work.
    func testMergedButDirtyIsStillBlocked() async {
        let (path, dir) = branchWithWork("dirty")
        GitFixture.sh("git merge -q --squash worktree/dirty && git commit -q -m squash", in: repo)
        GitFixture.sh("echo more >> f.txt", in: dir)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.mergedInto, "main")
        XCTAssertEqual(report.verdict, .blocked)
    }

    /// Commits that changed nothing were never "merged": they are all the
    /// branch has, so it is kept.
    func testBranchThatChangedNothingIsNotMerged() async {
        let path = addWorktree("empty")
        GitFixture.commit("nothing", in: URL(fileURLWithPath: path))
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertNil(report.mergedInto)
        XCTAssertEqual(report.verdict, .keepsCommits)
    }

    func testUncommittedAndUntrackedFilesBlockRemoval() async {
        let path = addWorktree("dirty")
        GitFixture.sh("echo work > notes.txt", in: URL(fileURLWithPath: path))

        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.verdict, .blocked)
        XCTAssertEqual(report.changedFiles, ["notes.txt"])
        XCTAssertTrue(report.blockers.first?.contains("notes.txt") == true)

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/notes.txt"), "nothing was touched")
        XCTAssertTrue(branches().contains("worktree/dirty"))
    }

    /// Re-checked at removal: a file written after the sheet was read still
    /// stops it.
    func testRemovalRechecksInsteadOfTrustingAnOldReport() async {
        let path = addWorktree("late")
        let before = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(before.verdict, .safe)
        GitFixture.sh("echo late > late.txt", in: URL(fileURLWithPath: path))

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - What a removal reports about the branch

    /// The branch is a session's only way back once its folder has gone, so
    /// the caller must hear whether it really went, not what was asked for.
    func testRemovalSaysTheBranchWentWhenItDid() async {
        let path = addWorktree("gone")
        let removal = await WorktreeCleanup.removeReporting(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(removal.error)
        XCTAssertTrue(removal.branchDeleted)
        XCTAssertFalse(branches().contains("worktree/gone"))
    }

    /// Asked to delete the branch, but its commits exist nowhere else: the
    /// folder goes, the branch stays, and the removal says so.
    func testRemovalSaysTheBranchStayedWhenItWasKept() async {
        let path = addWorktree("kept")
        let dir = URL(fileURLWithPath: path)
        GitFixture.commit("one", in: dir)
        GitFixture.commit("two", in: dir)

        let removal = await WorktreeCleanup.removeReporting(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(removal.error)
        XCTAssertFalse(removal.branchDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(branches().contains("worktree/kept"), "its commits exist nowhere else")
    }

    func testRemovalSaysTheBranchStayedWhenNotAsked() async {
        let path = addWorktree("asked")
        let removal = await WorktreeCleanup.removeReporting(path: path, deleteBranch: false, discard: delete)
        XCTAssertNil(removal.error)
        XCTAssertFalse(removal.branchDeleted)
        XCTAssertTrue(branches().contains("worktree/asked"))
    }

    func testABlockedRemovalDeletesNothing() async {
        let path = addWorktree("blocked")
        let before = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(before.verdict, .safe)
        GitFixture.sh("echo late > late.txt", in: URL(fileURLWithPath: path))

        let removal = await WorktreeCleanup.removeReporting(path: path, deleteBranch: true, discard: delete)
        XCTAssertNotNil(removal.error)
        XCTAssertFalse(removal.branchDeleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(branches().contains("worktree/blocked"))
    }

    func testSomethingUsingItBlocksRemoval() async {
        let path = addWorktree("busy")
        let report = await WorktreeCleanup.inspect(path: path, usedBy: ["node"])
        XCTAssertEqual(report.verdict, .blocked)
        XCTAssertEqual(report.blockers, ["In use by node."])
    }

    func testALockedWorktreeIsBlocked() async {
        let path = addWorktree("locked")
        GitFixture.sh("git worktree lock \(GitFixture.shellQuoted(path))", in: repo)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertTrue(report.isLocked)
        XCTAssertEqual(report.verdict, .blocked)
    }

    /// A branch you checked out yourself is yours: removing the folder never
    /// takes it, even when asked to delete branches.
    func testABranchOutsideWortelsNamespaceIsNeverDeleted() async {
        let path = addWorktree("mine", branch: "feature/mine")
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertFalse(report.ownsBranch)

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(error)
        XCTAssertTrue(branches().contains("feature/mine"))
    }

    /// A folder deleted by hand leaves git's registration behind. It's safe, and
    /// removing it drops that registration and nothing else.
    func testAMissingFolderOnlyLosesItsRegistration() async {
        let gone = addWorktree("gone")
        let other = addWorktree("other")
        try? FileManager.default.removeItem(atPath: gone)

        let found = await WorktreeCleanup.discover(knownRepos: [repo.path], under: base)
        XCTAssertTrue(found.contains { WorktreeCleanup.samePath($0, gone) })
        XCTAssertTrue(found.contains { WorktreeCleanup.samePath($0, other) })

        let report = await WorktreeCleanup.inspect(path: gone, knownRepos: [repo.path])
        XCTAssertTrue(report.isMissing)
        XCTAssertEqual(report.verdict, .safe)

        let error = await WorktreeCleanup.remove(path: gone, knownRepos: [repo.path],
                                                 deleteBranch: false, discard: delete)
        XCTAssertNil(error)
        let listed = GitFixture.sh("git worktree list", in: repo)
        XCTAssertFalse(listed.contains("/gone"))
        XCTAssertTrue(listed.contains("/other"), "only that registration goes")
    }

    /// A folder that isn't a checkout any more can't be vouched for.
    func testAFolderThatIsNoLongerACheckoutIsBlocked() async {
        let path = base.appendingPathComponent("repo/stray").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertTrue(report.isOrphanedFolder)
        XCTAssertEqual(report.verdict, .blocked)
    }

    /// A worktree on a branch with no commits yet (in a repository with none)
    /// has nothing to lose: git can't count commits on it, which must read as
    /// zero rather than as an error.
    func testAnUnbornBranchHasNothingToLose() async {
        let empty = GitFixture.newRepo("unborn")
        defer { GitFixture.destroy(empty) }
        let path = base.appendingPathComponent("empty/fresh").path
        GitFixture.sh("git worktree add -q --orphan -b worktree/fresh \(GitFixture.shellQuoted(path)) 2>/dev/null || git worktree add -q --orphan worktree/fresh \(GitFixture.shellQuoted(path))", in: empty)
        guard FileManager.default.fileExists(atPath: path) else {
            return // this git can't make an orphan worktree; nothing to check
        }
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertEqual(report.uniqueCommits, 0)
        XCTAssertEqual(report.verdict, .safe)
        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(error)
    }

    /// Commits on a detached HEAD have no branch to survive on: removing the
    /// worktree would drop the only thing pointing at them. (Review finding:
    /// this used to read as "keepsCommits", removal ticked by default.)
    func testDetachedCommitsBlockRemoval() async {
        let path = addWorktree("detached")
        let dir = URL(fileURLWithPath: path)
        GitFixture.sh("git checkout -q --detach", in: dir)
        GitFixture.commit("only here", in: dir)

        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertNil(report.branch)
        XCTAssertEqual(report.uniqueCommits, 1)
        XCTAssertEqual(report.verdict, .blocked)
        XCTAssertTrue(report.blockers.contains { $0.contains("detached") })

        let error = await WorktreeCleanup.remove(path: path, deleteBranch: false, discard: delete)
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// The same with the folder already gone: the registration's HEAD is still
    /// the only reference, so forgetting it isn't safe either.
    func testAMissingDetachedWorktreeWithCommitsIsBlocked() async {
        let path = addWorktree("gone-detached")
        let dir = URL(fileURLWithPath: path)
        GitFixture.sh("git checkout -q --detach", in: dir)
        GitFixture.commit("only here", in: dir)
        try? FileManager.default.removeItem(atPath: path)

        let report = await WorktreeCleanup.inspect(path: path, knownRepos: [repo.path])
        XCTAssertTrue(report.isMissing)
        XCTAssertEqual(report.uniqueCommits, 1)
        XCTAssertEqual(report.verdict, .blocked)
    }

    /// A lock still counts when the folder is gone. (Review finding: reported
    /// safe, then failed with a message that blamed the Trash.)
    func testAMissingLockedWorktreeIsBlocked() async {
        let path = addWorktree("gone-locked")
        GitFixture.sh("git worktree lock \(GitFixture.shellQuoted(path))", in: repo)
        try? FileManager.default.removeItem(atPath: path)

        let report = await WorktreeCleanup.inspect(path: path, knownRepos: [repo.path])
        XCTAssertTrue(report.isMissing)
        XCTAssertTrue(report.isLocked)
        XCTAssertEqual(report.verdict, .blocked)
    }

    /// A repository's own checkout sitting under the root (a nested clone, a
    /// submodule) is never a worktree to remove.
    func testARepositorysOwnCheckoutIsNeverOffered() async {
        let path = base.appendingPathComponent("repo/clone").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        GitFixture.sh("git init -q -b main && git commit -q --allow-empty -m x", in: URL(fileURLWithPath: path))

        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertTrue(report.isPrimaryCheckout)
        XCTAssertEqual(report.verdict, .blocked)
        let error = await WorktreeCleanup.remove(path: path, deleteBranch: false, discard: delete)
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testTheParserReadsLocks() {
        let parsed = GitWorktree.parse(porcelain: """
            worktree /r
            HEAD abc
            branch refs/heads/main

            worktree /w
            HEAD def
            branch refs/heads/worktree/x
            locked because

            """)
        XCTAssertEqual(parsed.map(\.isLocked), [false, true])
    }

    // MARK: - Left behind by Bring Here

    /// A folder Bring Here took the branch from is offered, and safe: it sits
    /// on a commit the branch still has. Once a branch is checked out in it
    /// again, it's somebody's folder and isn't.
    func testAFolderBringHereLeftIsOfferedOnlyWhileItHasNoBranch() async {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-brought-\(UUID().uuidString)")
        defer { GitFixture.destroy(elsewhere) }
        GitFixture.sh("git worktree add -q -b feature/agent \(GitFixture.shellQuoted(elsewhere.path))", in: repo)
        GitFixture.commit("agent work", in: elsewhere)
        GitFixture.sh("git switch -q --detach", in: elsewhere)

        let found = await WorktreeCleanup.discover(under: base, broughtHere: [elsewhere.path])
        XCTAssertTrue(found.contains { WorktreeCleanup.samePath($0, elsewhere.path) })
        let report = await WorktreeCleanup.inspect(path: elsewhere.path)
        XCTAssertEqual(report.verdict, .safe, report.summary)

        GitFixture.sh("git switch -q -c feature/back", in: elsewhere)
        let after = await WorktreeCleanup.discover(under: base, broughtHere: [elsewhere.path])
        XCTAssertFalse(after.contains { WorktreeCleanup.samePath($0, elsewhere.path) },
                       "a folder with a branch again is somebody's")
    }

    /// A status that fails says nothing about changes: blocked, never "clean".
    func testAFailedStatusBlocks() async {
        let path = addWorktree("broken")
        GitFixture.sh("echo work > notes.txt", in: URL(fileURLWithPath: path))
        // A corrupt index: status fails outright.
        let gitDir = GitFixture.sh("git rev-parse --absolute-git-dir", in: URL(fileURLWithPath: path))
        GitFixture.sh("printf garbage > \(GitFixture.shellQuoted(gitDir + "/index"))", in: repo)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertTrue(report.statusFailed)
        XCTAssertEqual(report.verdict, .blocked)
        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// Two branches holding the same unpushed commits (a session and its
    /// fork) each count the other as where those commits also are. Removed
    /// at once, in turn: the second sees the first gone and keeps its branch.
    func testTwinBranchesRemovedAtOnceKeepTheirCommits() async {
        let a = addWorktree("twin-a")
        GitFixture.commit("only here", in: URL(fileURLWithPath: a))
        let head = GitFixture.sh("git rev-parse HEAD", in: URL(fileURLWithPath: a))
        let b = base.appendingPathComponent("repo/twin-b").path
        GitFixture.sh("git worktree add -q -b worktree/twin-b \(GitFixture.shellQuoted(b)) \(head)", in: repo)
        async let first = WorktreeCleanup.remove(path: a, deleteBranch: true, discard: delete)
        async let second = WorktreeCleanup.remove(path: b, deleteBranch: true, discard: delete)
        _ = await (first, second)
        let kept = GitFixture.sh("git branch --contains \(head) --format='%(refname:short)'", in: repo)
        XCTAssertFalse(kept.isEmpty, "the commit is on no branch any more")
    }

    /// Removing a branch deletes it at the commit inspected, and its config
    /// (Wortel's record of making it) with it.
    func testARemovedBranchTakesItsRecord() async {
        let path = addWorktree("recorded")
        GitFixture.sh("git config branch.worktree/recorded.wortelCreated true", in: repo)
        let error = await WorktreeCleanup.remove(path: path, deleteBranch: true, discard: delete)
        XCTAssertNil(error)
        XCTAssertFalse(branches().contains("worktree/recorded"))
        XCTAssertEqual(GitFixture.sh("git config --get-regexp '^branch\\.worktree/recorded\\.' || true", in: repo), "")
    }
}
