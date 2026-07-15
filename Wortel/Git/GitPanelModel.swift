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
    /// Persisted across relaunches (app-wide, not per-session) so the panel
    /// reopens where you left it. Written through `setVisible`.
    private(set) var isVisible = UserDefaults.standard.bool(forKey: GitPanelModel.visibleKey)
    private(set) var repo: GitRepoModel?

    private static let visibleKey = "git.panelVisible"
    /// Bumped to ask the panel to move keyboard focus into the changes list.
    /// The list view watches this and claims focus; a monotonic counter (rather
    /// than a Bool) so repeated requests always register, even back-to-back.
    private(set) var listFocusRequest = 0
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
        setVisible(!isVisible)
        if isVisible {
            focus(cwd: currentCwd)
        }
    }

    /// Writable mirror of `isVisible` for `.inspector(isPresented:)`. The system
    /// dismisses the inspector on its own (its own chrome, window resize), so
    /// visibility has to be settable and not just toggled — and every write still
    /// goes through `setVisible` so persistence and repo focus stay in sync.
    var isPresented: Bool {
        get { isVisible }
        set {
            guard newValue != isVisible else { return }
            setVisible(newValue)
            if newValue { focus(cwd: currentCwd) }
        }
    }

    /// Show the panel if needed and ask the changes list to take keyboard focus.
    func requestListFocus() {
        if !isVisible {
            setVisible(true)
            focus(cwd: currentCwd)
        }
        listFocusRequest += 1
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.visibleKey)
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
