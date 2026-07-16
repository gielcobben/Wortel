import XCTest

/// CommitOrder exists so the pane can ask git for its cheap default ordering and
/// re-establish `--topo-order` locally, because asking git for that ordering
/// makes it walk the entire repo. So the bar is exact: same output as git, for
/// the same set of commits.
final class CommitOrderTests: XCTestCase {
    private var repo: URL!

    override func tearDown() {
        if let repo { GitFixture.destroy(repo) }
        repo = nil
        super.tearDown()
    }

    /// The core contract. This is what caught the tie-break bug where we walked
    /// the trunk before a merged-in branch, holding the branch's lane open for
    /// 13 rows instead of 3.
    func testMatchesGitTopoOrderOnBranchyHistory() async {
        repo = GitFixture.newRepo("branchy")
        // Long-lived branches leave genuinely independent chains, so the walk has
        // a real choice at each merge. With branches that merge a few rows after
        // forking, in-degree forces one ordering and any tie-break passes.
        GitFixture.importHistory(trunk: 400, concurrent: 5, lifetime: 80, in: repo)

        let ordered = CommitOrder.topological(
            await GitService.log(root: repo.path, limit: 100_000))

        XCTAssertEqual(ordered.map(\.sha), GitFixture.topoOrderSHAs(in: repo),
                       "ordering must be identical to git log --topo-order")
    }

    /// Octopus merges, a criss-cross, and an unrelated orphan root — the shapes
    /// that break naive graph code.
    func testMatchesGitOnOctopusCrissCrossAndOrphanRoot() async {
        repo = GitFixture.newRepo("tricky")
        let g = { GitFixture.sh($0, in: self.repo) }
        GitFixture.commit("base", in: repo)
        g("git branch b1; git branch b2; git branch b3")
        for b in ["b1", "b2", "b3"] {
            g("git checkout -q \(b)")
            GitFixture.commit("\(b) work", in: repo)
        }
        g("git checkout -q main")
        g("git merge -q --no-ff -m 'Octopus merge' b1 b2 b3")
        GitFixture.commit("after octopus", in: repo)
        // Criss-cross: each branch merges the other's tip.
        g("git checkout -q -b x")
        GitFixture.commit("x1", in: repo)
        g("git checkout -q main")
        GitFixture.commit("m1", in: repo)
        g("git merge -q --no-ff -m 'main takes x' x")
        g("git checkout -q x; git merge -q --no-ff -m 'x takes main' main")
        g("git checkout -q main; git merge -q --no-ff -m 'main takes x again' x")
        // A root sharing no history at all.
        g("git checkout -q --orphan orphan")
        GitFixture.commit("orphan root", in: repo)
        g("git checkout -q main")
        g("git merge -q --no-ff --allow-unrelated-histories -m 'Merge unrelated' orphan")

        let ordered = CommitOrder.topological(
            await GitService.log(root: repo.path, limit: 100_000))

        XCTAssertEqual(ordered.map(\.sha), GitFixture.topoOrderSHAs(in: repo))
    }

    /// The invariant the lane layout actually depends on, checked on a *window*
    /// rather than the full history — the case git's own flags can't give us
    /// cheaply.
    func testEveryCommitPrecedesItsParentsWithinAWindow() async {
        repo = GitFixture.newRepo("window")
        GitFixture.importHistory(trunk: 900, concurrent: 8, lifetime: 400, in: repo)

        let ordered = CommitOrder.topological(
            await GitService.log(root: repo.path, limit: 120))
        XCTAssertEqual(ordered.count, 120)

        let inWindow = Set(ordered.map(\.sha))
        var seen = Set<String>()
        for commit in ordered {
            for parent in commit.parents where inWindow.contains(parent) {
                XCTAssertFalse(seen.contains(parent),
                               "\(commit.shortSHA) was emitted after its parent")
            }
            seen.insert(commit.sha)
        }
    }

