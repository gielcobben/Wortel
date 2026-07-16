import AppKit
import Foundation
import Observation

/// The two sides of an image change, decoded for display. Either side is nil
/// when it doesn't exist (a newly added or deleted image).
struct ImageDiff {
    let old: NSImage?
    let new: NSImage?
}

/// Observable state for one git work tree: its status, the selected file's
/// diff, the commit-message draft, and the mutating actions. Main-thread only;
/// all `git` I/O is awaited on `GitService` (which hops to a background queue)
/// and the results are applied back here on the main actor.
@Observable
@MainActor
final class GitRepoModel {
    let root: String

    private(set) var status = GitStatus()
    private(set) var isRefreshing = false
    private(set) var isCommitting = false
    private(set) var isPushing = false
    private(set) var isGeneratingMessage = false
    /// stderr from the last failed action (commit conflicts, hook rejects…).
    private(set) var lastError: String?

    /// The change whose diff is shown. Setting it is done via `select(_:)` so
    /// the diff load can be awaited.
    private(set) var selectedChangeID: String?
    private(set) var diff: DiffResult?
    /// Non-nil when the selected change is an image; `diff` is nil in that case.
    private(set) var imageDiff: ImageDiff?

    var commitMessage = ""

    // MARK: - History

    private(set) var commits: [GitCommit] = []
    /// Lane layout for the commit list's graph gutter. Rebuilt with `commits`,
    /// never on its own — the two are read together on every row.
    private(set) var graph = CommitGraph.empty
    private(set) var isLoadingHistory = false
    /// More history exists behind what's loaded, so the list keeps paging as the
    /// reader scrolls. False once a short page proves we've hit the root.
    private(set) var canLoadMoreHistory = false
    private(set) var isLoadingMoreHistory = false
    /// True once a log has been read and came back empty — lets the pane say "no
    /// commits yet" instead of flashing an empty list on a fresh repo.
    private(set) var loadedHistory = false
    private(set) var selectedCommitID: String?
    /// SHAs not yet on the remote — the History pane's blue dots. A set, because
    /// every row asks; recomputed only when the answer can have changed (HEAD
    /// moved, or the ahead/upstream pair shifted under a push or fetch).
    private(set) var unpushed: Set<String> = []
    /// Diff of the selected commit. Separate from `diff` so switching panes back
    /// and forth doesn't make each pane reload the other's work.
    private(set) var commitDiff: DiffResult?
    /// Cache keyed by SHA: a commit's patch is immutable, so it never needs
    /// re-reading once seen.
    @ObservationIgnored private var commitDiffCache: [String: DiffResult] = [:]
    /// Guards against an out-of-order diff load landing on a newer selection.
    @ObservationIgnored private var commitDiffToken = 0

    // MARK: - Branches

    /// Local + remote branches for the switcher. Loaded lazily when the menu
    /// opens rather than on every refresh: a monorepo can carry thousands of
    /// remote refs, and nothing on screen needs them until you ask.
    private(set) var branches: [GitBranch] = []
    private(set) var isLoadingBranches = false
    /// Set when a checkout is refused — almost always git protecting local
    /// changes it would have to discard. Shown verbatim; cleared on the next try.
    private(set) var checkoutError: String?
    private(set) var isCheckingOut = false

    /// Whether the repo has any remote at all. Decides whether "unpushed" means
    /// anything; cached because remotes essentially never change during a session
    /// and every unpushed recompute would otherwise pay for `git remote`.
    @ObservationIgnored private var hasRemotes: Bool?
    /// The (upstream, ahead) pair `unpushed` was computed for, so a status that
    /// didn't move either doesn't re-run rev-list. Nil until first computed.
    @ObservationIgnored private var unpushedKey: String?

