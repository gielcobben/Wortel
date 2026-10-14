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

    // MARK: - The repository's own location

    func testLocationTemplates() {
        let repo = "/w/shop"
        XCTAssertEqual(GitWorktree.location(template: ".worktrees", repoRoot: repo, branch: "feature/x"),
                       "/w/shop/.worktrees/" + GitWorktree.slug(forBranch: "feature/x"))
        XCTAssertEqual(GitWorktree.location(template: "../{repo}-worktrees/", repoRoot: repo, branch: "fix"),
                       "/w/shop-worktrees/fix")
        XCTAssertEqual(GitWorktree.location(template: "/srv/wt/{repo}/{branch}", repoRoot: repo, branch: "fix"),
                       "/srv/wt/shop/fix")
        XCTAssertEqual(GitWorktree.location(template: "~/work/trees/{repo}.{branch}", repoRoot: repo, branch: "a b"),
                       NSHomeDirectory() + "/work/trees/shop." + GitWorktree.slug(forBranch: "a b"))
    }

    /// Set in git config (any level), read by the add path, and the folder
    /// it names replaces Wortel's; a worktree inside the repository is kept
    /// out of its status by info/exclude, never .gitignore.
    func testTheRepositorysLocationIsUsedAndKeptOutOfStatus() async {
        GitFixture.sh("git config wortel.worktreePath .worktrees", in: repo)
        let location = await GitService.worktreeLocation(root: repo.path)
        XCTAssertEqual(location, ".worktrees")
        let path = GitWorktree.newWorktreePath(forBranch: "inside", repoRoot: repo.path,
                                               under: base.appendingPathComponent("unused"), location: location)
        XCTAssertEqual(path, repo.appendingPathComponent(".worktrees/inside").path)
        let error = await GitService.addWorktree(root: repo.path, at: path, branch: "inside", source: .newBranch(from: "main"))
        XCTAssertNil(error)
        XCTAssertEqual(GitWorktree.linked(containing: path)?.isOwned, true)
        XCTAssertEqual(GitFixture.sh("git status --porcelain", in: repo), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".gitignore").path))
        XCTAssertTrue(GitFixture.sh("cat .git/info/exclude", in: repo).contains("/.worktrees/"))

        // A second one adds no second line.
        let next = GitWorktree.newWorktreePath(forBranch: "again", repoRoot: repo.path, location: location)
        _ = await GitService.addWorktree(root: repo.path, at: next, branch: "again", source: .newBranch(from: "main"))
        XCTAssertEqual(GitFixture.sh("grep -c '^/.worktrees/$' .git/info/exclude", in: repo), "1")

        // Clearing it goes back to Wortel's folder.
        let cleared = await GitService.setWorktreeLocation(nil, root: repo.path)
        XCTAssertTrue(cleared)
        let after = await GitService.worktreeLocation(root: repo.path)
        XCTAssertNil(after)
    }

    /// Wortel's own worktrees made in a repository's location are found by
    /// Clean Up, through the repository, by their marker; one made by hand
    /// beside them isn't.
    func testCleanUpFindsOwnedWorktreesInTheRepositorysLocation() async {
        let path = base.appendingPathComponent("trees/mine").path
        _ = await GitService.addWorktree(root: repo.path, at: path, branch: "mine", source: .newBranch(from: "main"))
        GitFixture.sh("git worktree add -q -b theirs ../trees/theirs", in: repo)
        let found = await WorktreeCleanup.discover(knownRepos: [repo.path], under: base.appendingPathComponent("none"),
                                                   broughtHere: [])
        XCTAssertEqual(found.map(GitWorktree.realPath), [GitWorktree.realPath(path)])
    }

    /// A location deeper in the repository (Claude Code's `.claude/worktrees`)
    /// excludes that folder, never its parent: `/.claude/` would hide every
    /// new file under `.claude` from status, and so from every commit.
    func testANestedLocationExcludesOnlyItsOwnFolder() async {
        GitFixture.sh("git config wortel.worktreePath .claude/worktrees", in: repo)
        let location = await GitService.worktreeLocation(root: repo.path)
        let path = GitWorktree.newWorktreePath(forBranch: "deep", repoRoot: repo.path, location: location)
        let error = await GitService.addWorktree(root: repo.path, at: path, branch: "deep", source: .newBranch(from: "main"))
        XCTAssertNil(error)
        let exclude = GitFixture.sh("cat .git/info/exclude", in: repo)
        XCTAssertTrue(exclude.contains("/.claude/worktrees/"))
        XCTAssertFalse(exclude.split(separator: "\n").contains("/.claude/"))
        GitFixture.sh("mkdir -p .claude/commands && echo x > .claude/commands/new.md", in: repo)
        XCTAssertEqual(GitFixture.sh("git status --porcelain", in: repo), "?? .claude/")
    }

    /// The git dir every checkout shares, from the repository's home, off the
    /// disk: the `worktrees` folder the sidebar watches lives in it.
    func testCommonDir() {
        XCTAssertEqual(GitWorktree.commonDir(ofHome: repo.path), repo.appendingPathComponent(".git").path)
        let bare = base.appendingPathComponent("bare-home")
        GitFixture.sh("mkdir -p bare-home && git clone -q --bare app bare-home/.bare", in: base)
        XCTAssertEqual(GitWorktree.commonDir(ofHome: bare.path), bare.appendingPathComponent(".bare").path)
        XCTAssertNil(GitWorktree.commonDir(ofHome: base.appendingPathComponent("nowhere").path))
    }

    /// Restoring an archived session in someone else's worktree makes its
    /// folder again without making it Wortel's to remove.
    func testAWorktreePutBackUnmarkedIsntOwned() async {
        GitFixture.sh("git branch theirs", in: repo)
        let path = base.appendingPathComponent("back/theirs").path
        let error = await GitService.addWorktree(root: repo.path, at: path, branch: "theirs",
                                                 source: .existingBranch, mark: false)
        XCTAssertNil(error)
        XCTAssertEqual(GitWorktree.linked(containing: path)?.isOwned, false)
    }

    /// A folder only looks gone when its volume isn't mounted, and its
    /// registration must survive that.
    func testAnUnmountedVolumeIsntGone() {
        XCTAssertTrue(GitService.isOnUnmountedVolume("/Volumes/wortel-no-such-disk-\(UUID().uuidString)/wt/x"))
        XCTAssertFalse(GitService.isOnUnmountedVolume(base.appendingPathComponent("gone").path))
        XCTAssertFalse(GitService.isOnUnmountedVolume("/Volumes"))
    }
}
