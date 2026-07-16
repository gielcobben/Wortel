import Foundation
import Observation

/// Drives the source-control panel: whether it's shown, and which repo it's
/// pointed at (derived from the selected session's cwd). Resolving a cwd to a
/// work-tree root is async, so the panel briefly shows nothing until it lands.
/// Repo models are cached by root, so switching between sessions in the same
/// repo — or hiding and reshowing — reuses state instead of rebuilding it.
///
/// Visibility is **per session**, not app-wide: whether the panel earns its
/// width is a property of what the session is for, not of the app. So this holds
/// no visibility state of its own — `isVisible` is a mirror of the focused
/// session's `gitPanelVisible`, re-read on every `focus` and written back
/// through `setVisible`. `SessionStore` persists it.
@Observable
@MainActor
final class GitPanelModel {
    /// Mirrors the focused session's `gitPanelVisible`. Observable so the
    /// inspector item and the menu item's Show/Hide title track it.
    private(set) var isVisible = false
    private(set) var repo: GitRepoModel?

    /// Which pane the panel shows. Stays app-wide (unlike visibility) — it's a
    /// preference for how you read a diff, not a fact about a session. Driven by
    /// the toolbar's segmented control.
    var pane: GitInspectorPane = GitPanelModel.storedPane {
        didSet {
            guard pane != oldValue else { return }
            UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey)
        }
    }

    private static var storedPane: GitInspectorPane {
        UserDefaults.standard.string(forKey: paneKey).flatMap(GitInspectorPane.init(rawValue:)) ?? .changes
    }

    private static let paneKey = "git.panelPane"
    /// Bumped to ask the panel to move keyboard focus into the list of whichever
    /// pane is showing — Changes or History. Both read the same token because
    /// only one pane is ever mounted. The list view watches this and claims
    /// focus; a monotonic counter (rather than a Bool) so repeated requests
    /// always register, even back-to-back.
    private(set) var listFocusRequest = 0
    /// True once a cwd has been resolved and it turned out not to be a repo — so
    /// the panel can show "not a git repository" rather than a blank flash.
    private(set) var resolvedNonRepo = false

    /// Whether the pending `isVisible` change should animate the divider across.
    /// False when it's the *session* that changed rather than the user toggling:
    /// switching sessions is meant to be instant, and animating the collapse
    /// would reflow the terminal every frame for the length of it. Read by
    /// MainSplitViewController when it applies the change — imperatively, off the
    /// back of `isVisible`'s own mutation, so it stays out of observation.
    @ObservationIgnored private(set) var animatesVisibilityChange = false

    /// The session the panel is pointed at. Weak — the manager owns sessions, and
    /// a closed one must not be kept alive by the panel.
    @ObservationIgnored private weak var session: Session?
    /// Set by AppDelegate to persist a visibility change: it's session state, so
    /// it belongs in sessions.json rather than in this model.
    @ObservationIgnored var onVisibilityChanged: (() -> Void)?

    @ObservationIgnored private var cache: [String: GitRepoModel] = [:]
    @ObservationIgnored private var currentCwd: String?
    /// Coalesces bursts of command-finished refreshes into one status read.
    @ObservationIgnored private var refreshWorkItem: DispatchWorkItem?
    private static let refreshDebounce: TimeInterval = 0.15

    /// Point the panel at the selected session: its `gitPanelVisible` decides
    /// whether the panel is up, its cwd decides which repo. Called on selection
    /// changes and whenever the selected session's cwd moves. No git work runs
    /// while hidden; showing re-focuses.
    func focus(session: Session?) {
        self.session = session
        currentCwd = session?.cwd
        // Only write `isVisible` when it actually moves: @Observable fires its
        // observers on every assignment, same value or not, and this runs on each
        // cwd report — i.e. every shell prompt — so an unguarded write would wake
        // the split controller a few times a second to decide nothing changed.
        let visible = session?.gitPanelVisible ?? false
        if visible != isVisible {
            // The session, not the user, decided this — snap (see the flag).
            animatesVisibilityChange = false
            isVisible = visible
        }
        resolveCurrent()
    }

    func toggle() {
        setVisible(!isVisible)
        resolveCurrent()
    }

    /// Writable mirror of `isVisible` for the paths that don't toggle: dragging
    /// the divider to the edge collapses the panel behind this model's back
    /// (MainSplitViewController reflects it here), and the toolbar's pane control
    /// forces it open. Every write still goes through `setVisible`, so a
    /// divider-drag dismissal is recorded on the session like any other.
    var isPresented: Bool {
        get { isVisible }
        set {
            guard newValue != isVisible else { return }
            setVisible(newValue)
            resolveCurrent()
        }
    }

    /// Show the panel if needed and ask the changes list to take keyboard focus.
    func requestListFocus() {
        if !isVisible {
            setVisible(true)
            resolveCurrent()
        }
        listFocusRequest += 1
    }

    /// The user showed or hid the panel — record it on the session it was done
    /// *to*, and have that persisted. Every write to `isVisible` outside `focus`
    /// goes through here, so the session and the panel can't drift apart.
    private func setVisible(_ visible: Bool) {
        animatesVisibilityChange = true
        isVisible = visible
        guard let session, session.gitPanelVisible != visible else { return }
        session.gitPanelVisible = visible
        onVisibilityChanged?()
    }

    /// Resolve the current cwd to a repo, if the panel is actually up.
    private func resolveCurrent() {
        guard isVisible else { return }
        let cwd = currentCwd
        Task { await resolve(cwd: cwd) }
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
            let model = GitRepoModel(root: root, highlighter: DiffHighlighter.shared)
            cache[root] = model
            repo = model
            resolvedNonRepo = false
            await model.refresh()
        }
    }
}
