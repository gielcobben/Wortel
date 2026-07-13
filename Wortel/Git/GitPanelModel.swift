import Foundation
import Observation

/// Drives the source-control panel: whether it's shown, and which repo it's
/// pointed at (derived from the selected session's cwd). Resolving a cwd to a
/// work-tree root is async, so the panel briefly shows nothing until it lands.
/// Repo models are cached by root, so switching between sessions in the same
/// repo — or hiding and reshowing — reuses state instead of rebuilding it.
@Observable
@MainActor
final class GitPanelModel {
    private(set) var isVisible = false
    private(set) var repo: GitRepoModel?
    /// True once a cwd has been resolved and it turned out not to be a repo — so
    /// the panel can show "not a git repository" rather than a blank flash.
    private(set) var resolvedNonRepo = false

    @ObservationIgnored private var cache: [String: GitRepoModel] = [:]
    @ObservationIgnored private var currentCwd: String?
    /// Coalesces bursts of command-finished refreshes into one status read.
    @ObservationIgnored private var refreshWorkItem: DispatchWorkItem?
    private static let refreshDebounce: TimeInterval = 0.15

    /// Point the panel at a working directory (the selected session's cwd).
    /// No-ops the git work while hidden; the toggle re-focuses on show.
    func focus(cwd: String?) {
        currentCwd = cwd
        guard isVisible else { return }
        Task { await resolve(cwd: cwd) }
    }

    func toggle() {
        isVisible.toggle()
        if isVisible {
            focus(cwd: currentCwd)
        }
    }

    /// A command finished in the shown repo's session — the work tree may have
    /// changed. Debounced so a chatty run collapses to a single refresh.
    func refreshCurrent() {
        guard isVisible, let repo else { return }
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { Task { await repo.refresh() } }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDebounce, execute: item)
    }

    private func resolve(cwd: String?) async {
        guard let cwd, !cwd.isEmpty else {
            repo = nil
            resolvedNonRepo = false
            return
        }
        guard let root = await GitService.repoRoot(for: cwd) else {
            // The user may have switched away while we awaited.
            guard currentCwd == cwd else { return }
            repo = nil
            resolvedNonRepo = true
            return
        }
        guard currentCwd == cwd else { return }

        if let existing = cache[root] {
            repo = existing
            resolvedNonRepo = false
            await existing.refresh()
        } else {
            let model = GitRepoModel(root: root)
            cache[root] = model
            repo = model
            resolvedNonRepo = false
            await model.refresh()
        }
    }
}