    /// FSEvents watcher on the work tree; keeps the changes list live when the
    /// repo changes out of band (an external commit, an agent editing files).
    @ObservationIgnored private var watcher: GitRepoWatcher?
    @ObservationIgnored private var watchRefreshItem: DispatchWorkItem?
    /// Coalescing state for `refresh()` — one `git status` at a time, with one
    /// more queued at most. See the note there.
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshQueued = false
    /// How long the last status took, which is how long we wait before running
    /// another on a repo big enough for that to matter.
    @ObservationIgnored private var lastStatusDuration: TimeInterval = 0
    /// HEAD as of the last status, to spot a commit made outside the panel.
    @ObservationIgnored private var lastKnownHead: String?
    /// How many `git status` scans have actually run. The whole point of the
    /// coalescing in `refresh()` is that a burst of watch events collapses into
    /// one scan, and that's invisible from the outside — this is what lets a test
    /// hold the line. Not observed: it must never invalidate a view.
    @ObservationIgnored private(set) var statusScans = 0

    init(root: String) {
        self.root = root
        watcher = GitRepoWatcher(root: root) { [weak self] in
            // Callback is on a background queue — hop to the main actor.
            Task { @MainActor in self?.scheduleWatchRefresh() }
        }
    }

    /// Debounce watch-driven refreshes: a burst of file writes (a build, an
    /// agent) collapses to one status read shortly after it settles.
    private func scheduleWatchRefresh() {
        watchRefreshItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        watchRefreshItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Repo folder name for the header.
    var name: String { (root as NSString).lastPathComponent }

    var canCommit: Bool {
        !status.stagedChanges.isEmpty
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCommitting
    }

    /// Whether there's anything to push: commits ahead of the upstream, or a
    /// branch with no upstream yet (a first push). Never in detached HEAD.
    var canPush: Bool {
        guard status.branch != nil, !isPushing else { return false }
        return status.ahead > 0 || status.upstream == nil
    }

    /// Whether the on-device commit-message drafter can run right now (model
    /// available and something staged to describe).
    var canGenerateMessage: Bool {
        guard !status.stagedChanges.isEmpty, !isGeneratingMessage else { return false }
        if #available(macOS 26.0, *) { return CommitMessageGenerator.isAvailable }
        return false
    }

    /// Draft a commit message from the staged diff with the on-device model and
    /// drop it into the message field.
    func generateCommitMessage() async {
        guard #available(macOS 26.0, *) else { return }
        guard !status.stagedChanges.isEmpty, !isGeneratingMessage else { return }
        isGeneratingMessage = true
        defer { isGeneratingMessage = false }

        guard let staged = await GitService.stagedDiff(root: root) else { return }
        let recentSubjects = await GitService.recentCommitSubjects(root: root)
        do {
            let message = try await CommitMessageGenerator.generate(
                stat: staged.stat, patch: staged.patch,
                branch: status.branch, recentSubjects: recentSubjects)
            if !message.isEmpty {
                commitMessage = message
                lastError = nil
            }
        } catch {
            lastError = "Couldn't draft a message: \(error.localizedDescription)"
        }
    }

    // MARK: - Refresh

    /// Re-read status, then keep the current selection's diff fresh (its content
    /// may have changed) or auto-select the first change.
    ///
    /// Only ever one `git status` at a time. It's a full walk of the work tree —
    /// measured at ~0.4s on a 120k-file repo, and worse on a real monorepo — and
    /// the watcher fires on every write, so a build or an agent editing files
    /// would otherwise stack several full scans on top of each other. (Six
    /// concurrent scans of that repo: 1.47s of wall time and six cores' worth of
    /// work, for one answer.) A request arriving mid-scan just marks the result
    /// stale, and we run exactly once more when the current one lands.
    func refresh() async {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        repeat {
            refreshQueued = false
            let started = Date()
            isRefreshing = true
            status = await GitService.status(root: root)
            isRefreshing = false
            statusScans += 1
            lastStatusDuration = Date().timeIntervalSince(started)

            if let id = selectedChangeID, let change = status.changes.first(where: { $0.id == id }) {
                await loadDiff(for: change)
            } else {
                select(status.changes.first?.id)
            }

            // HEAD moved — a commit, amend, checkout, rebase or reset, whether it
            // happened in this panel or (far more likely) in the terminal next to
            // it. Only worth reloading if History has already been read; otherwise
            // it stays lazy until the pane is first shown. The SHA rides along on
            // the status we just ran, so noticing costs no extra git call.
            if let head = status.head, head != lastKnownHead {
                let moved = lastKnownHead != nil
                lastKnownHead = head
                if moved, loadedHistory { await loadHistory() }
            }

            // A push or a fetch moves the ahead count without moving HEAD, and the
            // dots have to follow or they'd contradict the header sitting right
            // above them. Keyed so an ordinary status — the common case, several a
            // second under a build — doesn't re-run rev-list to learn nothing.
            if loadedHistory { await refreshUnpushed() }

            // Something changed while we were scanning. Wait out roughly the time
            // the last scan took before going again, so a long build can't pin a
            // core on back-to-back status walks — the terminal in the next pane is
            // the thing that has to stay smooth. Cheap repos barely pause.
            if refreshQueued, lastStatusDuration > 0.1 {
                try? await Task.sleep(for: .seconds(min(lastStatusDuration, 2)))
            }
        } while refreshQueued
    }

    // MARK: - History

    /// How many commits each page of the log adds. The pane shows ~10 rows, so
    /// one page is already a deep first read; the point of paging is that cost
    /// tracks the window rather than the repo, which is what lets a
    /// million-commit history open as fast as a small one.
    static let historyPageSize = 300

    /// Read the first page of the log. Called when the History pane appears and
    /// whenever HEAD moves, not on every status refresh: the FSEvents watcher
    /// fires on any working-tree write, and re-reading the log on each keystroke
    /// of a build would be pure waste — history only moves when HEAD does.
    ///
    /// Resets paging: a moved HEAD invalidates the `--skip` offsets that
    /// `loadMoreHistory` counts on, so scrolled-in pages are dropped rather than
    /// stitched onto a window that shifted underneath them.
    func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        let page = await GitService.log(root: root, limit: Self.historyPageSize)
        commits = CommitOrder.topological(page)
        graph = CommitGraph.build(commits)
        // A full page means there's probably more behind it. A short one is the
        // end of the history, and the pane stops asking.
        canLoadMoreHistory = page.count == Self.historyPageSize
        loadedHistory = true
        isLoadingHistory = false

        // The pane loads lazily, so the refresh that ran before it was ever shown
        // skipped this (it only recomputes once history is loaded). Without it a
        // first open would draw the log with no dots until something else moved.
        await refreshUnpushed()

        if let id = selectedCommitID, commits.contains(where: { $0.id == id }) {
            // Keep the selection across a reload (e.g. a new commit landed).
        } else {
            await selectCommit(commits.first?.id)
        }
    }

