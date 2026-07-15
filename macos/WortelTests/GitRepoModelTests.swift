import XCTest

/// The model's behaviour under the conditions that actually bite: a watcher
/// firing during a build, a commit made in the terminal, and a reader scrolling
/// back through a long history.
@MainActor
final class GitRepoModelTests: XCTestCase {
    private var repo: URL!

    override func tearDown() {
        if let repo { GitFixture.destroy(repo) }
        repo = nil
        super.tearDown()
    }

    /// Regression: `refresh()` used to check nothing before scanning, and the
    /// debounce only cancelled *pending* work — so a burst of watch events ran
    /// eight concurrent full worktree walks. On a monorepo that's seconds of CPU
    /// each, next to a terminal that has to stay smooth. Eight requests must
    /// collapse into one scan, plus at most one more for whatever changed while
    /// that scan was running.
    func testConcurrentRefreshesCollapseIntoOneScan() async {
        repo = GitFixture.newRepo("coalesce")
        GitFixture.commit("base", in: repo)
        let model = GitRepoModel(root: repo.path)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in await model.refresh() }
            }
        }
        // The queued re-run may still be settling.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertGreaterThanOrEqual(model.statusScans, 1, "the status must actually be read")
        XCTAssertLessThanOrEqual(model.statusScans, 2,
                                 "8 concurrent refreshes must not run 8 scans")
    }

    func testRefreshReadsStatus() async {
        repo = GitFixture.newRepo("refresh")
        GitFixture.commit("base", in: repo)
        GitFixture.sh("echo x > a.txt && git add a.txt", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()

        XCTAssertEqual(model.status.branch, "main")
        XCTAssertEqual(model.status.stagedChanges.map(\.path), ["a.txt"])
    }

    /// Committing in the terminal is the normal way to use Wortel. The History
    /// pane used to only reload for commits made through its own commit box, so
    /// it silently went stale.
    func testHistoryReloadsWhenHeadMovesOutsideThePanel() async {
        repo = GitFixture.newRepo("headmove")
        GitFixture.commit("first", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        await model.loadHistory()
        XCTAssertEqual(model.commits.count, 1)

        // A commit made behind the panel's back, as if typed in the terminal.
        GitFixture.commit("made in the terminal", in: repo)
        await model.refresh()

        XCTAssertEqual(model.commits.count, 2, "history must follow HEAD")
        XCTAssertEqual(model.commits.first?.subject, "made in the terminal")
    }

    /// ...but only once History has actually been read; otherwise it stays lazy.
    func testHeadMoveDoesNotForceHistoryLoadIfPaneWasNeverOpened() async {
        repo = GitFixture.newRepo("lazy")
        GitFixture.commit("first", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        GitFixture.commit("second", in: repo)
        await model.refresh()

        XCTAssertFalse(model.loadedHistory, "opening the panel on Changes must cost no log read")
        XCTAssertTrue(model.commits.isEmpty)
    }

    func testShortHistoryDoesNotOfferMorePages() async {
        repo = GitFixture.newRepo("short")
        for i in 0..<5 { GitFixture.commit("c\(i)", in: repo) }

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()

        XCTAssertEqual(model.commits.count, 5)
        XCTAssertFalse(model.canLoadMoreHistory, "a short first page means we hit the root")

        // Asking anyway must be a no-op, not a duplicate row.
        await model.loadMoreHistory()
        XCTAssertEqual(model.commits.count, 5)
    }

    /// The pane pages as you scroll; rows already on screen must not move, or the
    /// list jumps under the cursor.
    func testPagingAppendsWithoutDisturbingWhatIsOnScreen() async {
        repo = GitFixture.newRepo("paging")
        GitFixture.importHistory(trunk: 1100, concurrent: 8, lifetime: 450, in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()
        XCTAssertEqual(model.commits.count, GitRepoModel.historyPageSize)
        XCTAssertTrue(model.canLoadMoreHistory)

        let firstPage = model.commits.map(\.sha)
        await model.loadMoreHistory()

        XCTAssertGreaterThan(model.commits.count, firstPage.count, "the page must be appended")
        XCTAssertEqual(Array(model.commits.prefix(firstPage.count)).map(\.sha), firstPage,
                       "rows already shown must keep their exact positions")
        XCTAssertEqual(Set(model.commits.map(\.sha)).count, model.commits.count, "no duplicates")

        // The graph must stay consistent with the grown list.
        for commit in model.commits {
            XCTAssertNotNil(model.graph.row(for: commit.sha), "every row needs lane data")
        }
    }

    func testPagingToTheEndReproducesTheWholeHistory() async {
        repo = GitFixture.newRepo("pageall")
        GitFixture.importHistory(trunk: 1100, concurrent: 8, lifetime: 450, in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()
        var guardrail = 0
        while model.canLoadMoreHistory && guardrail < 20 {
            await model.loadMoreHistory()
            guardrail += 1
        }

        let everything = await GitService.log(root: repo.path, limit: 100_000)
        XCTAssertEqual(Set(model.commits.map(\.sha)), Set(everything.map(\.sha)),
                       "paging must reach exactly the history git reports")
        XCTAssertFalse(model.canLoadMoreHistory)
    }

    /// A commit landing invalidates the --skip offsets the pages ride on, so
    /// paging resets rather than stitching onto a window that moved.
    func testHeadMoveResetsPaging() async {
        repo = GitFixture.newRepo("reset")
        GitFixture.importHistory(trunk: 1100, concurrent: 8, lifetime: 450, in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        await model.loadHistory()
        await model.loadMoreHistory()
        XCTAssertGreaterThan(model.commits.count, GitRepoModel.historyPageSize)

        GitFixture.commit("new tip", in: repo)
        await model.refresh()

        XCTAssertEqual(model.commits.count, GitRepoModel.historyPageSize,
                       "a moved HEAD reloads the first page rather than stitching")
        XCTAssertEqual(model.commits.first?.subject, "new tip")
        XCTAssertEqual(Set(model.commits.map(\.sha)).count, model.commits.count)
    }

    func testSelectingACommitLoadsItsDiff() async {
        repo = GitFixture.newRepo("commitdiff")
        GitFixture.sh("echo a > f.txt && git add f.txt && git commit -q -m 'add f'", in: repo)
        GitFixture.sh("echo b >> f.txt && git commit -q -am 'append to f'", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()
        await model.selectCommit(model.commits[0].id)

        XCTAssertEqual(model.selectedCommitID, model.commits[0].sha)
        XCTAssertNotNil(model.commitDiff)
        XCTAssertTrue(model.commitDiff?.lines.contains { $0.text.contains("b") } ?? false)
    }

    /// ↑/↓ walk the log and stop at the ends rather than running off.
    func testArrowNavigationClampsAtBothEnds() async {
        repo = GitFixture.newRepo("arrows")
        for i in 0..<4 { GitFixture.commit("c\(i)", in: repo) }

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()

        XCTAssertEqual(model.selectedCommitID, model.commits[0].sha,
                       "opening History selects the newest commit, so ↑/↓ start from there")

        model.selectAdjacentCommit(1)
        await settle()
        XCTAssertEqual(model.selectedCommitID, model.commits[1].sha, "↓ steps to the next oldest")

        for _ in 0..<10 { model.selectAdjacentCommit(1); await settle() }
        XCTAssertEqual(model.selectedCommitID, model.commits.last?.sha, "↓ clamps at the oldest")

        for _ in 0..<10 { model.selectAdjacentCommit(-1); await settle() }
        XCTAssertEqual(model.selectedCommitID, model.commits.first?.sha, "↑ clamps at the newest")
    }

    func testEmptyRepoHasNoHistoryAndNoCrash() async {
        repo = GitFixture.newRepo("emptymodel")
        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        await model.loadHistory()

        XCTAssertTrue(model.commits.isEmpty)
        XCTAssertTrue(model.loadedHistory, "we did read the log; it was just empty")
        XCTAssertFalse(model.canLoadMoreHistory)
        model.selectAdjacentCommit(1)
        XCTAssertNil(model.selectedCommitID)
    }

    /// selectAdjacentCommit kicks off an async selection; give it a turn.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }
}
