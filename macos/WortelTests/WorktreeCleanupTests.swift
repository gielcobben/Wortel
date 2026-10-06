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
}
