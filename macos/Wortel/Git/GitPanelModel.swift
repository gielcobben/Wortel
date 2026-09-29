import Foundation
import Observation

/// Drives the trailing inspector column: whether it's shown, which of its three
/// panes it shows, and which repo it's pointed at (derived from the selected
/// session's cwd). Resolving a cwd to a work-tree root is async, so the panel
/// briefly shows nothing until it lands. Repo models are cached by root, so
/// switching between sessions in the same repo — or hiding and reshowing —
/// reuses state instead of rebuilding it.
///
/// Both **visibility and pane are per session**, not app-wide: whether the
/// column earns its width, and what it should show while it has it, are
/// properties of what the session is for — a manager sitting in your home
/// directory never wants it, the repo session wants Changes, the one you're
/// exploring wants Files. So this holds no such state of its own: `isVisible`
/// and `pane` are mirrors of the focused session's `gitPanelVisible` and
/// `inspectorPane`, re-read on every `focus` and written back through
/// `setVisible` / `setPane`. `SessionStore` persists both.
///
/// The column is a strip of **tabs** (`SideTab`): the three panes, and terminals
/// of the session's own. `tabs` and `activeTab` mirror the focused session's
/// the same way, through `open` / `select` / `close`. Opening a tab opens the
/// column, closing the last one closes it, and hiding it keeps them.
///
/// (The name is historical — this predates the Files pane and the tabs.
/// Renaming it to `SideColumnModel` would churn every call site for no
/// behavioural gain.)
@Observable
@MainActor
final class GitPanelModel {
    /// Mirrors the focused session's `gitPanelVisible`. Observable so the
    /// inspector item and the menu item's Show/Hide title track it.
    private(set) var isVisible = false
    private(set) var repo: GitRepoModel?

    /// Mirrors the focused session's `inspectorPane`. Driven by the toolbar's
    /// segmented control and the two View-menu commands, both through
    /// `activate(_:)`.
    private(set) var pane: InspectorPane = GitPanelModel.defaultPane

    /// Mirrors the focused session's side tabs and the one in front. `pane`
    /// keeps meaning "the pane on screen" whenever the active tab is a pane, so
    /// everything built on it (the panels, the column width) reads unchanged.
    private(set) var tabs: [SideTab] = []
    private(set) var activeTab: SideTab?
    /// Bumped when a terminal tab should take the keyboard: it was just opened
    /// or picked. A session switch that merely shows one does not bump it,
    /// because switching sessions puts you in the session's main terminal.
    private(set) var terminalFocusRequest = 0
    /// Hand the keyboard back to the session's main terminal, for when the tab
    /// that had it closes. Set by AppDelegate.
    @ObservationIgnored var onFocusMainTerminal: (() -> Void)?
    /// Ask whether to close a side terminal that is still running something;
    /// calls back only if the answer is yes. Set by AppDelegate.
    @ObservationIgnored var confirmCloseTerminal: ((_ proceed: @escaping () -> Void) -> Void)?

    /// The pane a session with no stored preference opens on: the last one the
    /// user explicitly chose, anywhere. Not the session's state — the *default*
    /// for sessions that have never expressed one, which is also how a
    /// `sessions.json` written before panes were per-session migrates (see
    /// `SessionManager.restore`). A new session inherits your habit rather than
    /// snapping back to Changes.
    static var defaultPane: InspectorPane {
        UserDefaults.standard.string(forKey: paneKey).flatMap(InspectorPane.init(rawValue:)) ?? .changes
    }

    /// The last *source-control* pane chosen, so "Show Source Control" from the
    /// Files pane returns you to History if that's where you were. Tracked apart
    /// from `defaultPane` precisely because that one can hold `.files`.
    static var lastSourceControlPane: InspectorPane {
        let stored = UserDefaults.standard.string(forKey: lastGitPaneKey)
            .flatMap(InspectorPane.init(rawValue:))
        guard let stored, stored.isSourceControl else { return .changes }
        return stored
    }

    private static let paneKey = "git.panelPane"
    private static let lastGitPaneKey = "git.lastSourceControlPane"
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
    /// Set by AppDelegate to persist a visibility or pane change: both are
    /// session state, so they belong in sessions.json rather than in this model.
    @ObservationIgnored var onStateChanged: (() -> Void)?
    /// Open a file in a preview window. Set by the app layer and handed to each
    /// repo model as it's created, so the Changes list and History can reach it.
    @ObservationIgnored var onOpenPreview: ((URL, PreviewDiffSource, Bool) -> Void)?

