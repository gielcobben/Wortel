import XCTest

/// Integration tests for the branch/unpushed reads behind the History pane's
/// chips, blue dots and switcher. Real git, real repos — including a real remote
/// (a bare repo on disk), because "unpushed" is defined entirely by what a
/// remote has and cannot be faked convincingly.
final class GitBranchServiceTests: XCTestCase {
    private var repo: URL!
    private var remote: URL!

    override func tearDown() {
        if let repo { GitFixture.destroy(repo) }
        if let remote { GitFixture.destroy(remote) }
        repo = nil
        remote = nil
        super.tearDown()
    }

    /// Give `repo` an `origin` that already has `main`, so the interesting states
    /// (ahead of upstream, branch with no upstream) can be built on top.
    private func attachRemote() {
        remote = GitFixture.newRepo("remote")
        GitFixture.sh("rm -rf .git && git init -q --bare .", in: remote)
        GitFixture.sh("git remote add origin \(remote.path)", in: repo)
        GitFixture.sh("git push -q --set-upstream origin HEAD:refs/heads/main", in: repo)
        GitFixture.sh("git fetch -q origin", in: repo)
    }

    // MARK: - Decoration on the log

    func testLogCarriesRefsForChips() async {
        repo = GitFixture.newRepo("decorate")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git tag v1.0", in: repo)
        GitFixture.commit("second", in: repo)
        GitFixture.sh("git branch sidequest", in: repo)

        let commits = await GitService.log(root: repo.path, limit: 10)
        let tip = commits[0]
        XCTAssertTrue(tip.isHead, "the tip is where HEAD is")
        XCTAssertEqual(
            Set(tip.refs.map(\.name)), ["main", "sidequest"],
            "both branches point at the tip")
        XCTAssertEqual(commits[1].refs.map(\.name), ["v1.0"])
        XCTAssertEqual(commits[1].refs.map(\.kind), [.tag])
        XCTAssertFalse(commits[1].isHead)
    }

    /// The subject stays last in the format string precisely so a subject that
    /// looks like a field separator can't shift anything after it. %D landing
    /// between parents and subject is the case that would break.
    func testDecorationDoesNotShearSubjects() async {
        repo = GitFixture.newRepo("shear")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git commit -q --allow-empty -m 'subject, with a comma -> arrow'",
                      in: repo)

