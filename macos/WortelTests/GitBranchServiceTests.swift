import XCTest

/// Integration tests for the branch/unpushed reads behind the History pane's
/// chips, blue dots and switcher. Real git, real repos — including a real remote
/// (a bare repo on disk), because "unpushed" is defined entirely by what a
/// remote has and cannot be faked convincingly.
final class GitBranchServiceTests: XCTestCase {
    private var repo: URL!
    private var remote: URL!
    /// A *second* remote, for the ambiguity cases. Only some tests attach one.
    private var otherRemote: URL!
    /// Worktrees the worktree tests create. They live outside `repo` by design
    /// (see GitWorktree.path), so tearing down the repo does not reach them.
    private var worktrees: [URL] = []

    override func tearDown() {
        for tree in worktrees { GitFixture.destroy(tree) }
        if let repo { GitFixture.destroy(repo) }
        if let remote { GitFixture.destroy(remote) }
        if let otherRemote { GitFixture.destroy(otherRemote) }
        worktrees = []
        repo = nil
        remote = nil
        otherRemote = nil
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

    /// A second bare remote under `name`, carrying every branch `repo` has. The
    /// fork-workflow shape: two remotes with the same branch names on them.
    private func attachSecondRemote(named name: String) {
        otherRemote = GitFixture.newRepo("remote2")
        GitFixture.sh("rm -rf .git && git init -q --bare .", in: otherRemote)
        GitFixture.sh("git remote add \(name) \(otherRemote.path)", in: repo)
        GitFixture.sh("git push -q \(name) --all", in: repo)
        GitFixture.sh("git fetch -q \(name)", in: repo)
    }

    /// A path for a worktree, outside the repo and cleaned up in tearDown.
    private func worktreePath(_ label: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-tests-wt-\(label)-\(UUID().uuidString)")
        worktrees.append(url)
        return url.path
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

    /// The split exists for cost (see GitService.localBranches), so the thing to
    /// pin is that narrowing the namespace did not also change the answer.
    func testLocalAndRemoteHalvesPartitionTheWholeList() async {
        repo = GitFixture.newRepo("halves")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git checkout -q -b feature/x", in: repo)
        GitFixture.commit("work", in: repo)

        let all = await GitService.branches(root: repo.path)
        let locals = await GitService.localBranches(root: repo.path)
        let remotes = await GitService.remoteBranches(root: repo.path)

        XCTAssertEqual(Set(locals.map(\.name)), ["main", "feature/x"])
        XCTAssertTrue(locals.allSatisfy { !$0.isRemote }, "refs/heads only")
        XCTAssertEqual(Set(remotes.map(\.name)), ["origin/main"])
        XCTAssertTrue(remotes.allSatisfy(\.isRemote), "refs/remotes only")
        XCTAssertEqual(
            Set(all.map(\.id)), Set(locals.map(\.id)).union(remotes.map(\.id)),
            "the two halves are the whole, or the cheap call is a different question")
        XCTAssertEqual(
            locals.filter(\.isCurrent).map(\.name), ["feature/x"],
            "the current marker survives the narrowing")
    }

    // MARK: - The fork point

    /// A fetch moves `refs/remotes/*` and never fast-forwards the local branch,
    /// so the local trunk is exactly the stale thing a new branch must not fork
    /// from. This is the assertion the whole fetch-while-the-dialog-is-open
    /// dance exists to make true.
    func testDefaultBasePrefersTheRemoteTrackingCopy() async {
        repo = GitFixture.newRepo("base-remote")
        GitFixture.commit("first", in: repo)
        attachRemote()

        let base = await GitService.defaultBase(root: repo.path)
        let trunk = await GitService.defaultBranch(root: repo.path)
        XCTAssertEqual(base, "origin/main")
        XCTAssertEqual(
            trunk, "main",
            "defaultBranch still names the local one; they are different questions")
    }

    /// The remote is trunk's *upstream*, not the string "origin". A fork
    /// checkout tracks `upstream/main`, and naming origin there either misses
    /// (stale local trunk) or hits your fork's own copy.
    func testDefaultBaseFollowsTrunksUpstreamRatherThanTheNameOrigin() async {
        repo = GitFixture.newRepo("base-fork")
        GitFixture.commit("first", in: repo)
        remote = GitFixture.newRepo("remote")
        GitFixture.sh("rm -rf .git && git init -q --bare .", in: remote)
        GitFixture.sh("git remote add upstream \(remote.path)", in: repo)
        GitFixture.sh("git push -q --set-upstream upstream HEAD:refs/heads/main", in: repo)
        GitFixture.sh("git fetch -q upstream", in: repo)

        let base = await GitService.defaultBase(root: repo.path)
        XCTAssertEqual(base, "upstream/main")
    }

    /// No remote to prefer, so the local branch is the honest answer rather than
    /// a ref that doesn't resolve.
    func testDefaultBaseFallsBackToTheLocalBranch() async {
        repo = GitFixture.newRepo("base-local")
        GitFixture.commit("first", in: repo)

        let base = await GitService.defaultBase(root: repo.path)
        XCTAssertEqual(base, "main")
    }

    /// A repository with no commits has no branch to name, and handing
    /// `worktree add` a base that doesn't resolve is the failure this avoids.
    func testDefaultBaseIsNilInAnEmptyRepository() async {
        repo = GitFixture.newRepo("base-empty")

        let base = await GitService.defaultBase(root: repo.path)
        XCTAssertNil(base)
    }

    // MARK: - Remote-only branches

    func testRemotesWithBranchNamesEveryRemoteCarryingIt() async {
        repo = GitFixture.newRepo("carriers")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git checkout -q -b shared", in: repo)
        GitFixture.commit("work", in: repo)
        GitFixture.sh("git push -q origin shared", in: repo)
        attachSecondRemote(named: "upstream")
        GitFixture.sh("git fetch -q --all", in: repo)

        let carriers = await GitService.remotesWithBranch(root: repo.path, branch: "shared")
        let none = await GitService.remotesWithBranch(root: repo.path, branch: "nobody-has-this")
        XCTAssertEqual(Set(carriers), ["origin", "upstream"])
        XCTAssertEqual(none, [], "a name no remote carries is not on a remote")
    }

    /// The local value wins over whatever the developer running the tests has in
    /// their global config, which is why this sets it on the repository.
    func testDefaultRemoteReadsCheckoutDefaultRemote() async {
        repo = GitFixture.newRepo("default-remote")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git config checkout.defaultRemote upstream", in: repo)

        let preferred = await GitService.defaultRemote(root: repo.path)
        XCTAssertEqual(preferred, "upstream")
    }

    func testDefaultRemoteIsNilWhenSetToNothing() async {
        repo = GitFixture.newRepo("default-remote-empty")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git config checkout.defaultRemote ''", in: repo)

        let preferred = await GitService.defaultRemote(root: repo.path)
        XCTAssertNil(preferred, "an empty value is not a remote name")
    }

    // MARK: - Worktrees for a branch

    /// Checking out a colleague's branch: it exists on a remote and nowhere
    /// locally, and `worktree add <path> <name>` with no `-b` is git's own
    /// answer. The local branch is created at the remote one, tracking it, with
    /// their commits — as opposed to a new empty branch wearing their name,
    /// which is what `-b` would have made.
    func testWorktreeForARemoteOnlyBranchChecksOutTheirWork() async {
        repo = GitFixture.newRepo("remote-only")
        GitFixture.commit("first", in: repo)
        attachRemote()
        GitFixture.sh("git checkout -q -b theirs", in: repo)
        GitFixture.commit("their work", in: repo)
        GitFixture.sh("git push -q origin theirs", in: repo)
        GitFixture.sh("git checkout -q main && git branch -q -D theirs", in: repo)
        GitFixture.sh("git fetch -q --prune", in: repo)

        let localsBefore = await GitService.localBranches(root: repo.path)
        XCTAssertFalse(
            localsBefore.contains { $0.name == "theirs" },
            "precondition: the branch is only on the remote")

        let path = worktreePath("theirs")
        let error = await GitService.addWorktree(
            root: repo.path, at: path, branch: "theirs", source: .existingBranch)
        XCTAssertNil(error)

        let tree = URL(fileURLWithPath: path)
        XCTAssertEqual(GitFixture.sh("git rev-parse --abbrev-ref HEAD", in: tree), "theirs")
        XCTAssertEqual(
            GitFixture.sh("git rev-parse --abbrev-ref '@{upstream}'", in: tree),
            "origin/theirs",
            "checking out someone's branch means tracking it")
        XCTAssertTrue(
            GitFixture.sh("git log --format=%s", in: tree).contains("their work"),
            "their commits, not an empty branch with their name on it")
    }

    /// Forking from a remote-tracking ref must not make that ref the new
    /// branch's upstream: `push.default=simple` refuses to push a branch whose
    /// upstream is named something else, so the session's first push would fail
    /// on a repository that had done nothing wrong. Hence `--no-track`.
    func testNewBranchForkedFromARemoteRefGetsNoUpstream() async {
        repo = GitFixture.newRepo("no-track")
        GitFixture.commit("first", in: repo)
        attachRemote()

        let path = worktreePath("fresh")
        let error = await GitService.addWorktree(
            root: repo.path, at: path, branch: "fresh", source: .newBranch(from: "origin/main"))
        XCTAssertNil(error)

        let tree = URL(fileURLWithPath: path)
        XCTAssertEqual(GitFixture.sh("git rev-parse --abbrev-ref HEAD", in: tree), "fresh")
        XCTAssertEqual(
            GitFixture.sh("git rev-parse --abbrev-ref '@{upstream}' 2>&1 || true", in: tree)
                .contains("no upstream"), true,
            "a branch you just made has nothing to be tracking yet")
        XCTAssertEqual(
            GitFixture.sh("git rev-parse HEAD", in: tree),
            GitFixture.sh("git rev-parse origin/main", in: repo),
            "it still forked from the ref it was told to")
    }

    /// A repository with no commits: HEAD resolves to nothing, so there is no
    /// base to name and git infers an orphan branch. Handing it `HEAD` anyway is
    /// what used to fail with `invalid reference: HEAD`.
    func testFirstBranchInAnEmptyRepositoryIsAnOrphan() async {
        repo = GitFixture.newRepo("orphan")

        let path = worktreePath("orphan")
        let error = await GitService.addWorktree(
            root: repo.path, at: path, branch: "start", source: .newBranch(from: nil))
        XCTAssertNil(error)
        // `symbolic-ref` rather than `rev-parse --abbrev-ref`, which answers
        // "HEAD" here: the branch is unborn, so HEAD points at a ref that does
        // not exist yet and there is nothing for rev-parse to resolve. That it
        // is unborn is the point — an orphan is what a first branch should be.
        let tree = URL(fileURLWithPath: path)
        XCTAssertEqual(GitFixture.sh("git symbolic-ref --short HEAD", in: tree), "start")
        XCTAssertEqual(
            GitFixture.sh("git rev-list -n1 --all | wc -l | tr -d ' '", in: tree), "0",
            "nothing to fork from, so nothing was forked")
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

    // MARK: - Branches in other folders

    /// The switcher's sections rest on this: which folder each local branch is
    /// checked out in, this one or another worktree's, and none for a free one.
    func testBranchesSayWhichFolderEachIsCheckedOutIn() async {
        repo = GitFixture.newRepo("where")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git branch free && git branch busy", in: repo)
        let tree = worktreePath("busy")
        GitFixture.sh("git worktree add -q \(tree) busy", in: repo)

        let branches = await GitService.localBranches(root: repo.path)
        let resolved = { (path: String?) in path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        let byName = Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) })

        XCTAssertEqual(resolved(byName["main"]?.worktreePath), resolved(repo.path))
        XCTAssertEqual(resolved(byName["busy"]?.worktreePath), resolved(tree))
        XCTAssertNil(byName["free"]?.worktreePath)
        XCTAssertNotNil(byName["free"]?.date, "the age on the right comes from here")
    }

    /// Reached only by a race (the list routes such a branch to Show), but
    /// then said in words, with the folder, and not as git's `fatal:`.
    func testCheckoutOfABranchInAnotherFolderSaysWhere() async {
        repo = GitFixture.newRepo("elsewhere")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git branch busy", in: repo)
        let tree = worktreePath("taken")
        GitFixture.sh("git worktree add -q \(tree) busy", in: repo)

        let branch = GitBranch(
            name: "busy", isRemote: false, sha: "", upstream: nil, isCurrent: false)
        let error = await GitService.checkout(root: repo.path, branch: branch)

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains((tree as NSString).lastPathComponent) ?? false, error ?? "")
        XCTAssertFalse(error?.contains("fatal") ?? true, error ?? "")
    }
}
