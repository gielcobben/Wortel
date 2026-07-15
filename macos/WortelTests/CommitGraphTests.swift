import XCTest

/// The gutter's job is to draw what `git log --graph` draws, in a column or two,
/// over a window rather than the whole repo. Width is the sharpest measure of
/// that: both lane bugs found in this code showed up as "we use N columns where
/// git uses far fewer".
final class CommitGraphTests: XCTestCase {
    private var repo: URL!

    override func tearDown() {
        if let repo { GitFixture.destroy(repo) }
        repo = nil
        super.tearDown()
    }

    private func graph(limit: Int = 100_000) async -> (commits: [GitCommit], graph: CommitGraph) {
        let ordered = CommitOrder.topological(
            await GitService.log(root: repo.path, limit: limit))
        return (ordered, CommitGraph.build(ordered))
    }

    func testWidthMatchesGitOnBranchyHistory() async {
        repo = GitFixture.newRepo("width")
        GitFixture.importHistory(trunk: 400, concurrent: 5, lifetime: 80, in: repo)

        let (_, g) = await graph()
        XCTAssertEqual(g.width, GitFixture.graphWidth(in: repo),
                       "gutter must be as wide as git's own graph, no wider")
    }

    /// Regression: twenty branches forking from one commit used to run twenty
    /// parallel columns to the same place — 31 lanes where git drew 5. git folds
    /// them as they converge and draws "|/"; so must we.
    func testFoldsLanesThatShareAParent() async {
        repo = GitFixture.newRepo("fold")
        GitFixture.commit("fork point", in: repo)
        let base = GitFixture.sh("git rev-parse HEAD", in: repo)
        for i in 0..<12 {
            GitFixture.sh("git checkout -q -b topic\(i) \(base)", in: repo)
            GitFixture.commit("topic\(i) work", in: repo)
        }
        GitFixture.sh("git checkout -q main", in: repo)
        for i in 0..<12 {
            GitFixture.sh("git merge -q --no-ff -m 'Merge topic\(i)' topic\(i)", in: repo)
        }

        let (_, g) = await graph()
        XCTAssertEqual(g.width, GitFixture.graphWidth(in: repo),
                       "branches sharing a fork point must converge, not run parallel columns")
        XCTAssertLessThan(g.width, 12, "twelve branches from one commit must not need twelve lanes")
    }

    /// Regression: a lane waiting on a parent below the window used to stay open
    /// forever, so lane count grew all the way down — 26 lanes at the bottom of a
    /// 1000-commit window. Those lanes must retire where their history is cut.
    func testLanesRetireAtTheWindowEdgeInsteadOfAccumulating() async {
        repo = GitFixture.newRepo("retire")
        // Branches must outlive the window, so the window is full of merges whose
        // fork points sit outside it — that's what leaves lanes waiting on
        // commits that never arrive.
        GitFixture.importHistory(trunk: 900, concurrent: 8, lifetime: 400, in: repo)

        let (commits, g) = await graph(limit: 200)
        XCTAssertEqual(commits.count, 200)

        // The fixture has to actually produce the condition, or this test is
        // green for the wrong reason.
        let loaded = Set(commits.map(\.sha))
        let dangling = commits.reduce(into: 0) { total, c in
            total += c.parents.filter { !loaded.contains($0) }.count
        }
        XCTAssertGreaterThan(dangling, 3, "fixture must cut several lanes for this to mean anything")

        // Width must not creep as you go down the list.
        func columns(_ c: GitCommit) -> Int {
            guard let r = g.row(for: c.sha) else { return 0 }
            var used = Set(r.passThrough)
            used.insert(r.lane)
            for e in r.incoming { used.insert(e.from) }
            for e in r.outgoing { used.insert(e.to) }
            return (used.max() ?? 0) + 1
        }
        let bottom = columns(commits[commits.count - 1])
        XCTAssertLessThanOrEqual(bottom, 4,
                                 "lanes are accumulating toward the bottom instead of retiring")
        XCTAssertLessThanOrEqual(g.width, 6, "windowed graph should stay narrow")
        // Deliberately not compared against git's width here. `--graph` implies
        // --topo-order, so git's own N-commit window holds a different set of
        // commits than our newest-N-by-date, and git has no reason to retire a
        // lane at the cut — it can legitimately be wider. Width equality only
        // holds over a whole history; testWidthMatchesGitOnBranchyHistory covers
        // that case.
    }

