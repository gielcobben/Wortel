import Foundation
import Observation

/// The focused session's tabs and splits, as the views and the keyboard see
/// them, and the repo its Changes, History and Files are pointed at (derived
/// from the session's cwd). Resolving a cwd to a work-tree root is async, so a
/// pane briefly shows nothing until it lands. Repo models are cached by root,
/// so switching between sessions in the same repo reuses state instead of
/// rebuilding it.
///
/// Everything beside the sidebar is one tree of splits (`WorkspaceTabs`), and
/// all of it is **per session**. This holds none of it as its own: `tabs`,
/// `mainTabs`, `bottomTabs`, `paneTabs`, the layout and the zoom mirror the
/// focused session's, re-read on every `focus` and after every change made
/// through `open` / `select` / `close` / `move` / `split`. `SessionStore`
/// persists them.
///
/// Changes, History and Files are tabs (`SideTab.pane`) like any other. They
/// open in the split beside your work (the side column's leaf), and are
/// closed, not hidden: a pane holds nothing a close loses. A split is on
/// screen while it holds a tab and leaves the tree with its last.
///
/// (The name is historical: this predates the Files pane, the tabs and the
/// splits. Renaming it would churn every call site for no behavioural gain.)
@Observable
@MainActor
final class GitPanelModel {
    /// Mirrors the focused session's `gitPanelVisible`, which now only says
    /// whether the side column's split has tabs (nothing hides it).
    /// Observable, so a view that reads it follows it.
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
    ///
    /// Never a split that has gone (a pane closed or another session's, the
    /// column or the strip out of the tree): then it is the main area. And
    /// never a leaf that a zoom is hiding, the column and the strip among
    /// them: then it is the leaf that is zoomed.
    ///
    /// The column and the strip used to be answered as they were, gone or
    /// not. Dragged out of their last tab to another window (`handOver`
    /// moves no keyboard), they stayed "the split you're in": ⌘W read them
    /// as the main row (`AppDelegate.focusedRegion`) and closed its tab,
    /// but `close` saw that you were not in the main row and gave the tab
    /// that came forward no keyboard.
    var lastRegion: TabRegion {
        get {
            let region = storedRegion
            if isGone(region) { return session?.zoomedRegion ?? .main }
            if let zoomed = session?.zoomedRegion, zoomed != region { return zoomed }
            return region
        }
        set {
            // Compared as the getter answers it, not as stored: a stored
            // split that has gone is the main row (or the zoom) to everyone
            // who reads this, and a move there is no move.
            let current = lastRegion
            if current != newValue {
                regionTrail.removeAll { $0 == newValue }
                // Where you were, for when the split you are going to
                // closes. Not when the stored split has gone (it closed
                // under you, or it was the last session's): it can't be
                // gone back to, and the main row it reads as is not where
                // you were. Pushed as the main row, it would bury the split
                // before it: after ⌘D three times, the second ⌘W would go
                // to the main row, not to the first ⌘D split.
                if !isGone(storedRegion) {
                    regionTrail.removeAll { $0 == current }
                    regionTrail.append(current)
                    if regionTrail.count > 12 { regionTrail.removeFirst() }
                }
            }
            storedRegion = newValue
            // Only when it moves: this is written on every key typed.
            if areaInFocus != newValue { areaInFocus = newValue }
        }
    }
    @ObservationIgnored private var storedRegion: TabRegion = .main

    /// Whether `region` is no longer a split of the session on screen: a
    /// pane closed (or another session's), the column or the strip out of
    /// the tree with their last tab. Read on every key typed, through
    /// `lastRegion`: a dictionary lookup, or a walk of a tree of a few leaves.
    private func isGone(_ region: TabRegion) -> Bool {
        switch region {
        case .main: return false
        case .pane(let id): return session?.paneTabs[id] == nil
        case .side, .bottom: return session?.splitLayout.contains(region.leaf) != true
        }
    }
    /// The splits you were in before this one, the latest last.
    @ObservationIgnored private var regionTrail: [TabRegion] = []

    /// Where the keyboard goes when `gone` closes under you: what is zoomed,
    /// else the split you were in before it that is still on screen, else
    /// the main row. It always went to the main row: ⌘D three times and ⌘W
    /// put you two splits away from where you had just been.
    private func regionBefore(_ gone: TabRegion) -> TabRegion {
        if let zoomedRegion, zoomedRegion != gone { return zoomedRegion }
        return regionTrail.last { $0 != gone && exists($0) && isShowing($0) } ?? .main
    }
    /// `storedRegion` again, as something a view can follow.
    private var areaInFocus: TabRegion = .main

    /// `lastRegion`, for a row to draw whether it is the one you're in: the
    /// same answer, read in a way that tells the row when it changes. The
    /// rows of a split main area draw the tab in front a little quieter
    /// while you're somewhere else, so it shows where ⌘T, ⌘W and ⌘D will act.
    var keyRegion: TabRegion {
        _ = areaInFocus
        _ = zoomedRegion
        _ = paneTabs
        return lastRegion
    }
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
    /// Mirrors how the focused session's area is divided: the tree, each
    /// pane's row and the one in front of it, and the leaf shown alone.
    private(set) var splitLayout = SplitLayout()
    private(set) var paneTabs: [UUID: WorkspaceTabs.PaneTabs] = [:]
    private(set) var zoomedRegion: TabRegion?
    /// The leaves of the tree that take no room (`WorkspaceTabs.hiddenLeaves`).
    /// What a view hands to `SplitLayout.frames` with the tree. Always empty
    /// now: until 2026-11-26 the column or the strip could be hidden with its
    /// tabs kept, and nothing makes a leaf hidden any more
    /// (`workspace-tabs.md`, "Nothing is hidden").
    private(set) var hiddenLeaves: Set<SplitLayout.Leaf> = []
    /// The leaves still at the share they were guessed at
    /// (`WorkspaceTabs.unsized`): each is to be given its size by the
    /// window the first time it is laid out (`resizeLeaf`).
    private(set) var unsizedLeaves: Set<SplitLayout.Leaf> = []
    /// Bumped, per pane, when a terminal in that pane's row should take the
    /// keyboard. Kept for panes that have gone and for other sessions': a
    /// count that started again from nothing would read as a request to
    /// whoever was still watching it.
    private(set) var paneFocusRequests: [UUID: Int] = [:]

    /// The request a terminal in front of `region` should answer: a number
    /// that goes up each time one there is to take the keyboard.
    func focusRequest(in region: TabRegion) -> Int {
        switch region {
        case .main: return mainFocusRequest
        case .side: return terminalFocusRequest
        case .bottom: return bottomFocusRequest
        case .pane(let id): return paneFocusRequests[id] ?? 0
        }
    }

    private func requestTerminalFocus(in region: TabRegion) {
        switch region {
        case .main: mainFocusRequest += 1
        case .side: terminalFocusRequest += 1
        case .bottom: bottomFocusRequest += 1
        case .pane(let id): paneFocusRequests[id, default: 0] += 1
        }
    }

    /// Whether `region`'s row is on screen: a leaf that is there, not
    /// hidden, and not behind a zoom on another one. The column and the
    /// strip are behind a zoom like any other leaf
    /// (`WorkspaceTabs.isShowing`, on the mirrored state).
    func isShowing(_ region: TabRegion) -> Bool {
        guard zoomedRegion == nil || zoomedRegion == region else { return false }
        switch region {
        case .main: return true
        case .side: return isVisible
        case .bottom: return bottomVisible
        case .pane(let id): return paneTabs[id] != nil
        }
    }

    /// Whether `region` is there at all: always, except for a pane that has
    /// been closed.
    private func exists(_ region: TabRegion) -> Bool {
        region.paneID.map { paneTabs[$0] != nil } ?? true
    }

    /// The tab in front of each pane that is on screen.
    private var shownPaneFronts: [SideTab] {
        paneTabs.compactMap { id, pane in isShowing(.pane(id)) ? pane.active ?? pane.tabs.first : nil }
    }