    /// Paging freezes what's already on screen. Sorting the grown window from
    /// scratch moved 118 of the first 300 rows — the list jumping under the
    /// reader's cursor mid-scroll.
    func testSettledPrefixNeverMoves() async {
        repo = GitFixture.newRepo("paging")
        // The window must cut branches mid-flight, or growing it changes nothing
        // and freezing the prefix is untested.
        GitFixture.importHistory(trunk: 900, concurrent: 8, lifetime: 400, in: repo)

        let page1 = CommitOrder.topological(await GitService.log(root: repo.path, limit: 200))
        let rest = await GitService.log(root: repo.path, limit: 200, skip: 200)
        let known = Set(page1.map(\.sha))
        let combined = page1 + rest.filter { !known.contains($0.sha) }

        let paged = CommitOrder.topological(combined, settled: page1.count)
        XCTAssertEqual(Array(paged.prefix(page1.count)).map(\.sha), page1.map(\.sha),
                       "rows already shown must keep their exact positions")
        XCTAssertEqual(Set(paged.map(\.sha)).count, paged.count, "no duplicated rows")

        // Guard the test itself: sorting the same input from scratch *must* move
        // rows here. If it doesn't, the fixture is too tame and the assertion
        // above proves nothing.
        let resorted = CommitOrder.topological(combined, settled: 0)
        XCTAssertNotEqual(Array(resorted.prefix(page1.count)).map(\.sha), page1.map(\.sha),
                          "fixture must be one where re-sorting from scratch shifts rows")
    }

    /// Freezing the prefix must not cost the invariant.
    func testSettledPagingStillOrdersParentsAfterChildren() async {
        repo = GitFixture.newRepo("paging-invariant")
        GitFixture.importHistory(trunk: 900, concurrent: 8, lifetime: 400, in: repo)

        var commits = CommitOrder.topological(await GitService.log(root: repo.path, limit: 100))
        for _ in 0..<3 {
            let next = await GitService.log(root: repo.path, limit: 100, skip: commits.count)
            let known = Set(commits.map(\.sha))
            commits = CommitOrder.topological(commits + next.filter { !known.contains($0.sha) },
                                              settled: commits.count)
        }

        let all = Set(commits.map(\.sha))
        var seen = Set<String>()
        for commit in commits {
            for parent in commit.parents where all.contains(parent) {
                XCTAssertFalse(seen.contains(parent), "\(commit.shortSHA) emitted after its parent")
            }
            seen.insert(commit.sha)
        }
    }

    func testKeepsEveryCommitItIsGiven() async {
        repo = GitFixture.newRepo("complete")
        GitFixture.importHistory(trunk: 200, concurrent: 4, lifetime: 60, in: repo)

        let raw = await GitService.log(root: repo.path, limit: 100_000)
        let ordered = CommitOrder.topological(raw)
        XCTAssertEqual(Set(ordered.map(\.sha)), Set(raw.map(\.sha)))
        XCTAssertEqual(ordered.count, raw.count)
    }

    func testEmptyAndSingleCommit() {
        XCTAssertTrue(CommitOrder.topological([]).isEmpty)
        let one = [commit("A", parents: [])]
        XCTAssertEqual(CommitOrder.topological(one).map(\.sha), ["A"])
    }

    /// A grafted or corrupt history mustn't drop rows — showing them slightly
    /// out of order beats showing nothing.
    func testStrandedCommitsAreStillReturned() {
        // B and C form a cycle, which a real git DAG can't contain; nothing
        // would ever reach in-degree zero.
        let cyclic = [
            commit("A", parents: ["B"]),
            commit("B", parents: ["C"]),
            commit("C", parents: ["B"]),
        ]
        let ordered = CommitOrder.topological(cyclic)
        XCTAssertEqual(Set(ordered.map(\.sha)), ["A", "B", "C"])
        XCTAssertEqual(ordered.count, 3, "no duplicates when recovering stranded commits")
    }

    func testParentsOutsideTheWindowAreIgnored() {
        let commits = [
            commit("A", parents: ["MISSING"]),
            commit("B", parents: ["ALSO-MISSING"]),
        ]
        XCTAssertEqual(CommitOrder.topological(commits).count, 2)
    }

    /// Refs are irrelevant here — ordering is pure topology — but they're not
    /// defaulted on the model, so that the log parser can never quietly stop
    /// populating them.
    private func commit(_ sha: String, parents: [String]) -> GitCommit {
        GitCommit(sha: sha, author: "t", date: Date(timeIntervalSince1970: 0),
                  subject: sha, parents: parents, refs: [])
    }
}