    /// A cut lane says so, so the pane can draw a stub rather than implying the
    /// history simply ends.
    func testCutHistoryIsMarkedContinuesBelow() async {
        repo = GitFixture.newRepo("stub")
        GitFixture.importHistory(trunk: 400, concurrent: 5, lifetime: 200, in: repo)

        let (commits, g) = await graph(limit: 20)
        let oldest = commits[commits.count - 1]
        XCTAssertFalse(oldest.parents.isEmpty, "fixture's oldest windowed commit has parents")
        XCTAssertTrue(g.row(for: oldest.sha)?.continuesBelow == true,
                      "a commit whose parents are all unloaded must be marked as continuing")
    }

    /// A true root ends the line; it doesn't continue anywhere.
    func testRootCommitEndsCleanly() async {
        repo = GitFixture.newRepo("root")
        GitFixture.commit("only commit", in: repo)

        let (commits, g) = await graph()
        let row = g.row(for: commits[0].sha)
        XCTAssertEqual(row?.outgoing.count, 0)
        XCTAssertEqual(row?.continuesBelow, false, "a root must not claim more history below")
        XCTAssertEqual(g.width, 1)
    }

    func testOctopusMergeGetsAnEdgePerLoadedParent() async {
        repo = GitFixture.newRepo("octopus")
        GitFixture.commit("base", in: repo)
        for b in ["b1", "b2", "b3"] {
            GitFixture.sh("git checkout -q -b \(b) main", in: repo)
            GitFixture.commit("\(b) work", in: repo)
        }
        GitFixture.sh("git checkout -q main", in: repo)
        GitFixture.sh("git merge -q --no-ff -m 'Octopus' b1 b2 b3", in: repo)

        let (commits, g) = await graph()
        guard let octopus = commits.first(where: { $0.parents.count > 2 }) else {
            return XCTFail("fixture did not produce an octopus merge")
        }
        XCTAssertEqual(octopus.parents.count, 4)
        XCTAssertEqual(g.row(for: octopus.sha)?.outgoing.count, 4,
                       "every loaded parent needs an edge leaving the dot")
        XCTAssertTrue(octopus.isMerge)
    }

    /// Nothing may be drawn in a column the gutter didn't reserve room for.
    func testNoRowDrawsBeyondTheReportedWidth() async {
        repo = GitFixture.newRepo("bounds")
        GitFixture.importHistory(trunk: 600, concurrent: 8, lifetime: 250, in: repo)

        let (commits, g) = await graph(limit: 150)
        for commit in commits {
            guard let r = g.row(for: commit.sha) else { return XCTFail("missing row") }
            XCTAssertLessThan(r.lane, g.width)
            for edge in r.incoming + r.outgoing {
                XCTAssertLessThan(edge.from, g.width)
                XCTAssertLessThan(edge.to, g.width)
            }
            for lane in r.passThrough { XCTAssertLessThan(lane, g.width) }
        }
    }

    /// Every loaded parent must be reachable from the dot, or a line is missing.
    func testEveryLoadedParentHasAnEdge() async {
        repo = GitFixture.newRepo("edges")
        GitFixture.importHistory(trunk: 400, concurrent: 5, lifetime: 150, in: repo)

        let (commits, g) = await graph(limit: 80)
        let loaded = Set(commits.map(\.sha))
        for commit in commits {
            guard let r = g.row(for: commit.sha) else { return XCTFail("missing row") }
            let expected = commit.parents.filter { loaded.contains($0) }.count
            XCTAssertEqual(r.outgoing.count, expected, "wrong edge count for \(commit.shortSHA)")
        }
    }

    func testEmptyHistory() {
        let g = CommitGraph.build([])
        XCTAssertEqual(g.width, 0)
        XCTAssertNil(g.row(for: "nope"))
    }

    /// Paging must resolve stubs, not leave a branch hanging.
    func testStubsBecomeRealLinesWhenMoreHistoryLoads() async {
        repo = GitFixture.newRepo("resolve")
        GitFixture.importHistory(trunk: 400, concurrent: 6, lifetime: 150, in: repo)

        let page1 = CommitOrder.topological(await GitService.log(root: repo.path, limit: 40))
        let g1 = CommitGraph.build(page1)
        let stubbed = page1.filter { g1.row(for: $0.sha)?.continuesBelow == true }
        XCTAssertFalse(stubbed.isEmpty, "a 40-commit window of this fixture must cut something")

        let rest = await GitService.log(root: repo.path, limit: 200, skip: 40)
        let known = Set(page1.map(\.sha))
        let all = CommitOrder.topological(page1 + rest.filter { !known.contains($0.sha) },
                                          settled: page1.count)
        let g2 = CommitGraph.build(all)
        for commit in stubbed where !commit.parents.isEmpty {
            XCTAssertFalse(g2.row(for: commit.sha)?.continuesBelow ?? true,
                           "\(commit.shortSHA) still marked cut after its parents loaded")
        }
    }
}