    @ObservationIgnored private var cache: [String: GitRepoModel] = [:]
    @ObservationIgnored private var currentCwd: String?
    /// Coalesces bursts of command-finished refreshes into one status read.
    @ObservationIgnored private var refreshWorkItem: DispatchWorkItem?
    private static let refreshDebounce: TimeInterval = 0.15

    /// Point the panel at the selected session: its `gitPanelVisible` decides
    /// whether the panel is up, its `inspectorPane` what it shows, its cwd which
    /// repo. Called on selection changes and whenever the selected session's cwd
    /// moves. No git work runs while hidden; showing re-focuses.
    func focus(session: Session?) {
        self.session = session
        currentCwd = session?.cwd
        // Only write `isVisible`/`pane` when they actually move: @Observable
        // fires its observers on every assignment, same value or not, and this
        // runs on each cwd report — i.e. every shell prompt — so an unguarded
        // write would wake the split controller and the toolbar a few times a
        // second to decide nothing changed.
        // The session, not the user, decided this — snap (see the flag).
        mirror(session, animated: false)
        resolveCurrent()
    }

    /// Copy a session's column state onto the model, writing only what moved
    /// (see `focus` for why that matters).
    private func mirror(_ session: Session?, animated: Bool) {
        let sessionTabs = session?.sideTabs ?? []
        if sessionTabs != tabs { tabs = sessionTabs }
        let active = session?.activeSideTab
        if active != activeTab { activeTab = active }
        let sessionPane = active?.pane ?? session?.inspectorPane ?? Self.defaultPane
        if sessionPane != pane { pane = sessionPane }
        let visible = (session?.gitPanelVisible ?? false) && !sessionTabs.isEmpty
        if visible != isVisible {
            animatesVisibilityChange = animated
            isVisible = visible
        }
    }

    /// One click on a pane control — a toolbar segment, or a View-menu command.
    /// Each means both "show me this pane" and "toggle, if it's already what's
    /// on screen":
    ///
    /// - hidden → open on that pane
    /// - showing a *different* pane → swap in place, don't close
    /// - showing that pane → close
    ///
    /// The single implementation behind both the toolbar and the menu, so ⌘⌥G,
    /// ⌘⌥E and the segments can't drift apart.
    func activate(_ requested: InspectorPane, via origin: PanelOrigin = .toolbar) {
        if isVisible && activeTab == .pane(requested) {
            setVisible(false)
            resolveCurrent()
        } else {
            show(requested, via: origin)
        }
    }

    /// Show a pane without the toggle — for the paths where a click can only
    /// mean "give me this", never "close": reclaiming the column from the
    /// markdown preview, which is a view of neither pane.
    func show(_ requested: InspectorPane, via origin: PanelOrigin = .toolbar) {
        let wasShowingThis = isVisible && activeTab == .pane(requested)
        open(.pane(requested))
        // Only when this actually put a different pane in front of someone. A
        // session switch that restores a panel already on that pane is not a
        // use of the feature, and counting those would make whichever pane
        // people leave open look like the one they keep choosing.
        if !wasShowingThis {
            Telemetry.capture(.inspectorShown(pane: InspectorPaneKind(requested), via: origin))
        }
    }

    /// Show or hide the column. Hiding keeps its tabs; showing a column that
    /// has none opens the pane you last chose, because an empty column is not
    /// something to show.
    func toggle() {
        if !isVisible, tabs.isEmpty {
            open(.pane(Self.defaultPane))
            return
        }
        setVisible(!isVisible)
        resolveCurrent()
    }

    // MARK: - Tabs

    /// Put a tab in front, adding it to the strip first if it isn't there. The
    /// column opens with it: asking for a tab means wanting to see it.
    func open(_ tab: SideTab) {
        guard let session else { return }
        if !session.sideTabs.contains(tab) {
            session.sideTabs.append(tab)
        }
        select(tab)
    }

    /// A new shell beside the session's own.
    func openTerminal() {
        open(.terminal(UUID()))
    }

