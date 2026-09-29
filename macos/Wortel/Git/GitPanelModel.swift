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
    private(set) var bottomTabs: [SideTab] = []
    private(set) var activeBottomTab: SideTab?
    /// The area you last worked in: the row of the tab you last picked, opened
    /// or moved, the area ⌘] took you to, or the one whose terminal you typed
    /// in. It's what "the row you're in" means to the keyboard commands when
    /// the keyboard itself isn't in a row: a file tab never takes it, and
    /// picking one in the column still means you're in the column.
    @ObservationIgnored var lastRegion: TabRegion = .main
    private(set) var bottomVisible = false
    /// Bumped when the strip's terminal should take the keyboard.
    private(set) var bottomFocusRequest = 0
    /// Whether the pending `bottomVisible` change should animate; false when a
    /// session switch drove it, for the same reason as the column's.
    @ObservationIgnored private(set) var animatesBottomChange = false
    /// Mirrors the main area's tab row: the tabs after the session's terminal,
    /// and the one in front (nil: the terminal).
    private(set) var mainTabs: [SideTab] = []
    private(set) var activeMainTab: SideTab?
    /// Bumped when a terminal in the main area's row should take the keyboard.
    private(set) var mainFocusRequest = 0
    /// Which side the column is on.
    private(set) var columnLeading = false

    /// Whether the Files pane is on screen, in either row: the one thing the
    /// file tree's upkeep is for.
    var showsFiles: Bool {
        (isVisible && activeTab == .pane(.files)) || activeMainTab == .pane(.files)
            || (bottomVisible && activeBottomTab == .pane(.files))
    }

    /// Whether a repo view could be on screen anywhere, which is when resolving
    /// and refreshing the repo is worth doing.
    private var needsRepo: Bool {
        isVisible || activeMainTab?.pane != nil || (bottomVisible && activeBottomTab?.pane != nil)
    }

    /// Tabs closed in this session and not reopened yet, for the menu item.
    var canReopenClosedTab: Bool { !(session?.closedTabs.isEmpty ?? true) }
    /// Hand the keyboard back to the session's main terminal, for when the tab
    /// that had it closes. Set by AppDelegate.
    @ObservationIgnored var onFocusMainTerminal: (() -> Void)?
    /// A tab closed, for whoever holds something for it (a previewed file's
    /// document). Set by AppDelegate.
    @ObservationIgnored var onTabClosed: ((SideTab) -> Void)?
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
    private func mirror(_ session: Session?, animated: Bool, animatesClosing: Bool = true) {
        let sessionTabs = session?.sideTabs ?? []
        if sessionTabs != tabs { tabs = sessionTabs }
        let active = session?.activeSideTab
        if active != activeTab { activeTab = active }
        let sessionPane = active?.pane ?? session?.inspectorPane ?? Self.defaultPane
        if sessionPane != pane { pane = sessionPane }
        let visible = (session?.gitPanelVisible ?? false) && !sessionTabs.isEmpty
        if visible != isVisible {
            animatesVisibilityChange = animated && (visible || animatesClosing)
            isVisible = visible
        }
        let main = session?.mainTabs ?? [.session]
        if main != mainTabs { mainTabs = main }
        let activeMain = session?.activeMainTab
        if activeMain != activeMainTab { activeMainTab = activeMain }
        let leading = session?.sideColumnLeading ?? false
        if leading != columnLeading { columnLeading = leading }
        let bottom = session?.bottomTabs ?? []
        if bottom != bottomTabs { bottomTabs = bottom }
        let activeBottom = session?.activeBottomTab
        if activeBottom != activeBottomTab { activeBottomTab = activeBottom }
        let showsBottom = (session?.bottomVisible ?? false) && !bottom.isEmpty
        if showsBottom != bottomVisible {
            animatesBottomChange = animated && (showsBottom || animatesClosing)
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
        // In the main area's row: the same toggle, against the terminal.
        if mainTabs.contains(.pane(requested)) {
            selectMain(activeMainTab == .pane(requested) ? .session : .pane(requested))
            return
        }
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
    ///
    /// The keyboard follows, as it does for the strip (⌘J): showing the column
    /// puts you in it (a terminal, or a pane's list), hiding it puts you back in
    /// the session's terminal. That's what makes ⌥⌘B, ⌘T, ⌘W a sequence you can
    /// type without reaching for the pointer.
    func toggle() {
        if !isVisible, tabs.isEmpty {
            fillEmptyColumn()
            focus(.side)
            return
        }
        setVisible(!isVisible)
        resolveCurrent()
        if isVisible {
            focus(.side)
        } else {
            lastRegion = .main
            onFocusMainTerminal?()
        }
    }

    // MARK: - Tabs
    //
    // The rules live in `WorkspaceTabs`, a pure value with its own tests. Every
    // operation here is the same shape: make the change to the session's
    // `workspace`, then do what isn't pure (`settle`): the pane on screen, the
    // keyboard, the repo, the mirror, saving.

    /// Run a change on the session's tabs and write it back.
    @discardableResult
    private func change<T>(_ owner: Session, _ body: (inout WorkspaceTabs) -> T) -> T {
        var workspace = owner.workspace
        let result = body(&workspace)
        owner.workspace = workspace
        return result
    }

    /// After a tab was brought to the front: show its pane, give a terminal the
    /// keyboard, and bring the model and the file up to date. A row that opened
    /// slides open; one that emptied snaps shut, as ChatGPT's do.
    private func settle(_ tab: SideTab, in session: Session) {
        if let pane = tab.pane { setPane(pane) }
        mirror(session, animated: true, animatesClosing: false)
        onStateChanged?()
        resolveCurrent()
        let region = session.workspace.region(of: tab)
        if let region { lastRegion = region }
        switch region {
        case .main?:
            if tab == .session { onFocusMainTerminal?() }
            else if tab.terminalID != nil { mainFocusRequest += 1 }
        case .side?:
            if tab.terminalID != nil { terminalFocusRequest += 1 }
        case .bottom?:
            if tab.terminalID != nil { bottomFocusRequest += 1 }
        case nil:
            break
        }
    }

    /// Put a tab in the column's row (at the end, if it isn't in any row) and
    /// bring it forward there. A tab that's in the main area's row is brought
    /// forward there instead: that's where it is.
    func open(_ tab: SideTab) {
        guard let session else { return }
        if session.mainTabs.contains(tab) {
            selectMain(tab)
            return
        }
        change(session) { $0.place(tab, in: .side, at: .max) }
        select(tab)
    }

    /// A new shell beside the session's own.
    func openTerminal() {
        open(.terminal(UUID()))
    }

    /// Bring a tab that's already in the column's row to the front.
    func select(_ tab: SideTab) {
        guard let session, session.sideTabs.contains(tab) else { return }
        change(session) { $0.bringForward(tab) }
        settle(tab, in: session)
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
    /// last one in the column or the strip hides it, instantly. The tab goes on
    /// the session's reopen stack. Never the session's own terminal.
    ///
    /// `target` is for a tab closing in a session that isn't the focused one,
    /// which is what a side shell exiting in the background looks like.
    func close(_ tab: SideTab, in target: Session? = nil) {
        guard let owner = target ?? session,
              let region = change(owner, { $0.close(tab) }) else { return }
        if let id = tab.terminalID { owner.closeSideSurface(id) }
        onTabClosed?(tab)
        if region == .side, let pane = owner.activeSideTab?.pane { owner.inspectorPane = pane }
        onStateChanged?()
        guard owner === session else { return }
        mirror(owner, animated: false)
        resolveCurrent()
        guard tab.terminalID != nil else { return }
        // Keep the keyboard in the row the terminal was closed from if another
        // terminal took its place there; otherwise hand it back.
        if region == .side, isVisible, activeTab?.terminalID != nil {
            terminalFocusRequest += 1
        } else if region == .main, activeMainTab?.terminalID != nil {
            mainFocusRequest += 1
        } else if region == .bottom, bottomVisible, activeBottomTab?.terminalID != nil {
            bottomFocusRequest += 1
        } else {
            onFocusMainTerminal?()
        }
    }

    /// A close the user asked for: the × on a tab, ⌘W in a side terminal. A
    /// terminal still running a program asks first; everything else just goes.
    func requestClose(_ tab: SideTab) {
        guard tab != .session, let session else { return }
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

    /// The tab a terminal with the keyboard belongs to, for ⌘W. `id` is the
    /// terminal tab's id.
    func tab(forTerminal id: UUID) -> SideTab? {
        guard let session, session.terminalTabIDs.contains(id) else { return nil }
        return .terminal(id)
    }

    /// Put back a closed tab: the last closed in `region` (the row you're in),
    /// or the last closed anywhere when that row has none. ⌘⇧T.
    func reopenClosedTab(in region: TabRegion) {
        guard let session, let tab = change(session, { $0.reopen(preferring: region) }) else { return }
        settle(tab, in: session)
    }

    // MARK: - Moving tabs

    /// Move a tab to `region` at `index`, or reorder it within its row; see
    /// `WorkspaceTabs.move`. It comes to the front of its new row, and a row it
    /// leaves empty hides. A terminal keeps its shell: moving is a new place for
    /// the same view, not a new terminal.
    func move(_ tab: SideTab, to region: TabRegion, at index: Int) {
        guard let session, change(session, { $0.move(tab, to: region, at: index) }) else { return }
        if let pane = session.activeSideTab?.pane { session.inspectorPane = pane }
        settle(tab, in: session)
    }

    // MARK: - The main area's row

    /// Bring a tab of the main area's row to the front; `.session` is the
    /// session's own terminal.
    func selectMain(_ tab: SideTab) {
        guard let session, session.mainTabs.contains(tab) else { return }
        change(session) { $0.bringForward(tab) }
        settle(tab, in: session)
    }

    /// Open `tab` in `region`'s row: to the front if it's there already, moved
    /// over if it's in the other row, added at the end otherwise. What "+" in a
    /// row means: here.
    func open(_ tab: SideTab, in region: TabRegion) {
        guard let session else { return }
        switch session.workspace.region(of: tab) {
        case region?:
            change(session) { $0.bringForward(tab) }
        case _?:
            change(session) { $0.move(tab, to: region, at: .max) }
        case nil:
            change(session) {
                $0.place(tab, in: region, at: .max)
                $0.bringForward(tab)
            }
        }
        settle(tab, in: session)
    }

    /// Give an empty column something to show, when it's asked to open. The
    /// pane last chosen, unless that one is in the main area's row (opening it
    /// would only bring it forward there, and the column would stay shut): then
    /// the first pane that isn't, and a terminal when all of them are.
    private func fillEmptyColumn() {
        guard let session else { return }
        let panes = [Self.defaultPane] + InspectorPane.allCases
        if let pane = panes.first(where: { !session.mainTabs.contains(.pane($0)) }) {
            open(.pane(pane), in: .side)
        } else {
            openTerminal()
        }
    }

    /// A new shell in the main area's row.
    func openMainTerminal() {
        open(.terminal(UUID()), in: .main)
    }

    /// Put the column on the terminal's leading or trailing side.
    func setColumnLeading(_ leading: Bool) {
        guard let session, session.sideColumnLeading != leading else { return }
        session.sideColumnLeading = leading
        mirror(session, animated: false)
        onStateChanged?()
    }

    // MARK: - Rows by region (for the keyboard)

    /// A row's tabs in order.
    func tabs(in region: TabRegion) -> [SideTab] {
        switch region {
        case .main: return mainTabs
        case .side: return tabs
        case .bottom: return bottomTabs
        }
    }

    /// The tab in front of a row that's showing.
    func activeTab(in region: TabRegion) -> SideTab? {
        switch region {
        case .main: return activeMainTab ?? .session
        case .side: return isVisible ? activeTab : nil
        case .bottom: return bottomVisible ? activeBottomTab : nil
        }
    }

    /// Bring a tab of `region`'s row forward.
    func bringForward(_ tab: SideTab, in region: TabRegion) {
        switch region {
        case .main: selectMain(tab)
        case .side: select(tab)
        case .bottom: selectBottom(tab)
        }
    }

    /// The tab `offset` places along in `region`'s row, wrapping. ⌃Tab, ⌥⌘→.
    func selectAdjacent(_ offset: Int, in region: TabRegion) {
        let row = tabs(in: region)
        guard !row.isEmpty else { return }
        guard let current = activeTab(in: region), let index = row.firstIndex(of: current) else {
            bringForward(row[0], in: region)
            return
        }
        bringForward(row[(index + offset % row.count + row.count) % row.count], in: region)
    }

    /// The `number`th tab (1-based) of `region`'s row; 9 is the last, as in
    /// Safari. ⌥⌘1…⌥⌘9.
    func selectTab(number: Int, in region: TabRegion) {
        let row = tabs(in: region)
        guard !row.isEmpty else { return }
        let index = number >= 9 ? row.count - 1 : number - 1
        guard row.indices.contains(index) else { return }
        bringForward(row[index], in: region)
    }

    /// Give the keyboard to what's in front of `region`: a terminal, or the
    /// list of a pane. ⌘] / ⌘[.
    func focus(_ region: TabRegion) {
        lastRegion = region
        switch region {
        case .main:
            guard let tab = activeMainTab else { onFocusMainTerminal?(); return }
            if tab.terminalID != nil { mainFocusRequest += 1 } else { listFocusRequest += 1 }
        case .side:
            guard isVisible, let tab = activeTab else { return }
            if tab.terminalID != nil { terminalFocusRequest += 1 } else { listFocusRequest += 1 }
        case .bottom:
            guard bottomVisible, let tab = activeBottomTab else { return }
            if tab.terminalID != nil { bottomFocusRequest += 1 } else { listFocusRequest += 1 }
        }
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
            focus(.bottom)
        } else {
            lastRegion = .main
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
        open(.terminal(UUID()), in: .bottom)
    }

    func selectBottom(_ tab: SideTab) {
        guard let session, session.bottomTabs.contains(tab) else { return }
        change(session) { $0.bringForward(tab) }
        settle(tab, in: session)
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
                fillEmptyColumn()
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

    /// Resolve the current cwd to a repo, if a repo view could be on screen.
    private func resolveCurrent() {
        guard needsRepo else { return }
        let cwd = currentCwd
        Task { await resolve(cwd: cwd) }
    }

    /// A command finished in the shown repo's session — the work tree may have
    /// changed. Debounced so a chatty run collapses to a single refresh.
    func refreshCurrent() {
        guard needsRepo, let repo else { return }
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
