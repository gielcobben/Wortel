import XCTest

/// The changes list is live because this is watching, and — like the file
/// tree's vnode watcher — the way it goes wrong is silent: a watch that covers
/// the wrong directory reports nothing, which looks exactly like a repo where
/// nothing is happening. The panel just keeps showing what it last read.
///
/// A session in a linked worktree is where that actually bit. Its `.git` is a
/// *file*; HEAD, the index and the reflog live under the primary's
/// `.git/worktrees/<name>`, so staging and committing there move nothing at all
/// under the work tree being watched, and the Changes list went on listing files
/// that had been committed minutes earlier.
final class GitRepoWatcherTests: XCTestCase {
    private var repo: URL!
    private var worktree: String!

    override func setUp() {
        super.setUp()
        repo = GitFixture.newRepo("watcher")
        GitFixture.sh("printf 'a\\n' > a.txt && git add a.txt", in: repo)
        GitFixture.commit("first", in: repo)
        worktree = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        GitFixture.sh("git worktree add -q -b linked \(GitFixture.shellQuoted(worktree!))", in: repo)
    }

    override func tearDown() {
        if let worktree { GitFixture.destroy(URL(fileURLWithPath: worktree)) }
        if let repo { GitFixture.destroy(repo) }
        repo = nil
        worktree = nil
        super.tearDown()
    }

    /// Both halves of the fix in one test, because the fix is a difference: the
    /// same commit, in the same worktree, watched two ways.
    ///
    /// The staging happens *before* either watcher starts, so the only thing
    /// left to observe is the commit — which writes no file under the work tree.
    func testAWorktreeCommitIsInvisibleFromTheWorkTreeAlone() async {
        let tree = URL(fileURLWithPath: worktree)
        GitFixture.sh("printf 'b\\n' >> a.txt && git add a.txt", in: tree)

        guard let gitDir = await GitService.externalGitDir(root: worktree) else {
            return XCTFail("a linked worktree keeps its git state outside its work tree")
        }

        let blind = expectation(description: "work tree alone saw the commit")
        blind.isInverted = true
        blind.assertForOverFulfill = false
        let rootOnly = GitRepoWatcher(paths: [worktree]) { blind.fulfill() }

        let sighted = expectation(description: "work tree plus gitdir saw the commit")
        sighted.assertForOverFulfill = false
        let withGitDir = GitRepoWatcher(paths: [worktree, gitDir]) { sighted.fulfill() }

        GitFixture.sh("git commit -q -m 'committed in the worktree'", in: tree)

        await fulfillment(of: [sighted], timeout: 5)
        // Long enough to be a real answer rather than a race with FSEvents'
        // coalescing window (0.25s), which the positive half has already cleared.
        await fulfillment(of: [blind], timeout: 2)

        withExtendedLifetime((rootOnly, withGitDir)) {}
    }

    /// The other half of what the work-tree watch is for: an edit to a tracked
    /// file is seen from the work tree, gitdir or no gitdir. Worth pinning
    /// separately — the widened watch must not have been a *replacement* for the
    /// root, which is where every ordinary change to a repo shows up.
    func testAFileEditIsStillSeenFromTheWorkTree() {
        let seen = expectation(description: "watcher fired")
        seen.assertForOverFulfill = false
        let watcher = GitRepoWatcher(paths: [worktree]) { seen.fulfill() }

        GitFixture.sh("printf 'edited\\n' >> a.txt", in: URL(fileURLWithPath: worktree))

        wait(for: [seen], timeout: 5)
        withExtendedLifetime(watcher) {}
    }
}

/// Worktrees *inside* the checkout: `wortel.worktreePath = .worktrees`, or
/// Claude Code's `.claude/worktrees/<name>`. Every file an agent writes in one
/// is under the main checkout's root too, and on the work laptop's monorepo
/// each was a seven-second `git status` there for nothing. The way this goes
/// wrong is quiet in both directions: leave one in and the cost is back, with
/// nothing on screen to say so; leave out a folder that holds the repository's
/// own files and edits there stop showing up.
final class GitRepoWatcherExclusionTests: XCTestCase {
    private func contents(_ tree: [String: [String]]) -> (String) -> [String]? {
        { tree[$0] }
    }

    func testAFolderOfNothingButWorktreesIsLeftOutWhole() {
        let found = GitRepoWatcher.exclusions(
            root: "/r", always: ["/r/.git/worktrees"],
            worktrees: ["/r/.worktrees/a", "/r/.worktrees/b"],
            contents: contents(["/r/.worktrees": ["a", "b", ".DS_Store"]]))
        XCTAssertEqual(found, ["/r/.git/worktrees", "/r/.worktrees"])
    }

