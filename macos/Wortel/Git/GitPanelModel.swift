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

    /// Mirrors the focused session's strip under its terminal.
    private(set) var bottomTabs: [UUID] = []
    private(set) var activeBottomTab: UUID?
    private(set) var bottomVisible = false
    /// Bumped when the strip's terminal should take the keyboard.
    private(set) var bottomFocusRequest = 0
    /// Whether the pending `bottomVisible` change should animate; false when a
    /// session switch drove it, for the same reason as the column's.
    @ObservationIgnored private(set) var animatesBottomChange = false
    /// Tabs closed in this session and not reopened yet, for the menu item.
    var canReopenClosedTab: Bool { !(session?.closedTabs.isEmpty ?? true) }
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
        let bottom = session?.bottomTabs ?? []
        if bottom != bottomTabs { bottomTabs = bottom }
        let activeBottom = session?.activeBottomTab
        if activeBottom != activeBottomTab { activeBottomTab = activeBottom }
        let showsBottom = (session?.bottomVisible ?? false) && !bottom.isEmpty
        if showsBottom != bottomVisible {
            animatesBottomChange = animated
            bottomVisible = showsBottom
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

    /// Close a tab, wherever it is. A terminal's shell ends with it. The
    /// neighbour that slides into its place comes to the front, and closing the
    /// last one in a region hides that region, instantly: nothing is left to
    /// animate towards. The tab goes on the session's reopen stack.
    ///
    /// `target` is for a tab closing in a session that isn't the focused one,
    /// which is what a side shell exiting in the background looks like.
    func close(_ tab: SideTab, in target: Session? = nil) {
        guard let owner = target ?? session,
              let (region, index) = detach(tab, from: owner) else { return }
        if let id = tab.terminalID { owner.closeSideSurface(id) }
        owner.closedTabs.append(ClosedTab(tab: tab, region: region, index: index))
        if owner.closedTabs.count > Self.closedTabLimit {
            owner.closedTabs.removeFirst(owner.closedTabs.count - Self.closedTabLimit)
        }
        onStateChanged?()
        guard owner === session else { return }
        mirror(owner, animated: false)
        resolveCurrent()
        guard tab.terminalID != nil else { return }
        // Keep the keyboard in the region the terminal was closed from if
        // another terminal took its place there; otherwise hand it back.
        if region == .side, isVisible, activeTab?.terminalID != nil {
            terminalFocusRequest += 1
        } else if region == .bottom, bottomVisible, activeBottomTab != nil {
            bottomFocusRequest += 1
        } else {
            onFocusMainTerminal?()
        }
    }

    /// How many closed tabs ⌘⇧T can reach back for, as in the ChatGPT app.
    private static let closedTabLimit = 25

    /// Take a tab out of whichever region holds it, fixing up what's in front
    /// and hiding a region left empty. Its shell, if it has one, is untouched:
    /// this is the half of closing that moving shares.
    private func detach(_ tab: SideTab, from owner: Session) -> (TabRegion, Int)? {
        if let index = owner.sideTabs.firstIndex(of: tab) {
            owner.sideTabs.remove(at: index)
            if owner.activeSideTab == tab {
                owner.activeSideTab = owner.sideTabs.isEmpty
                    ? nil : owner.sideTabs[min(index, owner.sideTabs.count - 1)]
                if let pane = owner.activeSideTab?.pane { owner.inspectorPane = pane }
            }
            if owner.sideTabs.isEmpty { owner.gitPanelVisible = false }
            return (.side, index)
        }
        if let id = tab.terminalID, let index = owner.bottomTabs.firstIndex(of: id) {
            owner.bottomTabs.remove(at: index)
            if owner.activeBottomTab == id {
                owner.activeBottomTab = owner.bottomTabs.isEmpty
                    ? nil : owner.bottomTabs[min(index, owner.bottomTabs.count - 1)]
            }
            if owner.bottomTabs.isEmpty { owner.bottomVisible = false }
            return (.bottom, index)
        }
        return nil
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

    /// The tab in front of whichever region has the keyboard's terminal, for
    /// ⌘W. `terminalID` is the id of the side surface that has focus.
    func tab(forTerminal id: UUID) -> SideTab? {
        guard let session, session.terminalTabIDs.contains(id) else { return nil }
        return .terminal(id)
    }

    /// Put a tab back: a pane as itself, a terminal as a new shell in the place
    /// the old one had. ⌘⇧T.
    ///
    /// Where you are decides which one: in the bottom strip it's the last tab
    /// closed there, anywhere else the last closed in the side column, and only
    /// when that place has nothing to give back, the last closed anywhere. A
    /// plain "last closed" stack felt random once tabs close in two places: the
    /// same key put things back in whichever one you'd happened to close last.
    func reopenClosedTab(in region: TabRegion) {
        guard let session, !session.closedTabs.isEmpty else { return }
        let index = session.closedTabs.lastIndex { $0.region == region }
            ?? session.closedTabs.count - 1
        let closed = session.closedTabs.remove(at: index)
        let tab: SideTab = closed.tab.terminalID != nil ? .terminal(UUID()) : closed.tab
        if tab.pane != nil, session.sideTabs.contains(tab) {
            select(tab)
            return
        }
        insert(tab, into: closed.region, at: closed.index, in: session)
    }

    // MARK: - Moving tabs

    /// Move a tab to `region` at `index` (clamped), or reorder it within the
    /// region it's already in. The tab comes to the front of its new region,
    /// and a region it leaves empty hides. A terminal keeps its shell: moving
    /// is a new place for the same view, not a new terminal.
    func move(_ tab: SideTab, to region: TabRegion, at index: Int) {
        guard let session, tab.fits(region),
              let (from, oldIndex) = detach(tab, from: session) else { return }
        // Removing the tab shifted everything after it by one; an index taken
        // from the strip before the drag has to account for that.
        let target = from == region && oldIndex < index ? index - 1 : index
        insert(tab, into: region, at: target, in: session)
    }

    private func insert(_ tab: SideTab, into region: TabRegion, at index: Int, in session: Session) {
        switch region {
        case .side:
            let at = min(max(index, 0), session.sideTabs.count)
            session.sideTabs.insert(tab, at: at)
            select(tab)
        case .bottom:
            guard let id = tab.terminalID else { return }
            let at = min(max(index, 0), session.bottomTabs.count)
            session.bottomTabs.insert(id, at: at)
            selectBottom(id)
        }
        // A move that emptied the other region hid it; `select` mirrored
        // only what it touched.
        mirror(session, animated: false)
        onStateChanged?()
    }

    // MARK: - The strip under the terminal

    /// Show or hide the strip. Showing one with nothing in it opens a
    /// terminal there, because an empty strip is not something to show. ⌘J.
    func toggleBottom() {
        guard let session else { return }
        if session.bottomTabs.isEmpty {
            openBottomTerminal()
            return
        }
        session.bottomVisible.toggle()
        mirror(session, animated: true)
        onStateChanged?()
        if bottomVisible {
            bottomFocusRequest += 1
        } else {
            onFocusMainTerminal?()
        }
    }

    /// The strip's divider was dragged shut: record it like ⌘J would.
    func bottomCollapsedByDrag() {
        guard let session, session.bottomVisible else { return }
        session.bottomVisible = false
        mirror(session, animated: false)
        onStateChanged?()
        onFocusMainTerminal?()
    }

    func openBottomTerminal() {
        guard let session else { return }
        let id = UUID()
        session.bottomTabs.append(id)
        selectBottom(id)
    }

    func selectBottom(_ id: UUID) {
        guard let session, session.bottomTabs.contains(id) else { return }
        session.activeBottomTab = id
        let wasVisible = bottomVisible
        session.bottomVisible = true
        mirror(session, animated: !wasVisible)
        onStateChanged?()
        bottomFocusRequest += 1
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