    /// Recompute the blue dots, but only when the answer can have moved.
    ///
    /// The key is the (upstream, ahead) pair the last set was computed for — the
    /// two things that define the range. `refresh()` calls this on every status,
    /// which is several a second while a build writes files, so without the key
    /// this would be a `rev-list` per file write for an answer that changes maybe
    /// once a day.
    private func refreshUnpushed() async {
        let key = "\(status.upstream ?? "-")|\(status.ahead)|\(status.head ?? "-")"
        guard key != unpushedKey else { return }

        if hasRemotes == nil { hasRemotes = await GitService.hasRemotes(root: root) }
        unpushed = await GitService.unpushedSHAs(
            root: root, upstream: status.upstream, hasRemotes: hasRemotes ?? false)
        unpushedKey = key
    }

    /// Select HEAD's commit, which reveals it — the list scrolls to whatever is
    /// selected. HEAD is always in the first page (the log walks *from* it), so
    /// this never has to page hunting for a row.
    func jumpToHead() async {
        guard let head = status.head else { return }
        guard commits.contains(where: { $0.sha == head }) else {
            // Only reachable if the log hasn't been read yet, or HEAD moved and
            // the reload hasn't landed. Reading it puts HEAD back at the top.
            await loadHistory()
            if commits.contains(where: { $0.sha == head }) { await selectCommit(head) }
            return
        }
        await selectCommit(head)
    }

