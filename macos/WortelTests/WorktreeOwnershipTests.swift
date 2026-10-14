import XCTest

/// What Wortel may remove is what it made, as it recorded making it: a marker
/// in the worktree's git folder and a key on the branch. A mistake here either
/// deletes someone's worktree or branch (the worst thing this app can do to a
/// repository) or keeps Wortel's own forever.
final class WorktreeOwnershipTests: XCTestCase {
    private var base: URL!
    private var repo: URL!

    override func setUp() {
        base = GitFixture.newRepo("ownership")
        repo = base.appendingPathComponent("app")
        GitFixture.sh("git init -q -b main app", in: base)
        GitFixture.commit("first", in: repo)
    }

    override func tearDown() { GitFixture.destroy(base) }

    private func configValue(_ key: String) -> String {
        GitFixture.sh("git config --get \(key) || true", in: repo)
    }

    func testAWorktreeWortelCreatesIsMarkedAndItsBranchRecorded() async {
        let path = base.appendingPathComponent("made/feature").path
        let error = await GitService.addWorktree(root: repo.path, at: path, branch: "feature",
                                                 source: .newBranch(from: "main"))
        XCTAssertNil(error)
        let linked = GitWorktree.linked(containing: path)
        XCTAssertEqual(linked?.isOwned, true)
        XCTAssertTrue(GitWorktree.Ownership.isOwned(root: path, under: base.appendingPathComponent("nowhere")))
        let created = await GitService.isCreatedByWortel(branch: "feature", root: repo.path)
        XCTAssertTrue(created)
        XCTAssertEqual(configValue("branch.feature.wortelBase"), "main")

        // The record follows the branch through a rename, and the report
        // then owns it whatever it's called.
        GitFixture.sh("git branch -m feature fix-login", in: URL(fileURLWithPath: path))
        let renamed = await GitService.isCreatedByWortel(branch: "fix-login", root: repo.path)
        XCTAssertTrue(renamed)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertTrue(report.isOwned)
        XCTAssertTrue(report.ownsBranch)
    }

    /// An existing branch checked out by Wortel: the worktree is Wortel's,
    /// the branch never is.
    func testAnExistingBranchIsNeverRecordedAsCreated() async {
        GitFixture.sh("git branch theirs", in: repo)
        let path = base.appendingPathComponent("made/theirs").path
        let error = await GitService.addWorktree(root: repo.path, at: path, branch: "theirs", source: .existingBranch)
        XCTAssertNil(error)
        XCTAssertEqual(GitWorktree.linked(containing: path)?.isOwned, true)
        let created = await GitService.isCreatedByWortel(branch: "theirs", root: repo.path)
        XCTAssertFalse(created)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertFalse(report.ownsBranch)
    }

    /// One made by hand, or by another tool: shown, never Wortel's.
    func testAForeignWorktreeIsNeverOwned() async {
        GitFixture.sh("git worktree add -q -b by-hand ../by-hand", in: repo)
        let path = base.appendingPathComponent("by-hand").path
        XCTAssertEqual(GitWorktree.linked(containing: path)?.isOwned, false)
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertFalse(report.isOwned)
        XCTAssertFalse(report.ownsBranch)
    }

    /// Everything made before the markers stays Wortel's by where it is, and
    /// a `worktree/` branch by its name.
    func testTheLegacyRulesStillCount() async {
        let legacyRoot = base.appendingPathComponent("legacy-root")
        GitFixture.sh("git worktree add -q -b worktree/old \(legacyRoot.path)/app/old", in: repo)
        let path = legacyRoot.appendingPathComponent("app/old").path
        XCTAssertTrue(GitWorktree.Ownership.isOwned(root: path, under: legacyRoot))
        XCTAssertFalse(GitWorktree.Ownership.isOwned(root: path, under: base.appendingPathComponent("elsewhere")))
        let report = await WorktreeCleanup.inspect(path: path)
        XCTAssertTrue(report.ownsBranch)
    }

