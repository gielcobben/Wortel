import AppKit
import Foundation
import Observation

/// The two sides of an image change, decoded for display. Either side is nil
/// when it doesn't exist (a newly added or deleted image).
struct ImageDiff {
    /// One decoded side, kept together with the size of the blob it was decoded
    /// from. The pixels say what changed; the bytes say what it costs, which is
    /// the other half of reviewing an image commit.
    struct Side {
        let image: NSImage
        let byteCount: Int

        /// Nil when the side doesn't exist, or when its bytes won't decode as an
        /// image — both read the same in the diff views.
        init?(data: Data?) {
            guard let data, let image = NSImage(data: data) else { return nil }
            self.image = image
            self.byteCount = data.count
        }

        /// "1200 × 630 · 245 KB" — the caption both diff views print under the
        /// image. `.file` counts the way Finder does, so the number matches what
        /// the Get Info panel says about the same file.
        var caption: String {
            let width = Int(image.size.width.rounded())
            let height = Int(image.size.height.rounded())
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(byteCount), countStyle: .file)
            return "\(width) × \(height) · \(bytes)"
        }
    }

    let old: Side?
    let new: Side?
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
    private(set) var isPulling = false
    private(set) var isFetching = false
    private(set) var isGeneratingMessage = false
    /// stderr from the last failed action (commit conflicts, hook rejects…).
    private(set) var lastError: String?

    /// Which rows are selected, and which one the diff follows. See
    /// `ChangeSelection` — the panel talks to it through the methods below so a
    /// changed lead always gets its diff loaded.
    private(set) var selection = ChangeSelection()

    /// The change whose diff is shown: the selection's lead. Still the name the
    /// panel and the tests use, because for a single selection nothing about it
    /// changed.
    var selectedChangeID: String? { selection.lead }
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
    /// The selected commit's changed files — the History pane's accordion. Empty
    /// while `isLoadingCommitFiles`, and for a merge whose first parent it matches.
    private(set) var commitFiles: [CommitFileChange] = []
    private(set) var isLoadingCommitFiles = false
    /// Paths (within the selected commit) whose diff is expanded open.
    private(set) var expandedCommitFiles: Set<String> = []
    /// Parsed diff per expanded file, keyed by path within the selected commit.
    /// Reset whenever the selection changes; the SHA-keyed caches below outlive it.
    private(set) var commitFileDiffs: [String: DiffResult] = [:]
    /// Decoded before/after images per expanded image file, keyed the same way —
    /// an image expands to the picture(s), not a text patch.
    private(set) var commitFileImages: [String: ImageDiff] = [:]
    /// File lists by SHA, and file diffs/images by SHA+path — all immutable once a
    /// commit is written, so a revisit or a re-expand never re-reads git.
    @ObservationIgnored private var commitFilesCache: [String: [CommitFileChange]] = [:]
    @ObservationIgnored private var commitFileDiffCache: [String: DiffResult] = [:]
    @ObservationIgnored private var commitFileImageCache: [String: ImageDiff] = [:]
    /// Guards an out-of-order file-list load from landing on a newer selection.
    @ObservationIgnored private var commitFilesToken = 0

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
    /// anything and whether the repo header's fetch/push commands do anything;
    /// resolved once (remotes essentially never change during a session) so the
    /// per-write status storm never pays for `git remote`. Observed — not
    /// `@ObservationIgnored` — so the sync controls light up when it lands.
    private(set) var hasRemotes: Bool?
    /// The (upstream, ahead) pair `unpushed` was computed for, so a status that
    /// didn't move either doesn't re-run rev-list. Nil until first computed.
    @ObservationIgnored private var unpushedKey: String?

    /// Open a file in a preview window. Set by `GitPanelModel`, which forwards
    /// to the app layer — the panes hold a repo, not the window machinery.
    @ObservationIgnored var onOpenPreview: ((URL, PreviewDiffSource, Bool) -> Void)?

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

    /// Syntax-highlights diffs off the main actor. Injected (rather than a hard
    /// reference to `DiffHighlighter`) so the unit tests — which compile this
    /// model — don't link the tree-sitter grammars; they pass nil and see plain
    /// diffs. The app passes `DiffHighlighter.shared`.
    private let highlighter: (any DiffHighlighting)?

    init(root: String, highlighter: (any DiffHighlighting)? = nil) {
        self.root = root
        self.highlighter = highlighter
        startWatching()
    }

    /// Watch the work tree immediately, then widen the watch once we know where
    /// this checkout keeps its git state.
    ///
    /// Two shapes, and the second is why this isn't just `root`:
    ///
    /// - The **primary** checkout holds `.git` inside its work tree, so the root
    ///   watch already sees commits and staging. What it *also* sees is
    ///   `.git/worktrees/<name>/index` — rewritten by every `git add` and every
    ///   index-refreshing `git status` an agent runs in *another* session — each
    ///   one a full `git status` walk here, for a work tree that did not move.
    ///   So that subtree is excluded. Not all of it goes away: a commit in a
    ///   worktree also writes `refs/heads/<branch>` and objects in the shared
    ///   `.git`, which this still sees. That's the rarer event and it is at
    ///   least real news about the repository; the per-worktree index churn is
    ///   the noise worth dropping.
    /// - A **linked worktree**'s `.git` is a file; its HEAD, index and reflog
    ///   live under the primary's `.git/worktrees/<name>`. Nothing under the work
    ///   tree changes when you stage or commit there, so without watching that
    ///   directory the panel keeps listing files that are already committed until
    ///   the session is re-selected. That's the bug this exists for.
    ///
    /// Resolving it needs a `git` call, so the root watch goes up first and the
    /// stream is replaced when the answer lands (the old one stops on release).
    /// File edits — the common case — are covered for the whole of that gap.
    private func startWatching() {
        watcher = makeWatcher(paths: [root], excluding: [Self.worktreesDir(inside: root)])
        Task { @MainActor [weak self] in
            guard let self, let gitDir = await GitService.externalGitDir(root: self.root) else { return }
            // A worktree's own gitdir is small and entirely ours: no exclusions,
            // and nothing here belongs to another session.
            self.watcher = self.makeWatcher(paths: [self.root, gitDir])
        }
    }

    private func makeWatcher(paths: [String], excluding: [String] = []) -> GitRepoWatcher {
        GitRepoWatcher(paths: paths, excluding: excluding) { [weak self] in
            // Callback is on a background queue — hop to the main actor.
            Task { @MainActor in self?.scheduleWatchRefresh() }
        }
    }

    private static func worktreesDir(inside root: String) -> String {
        (root as NSString).appendingPathComponent(".git/worktrees")
    }

    /// A changed file, in its own window, showing that row's diff.
    func openPreview(for change: GitFileChange) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
        onOpenPreview?(url, .change(root: root, change: change), true)
    }

    /// A file within a commit, in its own window, showing that commit's diff for
    /// it — the question History is asking, which is neither of the other two.
    func openPreview(for file: CommitFileChange, in sha: String) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        onOpenPreview?(
            url,
            .commit(root: root, sha: sha, path: file.path, originalPath: file.originalPath),
            true)
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
    /// branch with no upstream yet (a first push). Never in detached HEAD, and
    /// never without a remote to push to.
    var canPush: Bool {
        guard hasRemotes == true, status.branch != nil, !isPushing else { return false }
        return status.ahead > 0 || status.upstream == nil
    }

    /// Whether a fetch would do anything: there's a remote to fetch from. Unlike
    /// push it doesn't wait on being ahead/behind — you fetch precisely to learn
    /// whether you've fallen behind.
    var canFetch: Bool { hasRemotes == true && !isFetching }

    /// Whether there's an upstream to pull from. Like fetch, and unlike push,
    /// this doesn't wait on the behind count: `git pull` fetches first, so
    /// gating on the count would gate on what the *last* fetch knew, and a
    /// branch someone pushed to a minute ago would read as nothing to do.
    var canPull: Bool {
        hasRemotes == true && status.branch != nil && status.upstream != nil && !isPulling
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

            // Resolve once whether there's a remote at all. The Changes pane can
            // be open long before History (which is what otherwise triggers this
            // via refreshUnpushed), and the repo header's fetch/push commands need the
            // answer to enable themselves. Cached, so the status storm during a
            // build never re-runs `git remote`.
            if hasRemotes == nil { hasRemotes = await GitService.hasRemotes(root: root) }
            lastStatusDuration = Date().timeIntervalSince(started)

            // Rows the last action consumed are gone from the new status; drop
            // them before anything reads the selection, so a bulk action can't
            // inherit an id that is no longer on screen.
            selection.prune(to: orderedChanges.map(\.id))
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

    /// Reveal a commit's changed files. Loads only the file list (a cheap numstat
    /// + name-status), not every file's patch — the accordion pulls each file's
    /// diff lazily on expand, so opening a 60-file commit costs one summary rather
    /// than 60 patches. The list is immutable once written and cached by SHA.
    func selectCommit(_ id: String?) async {
        selectedCommitID = id
        // The previous commit's expansions and diffs never belong to a new one.
        expandedCommitFiles = []
        commitFileDiffs = [:]
        commitFileImages = [:]
        guard let id, let commit = commits.first(where: { $0.id == id }) else {
            commitFiles = []
            isLoadingCommitFiles = false
            return
        }
        // Bump the load token for EVERY selection — cached or not — so a slow
        // uncached load still in flight can't land and overwrite a newer
        // selection made in the meantime (fast ↑/↓ across cached and uncached
        // commits). The cached branch not bumping it was the hole.
        commitFilesToken += 1
        let token = commitFilesToken
        if let cached = commitFilesCache[commit.sha] {
            commitFiles = cached
            isLoadingCommitFiles = false
        } else {
            // Clear first so the accordion doesn't show the previous commit's
            // files under the new commit while this loads.
            commitFiles = []
            isLoadingCommitFiles = true
            // Coalesce fast ↑/↓ scrubbing: settle briefly and bail if the
            // selection already moved on, so holding the arrow keys doesn't spawn
            // a `git show` per row next to the terminal. Only the commit you land
            // on (held past this beat) actually loads. Cached commits skip this.
            try? await Task.sleep(for: .milliseconds(60))
            guard token == commitFilesToken else { return }
            let files = await GitService.commitFiles(root: root, sha: commit.sha)
            // A faster ↓ may have superseded this load — drop it if so.
            guard token == commitFilesToken else { return }
            commitFilesCache[commit.sha] = files
            commitFiles = files
            isLoadingCommitFiles = false
        }

        // A commit that touched exactly one file: open it straight away, so the
        // diff is there without a click — what the old whole-commit view gave.
        if commitFiles.count == 1 { await toggleCommitFile(commitFiles[0]) }
    }

    /// True when every file in the current commit is expanded — drives the
    /// header's Expand All / Collapse All toggle.
    var allCommitFilesExpanded: Bool {
        !commitFiles.isEmpty && expandedCommitFiles.count == commitFiles.count
    }

    /// Expand or collapse one file in the accordion. Expanding loads its diff
    /// once (then it's cached by SHA+path forever).
    func toggleCommitFile(_ file: CommitFileChange) async {
        if expandedCommitFiles.contains(file.path) {
            expandedCommitFiles.remove(file.path)
            return
        }
        expandedCommitFiles.insert(file.path)
        await loadCommitFileDiff(file)
    }

    /// Open every file (the header's Expand All). Text files load their diffs;
    /// binary ones just mark expanded and show a note. Loads run in turn, so a
    /// big commit paints top-down rather than stalling on one huge file.
    func expandAllCommitFiles() async {
        let sha = selectedCommitID
        for file in commitFiles {
            // Stop if the selection moved out from under the loop — otherwise it
            // would stamp this commit's paths into a different commit's expansion
            // set and load the wrong diffs.
            guard selectedCommitID == sha else { return }
            if expandedCommitFiles.contains(file.path) { continue }
            expandedCommitFiles.insert(file.path)
            await loadCommitFileDiff(file)
        }
    }

    func collapseAllCommitFiles() {
        expandedCommitFiles = []
    }

    /// Fetch, parse and (later) highlight one file's diff within the selected
    /// commit. Binary files carry no patch worth parsing and are skipped — the
    /// view shows a note from `CommitFileChange.isBinary`.
    private func loadCommitFileDiff(_ file: CommitFileChange) async {
        guard let sha = selectedCommitID else { return }

        // An image expands to the picture(s), not a patch — fetch its blobs at the
        // commit and its first parent and decode, mirroring the Changes pane.
        if file.isImage {
            guard commitFileImages[file.path] == nil else { return }
            let cacheKey = sha + "\u{1f}" + file.path
            if let cached = commitFileImageCache[cacheKey] {
                commitFileImages[file.path] = cached
                return
            }
            let (old, new) = await GitService.commitImageData(root: root, sha: sha, file: file)
            guard selectedCommitID == sha, expandedCommitFiles.contains(file.path) else { return }
            let images = ImageDiff(
                old: ImageDiff.Side(data: old), new: ImageDiff.Side(data: new))
            commitFileImageCache[cacheKey] = images
            commitFileImages[file.path] = images
            return
        }

        // A non-image binary has no patch worth parsing — the view shows a note.
        guard !file.isBinary else { return }
        guard commitFileDiffs[file.path] == nil else { return }

        let cacheKey = sha + "\u{1f}" + file.path
        if let cached = commitFileDiffCache[cacheKey] {
            commitFileDiffs[file.path] = cached
            return
        }

        let raw = await GitService.commitFileDiff(
            root: root, sha: sha, path: file.path, originalPath: file.originalPath)
        // Off the main actor — see loadDiff; this model is @MainActor and a big
        // patch is not a small job.
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffParser.parse(raw)
        }.value
        // Dropped if the selection moved or the row was collapsed while loading.
        guard selectedCommitID == sha, expandedCommitFiles.contains(file.path) else { return }
        commitFileDiffCache[cacheKey] = parsed
        commitFileDiffs[file.path] = parsed

        // Colour it a beat later so the diff (and the terminal beside it) never
        // waits on tree-sitter; cache the highlighted result so a re-expand is
        // instant. See DiffResult.highlights.
        guard let highlighter else { return }
        let spans = await highlighter.highlight(parsed.lines)
        guard selectedCommitID == sha, expandedCommitFiles.contains(file.path) else { return }
        var highlighted = parsed
        highlighted.highlights = spans
        commitFileDiffCache[cacheKey] = highlighted
        commitFileDiffs[file.path] = highlighted
    }

    /// ↑/↓ through the history list, mirroring selectAdjacent for changes.
    func selectAdjacentCommit(_ delta: Int) {
        revealRequest += 1
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

    /// The selected changes, in the order the panel lists them — what every bulk
    /// action applies to, and the order it reports them in.
    var selectedChanges: [GitFileChange] {
        orderedChanges.filter { selection.contains($0.id) }
    }

    /// Move the selection by `delta` rows within `orderedChanges` (clamped at the
    /// ends). With nothing selected yet, selects the first change. `extending` is
    /// ⇧↑/⇧↓: the lead moves and the range from the anchor comes with it.
    func selectAdjacent(_ delta: Int, extending: Bool = false) {
        let ids = orderedChanges.map(\.id)
        guard selection.move(by: delta, in: ids, extending: extending) else { return }
        revealRequest += 1
        loadLeadDiff()
    }

    /// Bumped only by keyboard navigation — see `FileTreeModel.revealRequest`.
    /// A clicked row is already on screen; scrolling it anyway moves it out from
    /// under the pointer between the two halves of a double-click.
    private(set) var revealRequest = 0

    /// A plain click, or any programmatic selection: this row and nothing else.
    func select(_ id: String?) {
        selection.select(id)
        loadLeadDiff()
    }

    /// ⌘-click: add or remove one row without disturbing the rest.
    func toggleSelection(_ id: String) {
        selection.toggle(id, in: orderedChanges.map(\.id))
        loadLeadDiff()
    }

    /// ⇧-click: everything between the anchor and this row.
    ///
    /// The range runs over the list as drawn, which puts the two sections on one
    /// continuous run: a ⇧-click that starts in Staged Changes and ends in
    /// Changes takes the rows between them, because that is what the reader
    /// dragged across. What each of those rows *means* stays per row — Discard
    /// resets a staged file to HEAD and a working-tree file to the index, exactly
    /// as it does one at a time.
    func extendSelection(to id: String) {
        selection.extend(to: id, in: orderedChanges.map(\.id))
        loadLeadDiff()
    }

    /// ⌘A while the list has focus.
    func selectAllChanges() {
        selection.selectAll(in: orderedChanges.map(\.id))
        loadLeadDiff()
    }

    /// Show the lead's diff, or clear the pane when the selection is empty. The
    /// pane follows one row even when many are selected: it's the row you last
    /// touched, and the alternative — blanking it whenever a second row joins —
    /// takes the diff away at exactly the moment you're deciding what to discard.
    private func loadLeadDiff() {
        guard let id = selection.lead,
              let change = status.changes.first(where: { $0.id == id }) else {
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
            imageDiff = ImageDiff(old: ImageDiff.Side(data: old),
                                  new: ImageDiff.Side(data: new))
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

        // Colour it a beat later so the diff (and the terminal beside it) never
        // waits on tree-sitter. Spans are keyed by DiffLine.id, so a superseding
        // selection just makes them not apply — guard covers the common case.
        guard let highlighter else { return }
        let spans = await highlighter.highlight(parsed.lines)
        guard selectedChangeID == change.id else { return }
        diff?.highlights = spans
    }

    // MARK: - Staging

    func stage(_ changes: [GitFileChange]) async {
        guard !changes.isEmpty else { return }
        _ = await GitService.stage(root: root, changes: changes)
        await refresh()
    }

    func unstage(_ changes: [GitFileChange]) async {
        guard !changes.isEmpty else { return }
        _ = await GitService.unstage(root: root, changes: changes)
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

    /// Discard changes (destructive — the caller confirms first).
    func discard(_ changes: [GitFileChange]) async {
        guard !changes.isEmpty else { return }
        _ = await GitService.discard(root: root, changes: changes)
        // Their diffs no longer apply. Clear the pane if the lead was one of
        // them rather than waiting for the refresh, so it can't show a patch
        // against a file that has already been reverted.
        if let lead = selectedChangeID, changes.contains(where: { $0.id == lead }) { select(nil) }
        await refresh()
    }

    /// Add the files to the repo's `.gitignore`.
    func ignore(_ changes: [GitFileChange]) async {
        guard !changes.isEmpty else { return }
        await GitService.addToGitignore(root: root, paths: changes.map(\.path))
        await refresh()
    }

    /// Absolute filesystem path for a change, for Finder/open/copy actions.
    func absoluteURL(for change: GitFileChange) -> URL {
        absoluteURL(forPath: change.path)
    }

    /// Absolute filesystem path for a repo-relative path — the History
    /// accordion's file rows open the current on-disk file this way (which may,
    /// for an old commit, differ from or predate what it committed).
    func absoluteURL(forPath path: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(path)
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

    // MARK: - Fetch / Pull / Push

    func fetch() async {
        guard hasRemotes == true, !isFetching else { return }

        isFetching = true
        let result = await GitService.fetch(root: root)
        isFetching = false

        if result.ok {
            lastError = nil
        } else {
            lastError = result.stderr.isEmpty ? result.stdout : result.stderr
        }
        // Pick up the new behind count and any refs the fetch moved; refresh's
        // keyed recompute redraws the blue dots only if the range actually moved.
        await refresh()
    }

    /// Fast-forward onto the upstream (fetching as part of it). A branch that
    /// has diverged, or a work tree in the way, fails here rather than starting
    /// a merge — the refusal git prints is the message worth showing.
    func pull() async {
        guard canPull else { return }

        isPulling = true
        let result = await GitService.pull(root: root)
        isPulling = false

        if result.ok {
            lastError = nil
        } else {
            lastError = result.stderr.isEmpty ? result.stdout : result.stderr
        }
        // A fast-forward moves HEAD and the work tree under us: everything the
        // panel shows is downstream of this refresh.
        await refresh()
    }

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
