import XCTest
import os

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

    func testSelectingACommitLoadsItsFilesAndDiff() async {
        repo = GitFixture.newRepo("commitdiff")
        GitFixture.sh("echo a > f.txt && git add f.txt && git commit -q -m 'add f'", in: repo)
        GitFixture.sh("echo b >> f.txt && git commit -q -am 'append to f'", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()
        await model.selectCommit(model.commits[0].id)

        XCTAssertEqual(model.selectedCommitID, model.commits[0].sha)
        // The commit touched exactly one file, so it lists f.txt as modified…
        XCTAssertEqual(model.commitFiles.map(\.path), ["f.txt"])
        XCTAssertEqual(model.commitFiles.first?.statusCode, "M")
        XCTAssertEqual(model.commitFiles.first?.additions, 1)
        XCTAssertEqual(model.commitFiles.first?.deletions, 0)
        // …and a single-file commit auto-expands, so its diff is already loaded.
        XCTAssertTrue(model.expandedCommitFiles.contains("f.txt"))
        let diff = model.commitFileDiffs["f.txt"]
        XCTAssertNotNil(diff)
        XCTAssertTrue(diff?.lines.contains { $0.text.contains("b") } ?? false)
    }

    /// Collapsing a file drops its diff from view but the SHA+path cache keeps it,
    /// so re-expanding never re-reads git — and a multi-file commit does not
    /// auto-expand.
    func testTogglingCommitFiles() async {
        repo = GitFixture.newRepo("toggle")
        GitFixture.sh("echo a > a.txt && echo b > b.txt && git add . "
                      + "&& git commit -q -m 'two files'", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.loadHistory()
        await model.selectCommit(model.commits[0].id)

        XCTAssertEqual(Set(model.commitFiles.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertTrue(model.expandedCommitFiles.isEmpty, "a multi-file commit opens collapsed")

        let a = model.commitFiles.first { $0.path == "a.txt" }!
        await model.toggleCommitFile(a)
        XCTAssertTrue(model.expandedCommitFiles.contains("a.txt"))
        XCTAssertNotNil(model.commitFileDiffs["a.txt"])

        await model.toggleCommitFile(a)
        XCTAssertFalse(model.expandedCommitFiles.contains("a.txt"))
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


    // MARK: - Multi-selection

    /// The panel's whole reason for having a selection rather than a selected
    /// row: pick several, discard them once. The model has to end with those rows
    /// gone from both the list and the selection, because a stale id is a file
    /// the next bulk action would take without it ever being highlighted again.
    func testDiscardingASelectionTakesEveryRowAndLeavesNoneSelected() async {
        repo = GitFixture.newRepo("multi-discard")
        GitFixture.sh("printf 'one\\n' > a.txt && printf 'two\\n' > b.txt", in: repo)
        GitFixture.sh("printf 'three\\n' > c.txt", in: repo)
        GitFixture.sh("git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'edit\\n' >> a.txt", in: repo)
        GitFixture.sh("printf 'edit\\n' >> b.txt", in: repo)
        GitFixture.sh("printf 'edit\\n' >> c.txt", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        XCTAssertEqual(model.orderedChanges.count, 3)

        // Click the first row, then ⇧-click the second: two of the three.
        model.select(model.orderedChanges[0].id)
        model.extendSelection(to: model.orderedChanges[1].id)
        XCTAssertEqual(model.selectedChanges.map(\.path), ["a.txt", "b.txt"])

        await model.discard(model.selectedChanges)

        XCTAssertEqual(model.orderedChanges.map(\.path), ["c.txt"],
                       "both selected files went back to HEAD; the third was never asked about")
        XCTAssertFalse(model.selection.contains("W:a.txt"))
        XCTAssertFalse(model.selection.contains("W:b.txt"))
    }

    /// The diff pane follows the lead, and the lead has to stay inside the
    /// selection. ⌘-clicking the row it is on is the case that breaks it: the
    /// pane would go on showing a patch for a file no longer in what the next
    /// action takes.
    func testTheDiffAlwaysFollowsARowThatIsStillSelected() async {
        repo = GitFixture.newRepo("multi-lead")
        GitFixture.sh("printf 'one\\n' > a.txt && printf 'two\\n' > b.txt", in: repo)
        GitFixture.sh("git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'edit\\n' >> a.txt && printf 'edit\\n' >> b.txt", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()

        model.select(model.orderedChanges[0].id)
        model.toggleSelection(model.orderedChanges[1].id)
        XCTAssertEqual(model.selectedChangeID, model.orderedChanges[1].id)

        model.toggleSelection(model.orderedChanges[1].id)
        XCTAssertEqual(model.selectedChangeID, model.orderedChanges[0].id,
                       "the lead moved to the row that is still selected")
        XCTAssertTrue(model.selection.contains(model.selectedChangeID!))
    }

    /// Staging a selection is one `git add`, and one status after it. Per file it
    /// would be a full worktree walk each, which is the cost rule this whole pane
    /// is built around.
    func testStagingASelectionRunsOneStatusScan() async {
        repo = GitFixture.newRepo("multi-stage")
        GitFixture.sh("printf 'x\\n' > a.txt && printf 'x\\n' > b.txt", in: repo)
        GitFixture.sh("printf 'x\\n' > c.txt && git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'edit\\n' >> a.txt", in: repo)
        GitFixture.sh("printf 'edit\\n' >> b.txt && printf 'edit\\n' >> c.txt", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        model.selectAllChanges()
        XCTAssertEqual(model.selectedChanges.count, 3)

        let before = model.statusScans
        await model.stage(model.selectedChanges)
        XCTAssertEqual(model.statusScans - before, 1, "three files, one scan")
        XCTAssertEqual(model.status.stagedChanges.count, 3)
        XCTAssertTrue(model.status.unstagedChanges.isEmpty)
    }

    /// The panel caches a model per repo it has shown, and every one of them
    /// used to scan on every write. An agent merging in one worktree then woke
    /// a full `git status` in every cached checkout at once: four concurrent 7s
    /// scans of a monorepo, a core each. One that isn't shown must only note
    /// that it's stale; the shown one beside it proves the write was seen.
    func testAnInactiveModelGoesStaleInsteadOfScanning() async {
        repo = GitFixture.newRepo("inactive")
        GitFixture.commit("base", in: repo)
        let shown = GitRepoModel(root: repo.path)
        let hidden = GitRepoModel(root: repo.path)
        await shown.refresh()
        await hidden.refresh()
        XCTAssertFalse(hidden.isStale, "a fresh read is current")
        hidden.setActive(false)
        let shownBefore = shown.statusScans
        let hiddenBefore = hidden.statusScans
        // Let the streams come up before writing, or the write predates them.
        try? await Task.sleep(for: .milliseconds(500))

        GitFixture.sh("echo x > new.txt", in: repo)
        await waitUntil { shown.statusScans > shownBefore && hidden.isStale }

        XCTAssertGreaterThan(shown.statusScans, shownBefore, "the write must wake the shown model")
        XCTAssertTrue(hidden.isStale, "the hidden one must know it missed something")
        XCTAssertEqual(hidden.statusScans, hiddenBefore, "and must not have scanned for it")

        // Shown again, it catches up with exactly one scan.
        hidden.setActive(true)
        await hidden.refreshIfStale()
        XCTAssertEqual(hidden.statusScans, hiddenBefore + 1)
        XCTAssertFalse(hidden.isStale)
        XCTAssertTrue(hidden.status.changes.contains { $0.path == "new.txt" })
    }

    /// Switching back to a repo nothing happened in runs no git at all.
    func testSwitchingBackToAQuietRepoRunsNoScan() async {
        repo = GitFixture.newRepo("quiet")
        GitFixture.commit("base", in: repo)
        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        model.setActive(false)
        try? await Task.sleep(for: .milliseconds(300))
        let before = model.statusScans

        model.setActive(true)
        await model.refreshIfStale()

        XCTAssertEqual(model.statusScans, before)
    }

    /// Background scans (other worktrees' change counts) are queued app-wide:
    /// however many pile up, only one runs at a time, and all of them finish.
    func testTheBackgroundGateRunsOneAtATime() async {
        let gate = SerialGate()
        let counter = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        await withTaskGroup(of: Int.self) { group in
            for i in 0..<6 {
                group.addTask {
                    await gate.run {
                        counter.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                        try? await Task.sleep(for: .milliseconds(20))
                        counter.withLock { $0.now -= 1 }
                        return i
                    }
                }
            }
            var finished = 0
            for await _ in group { finished += 1 }
            XCTAssertEqual(finished, 6)
        }
        XCTAssertEqual(counter.withLock { $0.peak }, 1)
    }

    /// Poll for a condition FSEvents will make true, for up to four seconds.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<40 where !condition() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// selectAdjacentCommit kicks off an async selection; give it a turn.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Clicking a row must not scroll the list.
    ///
    /// The list revealed whatever became selected, however it became selected —
    /// so a click scrolled the row it had just selected into the *centre* of the
    /// pane, sliding it out from under the pointer. Disorienting on its own, and
    /// actively broken for double-click: the second press lands where the row
    /// used to be. Only the keyboard asks to be revealed now, because only the
    /// keyboard can move the selection somewhere you can't see.
    func testOnlyKeyboardNavigationAsksToBeRevealed() async {
        repo = GitFixture.newRepo("reveal")
        GitFixture.sh("printf 'one\n' > a.txt && printf 'two\n' > b.txt", in: repo)
        GitFixture.sh("git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'edit\n' >> a.txt && printf 'edit\n' >> b.txt", in: repo)

        let model = GitRepoModel(root: repo.path)
        await model.refresh()
        XCTAssertEqual(model.status.changes.count, 2)

        let before = model.revealRequest
        model.select(model.orderedChanges.first?.id)
        XCTAssertEqual(model.revealRequest, before, "a click reveals nothing — you clicked it")

        model.selectAdjacent(1)
        XCTAssertGreaterThan(model.revealRequest, before, "↑/↓ can move off screen, so it reveals")
    }
}