    /// `.claude` holds settings and commands the checkout's status must still
    /// see; only `.claude/worktrees` is the agent's.
    func testOnlyTheFolderTheWorktreesAreIn() {
        let found = GitRepoWatcher.exclusions(
            root: "/r", always: [],
            worktrees: ["/r/.claude/worktrees/x"],
            contents: contents(["/r/.claude/worktrees": ["x"], "/r/.claude": ["settings.json", "worktrees"]]))
        XCTAssertEqual(found, ["/r/.claude/worktrees"])
    }

    func testAFolderThatAlsoHoldsTheRepositorysFilesIsNot() {
        let found = GitRepoWatcher.exclusions(
            root: "/r", always: [],
            worktrees: ["/r/tools/wt"],
            contents: contents(["/r/tools": ["wt", "build.sh"]]))
        XCTAssertEqual(found, ["/r/tools/wt"])
    }

    /// Worktrees beside the root, or the root itself, are never collapsed into
    /// the root: that would leave out the whole checkout.
    func testNeverTheRootAndNeverOutside() {
        let found = GitRepoWatcher.exclusions(
            root: "/r", always: [],
            worktrees: ["/r", "/r-feature", "/r/wt", "/elsewhere/x"],
            contents: contents(["/r": ["wt"]]))
        XCTAssertEqual(found, ["/r/wt"])
    }

    func testAWorktreeInsideAnotherIsCoveredByIt() {
        let found = GitRepoWatcher.exclusions(
            root: "/r", always: [],
            worktrees: ["/r/a", "/r/a/.claude/worktrees/x"],
            contents: contents(["/r": ["a", "src"], "/r/a/.claude/worktrees": ["x"]]))
        XCTAssertEqual(found, ["/r/a"])
    }

    func testIsExcludedByWholeComponents() {
        let excluded = ["/r/.worktrees"]
        XCTAssertTrue(GitRepoWatcher.isExcluded("/r/.worktrees", by: excluded))
        XCTAssertTrue(GitRepoWatcher.isExcluded("/r/.worktrees/", by: excluded))
        XCTAssertTrue(GitRepoWatcher.isExcluded("/r/.worktrees/a/file", by: excluded))
        XCTAssertFalse(GitRepoWatcher.isExcluded("/r/.worktrees-old/file", by: excluded))
        XCTAssertFalse(GitRepoWatcher.isExcluded("/r/src/file", by: excluded))
    }

    /// Against real git: what `git worktree add` writes is what's read.
    func testReadFromTheRepositoryOnDisk() {
        let repo = GitFixture.newRepo("exclusions")
        defer { GitFixture.destroy(repo) }
        GitFixture.sh("printf 'a\\n' > a.txt && git add a.txt", in: repo)
        GitFixture.commit("first", in: repo)
        GitFixture.sh("mkdir -p tools && printf 'x\\n' > tools/build.sh", in: repo)
        GitFixture.sh("git worktree add -q -b one .worktrees/one", in: repo)
        GitFixture.sh("git worktree add -q -b two .worktrees/two", in: repo)
        GitFixture.sh("git worktree add -q -b three tools/three", in: repo)
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)").path
        defer { GitFixture.destroy(URL(fileURLWithPath: outside)) }
        GitFixture.sh("git worktree add -q -b four \(GitFixture.shellQuoted(outside))", in: repo)

        let root = GitWorktree.realPath(repo.path)
        XCTAssertEqual(GitRepoWatcher.exclusions(forCheckoutAt: repo.path), [
            root + "/.git/worktrees",
            root + "/.git/objects",
            root + "/.worktrees",
            root + "/tools/three",
        ])
        // From a linked worktree: nothing inside it, and no `.git/worktrees`.
        XCTAssertEqual(GitRepoWatcher.exclusions(forCheckoutAt: outside), [])
    }

    /// Past FSEvents' eight, the callback has to drop what the kernel
    /// couldn't. The ninth exclusion is the one written to.
    func testExclusionsPastTheKernelsLimitAreFiltered() {
        let repo = GitFixture.newRepo("overflow")
        defer { GitFixture.destroy(repo) }
        GitFixture.sh("mkdir -p ninth && printf 'a\\n' > a.txt", in: repo)
        let root = GitWorktree.realPath(repo.path)
        let excluding = (1...8).map { "\(root)/nothing-\($0)" } + ["\(root)/ninth"]

        let quiet = expectation(description: "a write in the ninth exclusion woke the watch")
        quiet.isInverted = true
        quiet.assertForOverFulfill = false
        let watcher = GitRepoWatcher(paths: [root], excluding: excluding) { quiet.fulfill() }
        GitFixture.sh("printf 'b\\n' > ninth/file", in: repo)
        wait(for: [quiet], timeout: 2)
        withExtendedLifetime(watcher) {}

        let seen = expectation(description: "a write elsewhere woke the watch")
        seen.assertForOverFulfill = false
        let second = GitRepoWatcher(paths: [root], excluding: excluding) { seen.fulfill() }
        GitFixture.sh("printf 'c\\n' >> a.txt", in: repo)
        wait(for: [seen], timeout: 5)
        withExtendedLifetime(second) {}
    }
}