    /// Whether the Files pane is on screen, in any row: the one thing the
    /// file tree's upkeep is for.
    var showsFiles: Bool {
        (isShowing(.side) && activeTab == .pane(.files)) || (isShowing(.main) && activeMainTab == .pane(.files))
            || (isShowing(.bottom) && activeBottomTab == .pane(.files))
            || shownPaneFronts.contains(.pane(.files))
    }

    /// Whether a repo view could be on screen anywhere, which is when resolving
    /// and refreshing the repo is worth doing.
    private var needsRepo: Bool {
        isShowing(.side) || (isShowing(.main) && activeMainTab?.pane != nil)
            || (isShowing(.bottom) && activeBottomTab?.pane != nil)
            || shownPaneFronts.contains { $0.pane != nil }
    }

    /// Tabs closed in this session and not reopened yet, for the menu item.
    var canReopenClosedTab: Bool { !(session?.closedTabs.isEmpty ?? true) }
    /// Hand the keyboard back to the session's main terminal, for when the tab
    /// that had it closes. Set by AppDelegate.
    @ObservationIgnored var onFocusMainTerminal: (() -> Void)?
    /// Take the keyboard from whatever has it, for when what's in front can't
    /// hold it (a file). Set by AppDelegate.
    @ObservationIgnored var onClearKeyboard: (() -> Void)?
    /// A tab closed, for whoever holds something for it (a previewed file's
    /// document). Set by AppDelegate.
    @ObservationIgnored var onTabClosed: ((SideTab) -> Void)?
    /// A tab came to the front of a session's row, by any of the ways one
    /// does (all of them end in `settle`): a stop on Back and Forward's trail.
    /// Set by AppDelegate.
    @ObservationIgnored var onTabBroughtForward: ((SideTab, Session) -> Void)?
    /// The preview tab, in front, swapped for the next file in its place:
    /// not a new stop on Back and Forward's trail, only where you are now.
    @ObservationIgnored var onTabReplaced: ((SideTab, Session) -> Void)?
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
        /// Uncommitted changes there, once something asked: nil until a list
        /// that shows it opens, or the shown checkout comes clean
        /// (`readCheckoutCounts`).
        var changes: Int?
        /// Commits there that the shown checkout doesn't have.
        var ahead = 0
        /// The repository's main folder, not a linked worktree.
        var isPrimary = false
        var id: String { path }
    }

    /// Every checkout of the shown repository, when it has more than one:
    /// what the worktree chip offers to show instead.
    ///
    /// **The list is the manager's** (`worktreeListing`): one cached `git
    /// worktree list` per repository, read again when its `.git/worktrees`
    /// changes, so switching between sessions of one repository reads nothing.
    /// **What's in each is read only when asked** (`readCheckoutCounts`): a
    /// list opening. Not a watch per worktree, not a timer. On a large monorepo,
    /// where `git status` takes seven seconds, the panel used to keep a
    /// recursive watch on every other worktree and a scan going behind each
    /// write an agent made in one, for as long as it was up.
    private(set) var checkouts: [Checkout] = []
    /// The root of the session's own checkout (`homeFolder`'s).
    private(set) var terminalCheckout: String?
    /// Mirrors the focused session's `gitCheckout`: nil follows the session's
    /// own folder (`homeFolder`).
    private(set) var pinnedCheckout: String?

    /// Set by AppDelegate: the manager's cached worktree listing of the
    /// repository whose home (`GitWorktree.repositoryHome`) is the argument,
    /// nil when it has none yet (no sidebar folder stands for it).
    @ObservationIgnored var worktreeListing: ((String) -> [GitWorktree]?)?
    /// Set by AppDelegate: the name of the session in the checkout at a path,
    /// live, else archived. See `CheckoutPlace`.
    @ObservationIgnored var placeName: ((String) -> String?)?

    /// "3 changes, 12 commits ahead", "clean": what a checkout has in it. nil
    /// while that hasn't been read.
    static func summary(of checkout: Checkout) -> String? {
        var parts: [String] = []
        if let changes = checkout.changes, changes > 0 {
            parts.append("\(changes) change\(changes == 1 ? "" : "s")")
        }
        if checkout.ahead > 0 {
            parts.append("\(checkout.ahead) commit\(checkout.ahead == 1 ? "" : "s") ahead")
        }
        guard parts.isEmpty else { return parts.joined(separator: ", ") }
        return checkout.changes == nil ? nil : "clean"
    }

    /// What to call the checkout at `path`: the session in it, else its
    /// branch, else its folder (`CheckoutPlace`). Read while a view draws, so
    /// a session's rename shows at once.
    func placeTitle(of path: String, branch: String?, isPrimary: Bool = false) -> String {
        CheckoutPlace.title(path: path, sessionName: placeName?(path), branch: branch, isPrimary: isPrimary)
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
        currentCwd = pinned ?? shownFolder(of: session)
        resolveCurrent()
    }

    /// The session's own folder: where it was started (`originCwd`), so
    /// its worktree for a worktree session (New Worktree Session, Fork, Open
    /// Branch all start one there), else its repository.
    static func homeFolder(of session: Session) -> String? {
        session.originCwd ?? session.cwd
    }

    /// The folder the panes follow when none is picked: the session's own
    /// (`homeFolder`) while the shell is anywhere in the same repository.
    /// An agent or a `cd` into another worktree of it is that worktree's
    /// work, usually gone again when the agent is done, and following it is
    /// how the panel ended up somewhere you couldn't place. A `cd` into a
    /// different repository is a different project, and staying behind
    /// there would put a commit in the one you left: the shell's folder
    /// then. So is a home known not to be in a repository at all (started in
    /// `~`), without asking `rev-parse` about `~` again at every prompt. A
    /// shell outside any repository keeps the session's own.
    private func shownFolder(of session: Session) -> String? {
        let home = Self.homeFolder(of: session)
        guard let home, let shell = session.cwd, shell != home else { return home }
        if nonRepoCwds.contains(home) { return shell }
        if let there = GitWorktree.commonDir(containing: shell),
           there != GitWorktree.commonDir(containing: home) { return shell }
        return home
    }

    /// The repository home of each root shown, read off the disk once.
    @ObservationIgnored private var homeByRoot: [String: String] = [:]
    /// Listings read here, for a repository the manager doesn't list.
    @ObservationIgnored private var ownListings: [String: [GitWorktree]] = [:]
    @ObservationIgnored private var ownListingsReading: Set<String> = []
    /// Whether a change to the manager's listings will rebuild `checkouts`.
    @ObservationIgnored private var tracksListings = false
    /// Each linked worktree's branch as its own files said when a list last
    /// opened (`GitWorktree.checkedOutBranch`): the listing is only re-read
    /// when worktrees come and go, and an agent may have switched one since.
    @ObservationIgnored private var branchOnDisk: [String: String] = [:]

    /// What a read of another checkout found: all the lists need, not the
    /// file list.
    struct CheckoutScan: Equatable {
        let head: String?
        let changes: Int
        let at: Date
    }

    /// The last read of each other checkout, by path.
    @ObservationIgnored private var scans: [String: CheckoutScan] = [:]
    /// `rev-list --count` answers by commit pair, which never go stale.
    @ObservationIgnored private var aheadCounts: [String: Int] = [:]
    @ObservationIgnored private var countsGeneration = 0
    /// A read that landed this recently stands: the branch list and the
    /// worktree list opened one after the other are one question.
    private static let scanFreshness: TimeInterval = 10

    private func home(of root: String) -> String? {
        if let known = homeByRoot[root] { return known }
        guard let found = GitWorktree.repositoryHome(containing: root) else { return nil }
        if homeByRoot.count > 200 { homeByRoot.removeAll() }
        homeByRoot[root] = found
        return found
    }

    /// The worktrees of the repository at `home`: the manager's listing, else
    /// one read of our own. Watches the manager's for a change, which
    /// rebuilds `checkouts` (a worktree made or removed while the panel is up).
    private func listing(for home: String) -> [GitWorktree]? {
        guard let worktreeListing else { return ownListing(for: home) }
        let managed: [GitWorktree]?
        if tracksListings {
            managed = worktreeListing(home)
        } else {
            tracksListings = true
            managed = withObservationTracking {
                worktreeListing(home)
            } onChange: { [weak self] in
                // Called as the value is about to change: rebuild after.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.tracksListings = false
                        self?.updateCheckouts()
                    }
                }
            }
        }
        return managed ?? ownListing(for: home)
    }

    /// A repository no sidebar folder stands for has no listing in the
    /// manager: read it here, once, and again only when a list opens.
    private func ownListing(for home: String, reread: Bool = false) -> [GitWorktree]? {
        if let known = ownListings[home], !reread { return known }
        if ownListingsReading.insert(home).inserted {
            Task { [weak self] in
                let listing = await GitService.worktrees(root: home)
                guard let self else { return }
                self.ownListingsReading.remove(home)
                if self.ownListings[home] != listing {
                    self.ownListings[home] = listing
                    self.updateCheckouts()
                }
            }
        }
        return ownListings[home]
    }

    /// Rebuild `checkouts` from the listing and what has been read. No git:
    /// what each holds comes from the last read of it (`scans`), or from a
    /// model the panel has open and current. `rereadBranches`, as a list
    /// opens: each linked worktree's branch from its own files.
    func updateCheckouts(rereadBranches: Bool = false) {
        guard let repo, let home = home(of: repo.root) else {
            if !checkouts.isEmpty { checkouts = [] }
            if terminalCheckout != repo?.root { terminalCheckout = repo?.root }
            return
        }
        let root = repo.root
        if rereadBranches, worktreeListing?(home) == nil { _ = ownListing(for: home, reread: true) }
        // A bare clone's own entry has no work tree to show, and a prunable
        // one's folder is gone.
        let worktrees = (listing(for: home) ?? []).filter { !$0.isBare && !$0.isPrunable }
        var found: [Checkout] = []
        if worktrees.count > 1 {
            for worktree in worktrees {
                let path = worktree.path
                var branch = worktree.branch
                if path == root {
                    branch = repo.status.branch ?? branch
                } else if !worktree.isPrimary {
                    if rereadBranches { branchOnDisk[path] = GitWorktree.checkedOutBranch(at: path) }
                    branch = branchOnDisk[path] ?? branch
                }
                var checkout = Checkout(path: path, branch: branch, isPrimary: worktree.isPrimary)
                if let scan = currentScan(of: path) {
                    checkout.changes = scan.changes
                    if let head = repo.status.head, let theirs = scan.head, theirs != head {
                        checkout.ahead = aheadCounts[head + ".." + theirs] ?? 0
                    }
                }
                found.append(checkout)
            }
        }
        if found != checkouts { checkouts = found }
        // Which checkout is the session's own: the root, unless the panes are
        // pinned elsewhere; then the folder they'd follow (`shownFolder`, else
        // the shell's for a session started outside a repository, as
        // `resolve` falls back), as resolved or off the disk.
        var terminal: String? = root
        if pinnedCheckout != nil, let session {
            terminal = [shownFolder(of: session), session.cwd].lazy.compactMap { $0 }.compactMap {
                self.rootByCwd[$0]
                    ?? GitWorktree.linked(containing: $0)?.root
                    ?? GitWorktree.repositoryHome(containing: $0)
            }.first
        }
        if terminal != terminalCheckout { terminalCheckout = terminal }
    }

    /// What's known of the checkout at `path`: the shown model's own status,
    /// or another model the panel has open whose watch says it's current, or
    /// the last read of it.
    private func currentScan(of path: String) -> CheckoutScan? {
        if let model = cache[path], !model.isStale {
            return CheckoutScan(head: model.status.head, changes: model.status.changes.count, at: Date())
        }
        return scans[path]
    }

    /// Read what's in each other checkout of the shown repository. Only on
    /// demand: a list that shows it opening (it opens at once, and the counts
    /// fill in). One `git status` each, the
    /// cheap kind, queued app-wide one at a time; a read less than a few
    /// seconds old stands. Stops when a newer read supersedes it, or when
    /// whoever asked has gone (the popover closed).
    func readCheckoutCounts() async {
        guard let repo else { return }
        updateCheckouts(rereadBranches: true)
        countsGeneration += 1
        let generation = countsGeneration
        let root = repo.root
        for checkout in checkouts where checkout.path != root {
            guard generation == countsGeneration, !Task.isCancelled else { return }
            let path = checkout.path
            if cache[path].map({ !$0.isStale }) != true {
                if let last = scans[path], Date().timeIntervalSince(last.at) < Self.scanFreshness {
                    // Read a moment ago: stands.
                } else {
                    let status = await GitService.backgroundStatus(root: path, light: true)
                    scans[path] = CheckoutScan(head: status.head, changes: status.changes.count, at: Date())
                }
            }
            if let head = self.repo?.status.head, let theirs = currentScan(of: path)?.head, theirs != head {
                let key = head + ".." + theirs
                if aheadCounts[key] == nil {
                    // Two commits' distance never changes: asked once.
                    aheadCounts[key] = await GitService.commitsAhead(from: head, to: theirs, root: root)
                }
            }
            // Row by row, so a slow repository fills the list as it goes.
            updateCheckouts()
        }
        if aheadCounts.count > 500 { aheadCounts.removeAll() }
        if scans.count > 200 { scans = scans.filter { path, _ in checkouts.contains { $0.path == path } } }
    }

    /// Set by AppDelegate: what is using a folder (open sessions, processes
    /// standing in it, archived sessions waiting in it), which only the app
    /// can tell and git can't.
    @ObservationIgnored var worktreeUsage: (() -> WorktreeUsage?)?

    /// "Bring Here": take `branch` off the other folder it's checked out in
    /// and switch the shown folder to it. Git lets a branch be in one folder
    /// at a time, and doing this by hand meant finishing up there, removing
    /// the worktree and coming back. Returns why not, or nil when it worked.
    ///
    /// Only when nothing there can be lost or pulled from under someone: no
    /// uncommitted or untracked files, no session open in it or archived in
    /// it (restoring one would find its branch gone), nothing running in it,
    /// its folder still there, and not the repository's main folder (taking
    /// `main` from your own clone is not a side effect anyone expects). The
    /// same inspection Clean Up Worktrees makes, then:
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
        // Where it is, by the session in it when there is one: the folder of a
        // worktree is named for a branch it may no longer have.
        let place = placeName?(path).map { "\u{201C}\($0)\u{201D}" } ?? folder
        let name = "\u{201C}\(branch.name)\u{201D}"
        if report.isPrimaryCheckout {
            return "\(name) is checked out in the repository's main folder, \(folder). Switch it there, or show that folder here."
        }
        if report.isMissing {
            // Git still has the branch there, and an archived session may be
            // waiting to make the folder again from it.
            let reasons = users.map { "In use by \($0)." }
            return (["\(name) stays with \(place): its folder is gone, but git still has the branch checked out there."]
                + reasons).joined(separator: " ")
        }
        if report.isOrphanedFolder || !report.changedFiles.isEmpty || !report.usedBy.isEmpty {
            var reasons = report.blockers
            if !report.changedFiles.isEmpty { reasons.append("Commit them there first.") }
            return "\(name) stays in \(place). " + reasons.joined(separator: " ")
        }
        if GitWorktree.Ownership.isOwned(root: path) {
            if let error = await WorktreeCleanup.remove(path: path, usedBy: users, deleteBranch: false) {
                return error
            }
        } else {
            let detached = await GitService.run(["switch", "--detach"], in: path)
            if !detached.ok {
                return "\(name) stays in \(place). " + GitMessage.readable(detached.stderr)
            }
            // Left on a commit with no branch: a trace now, which Clean Up
            // Worktrees offers to remove (WorktreeCleanup.broughtHere).
            WorktreeCleanup.rememberBroughtHere(path)
        }
        await repo.checkout(branch)
        // What's in that folder just changed. A removed worktree leaves the
        // manager's listing by its own watch; a detached one has no branch.
        scans[path] = nil
        branchOnDisk[path] = nil
        updateCheckouts(rereadBranches: true)
        return repo.checkoutError
    }

    /// Whether closing the focused session puts away the checkout on screen:
    /// it lives there (it was opened there, so closing archives it with that
    /// worktree), and the panes aren't pinned to another. Asked by the
    /// merged pane, to say whether its Close Session also closes the worktree.
    var closingPutsAwayShownCheckout: Bool {
        guard pinnedCheckout == nil, let session, let root = repo?.root else { return false }
        let home = session.homeCheckout
            ?? Self.homeFolder(of: session).flatMap(GitWorktree.linked(containing:))
        return home?.root == root
    }

    /// The pinned checkout's folder is gone (a worktree removed while you
    /// looked at it): show the session's own again, rather than a pane that
    /// reads "detached, no changes" for a missing path.
    private func checkoutVanished(_ model: GitRepoModel) {
        let root = model.root
        if model !== repo { cache[root] = nil }
        scans[root] = nil
        guard let session, let pinned = session.gitCheckout,
              pinned == root || !FileManager.default.fileExists(atPath: pinned) else { return }
        session.gitCheckout = nil
        pinnedCheckout = nil
        onStateChanged?()
        currentCwd = shownFolder(of: session)
        resolveCurrent()
    }

    /// True once a cwd has been resolved and it turned out not to be a repo — so
    /// the panel can show "not a git repository" rather than a blank flash.
    private(set) var resolvedNonRepo = false

    /// Whether the pending `isVisible` change should slide the side split in
    /// or out. False when it's the *session* that changed rather than the user
    /// toggling: switching sessions is meant to be instant. Read by
    /// `MainAreaController.slides` when it applies the change, imperatively,
    /// off the back of `isVisible`'s own mutation, so it stays out of
    /// observation.
    @ObservationIgnored private(set) var animatesVisibilityChange = false

    /// The session the panel is pointed at. Weak — the manager owns sessions, and
    /// a closed one must not be kept alive by the panel. Readable so Back and
    /// Forward can tell whether the panel is on the session they step into yet.
    @ObservationIgnored private(set) weak var session: Session?
    /// Set by AppDelegate to persist a visibility or pane change: both are
    /// session state, so they belong in sessions.json rather than in this model.
    @ObservationIgnored var onStateChanged: (() -> Void)?
    /// Open a file in a preview window. Set by the app layer and handed to each
    /// repo model as it's created, so the Changes list and History can reach it.
    @ObservationIgnored var onOpenPreview: ((URL, PreviewDiffSource, Bool) -> Void)?
    /// Show a changed file in the preview tab, for a click, ↑/↓ or Space in
    /// the Changes list. Set by the app layer and handed to each repo model.
    @ObservationIgnored var onPeek: ((URL, PreviewDiffSource, PeekTrigger) -> Void)?

    @ObservationIgnored private var cache: [String: GitRepoModel] = [:]

    /// What this window last read of the status of the work tree at `root`,
    /// and whether that read is current: ⌘P's file list takes its untracked
    /// files and its changed ones from here when it can, rather than scan
    /// again. Nil when this window has no model for it.
    func knownStatus(ofRoot root: String) -> (status: GitStatus, isCurrent: Bool)? {
        let real = GitWorktree.realPath(root)
        guard let model = cache[root] ?? cache.first(where: { GitWorktree.realPath($0.key) == real })?.value
        else { return nil }
        return (model.status, !model.isStale)
    }
    /// Each directory's work-tree root, as `resolve` last found it.
    @ObservationIgnored private var rootByCwd: [String: String] = [:]
    /// The directories `resolve` last found in no repository.
    @ObservationIgnored private var nonRepoCwds: Set<String> = []
    @ObservationIgnored private var currentCwd: String?
    /// Coalesces bursts of command-finished refreshes into one status read.
    @ObservationIgnored private var refreshWorkItem: DispatchWorkItem?
    private static let refreshDebounce: TimeInterval = 0.15

    /// Point the model at the selected session: its tabs and splits are
    /// mirrored (`mirror`), its cwd decides which repo. Called on selection
    /// changes and whenever the selected session's cwd moves. No git work runs
    /// while no repo view is on screen (`needsRepo`).
    func focus(session: Session?) {
        let switched = session !== self.session
        self.session = session
        // Another session on screen: you are in its own terminal's row (or
        // what it has zoomed, which the getter answers), and the splits you
        // were in were the last session's. Kept, the trail sent ⌘W in a new
        // split to a split of this session you had never been in (the last
        // session's column pushed, its pane skipped), and the stored pane,
        // read as the main row, was what the next move pushed.
        if switched {
            regionTrail.removeAll()
            storedRegion = session?.workspace.region(of: .session) ?? .main
            if areaInFocus != storedRegion { areaInFocus = storedRegion }
        }
        // Pinned to a worktree that has since gone (removed while you were in
        // another session): the session's own checkout, not a stale pane.
        // Only a `stat`, and only while pinned.
        if let session, let pinned = session.gitCheckout, !FileManager.default.fileExists(atPath: pinned) {
            session.gitCheckout = nil
            onStateChanged?()
        }
        currentCwd = session.flatMap { $0.gitCheckout ?? shownFolder(of: $0) }
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
        let layout = session?.splitLayout ?? SplitLayout()
        if layout != splitLayout { splitLayout = layout }
        let panes = session?.paneTabs ?? [:]
        if panes != paneTabs { paneTabs = panes }
        let zoomed = session?.zoomedRegion
        if zoomed != zoomedRegion { zoomedRegion = zoomed }
        let hidden = session?.workspace.hiddenLeaves ?? []
        if hidden != hiddenLeaves { hiddenLeaves = hidden }
        let unsized = session?.unsizedLeaves ?? []
        if unsized != unsizedLeaves { unsizedLeaves = unsized }
    }

    /// Whether `activate(_:)` would close the pane rather than bring it up:
    /// what the menu calls it, Show or Hide, and what its button in the
    /// titlebar says, has to be what the key or the click then does.
    func activateHides(_ requested: InspectorPane) -> Bool {
        let tab = SideTab.pane(requested)
        guard let region = session?.workspace.region(of: tab) else { return false }
        // Behind a zoomed split it isn't on screen: the command shows it.
        if let zoomedRegion, zoomedRegion != region { return false }
        return isShowing(region) && activeTab(in: region) == tab
    }

    /// One rule, wherever the pane is: not open, it opens (in the split
    /// Changes and Files open in); open behind another tab or a zoom, it
    /// comes forward; on screen, it closes. A pane holds nothing a close
    /// loses.
    ///
    /// Until 2026-11-26 a pane in the main row was swapped for the terminal
    /// with its tab kept, and one in a split made by hand only ever came
    /// forward: three answers to one key, by where the pane happened to be.
    func activate(_ requested: InspectorPane, via origin: PanelOrigin = .toolbar) {
        let tab = SideTab.pane(requested)
        guard let region = session?.workspace.region(of: tab) else { return show(requested, via: origin) }
        if activateHides(requested) {
            putAway([tab], from: region)
        } else if region == .side {
            // Through `show`, which counts a pane put in front of someone.
            show(requested, via: origin)
        } else {
            bringForward(tab, in: region)
        }
    }

    /// Close panes of `region`'s row as a Show command pressed again does.
    /// If you were in that split: the keyboard stays in it when something is
    /// left there, and goes to the split you were in before it when it went
    /// with them. If you were somewhere else, it stays there.
    ///
    /// When the split goes, `close` has already sent the keyboard back (it
    /// does for any tab whose split goes while you are in it), so this only
    /// refocuses a split that is still there. It used to refocus after the
    /// split had gone as well: `close` had moved you to the split before,
    /// which rewrote `regionTrail`, so the second `regionBefore` picked the
    /// one before that. Escape on an empty tab in a split made beside a ⌘D
    /// split put you in the main row, not in the ⌘D split, and the window's
    /// edge blinked twice.
    ///
    /// The closes are told not to refocus a split that stays
    /// (`focusesSplit`): since ⌘W on a pane or an empty tab hands the
    /// keyboard on, each close here would have done it too, once per pane
    /// put away, before the `focus` below did it again.
    private func putAway(_ tabs: [SideTab], from region: TabRegion) {
        let wasThere = lastRegion == region
        for tab in tabs { close(tab, focusesSplit: false) }
        resolveCurrent()
        if wasThere, isShowing(region) { focus(region) }
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

    /// ⌥⌘B: Changes and Files, in the split they open in (the outer edge of
    /// the window's splits, the right unless it was moved).
    ///
    /// With none of the panes open there, or that split behind a zoom,
    /// Changes and Files are opened (or brought forward, which ends the
    /// zoom), the one you last used in front, and the keyboard goes to it.
    /// With any open there and on screen, they are closed (`putAway`): if
    /// you were in that split the keyboard goes to the split you were in
    /// before it, or stays in it when something is left. Changes, History
    /// and Files hold nothing a close loses, so putting them away needs no
    /// hidden state. Anything else in that split (a terminal, a file)
    /// stays, and the split with it.
    ///
    /// Until 2026-11-26 this hid and showed the side column with its tabs
    /// kept. With every split movable there is no side column to hide, and
    /// a second kind of "gone" for one split among many was the last thing
    /// that made it a place of its own. To have the whole window for the
    /// terminal for a moment, zoom it (⇧⌘↩).
    func toggle() {
        guard let session else { return }
        if toggleCloses { return putAway(session.sideTabs.filter { $0.pane != nil }, from: .side) }
        // Read first: opening a pane makes it the one last used.
        let last = session.inspectorPane ?? Self.defaultPane
        let front = SideTab.pane(last == .history ? .changes : last)
        // A pane that is open in another split is brought forward where it
        // is; the rest open here.
        for pane in [InspectorPane.changes, .files] where session.workspace.region(of: .pane(pane)) == nil {
            open(.pane(pane), in: .side)
        }
        open(front)
        focus(session.workspace.region(of: front) ?? .side)
    }

    /// Whether ⌥⌘B would put Changes and Files away rather than open them:
    /// what its menu item calls itself, so `toggle` decides by this too.
    ///
    /// Only while that split is on screen. Behind a zoom on another split
    /// (`isShowing` answers false then) the panes are out of sight, and ⌥⌘B
    /// takes the open path, which brings them forward and ends the zoom, as
    /// ⇧⌘C does (`activateHides`). It used to look only at whether the row
    /// held a pane: with the main row zoomed, ⌥⌘B closed Changes and Files
    /// you could not see.
    var toggleCloses: Bool { isShowing(.side) && tabs.contains { $0.pane != nil } }

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
    ///
    /// Every way a tab comes to the front ends here, and that is what makes
    /// it a stop on Back and Forward's trail (`onTabBroughtForward`). A new
    /// one has to as well, or Back will skip what it showed.
    ///
    /// `takesKeyboard` is false for a tab that came forward without you
    /// (`splitFromCommand`): the views and the file follow, and that is all.
    /// The keyboard, the area you're in and Back's trail are about where you
    /// are, and you haven't moved.
    private func settle(_ tab: SideTab, in session: Session, isStop: Bool = true,
                        takesKeyboard: Bool = true) {
        let region = session.workspace.region(of: tab)
        // `pane` is the column's; a pane picked in another row only counts
        // as the one you last chose.
        if let pane = tab.pane { setPane(pane, inColumn: region == .side) }
        mirror(session, animated: true, animatesClosing: false)
        onStateChanged?()
        resolveCurrent()
        guard takesKeyboard else { return }
        if let region {
            lastRegion = region
            if tab == .session { onFocusMainTerminal?() }
            else if tab.terminalID != nil { requestTerminalFocus(in: region) }
            // Its page takes the keyboard when it appears; until then the
            // terminal it now covers must not keep it.
            else if tab.isBlank { onClearKeyboard?() }
        }
        if isStop { onTabBroughtForward?(tab, session) } else { onTabReplaced?(tab, session) }
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
    /// last one in a split (the column and the strip among them) takes the
    /// split away, instantly. The tab goes on the session's reopen stack.
    /// Never the session's own terminal.
    ///
    /// `target` is for a tab closing in a session that isn't the focused one,
    /// which is what a side shell exiting in the background looks like.
    ///
    /// `focusesSplit` false is for a caller that gives the keyboard to the
    /// split itself when the split is still there (`putAway`, `fill`), so it
    /// is given once: a close that takes the split away still sends the
    /// keyboard back, which those callers count on.
    func close(_ tab: SideTab, in target: Session? = nil, focusesSplit: Bool = true) {
        // Where you are, as the keyboard commands mean it: a split a zoom is
        // hiding is not it (`lastRegion`).
        let wasIn = lastRegion
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
        // The keyboard moves only when you were in the split the tab closed
        // in. A tab whose shell exited in another split leaves it where it
        // is. A × clicked in another split does not count as one: the click
        // has already put you in that split (a mouse-down in an area makes
        // it the one you're in, `AppDelegate`'s monitor), so the keyboard
        // goes to what comes forward there, or back along the trail if the
        // split went. Only the branch for a made split used to ask: when the
        // column's or the strip's last terminal exited by itself, the
        // keyboard went to `regionBefore`, which never holds the split you
        // are in now, so it jumped out of the terminal you were typing in.
        guard wasIn == region else { return }
        if isShowing(region) {
            guard focusesSplit else { return }
            // Only what can hold the keyboard: a terminal, a browser's page,
            // an empty tab's page or a pane's list. A file never had it.
            // The empty tab and the pane used to be left out: ⌘W on either,
            // in a split that kept other tabs, left the keyboard with
            // nobody, while Escape on the same empty tab (`putAway`) gave
            // it to the tab that came forward.
            guard tab.terminalID != nil || tab.browserID != nil || tab.isBlank || tab.pane != nil
            else { return }
            // The row is still there: you're still in it, so the next ⌘W
            // closes its next tab rather than, from the main area, the session.
            // (A terminal that took the tab's place takes the keyboard.)
            focusFront(of: region)
        } else {
            // The split went with its last tab, whatever the tab was: the
            // place itself is gone, so the keyboard goes to the split you
            // were in before it (or to what is zoomed). `putAway` counts on
            // this, and does not refocus a split that went.
            focus(regionBefore(region))
        }
    }

    /// A tab gone to another session, dragged to another window's row: out
    /// of `owner`'s rows as a close takes it, but not closed. Its page or
    /// document goes on in the other session, so nothing is let go of
    /// (`onTabClosed`), and it isn't put on the reopen stack: ⇧⌘T here
    /// would make a second tab of the same page.
    func handOver(_ tab: SideTab, from owner: Session) {
        guard tab != .session, change(owner, { $0.detach(tab) }) != nil else { return }
        if let pane = owner.activeSideTab?.pane, owner.inspectorPane != pane { owner.inspectorPane = pane }
        onStateChanged?()
        guard owner === session else { return }
        mirror(owner, animated: false)
        resolveCurrent()
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
    /// `WorkspaceTabs.move`. It comes to the front of its new row, and a split
    /// it leaves empty goes. A terminal keeps its shell: moving is a new place for
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
        // A pane that has gone since whoever asked last looked: the main area.
        let region = session.workspace.exists(region) ? region : .main
        if session.workspace.region(of: tab) == nil { reportOpened(tab, in: region) }
        switch session.workspace.region(of: tab) {
        case region?:
            change(session) { $0.bringForward(tab) }
        case _?:
            // Asked for here (⌥-click, a menu naming the row): moved over.
            // (`recordsHabit` is no longer read: where a kind of tab opens
            // is `WorkspaceTabs.home(for:)`, the same every time.)
            change(session) { $0.move(tab, to: region, at: .max, recordsHabit: false) }
        case nil:
            change(session) {
                $0.place(tab, in: region, at: .max)
                $0.bringForward(opened: tab)
            }
        }
        settle(tab, in: session)
    }

    // MARK: - The empty tab

    /// Bumped when the keyboard is sent to a split whose front tab is an
    /// empty one: its page takes it (`NewTabPage`).
    private(set) var newTabFocusRequest = 0

    /// A row's "+": an empty tab at the end of `region`'s row, in front,
    /// whose page offers what it can become. One a row already has is
    /// brought forward instead: two of nothing is one too many.
    func openBlank(in region: TabRegion) {
        if let blank = tabs(in: region).first(where: \.isBlank) { return bringForward(blank, in: region) }
        open(.blank(UUID()), in: region)
    }

    /// What an empty tab's page offers.
    enum NewTabChoice {
        case terminal, browser
        case pane(InspectorPane)
    }

    /// The empty tab `blank` becomes `choice`, in its split: the new tab is
    /// opened there, in front, and the empty one goes. A pane that is open
    /// somewhere else is moved here, as by its row's menu before.
    func fill(_ blank: SideTab, with choice: NewTabChoice) {
        guard let session, let region = session.workspace.region(of: blank) else { return }
        // The split you're in, whichever you were in when you clicked.
        lastRegion = region
        switch choice {
        case .terminal: open(.terminal(UUID()), in: region)
        case .browser: openBrowser(at: nil, in: region)
        case .pane(let pane): open(.pane(pane), in: region)
        }
        // The keyboard is given below, once (`focusesSplit`).
        close(blank, focusesSplit: false)
        focusFront(of: region)
    }

    /// Escape on an empty tab's page: the tab goes, and the keyboard goes to
    /// what is in front of its row now, or to the split you were in before
    /// it if the split went with it (`putAway`). Without this it was left
    /// with nothing.
    func dismissBlank(_ blank: SideTab) {
        guard blank.isBlank, let region = session?.workspace.region(of: blank) else { return }
        lastRegion = region
        putAway([blank], from: region)
    }

    /// A tab dragged in from outside the rows (a file out of a list) and dropped
    /// at `index` in `region`'s row: opened there, the way a dragged tab lands.
    /// One that's already open somewhere is moved there instead.
    ///
    /// `isNew` is false for a tab that only changed windows (`handOver`): it
    /// was opened once already, where it came from.
    func openDropped(_ tab: SideTab, in region: TabRegion, at index: Int, isNew: Bool = true) {
        guard let session else { return }
        let region = session.workspace.exists(region) ? region : .main
        guard session.workspace.region(of: tab) == nil else {
            move(tab, to: region, at: index)
            return
        }
        if isNew { reportOpened(tab, in: region) }
        change(session) { $0.placeDropped(tab, in: region, at: index) }
        settle(tab, in: session)
    }

    /// Give an empty column something to show, when it's asked to open. The
    /// pane last chosen, unless that one is in the main area's row (opening it
    /// would only bring it forward there, and the column would stay shut): then
    /// the first pane that isn't, and a terminal when all of them are.
    private func fillEmptyColumn() {
        guard let session else { return }
        let panes = [Self.defaultPane] + InspectorPane.allCases
        if let pane = panes.first(where: { pane in
            !session.mainTabs.contains(.pane(pane))
                && !session.paneTabs.values.contains { $0.tabs.contains(.pane(pane)) }
        }) {
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
    /// open, else a file in the main row and a browser in the split beside
    /// your work (`WorkspaceTabs.home(for:)`), every time. `elsewhere`, for
    /// ⌥-click, puts it in the other place (out of the main area, else into
    /// it), just this once.
    func openAtHome(_ tab: SideTab, elsewhere: Bool = false) {
        guard let session else { return }
        if elsewhere {
            open(tab, in: session.workspace.elsewhere(for: tab))
        } else if session.workspace.region(of: tab) != nil {
            open(tab)
        } else {
            open(tab, in: session.workspace.home(for: tab))
        }
    }

    // MARK: - The preview tab

    /// Where a file looked at from the list in `list` (a pane tab) would show.
    private func peekRegion(for tab: SideTab, from list: SideTab, in session: Session) -> TabRegion {
        let workspace = session.workspace
        return workspace.peekRegion(for: tab, avoiding: workspace.region(of: list))
    }

    /// What the list in `list` does with `tab` for `trigger`
    /// (`WorkspaceTabs.peekAction`).
    func peekAction(for tab: SideTab, _ trigger: PeekTrigger, from list: SideTab) -> PeekAction {
        guard let session else { return .none }
        let workspace = session.workspace
        return workspace.peekAction(for: tab, trigger, avoiding: workspace.region(of: list))
    }

    /// The preview tab of this session, in front or not.
    var peekTab: SideTab? { session?.peekTab }

    /// Show a file looked at from the list in `list` in the preview tab
    /// (`WorkspaceTabs.showPeek`). The file it replaced is let go of as a
    /// closed one is.
    func showPeek(_ tab: SideTab, from list: SideTab) {
        guard let session else { return }
        let region = peekRegion(for: tab, from: list, in: session)
        let isNew = session.workspace.region(of: tab) == nil && session.workspace.peek == nil
        if isNew { reportOpened(tab, in: region) }
        let wasInFront = session.workspace.peek.map { peek in
            session.workspace.region(of: peek).map { session.workspace.front(of: $0) == peek } ?? false
        } ?? false
        let replaced = change(session) { $0.showPeek(tab, in: region) }
        if let replaced { onTabClosed?(replaced) }
        settle(tab, in: session, isStop: !(replaced != nil && wasInFront))
    }

    /// A file opened for good (a double-click, in a list or on its tab): if
    /// it is the preview tab, it stays.
    func keep(_ tab: SideTab) {
        guard let session, session.workspace.peek == tab else { return }
        change(session) { $0.keep(tab) }
    }

    /// Show what's at `url`: a browser already on that server, or on that
    /// file, comes forward wherever it is, otherwise a new one opens where
    /// browsers go (`elsewhere`: the other place, for ⌥-click).
    func showInBrowser(_ url: URL, elsewhere: Bool = false) {
        guard let session else { return }
        let existing = session.allTabs.first { tab in
            guard let id = tab.browserID,
                  let address = session.browserAddresses[id].flatMap(URL.init(string:)) else { return false }
            return BrowserAddress.showsSame(address, as: url)
        }
        if let existing {
            openAtHome(existing, elsewhere: elsewhere)
        } else {
            let tab = SideTab.browser(UUID())
            openBrowser(at: url, in: elsewhere ? session.workspace.elsewhere(for: tab)
                                               : session.workspace.home(for: tab))
        }
    }

    // MARK: - Panes of the main area

    /// The leaf you're in, for a command that doesn't say which: the row
    /// you last worked in, the column and the strip included, while it is
    /// in the tree and on screen. Else the main row.
    private var currentLeaf: TabRegion {
        let region = lastRegion
        return splitLayout.contains(region.leaf) && isShowing(region) ? region : .main
    }

    /// The leaf a split asked for beside `region` is made beside: `region`
    /// while it is in the tree and takes room, else the main row
    /// (`WorkspaceTabs.split`).
    private func splitTarget(_ region: TabRegion) -> TabRegion {
        exists(region) && splitLayout.contains(region.leaf) && !hiddenLeaves.contains(region.leaf)
            ? region : .main
    }

    /// Split a leaf: a new pane on `edge` of `region`, with `tab` in it and
    /// the keyboard, if the tab takes it. The pane, or nil when nothing was
    /// split (`WorkspaceTabs.split`).
    ///
    /// `region` nil is the leaf you're in, which from the column or the
    /// strip is that one: the split is made beside it, not beside the main
    /// row. `tab` nil is a new terminal; one
    /// that is already open is moved into the pane. `recordsHabit` is passed
    /// on and no longer read (`WorkspaceTabs.home(for:)`).
    @discardableResult
    func split(_ region: TabRegion? = nil, on edge: SplitLayout.Edge, with tab: SideTab? = nil,
               recordsHabit: Bool = false) -> TabRegion? {
        guard let session else { return nil }
        let target = region ?? currentLeaf
        // Asked of the window, which knows the sizes: halved when the split
        // is big enough to be two, room made by the whole row when it isn't
        // but the row is, and not at all (said out loud) when neither is. A
        // split that opens too small to use is worse than none.
        let room = roomToSplit?(splitTarget(target), edge) ?? .halves
        guard room != .none else { return nil }
        let tab = tab ?? .terminal(UUID())
        return split(target, on: edge, placing: tab, in: session, recordsHabit: recordsHabit,
                     reports: session.workspace.region(of: tab) == nil, spreads: room == .spreads)
    }

    /// How a split asked for by a key or a menu finds its room.
    enum SplitRoom {
        /// The split it is asked of is big enough to be two.
        case halves
        /// It isn't, but the row or column it is in can give the new one an
        /// equal share: ⌘D in a narrow side split.
        case spreads
        /// Neither: nothing is made.
        case none
    }

    /// The window's answer to where a new split's room comes from
    /// (`MainAreaController.room`). A drag is told where it can land before
    /// it lands, and never comes here.
    @ObservationIgnored var roomToSplit: ((TabRegion, SplitLayout.Edge) -> SplitRoom)?

    /// A tab let go on the edge of a part of the main area: a file dragged
    /// out of a list (`isNew`), or a tab dragged from a row. A pane there,
    /// holding it. Where its kind opens next time does not change: that is
    /// `WorkspaceTabs.home(for:)`, the same every time.
    ///
    /// `isNew` is false for a tab that only changed windows (`handOver`): it
    /// was opened once already, where it came from.
    func splitDropped(_ tab: SideTab, beside region: TabRegion, on edge: SplitLayout.Edge, isNew: Bool) {
        guard let session else { return }
        split(region, on: edge, placing: tab, in: session, recordsHabit: true,
              reports: isNew && session.workspace.region(of: tab) == nil, spreads: false)
    }

    @discardableResult
    private func split(_ region: TabRegion, on edge: SplitLayout.Edge, placing tab: SideTab,
                       in session: Session, recordsHabit: Bool, reports: Bool, spreads: Bool) -> TabRegion? {
        guard let pane = change(session, {
            $0.split(region, on: edge, placing: tab, recordsHabit: recordsHabit, spreads: spreads)
        }) else { return nil }
        if reports { reportOpened(tab, in: pane) }
        // The tab may have left the column, as in `move`.
        if let pane = session.activeSideTab?.pane, session.inspectorPane != pane { session.inspectorPane = pane }
        settle(tab, in: session)
        return pane
    }

    /// A split a command asked for (`wortel split`), not you: a new pane on
    /// `edge` of `owner`'s main row, holding `tab`, and nothing else moves.
    /// The keyboard stays where it is, the area you're in stays the one you're
    /// in, it is no stop on Back's trail, and a zoom is left alone, with the
    /// pane behind it. An agent runs this while someone is typing to it.
    ///
    /// `owner` need not be the session on screen: then its rows change and
    /// are saved, as in `close(_:in:)`, and the pane is there when it is next
    /// selected. The pane, or nil when nothing was split.
    @discardableResult
    func splitFromCommand(on edge: SplitLayout.Edge, placing tab: SideTab, in owner: Session) -> TabRegion? {
        let isNew = owner.workspace.region(of: tab) == nil
        guard let pane = change(owner, {
            $0.split(.main, on: edge, placing: tab, recordsHabit: false, keepsZoom: true)
        }) else { return nil }
        if isNew { reportOpened(tab, in: pane) }
        // The tab may have left the column, as in `move`.
        if let pane = owner.activeSideTab?.pane, owner.inspectorPane != pane { owner.inspectorPane = pane }
        guard owner === session else {
            onStateChanged?()
            return pane
        }
        settle(tab, in: owner, takesKeyboard: false)
        return pane
    }

    /// Show one part of the main area alone, or all of them again
    /// (`WorkspaceTabs.toggleZoom`). `region` nil is the part you're in.
    /// Nothing is saved: a zoom is about now.
    func toggleZoom(_ region: TabRegion? = nil) {
        guard let session else { return }
        let target = region ?? currentLeaf
        let before = session.zoomedRegion
        // Read while the zoom is still on: it answers with the zoomed part
        // then, whatever a click on the titlebar or the sidebar last wrote.
        let here = lastRegion
        change(session) { $0.toggleZoom(target) }
        guard session.zoomedRegion != before else { return }
        mirror(session, animated: false)
        // A pane that was showing a repo may be out of sight now, or back.
        resolveCurrent()
        // Zoomed in, that is where you are. Zoomed out, you stay where you were.
        lastRegion = session.zoomedRegion != nil ? target : here
        focusFront(of: lastRegion)
    }

    /// View ▸ Reset Layout: the session's tabs back in the arrangement a
    /// session starts in (`WorkspaceTabs.Preset.standard`), for when the
    /// splits have got away from you. Nothing is closed. The tab you were
    /// looking at stays in front, and the keyboard goes with it.
    func resetLayout() {
        guard let session else { return }
        let front = activeTab(in: lastRegion)
        let arranged = session.workspace.arranged(as: .standard, keeping: front)
        change(session) { $0 = arranged }
        mirror(session, animated: false)
        onStateChanged?()
        resolveCurrent()
        lastRegion = front.flatMap { session.workspace.region(of: $0) } ?? .main
        focusFront(of: lastRegion)
    }

    /// Every part of the main area the same size as its siblings.
    func equalizeSplits() {
        guard let session, !session.splitLayout.isEqualized else { return }
        change(session) { $0.equalize() }
        mirror(session, animated: false)
        onStateChanged?()
    }

    /// The layout as a divider's drag left it, from the view that moved it
    /// (`SplitTreeView` moves the divider in its own copy first, so the pane
    /// follows the pointer in the same event). Not saved: see
    /// `commitSplitLayout`.
    func setSplitLayout(_ layout: SplitLayout) {
        guard let session, session.splitLayout != layout,
              Set(layout.leaves) == Set(session.splitLayout.leaves) else { return }
        session.splitLayout = layout
        if splitLayout != layout { splitLayout = layout }
    }

    /// The end of a divider's drag: the layout as it now is, saved.
    func commitSplitLayout() {
        onStateChanged?()
    }

    /// Give `leaf` the size it was meant to open at: `extent` points along
    /// the split it is a part of, as the tree is laid out in `bounds`
    /// (`SplitLayout.resize`, with what is hidden now). Its share is no
    /// guess after that, whether or not anything had to move.
    ///
    /// Called from a layout pass, so nothing is saved here: the size is
    /// saved with the next change that is (`commitSplitLayout`).
    func resizeLeaf(_ leaf: SplitLayout.Leaf, to extent: CGFloat, in bounds: CGRect,
                    metrics: SplitLayout.Metrics) {
        guard let session else { return }
        change(session) { workspace in
            workspace.layout.resize(leaf, to: extent, in: bounds, metrics: metrics,
                                    hidden: workspace.hiddenLeaves)
            workspace.markSized(leaf)
        }
        mirror(session, animated: false)
    }

    /// `leaf` has the size it is going to have: it is no longer waiting for
    /// the window to give it one (`WorkspaceTabs.markSized`). Not saved.
    func markLeafSized(_ leaf: SplitLayout.Leaf) {
        guard let session, session.unsizedLeaves.contains(leaf) else { return }
        change(session) { $0.markSized(leaf) }
        mirror(session, animated: false)
    }

    // MARK: - Rows by region (for the keyboard)

    /// A row's tabs in order.
    func tabs(in region: TabRegion) -> [SideTab] {
        switch region {
        case .main: return mainTabs
        case .side: return tabs
        case .bottom: return bottomTabs
        case .pane(let id): return paneTabs[id]?.tabs ?? []
        }
    }

    /// The tab in front of a row that's showing.
    func activeTab(in region: TabRegion) -> SideTab? {
        switch region {
        case .main: return isShowing(.main) ? activeMainTab ?? .session : nil
        case .side: return isShowing(.side) ? activeTab : nil
        case .bottom: return isShowing(.bottom) ? activeBottomTab : nil
        case .pane(let id):
            return isShowing(region) ? paneTabs[id].flatMap { $0.active ?? $0.tabs.first } : nil
        }
    }

    /// Bring a tab of `region`'s row forward.
    func bringForward(_ tab: SideTab, in region: TabRegion) {
        switch region {
        case .main: selectMain(tab)
        case .side: select(tab)
        case .bottom: selectBottom(tab)
        case .pane:
            guard let session, session.workspace.tabs(in: region).contains(tab) else { return }
            change(session) { $0.bringForward(tab) }
            settle(tab, in: session)
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
        // A pane that has gone: `lastRegion` answers with where you are then.
        lastRegion = region
        let region = lastRegion
        focusFront(of: region)
        onAreaFocused?(region)
    }

    /// The keyboard was sent to an area by a command (⌘] / ⌘[, ⌘⌥L): the
    /// window blinks its edge, so a move you didn't make with the pointer is
    /// seen (MainSplitViewController.blink).
    @ObservationIgnored var onAreaFocused: ((TabRegion) -> Void)?

    /// A terminal in `region` that had the keyboard went out of sight: a tab
    /// came in front of it in its row (a file, Changes, another terminal),
    /// or the row itself went behind a zoom. The keyboard goes to what is in
    /// front of that row now, so you are still in the split you were in and
    /// ⌘W closes the tab there. A row that is out of sight hands it to the
    /// split you are in (`lastRegion`, which never answers with one that a
    /// zoom hides or that has gone).
    ///
    /// Every row's terminal host handed it to the main row until 2026-11-27:
    /// a file tab picked in a split whose terminal had the keyboard put you
    /// in the session's own terminal, and the next ⌘W closed the session.
    func handBackKeyboard(from region: TabRegion) {
        focusFront(of: isShowing(region) ? region : lastRegion)
    }

    /// Give the keyboard to what's in front of `region` without making it the
    /// area you're in: for handing the keyboard back to the row you are
    /// already in after a tab there closed or a zoom changed, which is
    /// housekeeping, not you going somewhere.
    func focusFront(of region: TabRegion) {
        let tab: SideTab
        switch region {
        case .main:
            // Behind a zoom on another split, as the other rows: the main
            // row's terminal or page would take keys nobody can see, and the
            // keyboard in the session's own terminal makes ⌘W close the
            // session.
            guard isShowing(.main) else { return }
            guard let front = activeMainTab else { onFocusMainTerminal?(); return }
            tab = front
            if tab.terminalID != nil { mainFocusRequest += 1; return }
        case .side:
            guard isShowing(.side), let front = activeTab else { return }
            tab = front
            if tab.terminalID != nil { terminalFocusRequest += 1; return }
        case .bottom:
            guard isShowing(.bottom), let front = activeBottomTab else { return }
            tab = front
            if tab.terminalID != nil { bottomFocusRequest += 1; return }
        case .pane:
            guard let front = activeTab(in: region) else { return }
            tab = front
            if tab.terminalID != nil { requestTerminalFocus(in: region); return }
        }
        if tab.isBlank {
            // Off the terminal that had it, then to the empty tab's page.
            onClearKeyboard?()
            newTabFocusRequest += 1
            return
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

    /// ⌘J: the terminal under the main row. With no strip, one is made
    /// with a terminal in it. With one, the keyboard goes to it, and from
    /// it back to the main row. Nothing is hidden: until 2026-11-26 this
    /// tucked the strip away with its tabs kept, and a key that puts a
    /// running shell out of sight was the strip's one difference from any
    /// other split. Zoom the terminal (⇧⌘↩) to have the window for it.
    func toggleBottom() {
        guard let session else { return }
        guard let front = session.activeBottomTab ?? session.bottomTabs.first else {
            openBottomTerminal()
            return
        }
        // There and showing: back to the main row.
        if lastRegion == .bottom, isShowing(.bottom) {
            focus(.main)
            return
        }
        // Brought forward first, which ends a zoom that was hiding it.
        selectBottom(front)
        resolveCurrent()
        focus(.bottom)
    }

    func openBottomTerminal() {
        open(.terminal(UUID()), in: .bottom)
    }

    func selectBottom(_ tab: SideTab) {
        guard let session, session.bottomTabs.contains(tab) else { return }
        change(session) { $0.bringForward(tab) }
        settle(tab, in: session)
    }

    /// Show the panel if needed and ask the changes list to take keyboard focus.
    func requestListFocus() {
        // Where a source-control or files pane is in front, else the column's.
        let panes = splitLayout.leaves.map(TabRegion.init).filter { $0.paneID != nil }
        var region = ([lastRegion, .main, .side, .bottom] + panes).first { activeTab(in: $0)?.pane != nil }
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

    /// The user chose a pane: recorded on the session it was done to, so the
    /// session and the panel can't drift apart. It also updates the two app-wide defaults: the pane a session
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
            // Its checkouts with it: the same repository's are already known.
            updateCheckouts()
        }
        updateActive()
        guard needsRepo else { return }
        let cwd = currentCwd
        Task { await resolve(cwd: cwd) }
    }

    /// Ask again where the folder on screen is. For the one answer that can
    /// change with nothing about the session changing: git arrived
    /// (`DeveloperTools`), and "no repository" was only ever "no git".
    func resolveAgain() {
        guard repo == nil else { return }
        nonRepoCwds.removeAll()
        resolveCurrent()
    }

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

    /// Only the repo on screen scans when its work tree changes; every other
    /// cached model just notes that it's stale (see `GitRepoModel.setActive`).
    /// With no repo view on screen, none at all, which is what "no git work
    /// runs while no repo view is on screen" on `focus` has to mean for the
    /// watchers too.
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
        if rootByCwd.count + nonRepoCwds.count > 1000 { rootByCwd.removeAll(); nonRepoCwds.removeAll() }
        rootByCwd[cwd] = found
        if found == nil { nonRepoCwds.insert(cwd) } else { nonRepoCwds.remove(cwd) }
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
                currentCwd = shownFolder(of: session)
                await resolve(cwd: currentCwd)
                return
            }
            // Started outside any repository: the shell's folder, if that's
            // in one (`homeFolder`).
            if let session, cwd == Self.homeFolder(of: session), let shell = session.cwd, shell != cwd {
                currentCwd = shell
                await resolve(cwd: shell)
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
            model.onPeek = { [weak self] url, diff, trigger in
                self?.onPeek?(url, diff, trigger)
            }
            model.onRootVanished = { [weak self, weak model] in
                guard let self, let model else { return }
                self.checkoutVanished(model)
            }
            cache[root] = model
            repo = model
            resolvedNonRepo = false
            updateActive()
            await model.refresh()
        }
        // From the manager's listing and what's been read: no git.
        updateCheckouts()
    }
}
