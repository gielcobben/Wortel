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