    /// A worktree deleted by hand still holds its branch in git's records.
    /// Adding that branch again works, and only that stale record goes: a
    /// missing worktree of another branch (an unmounted volume) is kept.
    func testAStaleRegistrationInTheWayIsDroppedAndNoOther() async {
        GitFixture.sh("git worktree add -q -b again ../gone-again", in: repo)
        GitFixture.sh("git worktree add -q -b elsewhere ../gone-elsewhere", in: repo)
        GitFixture.destroy(base.appendingPathComponent("gone-again"))
        GitFixture.destroy(base.appendingPathComponent("gone-elsewhere"))

        let path = base.appendingPathComponent("made/again").path
        let error = await GitService.addWorktree(root: repo.path, at: path, branch: "again", source: .existingBranch)
        XCTAssertNil(error)
        let listed = await GitService.worktrees(root: repo.path)
        XCTAssertEqual(listed.first { $0.branch == "again" }.map { GitWorktree.realPath($0.path) },
                       GitWorktree.realPath(path))
        XCTAssertTrue(listed.contains { $0.branch == "elsewhere" }, "an unrelated missing worktree stays registered")
    }

    // MARK: - Where a new one goes

    func testSameNamedRepositoriesGetTheirOwnFolders() {
        let root = base.appendingPathComponent("worktrees")
        let other = base.appendingPathComponent("side/app")
        GitFixture.sh("mkdir -p side && git init -q -b main side/app", in: base)
        GitFixture.commit("other", in: other)

        let first = GitWorktree.newWorktreePath(forBranch: "fix", repoRoot: repo.path, under: root)
        XCTAssertEqual(first, root.appendingPathComponent("app/fix").path)
        GitFixture.sh("git worktree add -q -b fix \(first)", in: repo)

        // The same repository keeps using its folder.
        XCTAssertEqual(GitWorktree.newWorktreePath(forBranch: "next", repoRoot: repo.path, under: root),
                       root.appendingPathComponent("app/next").path)
        // Another repository called "app" doesn't land beside it.
        let second = GitWorktree.newWorktreePath(forBranch: "fix", repoRoot: other.path, under: root)
        XCTAssertNotEqual((second as NSString).deletingLastPathComponent, root.appendingPathComponent("app").path)
        XCTAssertTrue((second as NSString).deletingLastPathComponent.hasPrefix(root.appendingPathComponent("app-").path))
        // And says so the same way every time.
        XCTAssertEqual(second, GitWorktree.newWorktreePath(forBranch: "fix", repoRoot: other.path, under: root))
    }

    /// Never a folder that's there, or that an agent keeps history for.
    func testAUsedFolderIsNeverReused() {
        let root = base.appendingPathComponent("worktrees")
        let taken = root.appendingPathComponent("app/fix").path
        GitFixture.sh("mkdir -p \(taken)", in: base)
        XCTAssertEqual(GitWorktree.newWorktreePath(forBranch: "fix", repoRoot: repo.path, under: root),
                       root.appendingPathComponent("app/fix-2").path)
        let remembered = GitWorktree.newWorktreePath(forBranch: "other", repoRoot: repo.path, under: root) {
            $0.hasSuffix("/other")
        }
        XCTAssertEqual(remembered, root.appendingPathComponent("app/other-2").path)
    }

    func testRepositoryHomeAtAnyDepth() {
        GitFixture.sh("mkdir -p src/deep", in: repo)
        XCTAssertEqual(GitWorktree.repositoryHome(containing: repo.appendingPathComponent("src/deep").path),
                       GitWorktree.realPath(repo.path))
        GitFixture.sh("git worktree add -q -b side ../app-side", in: repo)
        XCTAssertEqual(GitWorktree.repositoryHome(containing: base.appendingPathComponent("app-side").path),
                       GitWorktree.realPath(repo.path))
        XCTAssertNil(GitWorktree.repositoryHome(containing: "/nonexistent/at/all"))
    }
}
