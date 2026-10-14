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

    /// Mirrors the focused session's `inspectorPane`: the pane in front of the
    /// column. Changed by picking a tab and by the View-menu commands
    /// (`activate(_:)`).
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
    /// Continue in another worktree of the repository: its session, or a new
    /// one there. Set by AppDelegate.
    @ObservationIgnored var onOpenWorktree: ((String) -> Void)?
    /// Take the keyboard from whatever has it, for when what's in front can't
    /// hold it (a file). Set by AppDelegate.
    @ObservationIgnored var onClearKeyboard: (() -> Void)?
    /// A tab closed, for whoever holds something for it (a previewed file's
    /// document). Set by AppDelegate.
    @ObservationIgnored var onTabClosed: ((SideTab) -> Void)?
    /// Ask whether to close a side terminal that is still running something;
    /// calls back only if the answer is yes. Set by AppDelegate.
    @ObservationIgnored var confirmCloseTerminal: ((_ count: Int, _ proceed: @escaping () -> Void) -> Void)?

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
    /// A request to put the keyboard in the list of the pane in front of one
    /// row (Changes, History, the file tree). Each row reads its own through
    /// `listFocusRequest(in:)`: a pane can be in front of all three, and one
    /// shared request was answered by every one of them at once.
    ///
    /// A request is for the pane in front now or about to be (a tab opened
    /// and focused in one go), not for whatever pane appears later: a list
    /// takes a request it hasn't handled when it appears, so an old one would
    /// pull the keyboard out of wherever you'd since gone. So it expires.
    struct ListFocusRequest: Equatable {
        let region: TabRegion
        let serial: Int
        let expires: Date
    }
    private(set) var listFocus: ListFocusRequest?
    @ObservationIgnored private var listFocusSerial = 0

    /// The request a pane in `region` should answer, or 0 for none.
    func listFocusRequest(in region: TabRegion) -> Int {
        guard let listFocus, listFocus.region == region, listFocus.expires > Date() else { return 0 }
        return listFocus.serial
    }

    private func requestListFocus(in region: TabRegion) {
        listFocusSerial += 1
        listFocus = ListFocusRequest(region: region, serial: listFocusSerial,
                                     expires: Date().addingTimeInterval(1))
    }
    // MARK: Checkouts

    /// One checkout of the shown repository: its own or another worktree.
    struct Checkout: Identifiable, Equatable {
        let path: String
        let branch: String?
        /// Uncommitted changes there.
        let changes: Int
        /// Commits there that the shown checkout doesn't have.
        let ahead: Int
        /// The repository's main folder, not a linked worktree.
        var isPrimary = false
        var id: String { path }
        var name: String { branch ?? (path as NSString).lastPathComponent }
    }

    /// Every checkout of the shown repository, when it has more than one:
    /// what the worktree chip offers to show instead, and what a clean Changes
    /// pane points at when the work is somewhere else. Read when the repo
    /// resolves and when the menu opens, not on every refresh.
    private(set) var checkouts: [Checkout] = []
    /// The root of the session terminal's own checkout.
    private(set) var terminalCheckout: String?
    /// Mirrors the focused session's `gitCheckout`: nil follows the terminal.
    private(set) var pinnedCheckout: String?

    /// "3 changes, 12 commits ahead", "clean": what a checkout has in it.
    static func summary(of checkout: Checkout) -> String {
        var parts: [String] = []
        if checkout.changes > 0 {
            parts.append("\(checkout.changes) change\(checkout.changes == 1 ? "" : "s")")
        }
        if checkout.ahead > 0 {
            parts.append("\(checkout.ahead) commit\(checkout.ahead == 1 ? "" : "s") ahead")
        }
        return parts.isEmpty ? "clean" : parts.joined(separator: ", ")
    }

    /// Show another checkout of the repo in this session's git panes, or the
    /// terminal's again (nil, or its own path).
    func showCheckout(_ path: String?) {
        guard let session else { return }
        let pinned = path == terminalCheckout ? nil : path
        guard session.gitCheckout != pinned else { return }
        session.gitCheckout = pinned
        pinnedCheckout = pinned
        onStateChanged?()
        currentCwd = pinned ?? session.cwd
        resolveCurrent()
    }

    /// Read every checkout of the shown repo and what's in each.
    func loadCheckouts() async {
        guard let repo else { checkouts = []; return }
        // Already being read, for the same thing: the switch that resolved the
        // repo and the header's timer both ask the moment it appears, and two
        // reads would be two scans of every worktree for one answer. A read
        // superseded since (another session asked in between) is giving up,
        // so it doesn't count.
        let key = Self.checkoutsKey(root: repo.root, pinned: pinnedCheckout, cwd: session?.cwd)
        // For the same session too: a read discards its answer when the session
        // moved on, so one started for the session you just left answers
        // nobody, and skipping this one on its account left the hint stale.
        if let reading = checkoutsReading, reading.key == key, reading.owner === session,
           reading.generation == checkoutGeneration { return }
        // The newest read wins, for the session it was read for: ⌃Tab held
        // down starts one per tab, and a slow one finishing last, or one for
        // the session you just left, must not write over it.
        checkoutGeneration += 1
        let generation = checkoutGeneration
        checkoutsReading = (key, generation, session)
        defer { if checkoutsReading?.generation == generation { checkoutsReading = nil } }
        let owner = session
        let root = repo.root
        let cwd = session?.cwd
        var terminal: String? = root
        if pinnedCheckout != nil {
            terminal = nil
            if let cwd { terminal = await GitService.repoRoot(for: cwd) }
        }
        let worktrees = await GitService.worktrees(root: root)
        guard worktrees.count > 1 else {
            if generation == checkoutGeneration, repo === self.repo, owner === session {
                checkouts = []
                terminalCheckout = terminal
                checkoutsRead = (Self.checkoutsKey(root: root, pinned: pinnedCheckout, cwd: cwd), Date())
            }
            return
        }
        let head = repo.status.head
        await watchCheckouts(worktrees, shown: root)
        var found: [Checkout] = []
        for worktree in worktrees {
            // Superseded (another session, another repo): stop rather than
            // finish a scan per worktree for an answer nobody will see. ⌃Tab
            // through five sessions used to leave five of these running.
            guard generation == checkoutGeneration else { return }
            let summary: CheckoutScan
            if let known = cache[worktree.path], !known.isStale {
                // A checkout already open in the panel knows its status, and
                // its watch says nothing has moved since.
                summary = CheckoutScan(head: known.status.head, changes: known.status.changes.count)
            } else if let scanned = checkoutScans[worktree.path],
                      !changedCheckouts.contains(worktree.path) {
                // Its watch has seen nothing since the last scan: the answer
                // stands, and no git runs. This is what makes an idle worktree
                // cost nothing however long the panel stays up.
                summary = scanned
            } else {
                // Taken off before the scan, so a write landing during it
                // marks it again rather than being lost.
                changedCheckouts.remove(worktree.path)
                summary = await Self.scan(worktree.path)
                checkoutScans[worktree.path] = summary
            }
            var ahead = 0
            if let head, let theirs = summary.head, theirs != head {
                let key = head + ".." + theirs
                if let known = aheadCounts[key] {
                    ahead = known
                } else {
                    // Two commits' distance never changes: asked once.
                    ahead = await GitService.commitsAhead(from: head, to: theirs, root: root)
                    aheadCounts[key] = ahead
                }
            }
            found.append(Checkout(path: worktree.path, branch: worktree.branch,
                                  changes: summary.changes, ahead: ahead,
                                  isPrimary: worktree.isPrimary))
        }
        guard generation == checkoutGeneration, repo === self.repo, owner === session else { return }
        terminalCheckout = terminal
        if found != checkouts { checkouts = found }
        checkoutsRead = (Self.checkoutsKey(root: root, pinned: pinnedCheckout, cwd: cwd), Date())
    }

    @ObservationIgnored private var checkoutGeneration = 0
    /// The key of the checkouts read in flight, if any.
    @ObservationIgnored private var checkoutsReading: (key: String, generation: Int, owner: Session?)?
    /// What the checkouts were last read for, and when: they're read again
    /// when the repo or the pin changes, or when they're a while old, not on
    /// every tab pick (each read is a `git status` per worktree).
    @ObservationIgnored private var checkoutsRead: (key: String, at: Date)?
    /// How old the list of worktrees may get. Only the *list*: reading it is
    /// `git worktree list`, which reads a few files and walks nothing, and
    /// what each worktree holds is re-read only when its watch says so.
    private static let checkoutsMaxAge: TimeInterval = 60

    /// What a scan of another worktree found: all the header and the lists
    /// need, not the file list.
    struct CheckoutScan: Equatable {
        let head: String?
        let changes: Int
    }

    /// The last scan of each other worktree, kept until its watch fires.
    @ObservationIgnored private var checkoutScans: [String: CheckoutScan] = [:]
    /// Worktrees whose watch fired since their last scan.
    @ObservationIgnored private var changedCheckouts: Set<String> = []
    /// A watch per other worktree, by path. FSEvents is the kernel's: an idle
    /// watch costs nothing, and a busy one only marks its worktree changed.
    @ObservationIgnored private var checkoutWatchers: [String: GitRepoWatcher] = [:]
    /// `rev-list --count` answers by commit pair, which never go stale.
    @ObservationIgnored private var aheadCounts: [String: Int] = [:]

    /// Watch every worktree in `worktrees` but the shown one (its own model
    /// watches it), and stop watching, and forget, the ones gone from the list.
    private func watchCheckouts(_ worktrees: [GitWorktree], shown: String) async {
        let wanted = Set(worktrees.map(\.path).filter { $0 != shown && cache[$0] == nil })
        for path in checkoutWatchers.keys where !wanted.contains(path) {
            checkoutWatchers[path] = nil
            checkoutScans[path] = nil
            changedCheckouts.remove(path)
        }
        for worktree in worktrees where wanted.contains(worktree.path) && checkoutWatchers[worktree.path] == nil {
            let path = worktree.path
            // A linked worktree's HEAD and index live in the primary's .git, so
            // a commit there moves nothing under its own folder. The primary's
            // watch leaves out the other worktrees' state it also holds.
            var paths = [path]
            var excluding: [String] = []
            if worktree.isPrimary {
                excluding = [(path as NSString).appendingPathComponent(".git/worktrees")]
            } else if let gitDir = await GitService.externalGitDir(root: path) {
                paths.append(gitDir)
            }
            checkoutWatchers[path] = GitRepoWatcher(paths: paths, excluding: excluding) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = self?.changedCheckouts.insert(path) }
                }
            }
        }
        if aheadCounts.count > 500 { aheadCounts.removeAll() }
    }

    /// The cheap status: the counts, without what the changes list needs.
    /// `normal` untracked files (a new folder is one change, not a walk of it)
    /// and no rename detection, one at a time app-wide like every background
    /// scan.
    private static func scan(_ path: String) async -> CheckoutScan {
        let status = await GitService.backgroundStatus(root: path, light: true)
        return CheckoutScan(head: status.head, changes: status.changes.count)
    }

    /// The terminal's directory too while pinned: which checkout is the
    /// terminal's is then read from it, and two sessions pinned alike can have
    /// terminals in different checkouts. Unpinned, the terminal's checkout *is*
    /// the root, so the directory is left out: sessions in different folders of
    /// one repo share a read rather than each switch rescanning every worktree.
    private static func checkoutsKey(root: String, pinned: String?, cwd: String?) -> String {
        [root, pinned ?? "", pinned == nil ? "" : cwd ?? ""].joined(separator: "\u{0}")
    }

    /// Re-read the checkouts if a worktree's watch fired, or the list is old.
    /// The repo header asks every little while it's on screen, so what the
    /// lists and a clean pane say about other folders follows an agent working
    /// in one. (Only while Wortel is in front, which is the header's to say:
    /// changes are still marked meanwhile, and caught up on the next ask.)
    func refreshCheckoutsIfStale() async {
        guard let repo else { return }
        guard !checkoutsAreCurrent(for: repo.root) || !changedCheckouts.isEmpty else { return }
        await loadCheckouts()
    }

    /// Set by AppDelegate: what is using a folder (open sessions, processes
    /// standing in it), which only the app can tell and git can't.
    @ObservationIgnored var worktreeUsage: (() -> WorktreeUsage?)?

    /// "Bring Here": take `branch` off the other folder it's checked out in
    /// and switch the shown folder to it. Git lets a branch be in one folder
    /// at a time, and doing this by hand meant finishing up there, removing
    /// the worktree and coming back. Returns why not, or nil when it worked.
    ///
    /// Only when nothing there can be lost or pulled from under someone: no
    /// uncommitted or untracked files, no session open in it, nothing running
    /// in it, and not the repository's main folder (taking `main` from your
    /// own clone is not a side effect anyone expects). The same inspection
    /// Clean Up Worktrees makes, then:
    ///
    /// - a worktree Wortel made goes to the Trash, as the cleanup would take
    ///   it; its branch stays, it's the one coming here;
    /// - any other folder stays where it is, on the same commit, with no
    ///   branch (`switch --detach`): it isn't Wortel's to remove, and a
    ///   detached checkout changes no file in it.
    func bringHere(_ branch: GitBranch) async -> String? {
        guard let repo, let path = branch.worktreePath else { return nil }
        guard let make = worktreeUsage, let usage = make() else {
            return "Wortel couldn't tell what's using that folder, so the branch stays there."
        }
        let processes = await Task.detached { WorktreeUsage.Processes.read() }.value
        let users = usage.users(of: path, in: processes)
        let report = await WorktreeCleanup.inspect(path: path, usedBy: users, urgent: true)
        let folder = (path as NSString).lastPathComponent
        let name = "\u{201C}\(branch.name)\u{201D}"
        if report.isPrimaryCheckout {
            return "\(name) is checked out in the repository's main folder, \(folder). Switch it there, or show that folder here."
        }
        if report.isOrphanedFolder || !report.changedFiles.isEmpty || !report.usedBy.isEmpty {
            var reasons = report.blockers
            if !report.changedFiles.isEmpty { reasons.append("Commit them there first.") }
            return "\(name) stays in \(folder). " + reasons.joined(separator: " ")
        }
        if WorktreeCleanup.isUnder(GitWorktree.root, path) {
            if let error = await WorktreeCleanup.remove(path: path, usedBy: users, deleteBranch: false) {
                return error
            }
        } else {
            let detached = await GitService.run(["switch", "--detach"], in: path)
            if !detached.ok {
                return "\(name) stays in \(folder). " + GitMessage.readable(detached.stderr)
            }
            // Left on a commit with no branch: a trace now, which Clean Up
            // Worktrees offers to remove (WorktreeCleanup.broughtHere).
            WorktreeCleanup.rememberBroughtHere(path)
        }
        await repo.checkout(branch)
        // What's in which folder just changed: read it again now, not in 30s.
        checkoutsRead = nil
        await loadCheckouts()
        return repo.checkoutError
    }

    /// Where the work is when it isn't here: another checkout of the repo with
    /// uncommitted changes (the one with the most), most likely an agent in
    /// this session working in a worktree. Only while the panes follow the
    /// terminal: a checkout chosen by hand is where you asked to be. Commits
    /// alone don't count, or every old worktree with unmerged work would be
    /// pointed at forever.
    var workElsewhere: Checkout? {
        guard pinnedCheckout == nil, let root = repo?.root else { return nil }
        return checkouts
            .filter { $0.path != root && $0.changes > 0 }
            .max { $0.changes < $1.changes }
    }

    private func checkoutsAreCurrent(for root: String) -> Bool {
        guard let read = checkoutsRead else { return false }
        return read.key == Self.checkoutsKey(root: root, pinned: pinnedCheckout, cwd: session?.cwd)
            && Date().timeIntervalSince(read.at) < Self.checkoutsMaxAge
    }

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
    /// Each directory's work-tree root, as `resolve` last found it.
    @ObservationIgnored private var rootByCwd: [String: String] = [:]
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
        currentCwd = session?.gitCheckout ?? session?.cwd
        if session?.gitCheckout != pinnedCheckout { pinnedCheckout = session?.gitCheckout }
        // Only write `isVisible`/`pane` when they actually move: @Observable
        // fires its observers on every assignment, same value or not, and this
        // runs on each cwd report — i.e. every shell prompt — so an unguarded
        // write would wake the split controller and the titlebar a few times a
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

    /// One pane command: ⌘⌥G, ⌘⌥E, or their View-menu items.
    /// Each means both "show me this pane" and "toggle, if it's already what's
    /// on screen":
    ///
    /// - hidden → open on that pane
    /// - showing a *different* pane → swap in place, don't close
    /// - showing that pane → close
    ///
    /// A pane in the main row or the strip toggles there, against the terminal
    /// or the strip being up.
    /// Whether `activate(_:)` would put the pane away rather than bring it up,
    /// by the same rules in the same order: what the menu calls it, Show or
    /// Hide, has to be what the key then does.
    func activateHides(_ requested: InspectorPane) -> Bool {
        if mainTabs.contains(.pane(requested)) { return activeMainTab == .pane(requested) }
        if bottomTabs.contains(.pane(requested)) {
            return bottomVisible && activeBottomTab == .pane(requested)
        }
        return isVisible && activeTab == .pane(requested)
    }

    func activate(_ requested: InspectorPane, via origin: PanelOrigin = .toolbar) {
        // In the main area's row: the same toggle, against the terminal.
        if mainTabs.contains(.pane(requested)) {
            selectMain(activeMainTab == .pane(requested) ? .session : .pane(requested))
            return
        }
        // In the strip: the same toggle, against the strip being up.
        if bottomTabs.contains(.pane(requested)) {
            if bottomVisible && activeBottomTab == .pane(requested) {
                toggleBottom()
            } else {
                selectBottom(.pane(requested))
            }
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
    private func show(_ requested: InspectorPane, via origin: PanelOrigin = .toolbar) {
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
            focus(.main)
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
        let region = session.workspace.region(of: tab)
        // `pane` is the column's; a pane picked in another row only counts
        // as the one you last chose.
        if let pane = tab.pane { setPane(pane, inColumn: region == .side) }
        mirror(session, animated: true, animatesClosing: false)
        onStateChanged?()
        resolveCurrent()
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

    /// Bring a tab forward wherever it is, or put it at the end of the
    /// column's row if it isn't in any.
    func open(_ tab: SideTab) {
        guard let session else { return }
        if session.workspace.region(of: tab) == nil { reportOpened(tab, in: .side) }
        change(session) { workspace in
            if workspace.region(of: tab) == nil {
                workspace.place(tab, in: .side, at: .max)
                workspace.bringForward(opened: tab)
            } else {
                workspace.bringForward(tab)
            }
        }
        settle(tab, in: session)
    }

    /// A tab new to the session's rows. Bringing one forward isn't opening it,
    /// and neither is a session's tabs coming back at launch (they never come
    /// through here).
    private func reportOpened(_ tab: SideTab, in region: TabRegion) {
        guard let kind = TabOpenedKind(tab) else { return }
        Telemetry.capture(.tabOpened(kind: kind, area: TabArea(region)))
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
        if region == .side, let pane = owner.activeSideTab?.pane, owner.inspectorPane != pane {
            owner.inspectorPane = pane
        }
        onStateChanged?()
        guard owner === session else { return }
        mirror(owner, animated: false)
        resolveCurrent()
        // Only what can hold the keyboard: a terminal, or a browser's page.
        guard tab.terminalID != nil || tab.browserID != nil else { return }
        // Keep the keyboard in the row the tab was closed from if a terminal
        // took its place there; otherwise hand it back.
        if region == .side, isVisible, activeTab?.terminalID != nil {
            terminalFocusRequest += 1
        } else if region == .main, activeMainTab?.terminalID != nil {
            mainFocusRequest += 1
        } else if region == .bottom, bottomVisible, activeBottomTab?.terminalID != nil {
            bottomFocusRequest += 1
        } else if region == .main || (region == .side && isVisible) || (region == .bottom && bottomVisible) {
            // The row is still there: you're still in it, so the next ⌘W
            // closes its next tab rather than, from the main area, the session.
            focusFront(of: region)
        } else {
            focus(.main)
        }
    }

    /// A close the user asked for: the × on a tab, ⌘W in a side terminal. A
    /// terminal still running a program asks first; everything else just goes.
    func requestClose(_ tab: SideTab) {
        guard tab != .session, let session else { return }
        if let id = tab.terminalID, session.sideSurfaces[id]?.needsConfirmClose == true,
           let confirmCloseTerminal {
            confirmCloseTerminal(1) { [weak self, weak session] in
                guard let self, let session else { return }
                self.close(tab, in: session)
            }
            return
        }
        close(tab)
    }

    /// Close every tab in `keep`'s row but it (and the session's own
    /// terminal), bringing `keep` forward. Terminals still running something
    /// are asked about once, all together, not one sheet each.
    func closeOthers(keeping keep: SideTab) {
        guard let session, let region = session.workspace.region(of: keep) else { return }
        change(session) { $0.bringForward(keep) }
        settle(keep, in: session)
        let others = tabs(in: region).filter { $0 != keep && $0 != .session }
        let running = others.filter { tab in
            tab.terminalID.flatMap { session.sideSurfaces[$0]?.needsConfirmClose } == true
        }
        for tab in others where !running.contains(tab) { close(tab) }
        guard !running.isEmpty else { return }
        let closeRunning = { [weak self, weak session] in
            guard let self, let session else { return }
            for tab in running { self.close(tab, in: session) }
        }
        if let confirmCloseTerminal { confirmCloseTerminal(running.count, closeRunning) } else { closeRunning() }
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
        if let pane = session.activeSideTab?.pane, session.inspectorPane != pane { session.inspectorPane = pane }
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
        if session.workspace.region(of: tab) == nil { reportOpened(tab, in: region) }
        switch session.workspace.region(of: tab) {
        case region?:
            change(session) { $0.bringForward(tab) }
        case _?:
            // Asked for here (⌥-click, a menu naming the row), not dragged:
            // it says nothing about where this kind of tab belongs.
            change(session) { $0.move(tab, to: region, at: .max, recordsHabit: false) }
        case nil:
            change(session) {
                $0.place(tab, in: region, at: .max)
                $0.bringForward(opened: tab)
            }
        }
        settle(tab, in: session)
    }

    /// A tab dragged in from outside the rows (a file out of a list) and dropped
    /// at `index` in `region`'s row: opened there, the way a dragged tab lands.
    /// One that's already open somewhere is moved there instead.
    func openDropped(_ tab: SideTab, in region: TabRegion, at index: Int) {
        guard let session else { return }
        guard session.workspace.region(of: tab) == nil else {
            move(tab, to: region, at: index)
            return
        }
        reportOpened(tab, in: region)
        change(session) {
            $0.place(tab, in: region, at: index)
            $0.bringForward(opened: tab)
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

    /// A new browser in `region`'s row, on `url` or on nothing yet (its
    /// address field takes the keyboard).
    func openBrowser(at url: URL?, in region: TabRegion) {
        guard let session else { return }
        let id = UUID()
        session.browserAddresses[id] = url?.absoluteString
        open(.browser(id), in: region)
    }

    /// Open a file's or a browser's tab where it belongs: where it is if it's
    /// open, else where you last moved one of its kind (the column until you
    /// have). `inMain`, for ⌥-click, puts it in the main area either way,
    /// without making that the habit.
    func openAtHome(_ tab: SideTab, inMain: Bool = false) {
        guard let session else { return }
        if inMain {
            open(tab, in: .main)
        } else if session.workspace.region(of: tab) != nil {
            open(tab)
        } else {
            open(tab, in: session.workspace.home(for: tab))
        }
    }

    /// Show what's at `url`: a browser already on that server comes forward
    /// wherever it is, otherwise a new one opens where browsers go (`inMain`:
    /// the main area, for ⌥-click).
    func showInBrowser(_ url: URL, inMain: Bool = false) {
        guard let session else { return }
        let tabs = session.mainTabs + session.sideTabs + session.bottomTabs
        let existing = tabs.first { tab in
            guard let id = tab.browserID,
                  let address = session.browserAddresses[id].flatMap(URL.init(string:)) else { return false }
            return address.host() == url.host() && address.port == url.port
        }
        if let existing {
            openAtHome(existing, inMain: inMain)
        } else {
            openBrowser(at: url, in: inMain ? .main : session.workspace.home(for: .browser(UUID())))
        }
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

    /// Give the keyboard to what's in front of `region`: a terminal, a
    /// browser's page, or the list of a pane. ⌘] / ⌘[.
    func focus(_ region: TabRegion) {
        lastRegion = region
        focusFront(of: region)
        onAreaFocused?(region)
    }

    /// The keyboard was sent to an area by a command (⌘] / ⌘[, ⌘⌥L): the
    /// window blinks its edge, so a move you didn't make with the pointer is
    /// seen (MainSplitViewController.blink).
    @ObservationIgnored var onAreaFocused: ((TabRegion) -> Void)?

    /// Give the keyboard to what's in front of `region` without making it the
    /// area you're in: for handing the keyboard back from a terminal that was
    /// just hidden, which is housekeeping, not you going somewhere.
    func focusFront(of region: TabRegion) {
        let tab: SideTab
        switch region {
        case .main:
            guard let front = activeMainTab else { onFocusMainTerminal?(); return }
            tab = front
            if tab.terminalID != nil { mainFocusRequest += 1; return }
        case .side:
            guard isVisible, let front = activeTab else { return }
            tab = front
            if tab.terminalID != nil { terminalFocusRequest += 1; return }
        case .bottom:
            guard bottomVisible, let front = activeBottomTab else { return }
            tab = front
            if tab.terminalID != nil { bottomFocusRequest += 1; return }
        }
        if let id = tab.browserID, let page = BrowserTabs.shared.existingPage(for: id) {
            // Nowhere yet, its address field; else the page.
            if page.location == nil { page.focusAddress() } else { page.focusPage() }
        } else if tab.browserID != nil {
            return
        } else if tab.pane != nil {
            requestListFocus(in: region)
        } else {
            // A file takes no keyboard; at least take it from the terminal
            // that had it, which may be the one this tab now hides.
            onClearKeyboard?()
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
            // A pane in front of the strip needs this session's repo: while
            // nothing showed one, a session switch left the last session's.
            resolveCurrent()
            focus(.bottom)
        } else {
            focus(.main)
        }
    }

    /// The strip's divider was dragged shut: record it like ⌘J would.
    func bottomCollapsedByDrag() {
        guard let session, session.bottomVisible else { return }
        session.bottomVisible = false
        mirror(session, animated: false)
        onStateChanged?()
        focus(.main)
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
        // Where a source-control or files pane is in front, else the column's.
        var region = [lastRegion, .main, .side, .bottom].first { activeTab(in: $0)?.pane != nil }
        if region == nil {
            open(.pane(pane))
            // Wherever it came forward: the main row or the strip, if that's
            // where it was.
            region = session?.workspace.region(of: .pane(pane)) ?? .side
        }
        lastRegion = region ?? .side
        requestListFocus(in: lastRegion)
        onAreaFocused?(lastRegion)
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
    private func setPane(_ requested: InspectorPane, inColumn: Bool = true) {
        UserDefaults.standard.set(requested.rawValue, forKey: Self.paneKey)
        if requested.isSourceControl {
            UserDefaults.standard.set(requested.rawValue, forKey: Self.lastGitPaneKey)
        }
        guard inColumn else { return }
        if pane != requested { pane = requested }
        guard let session, session.inspectorPane != requested else { return }
        session.inspectorPane = requested
        onStateChanged?()
    }

    /// Resolve the current cwd to a repo, if a repo view could be on screen.
    private func resolveCurrent() {
        // A directory already resolved puts its repo up now, in the same pass as
        // the switch, rather than leaving the last session's repo on screen
        // until `rev-parse` answers (a frame on a quiet machine, much longer on
        // a busy one). `resolve` still asks, and corrects it if the answer moved.
        if needsRepo, let cwd = currentCwd, let root = rootByCwd[cwd],
           let known = cache[root], repo !== known {
            repo = known
            resolvedNonRepo = false
        }
        updateActive()
        guard needsRepo else { return }
        let cwd = currentCwd
        Task { await resolve(cwd: cwd) }
    }

    /// Only the repo on screen scans when its work tree changes; every other
    /// cached model just notes that it's stale (see `GitRepoModel.setActive`).
    /// Hidden means none at all, which is what "no git work runs while hidden"
    /// on `focus` has to mean for the watchers too.
    /// Drop the models of checkouts that are gone from disk, a removed
    /// worktree most of all. Each holds a recursive watch and its caches for
    /// as long as the app runs, for a folder that no longer exists. Done when
    /// a new repo is opened, the moment the cache grows anyway.
    private func pruneRemovedCheckouts() {
        for (root, model) in cache
        where model !== repo && !FileManager.default.fileExists(atPath: root) {
            cache[root] = nil
        }
    }

    private func updateActive() {
        let shown = needsRepo ? repo : nil
        for model in cache.values { model.setActive(model === shown) }
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
            updateActive()
            return
        }
        let found = await GitService.repoRoot(for: cwd)
        // Every `cd` adds one; a long day's worth is still small, but not
        // unbounded.
        if rootByCwd.count > 1000 { rootByCwd.removeAll() }
        rootByCwd[cwd] = found
        guard let root = found else {
            // The user may have switched away while we awaited.
            guard currentCwd == cwd else { return }
            // The checkout this session was pointed at is gone (a worktree
            // removed): back to the terminal's, rather than a panel reading
            // "not a git repository" with no way out of it.
            if let session, cwd == session.gitCheckout {
                session.gitCheckout = nil
                pinnedCheckout = nil
                onStateChanged?()
                currentCwd = session.cwd
                await resolve(cwd: session.cwd)
                return
            }
            repo = nil
            resolvedNonRepo = true
            updateActive()
            return
        }
        guard currentCwd == cwd else { return }

        if let existing = cache[root] {
            // Observed: assigning the same model would still wake every view.
            if repo !== existing { repo = existing }
            resolvedNonRepo = false
            updateActive()
            // The list it already has goes up at once; it's only re-read if the
            // tree moved while it was away, with the header's spinner saying so.
            await existing.refreshIfStale()
        } else {
            pruneRemovedCheckouts()
            let model = GitRepoModel(root: root, highlighter: DiffHighlighter.shared)
            model.onOpenPreview = { [weak self] url, diff, hasChanges in
                self?.onOpenPreview?(url, diff, hasChanges)
            }
            cache[root] = model
            repo = model
            resolvedNonRepo = false
            updateActive()
            await model.refresh()
        }
        if !checkoutsAreCurrent(for: root) { await loadCheckouts() }
    }
}