    /// Read the branch list for the switcher. Called when the menu opens, so it's
    /// always fresh without any of it being paid for on the refresh path.
    func loadBranches() async {
        guard !isLoadingBranches else { return }
        isLoadingBranches = true
        branches = await GitService.branches(root: root)
        isLoadingBranches = false
    }

    /// Switch branches. Never forced: git refuses rather than discarding local
    /// changes, and that refusal is surfaced verbatim instead of being worked
    /// around — the terminal is right there for anyone who means it.
    ///
    /// No explicit reload afterwards: checkout moves HEAD, the watcher fires, and
    /// `refresh()` notices the new `branch.oid` and reloads history — the same
    /// path a checkout typed in the terminal takes, so there's only one.
    func checkout(_ branch: GitBranch) async {
        guard !isCheckingOut, !branch.isCurrent else { return }
        isCheckingOut = true
        checkoutError = nil
        checkoutError = await GitService.checkout(root: root, branch: branch)
        isCheckingOut = false
        await refresh()
    }

    func dismissCheckoutError() { checkoutError = nil }

    /// Append the next page as the reader nears the bottom of the list.
    ///
    /// The rows already on screen keep their exact order — see `CommitOrder`'s
    /// `settled` — so scrolling never yanks the list out from under you. The
    /// graph is rebuilt across everything loaded, which is cheap (single-digit
    /// milliseconds even at several thousand commits) and necessary: lanes that
    /// ran off the bottom edge as stubs become real lines once the commits they
    /// were reaching for arrive.
    func loadMoreHistory() async {
        guard canLoadMoreHistory, !isLoadingHistory, !isLoadingMoreHistory else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }

        let settled = commits
        // `--skip` indexes git's date order, and `settled` holds exactly the
        // newest `count` by date — reordered for display, but the same set.
        let page = await GitService.log(
            root: root, limit: Self.historyPageSize, skip: settled.count)
        guard !page.isEmpty else {
            canLoadMoreHistory = false
            return
        }
        // HEAD moving mid-scroll could re-deal the window; drop anything we've
        // already got rather than showing it twice.
        let known = Set(settled.map(\.sha))
        let fresh = page.filter { !known.contains($0.sha) }
        canLoadMoreHistory = page.count == Self.historyPageSize
        guard !fresh.isEmpty else { return }