    /// Bring a tab that's already in the strip to the front.
    func select(_ tab: SideTab) {
        guard let session, session.sideTabs.contains(tab) else { return }
        session.activeSideTab = tab
        if let pane = tab.pane { setPane(pane) }
        let wasVisible = isVisible
        session.gitPanelVisible = true
        mirror(session, animated: !wasVisible)
        onStateChanged?()
        resolveCurrent()
        if tab.terminalID != nil { terminalFocusRequest += 1 }
    }

    /// The tab `offset` places along from the one in front, wrapping. ⌃Tab and
    /// ⌃⇧Tab.
    func selectAdjacent(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        guard isVisible, let activeTab, let index = tabs.firstIndex(of: activeTab) else {
            select(tabs[0])
            return
        }
        let next = (index + offset % tabs.count + tabs.count) % tabs.count
        select(tabs[next])
    }

    /// Close a tab. A terminal's shell ends with it. The neighbour that slides
    /// into its place comes to the front, and closing the last one closes the
    /// column, instantly: nothing is left to animate towards.
    ///
    /// `target` is for a tab closing in a session that isn't the focused one,
    /// which is what a side shell exiting in the background looks like.
    func close(_ tab: SideTab, in target: Session? = nil) {
        guard let owner = target ?? session,
              let index = owner.sideTabs.firstIndex(of: tab) else { return }
        if let id = tab.terminalID { owner.closeSideSurface(id) }
        owner.sideTabs.remove(at: index)
        if owner.activeSideTab == tab {
            owner.activeSideTab = owner.sideTabs.isEmpty
                ? nil : owner.sideTabs[min(index, owner.sideTabs.count - 1)]
            if let pane = owner.activeSideTab?.pane { owner.inspectorPane = pane }
        }
        if owner.sideTabs.isEmpty { owner.gitPanelVisible = false }
        onStateChanged?()
        guard owner === session else { return }
        mirror(owner, animated: false)
        resolveCurrent()
        if isVisible, activeTab?.terminalID != nil {
            terminalFocusRequest += 1
        } else if tab.terminalID != nil {
            // The terminal that had the keyboard is gone, and nothing that
            // takes one replaced it.
            onFocusMainTerminal?()
        }
    }

    /// A close the user asked for: the × on a tab, ⌘W in a side terminal. A
    /// terminal still running a program asks first; everything else just goes.
    func requestClose(_ tab: SideTab) {
        guard let session else { return }
        if let id = tab.terminalID, session.sideSurfaces[id]?.needsConfirmClose == true,
           let confirmCloseTerminal {
            confirmCloseTerminal { [weak self, weak session] in
                guard let self, let session else { return }
                self.close(tab, in: session)
            }
            return
        }
        close(tab)
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
        if !isVisible || activeTab?.pane == nil {
            open(.pane(pane))
        }
        listFocusRequest += 1
    }

    /// The user showed or hid the panel — record it on the session it was done
    /// *to*, and have that persisted. Every write to `isVisible` outside `focus`
    /// goes through here, so the session and the panel can't drift apart.
    private func setVisible(_ visible: Bool) {
        // An empty column has nothing to show; opening one goes through `open`.
        if visible, tabs.isEmpty {
            if let session, session.sideTabs.isEmpty {
                open(.pane(Self.defaultPane))
            }
            return
        }
        animatesVisibilityChange = true
        isVisible = visible
        guard let session, session.gitPanelVisible != visible else { return }
        session.gitPanelVisible = visible
        onStateChanged?()
    }

    /// The user chose a pane — the same funnel as `setVisible`, for the same
    /// reason. It also updates the two app-wide defaults: the pane a session
    /// with no preference of its own opens on, and (for a source-control pane)
    /// the one ⌘⌥G returns to from Files. Those are defaults, not state — the
    /// session is the state.
    private func setPane(_ requested: InspectorPane) {
        UserDefaults.standard.set(requested.rawValue, forKey: Self.paneKey)
        if requested.isSourceControl {
            UserDefaults.standard.set(requested.rawValue, forKey: Self.lastGitPaneKey)
        }
        pane = requested
        guard let session, session.inspectorPane != requested else { return }
        session.inspectorPane = requested
        onStateChanged?()
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
            model.onOpenPreview = { [weak self] url, diff, hasChanges in
                self?.onOpenPreview?(url, diff, hasChanges)
            }
            cache[root] = model
            repo = model
            resolvedNonRepo = false
            await model.refresh()
        }
    }
}
