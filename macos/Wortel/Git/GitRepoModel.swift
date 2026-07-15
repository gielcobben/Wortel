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
    /// True once a log has been read and came back empty — lets the pane say "no
    /// commits yet" instead of flashing an empty list on a fresh repo.
    private(set) var loadedHistory = false
    private(set) var selectedCommitID: String?
    /// Diff of the selected commit. Separate from `diff` so switching panes back
    /// and forth doesn't make each pane reload the other's work.
    private(set) var commitDiff: DiffResult?
    /// Cache keyed by SHA: a commit's patch is immutable, so it never needs
    /// re-reading once seen.
    @ObservationIgnored private var commitDiffCache: [String: DiffResult] = [:]
    /// Guards against an out-of-order diff load landing on a newer selection.
    @ObservationIgnored private var commitDiffToken = 0

    /// FSEvents watcher on the work tree; keeps the changes list live when the
    /// repo changes out of band (an external commit, an agent editing files).
    @ObservationIgnored private var watcher: GitRepoWatcher?
    @ObservationIgnored private var watchRefreshItem: DispatchWorkItem?

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
    func refresh() async {
        isRefreshing = true
        status = await GitService.status(root: root)
        isRefreshing = false

        if let id = selectedChangeID, let change = status.changes.first(where: { $0.id == id }) {
            await loadDiff(for: change)
        } else {
            select(status.changes.first?.id)
        }
    }

    // MARK: - History

    /// Read the log. Called when the History pane appears and after a commit, not
    /// on every status refresh: the FSEvents watcher fires on any working-tree
    /// write, and re-reading the whole log on each keystroke of a build would be
    /// pure waste — history only moves when a commit does.
    func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        commits = await GitService.log(root: root)
        graph = CommitGraph.build(commits)
        loadedHistory = true
        isLoadingHistory = false

        if let id = selectedCommitID, commits.contains(where: { $0.id == id }) {
            // Keep the selection across a reload (e.g. a new commit landed).
        } else {
            await selectCommit(commits.first?.id)
        }
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
        // A faster click may have superseded this load — drop it if so.
        guard token == commitDiffToken else { return }
        let parsed = DiffParser.parse(raw)
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
        guard selectedChangeID == change.id else { return }
        imageDiff = nil
        diff = DiffParser.parse(text)
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
            // The log just moved. Only reload if History has already been read —
            // otherwise leave it to load lazily when the pane is first shown.
            if loadedHistory {
                selectedCommitID = nil
                await loadHistory()
            }
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