        commits = CommitOrder.topological(settled + fresh, settled: settled.count)
        graph = CommitGraph.build(commits)
    }

    /// Show a commit's patch. A commit is immutable once written, so its diff is
    /// cached by SHA and never re-read.
    func selectCommit(_ id: String?) async {
        selectedCommitID = id
        guard let id, let commit = commits.first(where: { $0.id == id }) else {
            commitDiff = nil
            return
        }
        if let cached = commitDiffCache[commit.sha] {
            commitDiff = cached
            return
        }

        // Clear first so the pane doesn't show the previous commit's diff under
        // the new commit's header while this loads.
        commitDiff = nil
        commitDiffToken += 1
        let token = commitDiffToken
        let raw = await GitService.commitDiff(root: root, sha: commit.sha)
        // Off the main actor — see loadDiff. Holding ↓ through a log of big
        // commits is exactly how you'd notice this.
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffParser.parse(raw)
        }.value
        // A faster click may have superseded this load — drop it if so.
        guard token == commitDiffToken else { return }
        commitDiffCache[commit.sha] = parsed
        commitDiff = parsed
    }

    /// ↑/↓ through the history list, mirroring selectAdjacent for changes.
    func selectAdjacentCommit(_ delta: Int) {
        guard !commits.isEmpty else { return }
        let index: Int
        if let id = selectedCommitID, let current = commits.firstIndex(where: { $0.id == id }) {
            index = min(max(0, current + delta), commits.count - 1)
        } else {
            index = 0
        }
        Task { await selectCommit(commits[index].id) }
    }

    // MARK: - Selection

    /// The changes in the order the panel lists them (staged section first,
    /// then unstaged) — the order ↑/↓ navigation walks.
    var orderedChanges: [GitFileChange] {
        status.stagedChanges + status.unstagedChanges
    }

    /// Move the selection by `delta` rows within `orderedChanges` (clamped at the
    /// ends). With nothing selected yet, selects the first change.
    func selectAdjacent(_ delta: Int) {
        let ordered = orderedChanges
        guard !ordered.isEmpty else { return }
        guard let id = selectedChangeID,
              let index = ordered.firstIndex(where: { $0.id == id }) else {
            select(ordered.first?.id)
            return
        }
        let next = max(0, min(ordered.count - 1, index + delta))
        if next != index { select(ordered[next].id) }
    }

    func select(_ id: String?) {
        selectedChangeID = id
        guard let id, let change = status.changes.first(where: { $0.id == id }) else {
            diff = nil
            imageDiff = nil
            return
        }
        Task { await loadDiff(for: change) }
    }

    private func loadDiff(for change: GitFileChange) async {
        if change.isImage {
            let (old, new) = await GitService.imageData(root: root, change: change)
            // A newer selection may have won while we were awaiting — drop stale.
            guard selectedChangeID == change.id else { return }
            diff = nil
            imageDiff = ImageDiff(old: old.flatMap(NSImage.init(data:)),
                                  new: new.flatMap(NSImage.init(data:)))
            return
        }
        let text = await GitService.diff(root: root, change: change)
        // Parse off the main actor: this model is @MainActor, so parsing here
        // would block the terminal too, and a big patch is not a small job.
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffParser.parse(text)
        }.value
        guard selectedChangeID == change.id else { return }
        imageDiff = nil
        diff = parsed
    }

    // MARK: - Staging

    func stage(_ change: GitFileChange) async {
        _ = await GitService.stage(root: root, change: change)
        await refresh()
    }

    func unstage(_ change: GitFileChange) async {
        _ = await GitService.unstage(root: root, change: change)
        await refresh()
    }

    func stageAll() async {
        _ = await GitService.stageAll(root: root)
        await refresh()
    }

    func unstageAll() async {
        _ = await GitService.unstageAll(root: root)
        await refresh()
    }

    // MARK: - File actions

    /// Discard a file's changes (destructive — the caller confirms first).
    func discard(_ change: GitFileChange) async {
        _ = await GitService.discard(root: root, change: change)
        // Its diff no longer applies; drop the selection if it was this row.
        if selectedChangeID == change.id { select(nil) }
        await refresh()
    }

    /// Add the file to the repo's `.gitignore`.
    func ignore(_ change: GitFileChange) async {
        await GitService.addToGitignore(root: root, path: change.path)
        await refresh()
    }

    /// Absolute filesystem path for a change, for Finder/open/copy actions.
    func absoluteURL(for change: GitFileChange) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(change.path)
    }

    // MARK: - Commit

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !status.stagedChanges.isEmpty else { return }

        isCommitting = true
        let result = await GitService.commit(root: root, message: message)
        isCommitting = false

        if result.ok {
            commitMessage = ""
            lastError = nil
            // The log just moved, but the refresh below notices that from HEAD
            // like it would for a commit made in the terminal — no need to
            // special-case our own. Just drop the selection, since the diff the
            // user was looking at belongs to the old tip.
            selectedCommitID = nil
        } else {
            lastError = result.stderr.isEmpty ? result.stdout : result.stderr
        }
        await refresh()
    }

    // MARK: - Push

    func push() async {
        guard status.branch != nil, !isPushing else { return }

        isPushing = true
        let result = await GitService.push(root: root, setUpstream: status.upstream == nil)
        isPushing = false

        if result.ok {
            lastError = nil
        } else {
            lastError = result.stderr.isEmpty ? result.stdout : result.stderr
        }
        await refresh()
    }
}
