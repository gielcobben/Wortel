import XCTest

/// A worktree's placeholder branch, renamed for the work once the session
/// has a name. Renaming one somebody already knows by name (pushed, yours,
/// checked out elsewhere) would break their remote or their scripts, so the
/// rule is narrow, and this pins it.
final class BranchRenameTests: XCTestCase {
    func testOnlyAPlaceholderIsGenerated() {
        let made = GitWorktree.generatedBranch(seed: 12345)
        XCTAssertTrue(GitWorktree.isGenerated(made))
        XCTAssertTrue(GitWorktree.isGenerated("worktree/brave-river-1a2f"))
        for other in ["worktree/pr-7", "worktree/main-fork-1a2f", "brave-river-1a2f",
                      "worktree/brave-river", "worktree/brave-river-1a2g", "worktree/bold-river-1a2f",
                      "fix-login", "worktree/brave-river-1a2f-2"] {
            XCTAssertFalse(GitWorktree.isGenerated(other), other)
        }
    }

    func testANameBecomesABranch() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertEqual(GitWorktree.renamedBranch(forName: "Fix login redirect", isTaken: none), "fix-login-redirect")
        XCTAssertEqual(GitWorktree.renamedBranch(forName: "Café: résumé upload!", isTaken: none), "café-résumé-upload")
        XCTAssertEqual(GitWorktree.renamedBranch(forName: "  ", isTaken: none), nil)
        XCTAssertEqual(GitWorktree.renamedBranch(forName: "!!!", isTaken: none), nil)
        // Still the placeholder's own leaf: nothing to rename to.
        XCTAssertNil(GitWorktree.renamedBranch(forName: "brave-river-1a2f", isTaken: none))
        // Cut at a word, not mid-word.
        let long = GitWorktree.renamedBranch(
            forName: "Make the sidebar remember which folders were open across launches", isTaken: none)
        XCTAssertEqual(long, "make-the-sidebar-remember-which-folders")
        XCTAssertLessThanOrEqual(long?.count ?? 0, 40)
    }

    func testATakenNameGetsASuffix() {
        let taken: Set = ["fix-login", "fix-login-2"]
        XCTAssertEqual(GitWorktree.renamedBranch(forName: "Fix login", isTaken: { taken.contains($0) }),
                       "fix-login-3")
    }

    /// git accepts every name made, as a branch to rename to.
    func testGitAcceptsTheNames() throws {
        let repo = GitFixture.newRepo("rename")
        defer { GitFixture.destroy(repo) }
        GitFixture.commit("first", in: repo)
        for name in ["Fix login redirect", "Café: résumé upload!", "a.b..c", "-dash first", "trailing dot."] {
            guard let target = GitWorktree.renamedBranch(forName: name, isTaken: { _ in false }) else { continue }
            XCTAssertEqual(GitFixture.sh("git check-ref-format --branch \(GitFixture.shellQuoted(target)) >/dev/null && echo ok",
                                         in: repo), "ok", name)
        }
    }

    func testOnlyWhileNobodyElseKnowsIt() {
        let branch = "worktree/calm-stone-0042"
        XCTAssertTrue(GitWorktree.mayRename(branch, createdByWortel: true, hasUpstream: false, onRemote: false, checkouts: 1))
        XCTAssertFalse(GitWorktree.mayRename(branch, createdByWortel: false, hasUpstream: false, onRemote: false, checkouts: 1))
        XCTAssertFalse(GitWorktree.mayRename(branch, createdByWortel: true, hasUpstream: true, onRemote: false, checkouts: 1))
        XCTAssertFalse(GitWorktree.mayRename(branch, createdByWortel: true, hasUpstream: false, onRemote: true, checkouts: 1))
        XCTAssertFalse(GitWorktree.mayRename(branch, createdByWortel: true, hasUpstream: false, onRemote: false, checkouts: 2))
        XCTAssertFalse(GitWorktree.mayRename("fix-login", createdByWortel: true, hasUpstream: false, onRemote: false, checkouts: 1))
    }

    /// git moves the branch's config (the creation record) with a rename.
    func testTheCreationRecordFollowsTheRename() async {
        let repo = GitFixture.newRepo("rename-record")
        defer { GitFixture.destroy(repo) }
        GitFixture.commit("first", in: repo)
        let path = repo.deletingLastPathComponent().appendingPathComponent("rename-wt-\(UUID().uuidString)").path
        defer { GitFixture.destroy(URL(fileURLWithPath: path)) }
        let branch = "worktree/quiet-field-00aa"
        _ = await GitService.addWorktree(root: repo.path, at: path, branch: branch, source: .newBranch(from: "main"))
        GitFixture.sh("git branch -m \(branch) fix-login", in: repo)
        let created = await GitService.isCreatedByWortel(branch: "fix-login", root: repo.path)
        XCTAssertTrue(created)
        XCTAssertEqual(GitWorktree.checkedOutBranch(at: path), "fix-login")
    }
}