        let commits = await GitService.log(root: repo.path, limit: 10)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "subject, with a comma -> arrow")
    }

    // MARK: - Unpushed

    /// The blue dots must be exactly what git says is ahead — the header reports
    /// the same range as a count, and the two sitting side by side must agree.
    func testUnpushedMatchesAheadOfUpstream() async {
        repo = GitFixture.newRepo("ahead")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.commit("local one", in: repo)
        GitFixture.commit("local two", in: repo)

        let unpushed = await GitService.unpushedSHAs(
            root: repo.path, upstream: "origin/main", hasRemotes: true)
        let oracle = Set(
            GitFixture.sh("git rev-list origin/main..HEAD", in: repo)
                .split(separator: "\n").map(String.init))

        XCTAssertEqual(unpushed, oracle)
        XCTAssertEqual(unpushed.count, 2)

        let status = await GitService.status(root: repo.path)
        XCTAssertEqual(
            status.ahead, unpushed.count,
            "the header's count and the dots are the same range or the panel lies")
    }

    /// A branch with no upstream is the normal state of new work, and its commits
    /// are exactly the ones no remote has yet.
    func testUnpushedOnBranchWithNoUpstream() async {
        repo = GitFixture.newRepo("noupstream")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git checkout -q -b feature/new", in: repo)
        GitFixture.commit("work", in: repo)

        let status = await GitService.status(root: repo.path)
        XCTAssertNil(status.upstream, "a fresh branch tracks nothing")

        let unpushed = await GitService.unpushedSHAs(
            root: repo.path, upstream: nil, hasRemotes: true)
        XCTAssertEqual(unpushed.count, 1, "only the commit no remote has")
    }

    /// With no remote at all, `--not --remotes` excludes nothing, so every commit
    /// would dot. "Unpushed" isn't a thing the repo can mean yet — draw nothing.
    func testNoRemotesMeansNoDots() async {
        repo = GitFixture.newRepo("local-only")
        GitFixture.commit("first", in: repo)
        GitFixture.commit("second", in: repo)

        let hasRemotes = await GitService.hasRemotes(root: repo.path)
        XCTAssertFalse(hasRemotes)
        let unpushed = await GitService.unpushedSHAs(
            root: repo.path, upstream: nil, hasRemotes: false)
        XCTAssertTrue(unpushed.isEmpty, "a repo with no remote has nothing to be unpushed from")
    }

    func testPushedCommitsAreNotDotted() async {
        repo = GitFixture.newRepo("pushed")
        GitFixture.commit("first", in: repo)
        attachRemote()

        let unpushed = await GitService.unpushedSHAs(
            root: repo.path, upstream: "origin/main", hasRemotes: true)
        XCTAssertTrue(unpushed.isEmpty, "everything is on the remote")
    }

    // MARK: - Branches

    func testBranchesListsLocalAndRemoteWithCurrentMarked() async {
        repo = GitFixture.newRepo("branches")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git checkout -q -b feature/x", in: repo)
        GitFixture.commit("work", in: repo)

        let branches = await GitService.branches(root: repo.path)
        let local = branches.filter { !$0.isRemote }
        let remotes = branches.filter(\.isRemote)

        XCTAssertEqual(Set(local.map(\.name)), ["main", "feature/x"])
        XCTAssertEqual(local.filter(\.isCurrent).map(\.name), ["feature/x"])
        XCTAssertEqual(remotes.map(\.name), ["origin/main"])
        XCTAssertEqual(
            local.first { $0.name == "main" }?.upstream, "origin/main",
            "main tracks the remote it was pushed to")
        XCTAssertNil(
            local.first { $0.name == "feature/x" }?.upstream,
            "a fresh branch tracks nothing")
    }

    /// origin/HEAD is a symref to the remote's default branch — listing it offers
    /// a duplicate of origin/main that checks out the same thing.
    func testRemoteHeadSymrefIsNotOffered() async {
        repo = GitFixture.newRepo("symref")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git remote set-head origin main", in: repo)

        let branches = await GitService.branches(root: repo.path)
        XCTAssertFalse(
            branches.contains { $0.name.hasSuffix("/HEAD") },
            "origin/HEAD is not a branch a person picks")
    }

    // MARK: - Checkout

    func testCheckoutSwitchesBranch() async {
        repo = GitFixture.newRepo("checkout")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git branch sidequest", in: repo)

        let branch = GitBranch(
            name: "sidequest", isRemote: false, sha: "", upstream: nil, isCurrent: false)
        let error = await GitService.checkout(root: repo.path, branch: branch)

        XCTAssertNil(error)
        let status = await GitService.status(root: repo.path)
        XCTAssertEqual(status.branch, "sidequest")
    }

    /// Checking out a remote branch by its remote name would detach HEAD. The
    /// short name is passed so git's DWIM creates a tracking branch instead.
    func testCheckoutOfRemoteBranchCreatesTrackingBranch() async {
        repo = GitFixture.newRepo("track")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git checkout -q -b other && git commit -q --allow-empty -m x", in: repo)
        GitFixture.sh("git push -q origin other:refs/heads/upstream-only", in: repo)
        GitFixture.sh("git fetch -q origin && git checkout -q main", in: repo)

        let branch = GitBranch(
            name: "origin/upstream-only", isRemote: true, sha: "", upstream: nil, isCurrent: false)
        let error = await GitService.checkout(root: repo.path, branch: branch)

        XCTAssertNil(error)
        let status = await GitService.status(root: repo.path)
        XCTAssertEqual(status.branch, "upstream-only", "DWIM, not a detached HEAD")
        XCTAssertEqual(status.upstream, "origin/upstream-only")
    }

    /// The safety of the switcher: git refuses rather than discarding work, and
    /// the refusal is what gets shown. Nothing here ever passes --force.
    func testCheckoutRefusedRatherThanLosingChangesReportsWhy() async {
        repo = GitFixture.newRepo("dirty")
        GitFixture.sh("echo one > shared.txt && git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("git checkout -q -b other", in: repo)
        GitFixture.sh("echo other > shared.txt && git commit -q -am other", in: repo)
        GitFixture.sh("git checkout -q main", in: repo)
        // Uncommitted work that switching would have to throw away.
        GitFixture.sh("echo mine > shared.txt", in: repo)

        let branch = GitBranch(
            name: "other", isRemote: false, sha: "", upstream: nil, isCurrent: false)
        let error = await GitService.checkout(root: repo.path, branch: branch)

        XCTAssertNotNil(error, "git must refuse")
        XCTAssertTrue(
            error?.contains("shared.txt") ?? false,
            "the message names the file at risk — that's the whole value of showing it")
        let status = await GitService.status(root: repo.path)
        XCTAssertEqual(status.branch, "main", "still on the branch we started on")
        XCTAssertEqual(
            GitFixture.sh("cat shared.txt", in: repo).trimmingCharacters(in: .whitespacesAndNewlines),
            "mine",
            "the uncommitted work survived")
    }
}
