import AppKit
import Observation

/// Owns the session list, selection, and persistence. `@Observable` so the
/// SwiftUI shell (NavigationSplitView) reflects changes automatically — no
/// delegate. Main thread only.
@Observable
@MainActor
final class SessionManager {
    @ObservationIgnored private let runtime: GhosttyRuntime
    @ObservationIgnored private let store = SessionStore()

    private(set) var sessions: [Session] = []

    /// Bound to the sidebar List's selection. `didSet` lazily creates the
    /// selected session's surface and clears its bell — so both user clicks
    /// and programmatic selection (menu shortcuts) go through one path.
    var selectedID: Session.ID? {
        didSet {
            noteShowing()
            // The lead moved from somewhere that isn't a ⌘-click inside the
            // selection (a plain click, ⌘2, a notification): one row again.
            if selectedID != oldValue, !(selectedID.map(sidebarSelection.ids.contains) ?? false) {
                var collapsed = sidebarSelection
                collapsed.collapse(to: selectedID)
                if collapsed != sidebarSelection { sidebarSelection = collapsed }
            }
            guard selectedID != oldValue, let session = selected else { return }
            // The selected row is always drawn: ⌘-number, a notification or
            // Next Waiting Session can pick a session inside a folded section.
            reveal(session)
            // Where you were in the session you left, read before anything
            // else moves; a session that just closed is gone from `sessions`
            // and is nowhere to go back to.
            noteVisit(from: sessions.first { $0.id == oldValue }.map(currentPlace(of:)))
            // The tab you land on, held from now: the first tab brought forward
            // here is a stop away from it, and by the time the panel reports
            // that one the rows already show the new tab.
            if currentTabs[session.id] == nil {
                currentTabs[session.id] = session.workspace.front(of: .main) ?? .session
            }
            // Gone to another session: the one just made is one among the
            // rest now, and closing it later is not a way back.
            if justMade?.session != session.id { justMade = nil }
            // Most recent first, for ⌘P's list.
            recentSessionIDs.removeAll { $0 == session.id }
            recentSessionIDs.insert(session.id, at: 0)
            // Switching into a waiting session: flash a ring in the detail view
            // to orient the eye before the dot clears.
            if let kind = session.attention {
                attentionFlash = AttentionFlash(kind: kind)
            }
            clearAttention(session)
            // Coming back to a session marked unread: that's the "later" it was
            // marked for, so it clears the usual way from here.
            session.markedUnread = false
            // A reminder that went off for it has been answered the same way.
            answerReminder(session)
            // Left the previous session before it could count as read; start the
            // caught-up clock on the one you just landed on.
            cancelCaughtUp(oldValue)
            scheduleCaughtUp(session)
            // Not while its worktree is still being made: there's no folder
            // for the shell to start in yet (see `prepareWorktree`).
            if session.preparation == nil { session.ensureSurfaceView(runtime: runtime) }
            scheduleSave()
            onSwitch?(session)
            noteSelectionForSleep(left: oldValue, arrived: session)
        }
    }

    /// Run at the end of every change of the selected session, in the same
    /// turn: the window lays the whole switch out at once (`MainSplitViewController.show`)
    /// instead of leaving it to observers that each run a turn later.
    @ObservationIgnored var onSwitch: ((Session) -> Void)?

    /// Sessions in the order they were last selected, most recent first: what
    /// ⌘P lists before you type (SessionSwitcherMatch).
    @ObservationIgnored private(set) var recentSessionIDs: [Session.ID] = []
    /// The session just made and the one it was made from, for as long as the
    /// selection has not left the new one: closing it then goes back there
    /// (`SidebarStep.afterClosing`), wherever in the sidebar the new row went.
    @ObservationIgnored private var justMade: (session: Session.ID, from: Session.ID)?

    // MARK: Back and Forward

    /// The places you were on before this one (a session and the tab you had
    /// in front in it), oldest first, and the ones Back has stepped away from,
    /// nearest last: a browser's history over sessions and their tabs, as
    /// Xcode and VS Code keep one over files. Unlike `recentSessionIDs` a
    /// visit isn't moved to the front when repeated, so Back retraces the path
    /// you took. Observed, so the titlebar's arrows enable as it changes. Not
    /// persisted: it's a trail through this run, and a relaunch starts a new
    /// one. The rules are `SessionHistory`'s.
    private(set) var history = SessionHistory<WorkspacePlace>()
    /// Set while Back or Forward is moving the selection or a tab, so the
    /// move isn't recorded as a fresh visit (which would clear Forward).
    @ObservationIgnored private var navigatingHistory = false
    /// The tab last brought forward in each session: the "tab" half of where
    /// you are. Not observed, and it needn't be for the arrows to stay right:
    /// it changes for the selected session only alongside a write to
    /// `history` (a visit, or the step that moved it) or to `selectedID`, and
    /// both are observed. A tab closing is seen through `isOpen`, which reads
    /// the session's (observed) rows. Not pruned when a tab closes; a closed
    /// tab is never open, and the next bring-forward replaces it.
    @ObservationIgnored private var currentTabs: [Session.ID: SideTab] = [:]

    var canGoBack: Bool { history.canStep(.back, from: currentPlace, isOpen: isOpen) }
    var canGoForward: Bool { history.canStep(.forward, from: currentPlace, isOpen: isOpen) }

    /// Where you are: the selected session and its current tab.
    private var currentPlace: WorkspacePlace? {
        selected.map(currentPlace(of:))
    }

    /// A session and the tab last brought forward in it, or, before any has
    /// been, what its main area shows.
    private func currentPlace(of session: Session) -> WorkspacePlace {
        WorkspacePlace(session: session.id,
                       tab: currentTabs[session.id] ?? session.workspace.front(of: .main) ?? .session)
    }

    /// A place you could go back to: its session is open and its tab is in
    /// one of the session's rows.
    private func isOpen(_ place: WorkspacePlace) -> Bool {
        guard let session = sessions.first(where: { $0.id == place.session }) else { return false }
        return session.workspace.region(of: place.tab) != nil
    }

    /// A selection you made: what you left goes on Back, and Forward is
    /// gone, as following a link after going back is in a browser.
    private func noteVisit(from previous: WorkspacePlace?) {
        guard !navigatingHistory else { return }
        history.visit(from: previous, isOpen: isOpen)
    }

    /// A tab came to the front of `session` (a click, ⌃Tab, a pane command,
    /// `wortel open`): a stop on the trail, unless it is the tab you were
    /// already on. GitPanelModel reports every one from `settle`, after the
    /// session's rows have changed, which is why the tab you were on is the
    /// one kept here rather than read off the rows.
    func noteTabBroughtForward(_ tab: SideTab, in session: Session) {
        let previous = currentPlace(of: session)
        if !navigatingHistory, previous.tab != tab, session.id == selectedID {
            history.visit(from: previous, isOpen: isOpen)
        }
        currentTabs[session.id] = tab
        noteShowing()
    }

    /// Step back, or forward, to the nearest place still open. `bringForward`
    /// puts the place's tab in front of its session once the session is
    /// selected; it is the panel's to do, and the manager doesn't own it.
    func goBack(bringForward: (Session, SideTab) -> Void) { stepHistory(.back, bringForward: bringForward) }
    func goForward(bringForward: (Session, SideTab) -> Void) { stepHistory(.forward, bringForward: bringForward) }

    /// Pops to the nearest place still open (closed sessions and tabs are
    /// stepped over and dropped), leaves the current one on the other side,
    /// selects its session if it isn't already, and brings its tab forward in
    /// whichever row it is in now. The rest of the layout stays as it is.
    private func stepHistory(_ direction: SessionHistory<WorkspacePlace>.Direction,
                             bringForward: (Session, SideTab) -> Void) {
        // A copy, written back before the selection moves: `selectedID`'s
        // didSet runs a long chain, and nothing in it may find this
        // half-stepped.
        var stepped = history
        let target = stepped.step(direction, from: currentPlace, isOpen: isOpen)
        if stepped != history { history = stepped }
        guard let target, let session = sessions.first(where: { $0.id == target.session }) else { return }
        // Neither the selection moving nor the tab coming forward is a visit:
        // either would clear Forward.
        navigatingHistory = true
        defer { navigatingHistory = false }
        if selectedID != target.session { selectedID = target.session }
        currentTabs[target.session] = target.tab
        bringForward(session, target.tab)
    }

    /// The most recent "switched into a waiting session" event; the detail view
    /// flashes an orienting ring on each fresh value. Never cleared — at rest
    /// the overlay is simply invisible.
    private(set) var attentionFlash: AttentionFlash?

    /// The session whose name is being edited inline (nil = none). Observed by
    /// the sidebar so double-click, the context menu, and ⌘R all drive one path.
    var editingID: Session.ID?

    /// ⌘ is being held on its own: the rows show their ⌘1…⌘9 instead of
    /// their status, so the shortcut can be read off the row it goes to.
    var showsShortcutHints = false

    /// The sidebar row under the pointer: its name makes room for the row's
    /// "…" and × only then (SidebarRowContent), rather than always.
    var hoveredRowID: Session.ID?

    /// The sidebar rows selected beyond `selectedID` (⌘-click, ⇧-click), which
    /// a right-click inside acts on all of. UI state only: never saved,
    /// collapsed whenever the lead moves from outside it, pruned as its
    /// sessions close. See `SessionSelection` for the rules.
    private(set) var sidebarSelection = SessionSelection()

    /// The sessions as the sidebar draws them, top to bottom, folded sections
    /// left out: what a ⇧-click's range runs over and the order a bulk action
    /// applies in. Written by the outline after each change, never read for
    /// drawing, so not observed.
    @ObservationIgnored var sidebarRowOrder: [Session.ID] = []

    /// ⌘1…⌘9's sessions: the first nine rows as the sidebar draws them
    /// (Pinned first, Sort Unread First applied, folded sections left out),
    /// so the number on a row is the one that selects it. Observed, unlike
    /// `sidebarRowOrder`, so the numbers shown while ⌘ is held follow a
    /// re-sort. nil until the sidebar has drawn, when it's the stored order.
    private(set) var shortcutIDs: [Session.ID]?

    /// View ▸ Sort Unread First: within each section, sessions that want you
    /// are drawn first (`SidebarSort`). Only how the rows are drawn: the
    /// order you dragged is never touched, so turning it off restores it
    /// exactly. View state, beside the folds; off by default.
    var sortUnreadFirst = false {
        didSet { UserDefaults.standard.set(sortUnreadFirst, forKey: Self.sortUnreadFirstKey) }
    }
    @ObservationIgnored private static let sortUnreadFirstKey = "WortelSortUnreadFirst"

    /// Called when the last session closes (the window should close).
    @ObservationIgnored var onAllClosed: (() -> Void)?

    /// Presents a modal confirmation for closing a session that still has a
    /// running process, calling back with `true` to proceed. Set by the app
    /// layer (it owns the window to sheet onto). When nil, closes without
    /// asking.
    @ObservationIgnored var confirmClose: ((Session, @escaping (Bool) -> Void) -> Void)?

    /// Whether a session has work running that the terminal itself cannot see:
    /// a server behind the prompt (`bun dev &`), or one that has left the shell
    /// altogether. Ghostty only knows about the foreground process, so a shell
    /// idling at its prompt closes without a word while `:3000` goes with it.
    @ObservationIgnored var hasBackgroundWork: ((Session) -> Bool)?

    /// Stop everything a session started, as it closes. A session and the
    /// servers it ran are one thing: closing it must not leave them running,
    /// orphaned under launchd with nothing on screen to say so.
    @ObservationIgnored var stopSessionWork: ((Session) -> Void)?

    /// A background session raised attention (a program asked for you — e.g.
    /// Claude Code emits OSC 777 on a permission/idle prompt, or a bell). The
    /// app layer turns this into a native macOS notification. `title`/`body`
    /// come from the program when it's a notification, or are synthesized.
    @ObservationIgnored var onNeedsAttention: ((Session, _ kind: AttentionKind, _ title: String, _ body: String, _ alert: Bool) -> Void)?

    /// A session's attention was answered (selected / app came front / closed).
    /// The app layer uses this to retract the session's notification from
    /// Notification Center so stale "needs you" banners don't linger.
    @ObservationIgnored var onAttentionCleared: ((Session) -> Void)?
    /// Which sessions are waiting changed: what the Dock badge and the menu
    /// bar's list follow.
    @ObservationIgnored var onAttentionChanged: (() -> Void)?
    /// A session's reminder was set (its date), or ended (nil: cancelled,
    /// closed, or gone off and since visited). The app layer keeps a banner
    /// waiting in Notification Center for it, so it still comes with Wortel
    /// quit, and takes it back here.
    @ObservationIgnored var onReminderChanged: ((Session, Date?) -> Void)?
    /// A reminder went off for a session nobody is looking at: the banner,
    /// now, under the session's name as it is now.
    @ObservationIgnored var onReminderDue: ((Session) -> Void)?

    /// A foreground command finished in a session — its work tree may have
    /// changed. The app layer uses this to refresh the source-control panel.
    @ObservationIgnored var onCommandFinished: ((Session) -> Void)?

    /// A markdown file was clicked in a session's terminal (already resolved to
    /// an absolute file URL). The app layer opens it in the right-hand preview.
    @ObservationIgnored var onOpenMarkdown: ((URL) -> Void)?
    /// A side terminal's shell exited (`exit`, or the program it was running
    /// ended the session). Its tab goes with it; the column model decides what
    /// takes its place. Set by AppDelegate.
    @ObservationIgnored var onSideTerminalExited: ((Session, UUID) -> Void)?
    /// A session closed, after its terminals: for whoever holds something for
    /// its other tabs (a browser's page, a file's document).
    @ObservationIgnored var onSessionClosed: ((Session) -> Void)?

    /// Whether Wortel is the frontmost app. A session the user is *actively
    /// viewing* (app active + window visible + selected) never raises
    /// attention — they can see it. Set by the app layer on activate/resign.
    @ObservationIgnored var appIsActive = true

    /// Whether the main window is actually on screen (not miniaturized or
    /// fully occluded). An active app with a minimized window is *not*
    /// "actively viewing" anything. Set by the app layer on occlusion changes.
    @ObservationIgnored var windowIsVisible = true

    /// Which session has been in front of someone, and when: whether a turn
    /// that ended was already read before anything announced it. Fed by every
    /// change to what's on screen (`noteShowing`).
    @ObservationIgnored private var seen = SeenLedger()

    /// What's on screen just changed (selection, Wortel coming forward or
    /// going back, the window covered or shown): tell the ledger.
    ///
    /// Asks AppKit whether Wortel is frontmost rather than `appIsActive`, which
    /// starts out true: launched in the background (a login item), the
    /// restored session would otherwise count as read for as long as Wortel
    /// was never brought forward. Only the session's terminal counts, not a
    /// file or a page in front of it.
    private func noteShowing() {
        let onScreen = NSApp?.isActive == true && windowIsVisible
        let id = onScreen && selected?.workspace.showsSessionTerminal == true ? selectedID : nil
        guard id != seen.showing else { return }
        let present = !Self.userIsAway()
        AgentStatusLog.log.debug("""
            showing \(id?.uuidString ?? "nothing", privacy: .public) present=\(present, privacy: .public)
            """)
        seen.show(id, at: Date(), present: present)
    }


    /// Busy is shown only after a command has been running this long, so
    /// instant commands (ls, cd, git status) never flash the spinner.
    private static let busyShowDelay: TimeInterval = 0.15
    /// A command that ran at least this long and finished while its session was
    /// unselected raises the attention dot.
    private static let attentionAfterNs: UInt64 = 10_000_000_000 // 10s
    /// After a progress-emitting program (an agent like Claude Code) reports it
    /// stopped working (OSC 9;4;0), wait this long before raising attention —
    /// if progress resumes in the window (a blip between tools), it's cancelled.
    private static let quiesceSettleDelay: TimeInterval = 1.0
    /// Progress must have been active at least this long for its end to mean
    /// "the agent wants you"; shorter blips are noise, not a finished turn.
    private static let minBusyForQuiesceAttention: TimeInterval = 2.0
    /// The same gate for a busy the screen tier only *corroborated* on a session
    /// that has a channel of its own — see `progressEnded(corroborating:)`. Ten
    /// seconds is far past anything two stray repaints can produce, and far
    /// short of any turn worth a notification.
    private static let minBusyForCorroboratedQuiesce: TimeInterval = 10.0
    /// Pending "show busy" work items, keyed by session; cancelled if the
    /// command finishes before the delay elapses.
    @ObservationIgnored private var busyTimers: [Session.ID: DispatchWorkItem] = [:]
    /// Pending "agent stopped → raise attention" work items, keyed by session;
    /// cancelled if progress resumes first.
    @ObservationIgnored private var quiesceTimers: [Session.ID: DispatchWorkItem] = [:]
    /// When each session's busy spinner actually turned on; drives the
    /// minimum-duration gate above.
    @ObservationIgnored private var busyStartedAt: [Session.ID: Date] = [:]
    /// Sessions whose latest OSC 9;4 report was the error state. A span that
    /// ends from there is announced as a failure, not a finished turn.
    @ObservationIgnored private var progressErrored: Set<Session.ID> = []
    /// The last (start, cleared) busy interval per session. If busy re-arms
    /// shortly after clearing, it's a continuation of the same run of work —
    /// e.g. Pi's OSC 133 zone marks make the core synthesize a command-finished
    /// mid-turn, then its 1s progress keepalive re-marks busy — so the original
    /// start is restored to keep the duration gate honest. `onCommandFinished`
    /// now ignores those events while an agent marker is live, so this is the
    /// belt to that brace: it still covers a clear from any other source.
    @ObservationIgnored private var lastBusyInterval: [Session.ID: (start: Date, cleared: Date)] = [:]
    /// Re-arming busy within this window of the last clear counts as a
    /// continuation (see `lastBusyInterval`).
    private static let busyContinuationWindow: TimeInterval = 3.0
    /// Sessions whose terminal title currently shows a "working" marker
    /// (see `titleChanged`).
    @ObservationIgnored private var titleShowsWorking: Set<Session.ID> = []
    /// Sessions whose terminal title currently shows an action-required
    /// marker. Codex *blinks* its marker while blocked, "[ ! ] Action Required"
    /// then "[ . ] Action Required" and back, so the title arrives again and
    /// again saying the same thing; only the edge into this state is an event
    /// (see `titleChanged`).
    @ObservationIgnored private var titleShowsActionRequired: Set<Session.ID> = []
    /// How the last stretch of work in each session ended, by the same signals
    /// that raise its dot, kept until it starts working again. `attention`
    /// can't answer that: it is never raised for the session you're looking
    /// at and is cleared the moment you look, and `wortel list` and
    /// `wortel wait --idle` ask about every session, watched or not. The
    /// loudest wins within one quiet stretch, as it does for the dot.
    @ObservationIgnored private var turnOutcomes: [Session.ID: AttentionKind] = [:]
    /// When each session last reported starting work (a command, a progress
    /// report, a working title), before the debounce: a `wait --idle` that
    /// began before this has seen a turn happen, however short.
    @ObservationIgnored private var lastBusyReports: [Session.ID: Date] = [:]
    /// How long a session must stay actively-viewed before its "unread" mark
    /// clears. Long enough that a quick click-through to triage doesn't count as
    /// catching up, short enough that actually landing on it clears promptly.
    private static let unreadDwellDelay = SeenLedger.dwell
    /// Pending "you've now caught up → drop the unread mark" work items, keyed
    /// by session; cancelled the moment you navigate away.
    @ObservationIgnored private var unreadDwellTimers: [Session.ID: DispatchWorkItem] = [:]

    /// Whether a session has changed enough to be worth naming again. The rules
    /// and their reasoning live in `AutoNameThrottle`, which is pure so they can
    /// be tested against a fake clock.
    @ObservationIgnored private let autoNameThrottle = AutoNameThrottle()
    @ObservationIgnored private var autoNameState: [Session.ID: AutoNameThrottle.State] = [:]

    /// One session's wait for its agent's first prompt. See `beginPromptCapture`.
    private struct PromptCapture {
        let token = UUID()
        let startedAt: Date
        let resume: Bool
        let tap: PromptTap?
    }
    @ObservationIgnored private var promptCaptures: [Session.ID: PromptCapture] = [:]
    /// An agent nobody has prompted for this long is not about to be; stop
    /// listening rather than wait for a follow-up that would name it wrongly.
    private static let promptCaptureDeadline: TimeInterval = 15 * 60
    /// A title from the prompt is held back this long so an agent that names
    /// itself (Claude Code, a few seconds after the first prompt) wins outright
    /// instead of the row renaming twice in quick succession.
    private static let promptTitleHold: TimeInterval = 8

    var selected: Session? {
        sessions.first { $0.id == selectedID }
    }

    /// Names of folders the user has collapsed in the sidebar. Persisted to
    /// UserDefaults (view state, not session data), keyed by folder name.
    private(set) var collapsedFolders: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(collapsedFolders), forKey: Self.collapsedFoldersKey)
        }
    }
    @ObservationIgnored private static let collapsedFoldersKey = "WortelCollapsedFolders"

    /// The Pinned section and the folderless "Sessions" one, folded like a
    /// folder. View state, kept beside the folders'.
    private(set) var pinnedCollapsed = false {
        didSet { UserDefaults.standard.set(pinnedCollapsed, forKey: Self.pinnedCollapsedKey) }
    }
    private(set) var looseCollapsed = false {
        didSet { UserDefaults.standard.set(looseCollapsed, forKey: Self.looseCollapsedKey) }
    }
    @ObservationIgnored private static let pinnedCollapsedKey = "WortelPinnedCollapsed"
    @ObservationIgnored private static let looseCollapsedKey = "WortelLooseCollapsed"

    func setPinnedCollapsed(_ collapsed: Bool) {
        if pinnedCollapsed != collapsed { pinnedCollapsed = collapsed }
    }

    func setLooseCollapsed(_ collapsed: Bool) {
        if looseCollapsed != collapsed { looseCollapsed = collapsed }
    }

    /// How each section sorts (Sort By in its "…" menu), by folder name, ""
    /// for Sessions. Only the sections not on Recent have an entry:
    /// that is the default, for every section that existed before there was
    /// a choice too. View state, kept beside the folds. Pinned has none: it
    /// is arranged by hand.
    private(set) var sectionSorts: [String: SectionSort.Mode] = [:] {
        didSet {
            UserDefaults.standard.set(sectionSorts.mapValues(\.rawValue), forKey: Self.sectionSortsKey)
        }
    }
    @ObservationIgnored private static let sectionSortsKey = "WortelSectionSort"

    /// How the section of `folder` (nil: Sessions) sorts.
    func sectionSort(ofFolder folder: String?) -> SectionSort.Mode {
        sectionSorts[folder ?? ""] ?? .recent
    }

    func setSectionSort(_ mode: SectionSort.Mode, ofFolder folder: String?) {
        let value: SectionSort.Mode? = mode == .recent ? nil : mode
        if sectionSorts[folder ?? ""] != value { sectionSorts[folder ?? ""] = value }
    }

    /// Every session in the order the sidebar has them: Pinned, the folders,
    /// Sessions, each section by its Sort By. Folded sections included, and
    /// without Sort Unread First's band, which only moves rows while it's on.
    /// For what walks "the sidebar" without drawing it: `wortel list`, the
    /// jump to the next waiting session, the menu bar's list.
    var sessionsInSidebarOrder: [Session] {
        sidebarGroups.flatMap { group -> [Session] in
            guard let order = sortedOrder(of: group) else { return group.sessions }
            let byID = Dictionary(group.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return order.compactMap { byID[$0] }
        }
    }

    /// The order `group` is drawn in by its Sort By choice, beneath Sort
    /// Unread First; nil for Pinned and a Manual section, which are drawn as
    /// stored. Reads each row's times and name, so a Return in a sorted
    /// section redraws the sidebar, and nothing else's does.
    func sortedOrder(of group: SidebarGroup) -> [UUID]? {
        guard !group.isPinned else { return nil }
        let mode = sectionSort(ofFolder: group.folder)
        guard mode != .manual else { return nil }
        let facts = Dictionary(group.sessions.map {
            ($0.id, SectionSort.Facts(created: $0.createdAt, sent: $0.lastSentAt, name: $0.leafName))
        }, uniquingKeysWith: { first, _ in first })
        return SectionSort.order(group.sessions.map(\.id), mode: mode, facts: facts)
    }

    /// Unfold whichever section a session is drawn in now (Pinned, its folder,
    /// or Sessions), so it has a row: after it was selected, pinned, unpinned,
    /// or renamed into another place.
    private func reveal(_ session: Session) {
        if isPinned(session) {
            setPinnedCollapsed(false)
        } else if let folder = session.folderPath {
            if collapsedFolders.contains(folder) { collapsedFolders.remove(folder) }
        } else {
            setLooseCollapsed(false)
        }
    }

    /// What a folded Pinned or Sessions header shows for the sessions it
    /// hides, as `attention(inFolder:)` does for a folder.
    func attention(inPinned pinned: Bool) -> AttentionKind? {
        guard pinned ? pinnedCollapsed : looseCollapsed else { return nil }
        return AttentionKind.loudest(of: sessions.lazy.filter {
            pinned ? self.isPinned($0) : (!self.isPinned($0) && $0.folderPath == nil)
        }.map(\.attention))
    }

    /// Folders made on purpose (⌘O, or a worktree of a repository with no
    /// folder yet). Unlike folders that emerge from a "giel/…" name, these
    /// persist as sections even when empty. Ordered; persisted to UserDefaults.
    private(set) var declaredFolders: [String] = [] {
        didSet { UserDefaults.standard.set(declaredFolders, forKey: Self.declaredFoldersKey) }
    }
    @ObservationIgnored private static let declaredFoldersKey = "WortelDeclaredFolders"

    /// The user's chosen order of the sidebar's folder sections. Source of truth
    /// for section ordering (drag a header to rearrange). Kept in sync with the
    /// folders that actually exist by `syncFolderOrder`; persisted to
    /// UserDefaults. Empty on first run — sections then fall back to
    /// first-appearance order, and this is populated from that.
    private(set) var folderOrder: [String] = [] {
        didSet { UserDefaults.standard.set(folderOrder, forKey: Self.folderOrderKey) }
    }
    @ObservationIgnored private static let folderOrderKey = "WortelFolderOrder"

    /// The directory each folder stands for, keyed by folder name. A folder
    /// without one is what every folder used to be: a label.
    ///
    /// This is what makes "New Session in “GFPC”" mean GFPC. Before it, a
    /// folder was purely the part of a session's name before the last slash, so
    /// that command filed a session under GFPC and started it wherever the
    /// *selected* session happened to be standing — which looked like it had
    /// worked. Same shelf as the other three: view state about the sidebar, not
    /// session data, so UserDefaults rather than `sessions.json`.
    private(set) var folderRoots: [String: String] = [:] {
        didSet { UserDefaults.standard.set(folderRoots, forKey: Self.folderRootsKey) }
    }
    @ObservationIgnored private static let folderRootsKey = "WortelFolderRoots"

    /// Pinned sessions, in the order they're shown: a section of their own at
    /// the top of the sidebar, as the ChatGPT app pins chats. A pinned session
    /// keeps its folder (it's in its name), so unpinning puts it back there.
    /// View state about the sidebar, so UserDefaults like the folders'.
    private(set) var pinnedIDs: [Session.ID] = [] {
        didSet { UserDefaults.standard.set(pinnedIDs.map(\.uuidString), forKey: Self.pinnedKey) }
    }
    @ObservationIgnored private static let pinnedKey = "WortelPinnedSessions"

    func isPinned(_ session: Session) -> Bool { pinnedIDs.contains(session.id) }

    /// Pin (last among the pinned) or unpin one session.
    func setPinned(_ session: Session, _ pinned: Bool) {
        setPinned([session], pinned)
    }

    /// Pin or unpin several at once: the sidebar's selection, or a drag of it.
    /// One change to the pins and one save, not one per session. Pinned ones
    /// keep the order given (the order they're drawn in) and go just before
    /// `before` among the pinned, or at the end.
    func setPinned(_ batch: [Session], _ pinned: Bool, before: Session.ID? = nil) {
        let moving = Set(batch.map(\.id))
        var ids = pinnedIDs.filter { !moving.contains($0) }
        if pinned {
            let at = before.flatMap { ids.firstIndex(of: $0) } ?? ids.count
            ids.insert(contentsOf: batch.map(\.id), at: at)
        }
        guard ids != pinnedIDs else { return }
        pinnedIDs = ids
        // Pinning shows it in Pinned, unpinning back where it came from, as a
        // drop into a folder opens it.
        batch.forEach(reveal)
        normalizeOrder()
        scheduleSave()
    }

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        collapsedFolders = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedFoldersKey) ?? [])
        pinnedCollapsed = UserDefaults.standard.bool(forKey: Self.pinnedCollapsedKey)
        looseCollapsed = UserDefaults.standard.bool(forKey: Self.looseCollapsedKey)
        sectionSorts = (UserDefaults.standard.dictionary(forKey: Self.sectionSortsKey) as? [String: String] ?? [:])
            .compactMapValues(SectionSort.Mode.init(rawValue:))
        declaredFolders = UserDefaults.standard.stringArray(forKey: Self.declaredFoldersKey) ?? []
        folderOrder = UserDefaults.standard.stringArray(forKey: Self.folderOrderKey) ?? []
        folderRoots = UserDefaults.standard.dictionary(forKey: Self.folderRootsKey)
            as? [String: String] ?? [:]
        pinnedIDs = (UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [])
            .compactMap(UUID.init(uuidString:))
        sortUnreadFirst = UserDefaults.standard.bool(forKey: Self.sortUnreadFirstKey)
        // Delivered on the main queue by the keeper's process source.
        GhosttyRuntime.onKeeperLost = { [weak self] pid in
            MainActor.assumeIsolated { self?.keeperDidExit(pid: pid) }
        }
    }

    // MARK: - Sidebar folders (derived from session names)

    /// The sidebar's rows, grouped into folders: Pinned, the folders, then the
    /// top level (`nil` folder, under its "Sessions" header). Folder sections follow the
    /// user's `folderOrder`; any folder not yet tracked there falls back to
    /// first-appearance (populated) / declaration (empty) order so nothing is
    /// ever dropped. Sessions keep their array order within a group. Purely a
    /// view of `sessions` + folder state — nothing here is stored.
    var sidebarGroups: [SidebarGroup] {
        // The rules live in `SidebarLayout`; this maps its ids back to sessions.
        // First wins on a duplicate id, as the `sessions.first` lookups it
        // replaced did.
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SidebarLayout.groups(
            rows: sessions.map { SidebarLayout.Row(id: $0.id, folder: $0.folderPath) },
            pinned: pinnedIDs, folderOrder: folderOrder, declaredFolders: declaredFolders
        ).map { group in
            SidebarGroup(folder: group.folder, sessions: group.ids.compactMap { byID[$0] },
                         isPinned: group.isPinned)
        }
    }

    func isFolderCollapsed(_ folder: String) -> Bool { collapsedFolders.contains(folder) }

    func setFolder(_ folder: String, collapsed: Bool) {
        if collapsed { collapsedFolders.insert(folder) } else { collapsedFolders.remove(folder) }
    }

    /// Every folder shown in the sidebar (populated or empty) in render order.
    /// Drives name-collision checks and where ⌘O files a session.
    var folderNames: [String] { sidebarGroups.compactMap(\.folder) }

    // MARK: - Folder directories

    /// The directory `folder` stands for, or nil for a folder that is still
    /// just a label. nil folder (the top level) never has one: the top level
    /// isn't a project, it's everything that isn't in one.
    func root(ofFolder folder: String?) -> String? {
        folder.flatMap { folderRoots[$0] }
    }

    /// The folder whose directory covers `path`, deepest root winning: where
    /// ⌘O files a directory, and where a session started in it belongs.
    func folder(covering path: String) -> String? {
        FolderRoot.folder(containing: FolderRoot.normalize(path) ?? path, in: folderRoots)
    }

    /// Point a folder at a directory, or clear it with nil. Normalized on the
    /// way in so two spellings of one path can't become two different folders.
    func setRoot(_ path: String?, ofFolder folder: String) {
        folderRoots[folder] = path.flatMap(FolderRoot.normalize)
        // A repository nothing was watching yet gets its listing now, not at
        // the next archive or launch.
        if let home = repositoryHome(ofFolder: folder), listingWatchers[home] == nil {
            refreshWorktreeListings()
        }
    }

    /// `path`, if there is still a directory there.
    ///
    /// Every remembered directory in this file is a path recorded at some point
    /// in the past, and the disk moves underneath it: a project gets renamed, a
    /// worktree gets removed, a volume gets unmounted. Handing a dead path to a
    /// new session doesn't fail loudly — `chdir` is best-effort and the shell
    /// just starts somewhere else — so it has to be checked here, where there's
    /// still another answer to fall through to.
    ///
    /// What it deliberately does *not* do is forget the root. A folder pointed
    /// at an unmounted volume still shows its directory in the sidebar and can
    /// be repointed; silently clearing it would make a mounting problem look
    /// like lost configuration.
    private func existingDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    /// Adopt a directory for every folder that has never had one, from where its
    /// sessions already are. Runs once per launch, after restore, and is a no-op
    /// from the second launch on (a derived root is stored like any other).
    ///
    /// Without this, the feature ships switched off for everyone who already has
    /// folders: each one would be a label until pointed at a directory by hand,
    /// and "New Session in “GFPC”" would go on doing the wrong thing until then.
    /// The rules that keep the guess quiet live in `FolderRoot.derived`.
    private func adoptFolderRoots() {
        let home = NSHomeDirectory()
        let worktrees = [GitWorktree.root.path]
        for folder in folderNames where folderRoots[folder] == nil {
            // Worktrees don't vote, wherever they are: their common folder
            // is a place for branches, not the project.
            let cwds = sessions
                .filter { $0.folderPath == folder && $0.homeCheckout == nil }
                .compactMap { $0.originCwd }
            guard let root = FolderRoot.derived(
                from: cwds, excludingUnder: worktrees, home: home) else { continue }
            folderRoots[folder] = root
        }
    }

    /// Create a new, empty folder (for ⌘O, which then points it at its
    /// directory). Name is made unique; the folder is left expanded and its name returned.
    @discardableResult
    func addFolder(named requested: String? = nil) -> String {
        let base = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "New Folder"
        let existing = Set(folderNames)
        var name = base, n = 1
        while existing.contains(name) { n += 1; name = "\(base) \(n)" }
        declaredFolders.append(name)
        collapsedFolders.remove(name)
        syncFolderOrder() // give the new folder a tracked, persisted position
        return name
    }

    /// Rename a folder: re-prefix every member session and carry the declared /
    /// collapsed entries over to the new name.
    func renameFolder(_ folder: String, to newName: String) {
        guard let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              trimmed != folder else { return }
        // Its sort goes with it, as its fold does. Onto a folder that is
        // there already is a merge, and the destination keeps its own.
        let merging = folderOrder.contains(trimmed)
        if let sort = sectionSorts.removeValue(forKey: folder), !merging { sectionSorts[trimmed] = sort }
        for session in sessions where session.folderPath == folder {
            session.name = "\(trimmed)/\(session.leafName)"
        }
        refileArchived(from: folder, to: trimmed)
        if let i = declaredFolders.firstIndex(of: folder) {
            if declaredFolders.contains(trimmed) { declaredFolders.remove(at: i) }
            else { declaredFolders[i] = trimmed }
        }
        if collapsedFolders.remove(folder) != nil { collapsedFolders.insert(trimmed) }
        // The directory belongs to the folder, not to its name. Losing it on a
        // rename would quietly turn a project back into a label. Renaming *onto*
        // an existing folder is a merge, and there the destination keeps its own
        // directory — the sessions are moving into it, not redefining it.
        if let root = folderRoots.removeValue(forKey: folder), folderRoots[trimmed] == nil {
            folderRoots[trimmed] = root
        }
        // Rename in place so the folder keeps its position instead of jumping to
        // the end when syncFolderOrder drops the old name and appends the new.
        if let i = folderOrder.firstIndex(of: folder) { folderOrder[i] = trimmed }
        normalizeOrder()
        scheduleSave()
    }

    /// The archived sessions filed in `folder` go with it to `name` (nil: the
    /// top level), as its live ones do: the folder is part of their names.
    private func refileArchived(from folder: String, to name: String?) {
        var changed = false
        for i in archived.indices where archived[i].folderPath == folder {
            let leaf = archived[i].leafName
            archived[i].session.name = name.map { "\($0)/\(leaf)" } ?? leaf
            changed = true
        }
        if changed { ArchiveStore.save(archived) }
    }

    /// Delete a folder: its sessions drop to the top level (nothing is closed),
    /// and the section disappears.
    func deleteFolder(_ folder: String) {
        var released = false
        for session in sessions where session.folderPath == folder {
            session.name = session.leafName
            released = true
        }
        refileArchived(from: folder, to: nil)
        // They land in Sessions, which must not be folded over them.
        if released { setLooseCollapsed(false) }
        declaredFolders.removeAll { $0 == folder }
        collapsedFolders.remove(folder)
        sectionSorts.removeValue(forKey: folder)
        folderRoots.removeValue(forKey: folder)
        normalizeOrder()
        scheduleSave()
    }

    /// Move several sessions into `folder` (nil: the top level) together, in
    /// the order given, just before `before` (a session in that group) or at
    /// its end: a drag of the sidebar's selection. One
    /// change to `sessions` and one save. `unpin` takes them out of Pinned on
    /// the way, as a drop anywhere outside Pinned does.
    ///
    /// Placed by a neighbour rather than an index on purpose: with Sort Unread
    /// First on, the rows are drawn in an order that isn't the stored one, and
    /// "above the row you dropped on" is the one thing both orders agree on.
    func moveSessions(_ ids: [Session.ID], toFolder folder: String?, before: Session.ID? = nil,
                      unpin: Bool = false) {
        let moving = ids.compactMap { id in sessions.first { $0.id == id } }
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        if unpin, pinnedIDs.contains(where: movingIDs.contains) {
            pinnedIDs.removeAll(where: movingIDs.contains)
        }
        for session in moving where session.folderPath != folder {
            session.name = folder.map { "\($0)/\(session.leafName)" } ?? session.leafName
        }
        var rest = sessions.filter { !movingIDs.contains($0.id) }
        // Only the position among the group's own members matters:
        // `normalizeOrder` gathers each group together after.
        let index = SidebarLayout.insertionIndex(
            in: rest.map { SidebarLayout.Row(id: $0.id, folder: $0.folderPath) },
            folder: folder, before: before, pinned: Set(pinnedIDs))
        rest.insert(contentsOf: moving, at: index)
        sessions = rest
        normalizeOrder()
        if let folder { collapsedFolders.remove(folder) } else { setLooseCollapsed(false) }
        scheduleSave()
    }

    /// Re-flatten `sessions` to match the rendered order (groups contiguous, in
    /// the folder order). Keeps flat-index consumers — the Session menu —
    /// agreeing with what the sidebar shows.
    private func normalizeOrder() {
        syncFolderOrder()
        sessions = sidebarGroups.flatMap(\.sessions)
    }

    /// Reconcile `folderOrder` with the folders that actually exist: drop any
    /// that vanished, append newly-appeared ones (by first appearance), and
    /// dedupe — preserving the user's arrangement for everything already tracked.
    private func syncFolderOrder() {
        // A folder whose sessions are all archived is still there: its fold is.
        let order = SidebarLayout.syncedFolderOrder(
            folderOrder, rows: sessions.map { SidebarLayout.Row(id: $0.id, folder: $0.folderPath) },
            declaredFolders: declaredFolders, archivedFolders: archived.compactMap(\.folderPath))
        if order != folderOrder { folderOrder = order }
    }

    /// Reorder folder sections: move `folder` to `index` among the folder
    /// sections (an insertion index as rendered pre-move, the NSOutlineView
    /// drop convention — it may count the folder's own current position).
    func moveFolder(_ folder: String, toFolderIndex index: Int) {
        syncFolderOrder()
        guard let order = SidebarLayout.movingFolder(folder, to: index, in: folderOrder),
              order != folderOrder else { return }
        folderOrder = order
        normalizeOrder()
        scheduleSave()
    }

    // MARK: - Restore

    /// Restore persisted sessions (or create the first). Only the selected
    /// session's shell spawns before the first frame; the rest warm up shortly
    /// after so launch stays lean.
    func restore() {
        // Before the early return below: a first launch has nothing to restore but
        // still needs the watcher, or nothing would ever record a running agent and
        // the *next* launch would have nothing to resume.
        startAgentActivityWatch()
        // Every marker read until restore is done belongs to an agent that was
        // already running (it survived the last quit), so none is "started".
        // Set on every way out, the first launch's early return included.
        defer { agentMarkersBaselined = true }
        // Last, once every saved session is back.
        defer { syncReminders() }
        var persisted = store.load()
        archived = ArchiveStore.load()
        // In both files: archived, then the app ended before sessions.json
        // caught up. Archiving was the last word on it, and its shell is
        // already gone; started again here, the same id would be live and
        // archived at once.
        let archivedIDs = Set(archived.map(\.id))
        persisted.removeAll { archivedIDs.contains($0.id) }
        hasRestored = true
        if store.loadedCleanly { Self.retireDeadDefaults(persisted: persisted) }
        // Once launch has settled: the keeper is asked what it holds, which is
        // a round trip, and nothing about it is urgent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.recoverOrphanedShells()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshWorktreeListings()
        }
        guard !persisted.isEmpty else {
            // Plain, whatever Settings says: a launch is not a request for
            // an agent.
            newSession(starting: .plain)
            return
        }
        // Markers left by agents that were still running at quit — resume them.
        let resume = AgentResumeStore.consumeSnapshot()
        // One read of the process table for every surviving agent below.
        lazy var table = ProcessTable.snapshot()
        for entry in persisted {
            appendRestored(restoredSession(from: entry, marker: resume[entry.id], table: { table }))
        }
        renameOldHomePlaceholders()
        syncFolderOrder() // seed/prune the persisted folder order for the restored set
        adoptFolderRoots() // give folders that predate directories one, from where they already are
        assignPortBlocks() // before any surface: the first shell is spawned with its ports
        // Mirror the markers that outlived the last launch onto the sessions that
        // just came back. The directory watcher can't do it: it was armed before
        // there were any sessions to mirror onto, and a marker whose agent is
        // still running is one nobody is about to write to.
        refreshAgentActivity()
        resolveWorktreeBranches()
        selectedID = (persisted.first(where: \.selected) ?? persisted[0]).id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.warmRemainingSurfaces()
        }
    }

    /// A session as `entry` saved it, agent resume owed and all: what launch
    /// does for every saved session, and Restore for an archived one.
    /// `marker` is the agent marker that outlived the last launch, if any.
    private func restoredSession(from entry: PersistedSession, marker: AgentMarker?,
                                 table: () -> [ProcessEntry]) -> Session {
        // A file written before sessions recorded an origin has only the
        // last known cwd to offer, which is exactly what the old behaviour
        // would have inherited — so the migration changes nothing on the
        // launch that reads it, and the drift stops from the next one on.
        let session = Session(id: entry.id, name: entry.name, title: entry.title,
                              cwd: entry.cwd, originCwd: entry.originCwd ?? entry.cwd)
        // An unrecognised source (a file from a newer build) is treated as the
        // user's: the one reading that can never relabel work by surprise.
        session.nameSource = Session.NameSource(rawValue: entry.nameSource) ?? .user
        session.worktreeBranch = entry.worktreeBranch
        noteCheckout(session)
        // A colour only a newer build knows reads as none.
        session.colour = entry.colour.flatMap(SessionColour.init(rawValue:))
        // One already past is due now: `syncReminders` fires it once launch is done.
        session.remindAt = entry.remindAt
        session.createdAt = entry.createdAt
        // Saved before Returns were kept: when keys last went in is the
        // nearest thing, read once here so a click later never moves it.
        session.lastSentAt = entry.lastSentAt ?? entry.lastTypedAt
        if let typed = entry.lastTypedAt { lastTypedAt[session.id] = typed }
        // An earlier build named these "<folder>/<branch>" with the branch
        // whole, which read back as a folder of their own. The rename that
        // gave them their real names kept that folder half, so stopping it
        // isn't enough — the ones already filed there move on this launch.
        if let branch = session.worktreeBranch,
           let repaired = GitWorktree.repairedSessionName(session.name, branch: branch) {
            session.name = repaired
        }
        // nil means the file predates per-session visibility — inherit the
        // old app-wide flag just this once.
        session.gitPanelVisible = entry.gitPanelVisible ?? SessionStore.legacyGitPanelVisible
        // nil (a file predating per-session panes, or a session that never
        // had one chosen) and an unrecognised raw value both mean "no
        // preference" — leave it nil and let GitPanelModel.defaultPane
        // answer, so the session follows the last pane chosen anywhere
        // rather than being pinned to a guess made here.
        session.inspectorPane = entry.inspectorPane.flatMap(InspectorPane.init(rawValue:))
        // The column's tabs. A file from before the column had them said only
        // whether it was up and on which pane, and that becomes a strip of
        // one: a session with Changes open opens on a Changes tab, and one
        // that never had the column up starts with none, which is also what
        // makes its first ⌘⌥G open the pane you'd expect.
        var tabs = WorkspaceTabs(
            main: (entry.mainTabs ?? []).compactMap(SideTab.init(rawValue:)),
            activeMain: entry.activeMainTab.flatMap(SideTab.init(rawValue:)),
            side: (entry.sideTabs ?? []).compactMap(SideTab.init(rawValue:)),
            activeSide: entry.activeSideTab.flatMap(SideTab.init(rawValue:)),
            sideVisible: session.gitPanelVisible,
            bottom: (entry.bottomTabs ?? []).compactMap(Self.stripTab),
            activeBottom: entry.activeBottomTab.flatMap(Self.stripTab),
            bottomVisible: entry.bottomVisible ?? false,
            closed: (entry.closedTabs ?? []).compactMap(ClosedTab.init(rawValue:)),
            habits: Dictionary(uniqueKeysWithValues: (entry.tabHabits ?? [:]).compactMap { key, value in
                TabKind(rawValue: key).flatMap { kind in TabRegion(rawValue: value).map { (kind, $0) } }
            }))
        if entry.sideTabs == nil, session.gitPanelVisible {
            let pane = session.inspectorPane ?? GitPanelModel.defaultPane
            tabs.side = [.pane(pane)]
            tabs.activeSide = .pane(pane)
        }
        // Whatever the file said, made consistent: the terminal in the main
        // row exactly once, what's in front something the row has, an empty
        // column or strip hidden. See `WorkspaceTabs.normalized`.
        session.workspace = tabs.normalized()
        session.sideColumnWidth = entry.sideColumnWidth
        session.sideColumnLeading = entry.sideColumnLeading ?? false
        // A checkout that's gone (a worktree removed since) is forgotten:
        // the panes follow the terminal again.
        session.gitCheckout = entry.gitCheckout.flatMap {
            FileManager.default.fileExists(atPath: $0) ? $0 : nil
        }
        for (key, address) in entry.browserAddresses ?? [:] {
            if let id = UUID(uuidString: key) { session.browserAddresses[id] = address }
        }
        // A surviving marker means the app died without cleaning up (a crash),
        // and is the most direct evidence. A clean quit leaves none — killing
        // the agent hands control back to the shell, whose last prompt clears
        // it on the way down — so fall back to what we recorded at termination.
        let agent = marker ?? entry.runningAgent.map {
            // No pid: the shell that ran it died with the last launch. Liveness
            // was already checked when this was recorded at quit.
            AgentMarker(agent: $0, model: entry.runningModel,
                        cwd: entry.cwd, argv: entry.runningArgv,
                        shellPID: nil, startedAt: nil)
        }
        // Which conversation to resume, best evidence first. A surviving
        // marker knows when its agent started, and a fresh `claude` creates
        // its transcript at that moment: that is exact, and it is newer than
        // anything saved, which matters after a crash where a new
        // conversation began after the last save. A resume appends instead
        // of creating, so nothing is found and the saved ids stand: the one
        // recorded at quit, else the last one this session was ever seen
        // in, before the newest-file guess as the last resort.
        //
        // The marker's command line counts as evidence too: a resume names
        // its conversation there. And the last id only counts in the
        // directory it belongs to; Claude can't resume it anywhere else.
        //
        // Claude, Pi and Codex alike: see `AgentConversation`.
        var agentIsRunning = false
        let observedID: String? = {
            guard let marker, AgentConversation.exact.contains(marker.agent),
                  let cwd = marker.cwd else { return nil }
            // A surviving marker is an agent still running (the snapshot
            // drops the rest), so whatever it can tell about itself counts.
            var livePID: pid_t?
            if case .running(let pid) = AgentLiveness.locate(
                agent: marker.agent, shellPID: marker.shellPID, table: table()) {
                livePID = pid
                agentIsRunning = true
            }
            return AgentConversation.observe(agent: marker.agent, livePID: livePID, cwd: cwd,
                                             argv: marker.argv, startedAt: marker.startedAt)
        }()
        let resumingAgent = marker?.agent ?? entry.runningAgent
        let lastID = entry.lastConversationID.flatMap { id -> String? in
            guard let agent = resumingAgent, let cwd = marker?.cwd ?? entry.cwd,
                  AgentConversation.exists(agent: agent, id: id, cwd: cwd) else { return nil }
            return id
        }
        let conversationID = observedID ?? entry.runningConversationID ?? lastID
        session.lastConversationID = observedID ?? entry.lastConversationID
        session.portBase = entry.portBase
        // An agent still running is owed nothing: the marker mirrors onto
        // the session below, and its own turns say which conversation it
        // is in. Anything less certain is owed, and the shell decides
        // whether to type it (`Attachment.resumeIsOwed`).
        if let agent, !agentIsRunning,
           let input = AgentResumeStore.resumeInput(for: agent, knownConversationID: conversationID) {
            // It was asleep when this was saved: still asleep, and resumed
            // when the session is selected, not typed with the rest at
            // launch. Only with no marker (the agent really is gone) and its
            // exact conversation still on disk; anything less is an ordinary
            // owed resume, which is what an older build makes of it too.
            if entry.agentAsleep != nil, marker == nil, AgentSleep.enabledAgents.contains(agent.agent),
               let conversationID, input.hasSuffix("\n"), input.contains(conversationID),
               let cwd = agent.cwd, AgentConversation.exists(agent: agent.agent, id: conversationID, cwd: cwd) {
                session.sleep = .asleep(SleepingAgent(
                    marker: agent, conversationID: conversationID, input: input,
                    waiting: entry.agentAsleep == "waiting"))
            } else {
                session.owedResume = OwedResume(agent: agent, conversationID: conversationID, input: input)
            }
        }
        return session
    }

    // MARK: - Live agent activity

    /// Watches the shared `agents/` directory the shell integration writes its
    /// markers into, so the sidebar can show which agent (and model) is running
    /// in each session while it runs. Markers appear at an agent's preexec and
    /// vanish at the next prompt, so a directory change is exactly the moment the
    /// badges need refreshing. Fail-safe: if the watch can't be set up the badges
    /// simply never appear.
    private var agentWatchSource: DispatchSourceFileSystemObject?
    /// False until `restore()` has matched the markers left by agents that
    /// survived the last quit, so those are not reported as started.
    private var agentMarkersBaselined = false

    private func startAgentActivityWatch() {
        HibernationPolicy.shared.onMemoryPressure = { [weak self] in self?.sleepUnderPressure() }
        guard agentWatchSource == nil else { return }
        let dir = AgentResumeStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.refreshAgentActivity() }
        source.setCancelHandler { Darwin.close(fd) }
        agentWatchSource = source
        source.resume()
        refreshAgentActivity()
    }

    /// Re-read all live markers and mirror them onto the sessions. Cheap: the
    /// directory holds at most one tiny file per running agent.
    private func refreshAgentActivity() {
        let live = AgentResumeStore.currentMarkers()
        var changed = false
        for session in sessions {
            let marker = live[session.id]
            let wasRunning = session.runningAgent
            let isNewRun = marker?.agent != wasRunning || marker?.startedAt != session.runningStartedAt
            // Another agent, or none: what the last one was in is no longer
            // this one's, and a lost keeper or a quit may yet owe it a resume.
            if let wasRunning, isNewRun {
                session.endedAgent = AgentConversation.EndedAgent(
                    marker: AgentMarker(agent: wasRunning, model: session.runningModel,
                                        cwd: session.runningCwd ?? session.cwd, argv: session.runningArgv,
                                        shellPID: session.runningShellPID,
                                        startedAt: session.runningStartedAt),
                    conversationID: session.liveConversationID, at: Date())
                session.liveConversationID = nil
            }
            if session.runningAgent != marker?.agent { session.runningAgent = marker?.agent }
            if session.runningModel != marker?.model { session.runningModel = marker?.model }
            session.runningArgv = marker?.argv
            session.runningShellPID = marker?.shellPID
            session.runningStartedAt = marker?.startedAt
            session.runningCwd = marker?.cwd
            if isNewRun {
                changed = true
                session.liveConversationID = nil
            }
            // A run Wortel started itself (a resume it owed and typed) is not
            // one the person started, and the markers already live when this
            // first runs are agents that survived the last quit, counted as
            // `agents_resumed` on launch. Everything else is someone starting
            // an agent.
            var isOwedResume = false
            if let marker, let owed = session.owedResume, AgentConversation.confirms(marker, owed) {
                session.owedResume = nil
                isOwedResume = true
            }
            if let marker, isNewRun, agentMarkersBaselined, !isOwedResume {
                Telemetry.capture(.agentStarted(kind: AgentName(command: marker.agent)))
            }
            if marker != nil, isNewRun { noteConversation(session) }
            if isNewRun { agentRunChanged(session, marker: marker, wasResume: isOwedResume) }
            // An agent launching is the moment to start listening for its first
            // prompt; the same agent exiting, or being replaced, ends the wait.
            if let marker, marker.agent != wasRunning {
                beginPromptCapture(session, marker: marker)
            } else if marker == nil, wasRunning != nil {
                endPromptCapture(session)
                // The marker is cleared at the shell's next prompt, so this
                // *is* the shell back in charge and idle — the backstop that
                // `onCommandFinished` no longer provides while an agent runs
                // (its 133;D goes out before the marker is removed, so that
                // event still arrives with the agent apparently live). The
                // agent's own turn-end quiesce, if one is pending, is not
                // cancelled: an agent that finished a turn and then exited
                // still finished a turn.
                clearBusy(session)
            }
        }
        // Markers appearing/vanishing is exactly when the screen sampler has
        // work to start or stop doing.
        updateAgentScreenSampling()
        // And when what a crash would leave behind changes: a Force Quit takes
        // the keeper with it, and the next launch has only the last save.
        if changed { scheduleSave() }
    }

    // MARK: - Agent screen activity (fallback for agents that emit nothing)

    /// Per-session sampling state. Only holds entries for sessions currently
    /// being watched; the sampler drops a session's state the moment it stops
    /// qualifying, so becoming eligible again always starts from a fresh
    /// baseline and grace window.
    @ObservationIgnored private var agentScreenTrackers: [Session.ID: AgentActivityTracker] = [:]
    /// When a session last produced an explicit signal (OSC progress, title
    /// spinner). Those agents speak for themselves and are left alone — see
    /// `speaksForItself`.
    @ObservationIgnored private var explicitSignalAt: [Session.ID: Date] = [:]
    /// Sessions whose busy state this tier *guessed* from a moving screen,
    /// rather than being told. Only these may be cleared when the tier lets go
    /// of a session (`releaseAgentScreenTracker`), which is the whole reason
    /// the distinction is recorded.
    @ObservationIgnored private var screenInferredBusy: Set<Session.ID> = []
    /// Nil whenever no agent is running anywhere — the common case, and the
    /// reason this costs nothing in an ordinary terminal session.
    @ObservationIgnored private var agentScreenTimer: Timer?
    /// Held while any agent is being watched. Without it, App Nap throttles a
    /// backgrounded app's timers — precisely the situation this whole feature
    /// exists for, since a session you're looking at never needs a
    /// notification. It also keeps the *existing* quiesce timers punctual.
    /// `allowingIdleSystemSleep` because the Mac should still be free to sleep;
    /// we only want to stay awake as long as it is.
    @ObservationIgnored private var agentActivityAssertion: NSObjectProtocol?

    private func noteExplicitSignal(_ session: Session) {
        explicitSignalAt[session.id] = Date()
        // Ownership transfers here: the screen tier guessed busy a moment ago
        // and the program is only now announcing the same turn, so the turn is
        // the program's to end. Without this the tier would still believe the
        // busy was its own and would end it from a quiet screen, mid-turn, right
        // after the program said otherwise — and take `busyStartedAt` with it,
        // so the `9;4;0` at the real end read as too short to be worth a
        // notification and the finished turn went unannounced.
        screenInferredBusy.remove(session.id)
        // A session that just proved it announces itself no longer needs this
        // app kept awake on its behalf. The sampler itself keeps running (see
        // `wantsScreenSampling`) — what changes is only the assertion.
        //
        // Asked every time rather than only on the session's first-ever signal:
        // `explicitSignalAt` outlives an agent run, so the *next* agent to run
        // here finds a key already present and would never have been noticed
        // announcing itself. The check is a handful of dictionary lookups and
        // acts only on a transition.
        updateAgentActivityAssertion()
    }

    /// Whether the agent currently running in `session` has already proved it
    /// announces its own turns (an OSC 9;4 progress report or a title spinner).
    ///
    /// This now decides **cost, not authority**. It used to switch the screen
    /// tier off for the rest of the agent's run, which made it a verdict a
    /// session could never appeal: the proof can come from a subprocess rather
    /// than the agent (`onProgress` cannot tell them apart), and once recorded
    /// nothing ever re-examined it. All it decides now is whether this app stays
    /// awake in the background for that session — see `wantsActivityAssertion`.
    /// Authority belongs to whoever claimed the busy, in `sampleAgentScreensPass`.
    ///
    /// Still sticky rather than a timeout, because the question it answers is
    /// still "does this session have a channel of its own": Claude Code emits
    /// one `9;4;3` per turn with no keepalive, so a minute after a turn ends it
    /// is indistinguishable from an agent that never spoke, and the old timeout
    /// read that silence as a reason to start guessing.
    ///
    /// Proof belongs to one agent run, so it's only honoured when it was
    /// observed after that run started — signals from whatever the session was
    /// doing before the agent launched don't vouch for the agent.
    private func speaksForItself(_ session: Session) -> Bool {
        guard let at = explicitSignalAt[session.id] else { return false }
        guard let started = session.runningStartedAt else { return true }
        return at >= started
    }

    /// Every terminal just repainted for a reason that has nothing to do with
    /// its agent — the window or inspector resized (which re-wraps every
    /// session, visible or not), or focus moved and each TUI answered the focus
    /// report by redrawing. Re-baseline every tracker so that frame is not
    /// counted, and the next sample serves a fresh grace window.
    ///
    /// `rebaseline` rather than dropping the trackers: what a resize invalidates
    /// is the screen, not the verdict. See `AgentActivityTracker.rebaseline`.
    private func rebaselineAgentScreens() {
        guard !agentScreenTrackers.isEmpty else { return }
        AgentStatusLog.log.debug("screen: re-baselining \(self.agentScreenTrackers.count) tracker(s)")
        let now = Date()
        for id in agentScreenTrackers.keys {
            agentScreenTrackers[id]?.rebaseline(now: now)
        }
    }

    /// Let go of a session's tracker, settling what it owes first.
    ///
    /// The tracker holds the `working` flag, and so the `.wentQuiet` that clears
    /// the sidebar spinner. Dropping it while the session is busy is how a
    /// spinner ends up turning forever: the replacement starts at not-working
    /// and can never pay a debt it doesn't know about, and nothing else in the
    /// app ever re-checks a stuck busy. (Selecting the session used to be one
    /// of the reasons a tracker was dropped, which made the stall self-sealing:
    /// the first thing you do when you notice a stuck spinner is click it.)
    ///
    /// Clears silently: this is the tier losing sight of the session, not an
    /// agent finishing, so it must not raise the attention a real quiesce does.
    /// And only a busy this tier inferred — a program's own OSC 9;4 belongs to
    /// the program, and our giving up on watching its screen says nothing at
    /// all about whether it is still working.
    private func releaseAgentScreenTracker(_ session: Session) {
        agentScreenTrackers.removeValue(forKey: session.id)
        guard screenInferredBusy.contains(session.id) else { return }
        AgentStatusLog.log.debug("""
            screen: released a busy tracker for \(session.name, privacy: .private) — clearing
            """)
        clearBusy(session)
    }

    /// The whole tier is shutting down (the last agent marker went away). Same
    /// settle-then-drop as `releaseAgentScreenTracker`, for every session at once.
    private func releaseAllAgentScreenTrackers() {
        for session in sessions where screenInferredBusy.contains(session.id) {
            clearBusy(session)
        }
        agentScreenTrackers.removeAll()
        // Sessions closed while busy never reach the loop above; nothing else
        // prunes this, and a stale id would clear a *future* session's OSC busy
        // if the tier ever let go of it.
        screenInferredBusy.removeAll()
    }

    /// Drop markers whose agent is provably gone, which stops the sampler and
    /// releases the assertion. Fail-open: `AgentLiveness` answers `unknown` when
    /// it can't read enough to be sure, and unknown must never delete a marker
    /// for an agent that is merely hard to see.
    private func sweepDeadAgentMarkers() {
        var removedAny = false
        // One read for every session asked about, as `AgentLiveness` asks of
        // a caller like this one.
        let table = GhosttyRuntime.recentProcessTable()
        for session in sessions where session.runningAgent != nil {
            guard let agent = session.runningAgent else { continue }
            guard !AgentLiveness.isRunning(agent: agent, shellPID: session.runningShellPID,
                                           table: table) else {
                goneSweeps[session.id] = nil // seen alive; any earlier miss was noise
                continue
            }
            // Deleting a marker is irreversible for a running agent — only the
            // shell writes one, at a prompt the agent is holding — so it takes
            // more than one reading. Every way of missing a live process here is
            // transient (a racing sysctl, a pid that moved between the table and
            // the argument read), and every one of them used to cost the session
            // its busy state for the rest of the agent's life. A dead marker
            // surviving one more minute costs a timer that was already running.
            let misses = (goneSweeps[session.id] ?? 0) + 1
            goneSweeps[session.id] = misses
            guard misses >= Self.sweepsBeforeDroppingMarker else {
                AgentStatusLog.log.debug("""
                    \(agent, privacy: .public) unseen \(misses, privacy: .public)x — keeping its marker
                    """)
                continue
            }
            AgentStatusLog.log.debug("dropping stale marker for \(agent, privacy: .public)")
            // The shell went too, not only the agent. Nobody ends a session
            // like that on purpose (an agent you quit hands its shell back to
            // a prompt), so the resume outlives the marker and the next
            // launch brings the agent back. Dropping it with the marker is
            // how a keeper killed under a running app on 2026-10-08 cost
            // every agent its resume. (A session with a terminal on screen
            // hears about its shell itself; see `shellEnded`.)
            if session.surfaceView == nil, session.owedResume == nil,
               let shell = session.runningShellPID, AgentLiveness.shellIsGone(shellPID: shell, table: table),
               let owed = owedResume(forLostShellOf: session, lostAt: Date()) {
                session.owedResume = owed
            }
            AgentResumeStore.remove(sessionID: session.id)
            goneSweeps[session.id] = nil
            removedAny = true
        }
        // Sessions that closed while being counted against would otherwise keep
        // their tally forever, and hand a strike to whatever reuses the id.
        goneSweeps = goneSweeps.filter { id, _ in
            sessions.contains { $0.id == id && $0.runningAgent != nil }
        }
        // Mirrors the markers back onto the sessions, which also stops the
        // sampler and releases the assertion when the last one goes.
        if removedAny { refreshAgentActivity() }
    }

    // MARK: - A keeper lost while the app runs

    /// What happened when the keeper died under a running app, for the one
    /// message that says so. See `keeperDidExit`.
    struct KeeperLoss {
        let at: Date
        /// Terminals whose shell had gone and got a new one.
        let restarted: Int
        /// Of those, the ones whose agent was typed back in.
        let resumed: Int
        /// Terminals whose shell outlived the keeper. They keep working, but
        /// nothing holds them past this app's quit.
        let survived: Int
        /// Whether a new keeper took over. If not, the new shells are the
        /// app's own and end when it quits.
        let keeperBack: Bool
    }

    /// Called once per keeper lost while the app runs, after the terminals
    /// have been dealt with.
    @ObservationIgnored var onKeeperLost: ((KeeperLoss) -> Void)?

    /// The keeper process ended while the app is running.
    ///
    /// Never meant to happen, and on 2026-10-08 it did: something outside the
    /// app (a Force Quit in the Dock, on an app started from one of these
    /// terminals) killed the keeper and every shell and agent with it. The app
    /// noticed nothing, the terminals just stopped, and seven minutes later
    /// the liveness sweep had thrown away every agent's resume. So: start a
    /// new keeper, give every terminal whose shell went with it a new one,
    /// with its agent resumed into the same conversation, and say so.
    ///
    /// **Each terminal comes back when its own shell ends** (`shellEnded`),
    /// not from one look at the process table here. The app holds its own
    /// copy of every pty, so a keeper's death hangs nothing up by itself; the
    /// shells end only as fast as whatever killed the keeper ends them, and an
    /// agent finishing a write can take longer than any fixed wait. On
    /// 2026-10-10 one look half a second in was what this did. A shell that
    /// never ends keeps working on the app's copy, and is told apart at quit.
    func keeperDidExit(pid: pid_t) {
        let at = Date()
        lostKeepers[pid] = KeeperLossTally(at: at)
        NSLog("wortel: keeper %d exited while Wortel was running", pid)
        KeeperLog.log.error("keeper \(pid, privacy: .public) exited while Wortel was running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recoverSessionsNotOnScreen(lostWith: pid)
        }
        // Long enough for every shell that is going to end with it to have
        // ended and come back (`shellEnded` waits a second of its own).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reportKeeperLoss(pid)
        }
    }

    /// What a lost keeper cost and what came back, kept per keeper until it
    /// is reported. See `keeperDidExit`.
    private struct KeeperLossTally {
        let at: Date
        /// Whether a new keeper took over; nil until one was asked for.
        var keeperBack: Bool?
        var restarted = 0
        var resumed = 0
    }

    /// Keepers that died under this launch, by pid. A terminal whose shell
    /// ends is restarted only if the keeper that held it is in here. An entry
    /// goes when its pid is handed to a new keeper: a recycled pid must not
    /// make that keeper's terminals look lost.
    @ObservationIgnored private var lostKeepers: [pid_t: KeeperLossTally] = [:]

    /// Start the keeper that replaces `pid`, once, before the first shell
    /// that needs one. Whichever comes first, a restarted terminal or the
    /// sessions not on screen, asks.
    @discardableResult
    private func replaceKeeper(lost pid: pid_t) -> Bool {
        if let back = lostKeepers[pid]?.keeperBack { return back }
        let back = GhosttyRuntime.reconnectKeeper() != nil
        lostKeepers[pid]?.keeperBack = back
        if let new = GhosttyRuntime.keeper?.keeperPID, new != pid { lostKeepers[new] = nil }
        return back
    }

    /// Sessions with no terminal this launch had their shell in the lost
    /// keeper with nobody reading it. Each gets a new shell when it is first
    /// shown, and this makes that shell resume its agent.
    private func recoverSessionsNotOnScreen(lostWith pid: pid_t) {
        guard let loss = lostKeepers[pid] else { return }
        replaceKeeper(lost: pid)
        for session in sessions where session.surfaceView == nil && session.owedResume == nil {
            guard let owed = owedResume(forLostShellOf: session, lostAt: loss.at) else { continue }
            AgentResumeStore.remove(sessionID: session.id)
            session.owedResume = owed
            lostKeepers[pid]?.resumed += 1
        }
        refreshAgentActivity()
        scheduleSave()
    }

    /// A keeper-held terminal's shell has ended: everything on its tty closed.
    ///
    /// Decided a second later, because two endings look the same here. A
    /// shell that ended with a lost keeper gets a new one, its agent resumed;
    /// one that ended because you typed `exit` ends like any terminal's.
    /// Which keeper went is learned from its own process, and a keeper ending
    /// its shells on the way out can end them before the app hears that it
    /// has gone itself.
    private func shellEnded(_ view: SurfaceView, in session: Session, tab: UUID?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak session, weak view] in
            guard let self, let session, let view else { return }
            // Closed, or already given a new shell, in that second.
            let current: SurfaceView? = if let tab { session.sideSurfaces[tab] } else { session.surfaceView }
            guard current === view else { return }
            guard let keeper = view.keeperPID, let loss = self.lostKeepers[keeper],
                  AgentConversation.restartsAfterLoss(
                      lostAt: loss.at, endedAt: Date().addingTimeInterval(-1),
                      isSessionTerminal: tab == nil, agentRunning: session.runningAgent != nil)
            else {
                view.finishProcess()
                return
            }
            self.replaceKeeper(lost: keeper)
            self.restartTerminal(view, of: session, tab: tab, lostAt: loss.at, keeper: keeper)
        }
    }

    private func restartTerminal(_ view: SurfaceView, of session: Session, tab: UUID?,
                                 lostAt: Date, keeper: pid_t) {
        lostKeepers[keeper]?.restarted += 1
        if let tab {
            view.restartShell(workingDirectory: session.cwd ?? session.originCwd, sessionID: tab,
                              initialInput: nil)
            return
        }
        // A resume already typed is still the one owed until its agent answers
        // or the window passes (`OwedResume.isOwed`); don't replace it with one
        // worked out from this lost shell.
        if session.owedResume?.isOwed(at: Date()) != true,
           let owed = owedResume(forLostShellOf: session, lostAt: lostAt) {
            session.owedResume = owed
        }
        // The new shell's agent writes a marker of its own; this one names a
        // shell that no longer exists.
        AgentResumeStore.remove(sessionID: session.id)
        // Typed again even if it was typed once already: a resume typed into
        // the shell the keeper just took with it (a keeper lost twice in a
        // row) never ran.
        let now = Date()
        let owed = session.owedResume.flatMap { $0.isOwed(at: now) ? $0 : nil }
        if owed != nil {
            session.owedResume?.typedAt = now
            lostKeepers[keeper]?.resumed += 1
        }
        // Where the agent ran, which a `cd x && claude` makes other than
        // where the shell last reported being.
        let directory = owed?.agent.cwd ?? session.cwd ?? session.originCwd
        view.restartShell(workingDirectory: directory, sessionID: session.id, initialInput: owed?.input)
        refreshAgentActivity()
        scheduleSave()
    }

    /// Say what a lost keeper cost and what came back, once. Terminals still
    /// held by it are the ones whose shells outlived it.
    private func reportKeeperLoss(_ pid: pid_t) {
        guard let loss = lostKeepers[pid] else { return }
        let views = sessions.flatMap { [$0.surfaceView].compactMap { $0 } + Array($0.sideSurfaces.values) }
        let survived = views.filter { $0.keeperPID == pid }.count
        let keeperBack = loss.keeperBack ?? replaceKeeper(lost: pid)
        KeeperLog.log.notice("""
            after keeper \(pid, privacy: .public) was lost: \(loss.restarted, privacy: .public) \
            terminals restarted, \(loss.resumed, privacy: .public) agents resumed, \
            \(survived, privacy: .public) survived; new keeper: \(keeperBack, privacy: .public)
            """)
        // Every lost keeper, including one that took nothing with it: how
        // often this happens at all is the number, and the bucket says how bad.
        Telemetry.capture(.keeperLost(sessions: CountBucket(loss.restarted)))
        guard loss.restarted + survived + loss.resumed > 0 else { return }
        onKeeperLost?(KeeperLoss(at: loss.at, restarted: loss.restarted, resumed: loss.resumed,
                                 survived: survived, keeperBack: keeperBack))
    }

    /// What `session` owes the agent its shell was running when that shell
    /// was lost, or nil when no agent was running or it has no way back.
    ///
    /// "Running" includes an agent whose shell cleared its marker in the
    /// moments before the keeper went (`AgentConversation.lostWithKeeper`).
    /// The conversation is what the agent was last seen in while it ran, then
    /// what its files or command line still say, then the one this session
    /// was last seen in (`AgentConversation.afterExit`). Never the newest file
    /// in the folder while anything better is known: that can be another
    /// session's.
    private func owedResume(forLostShellOf session: Session, lostAt: Date) -> OwedResume? {
        let running = session.runningAgent.map {
            AgentMarker(agent: $0, model: session.runningModel, cwd: session.runningCwd ?? session.cwd,
                        argv: session.runningArgv, shellPID: nil,
                        startedAt: session.runningStartedAt)
        }
        guard let (marker, live) = AgentConversation.lostWithKeeper(
            running: running, liveConversationID: session.liveConversationID,
            ended: session.endedAgent, keeperLostAt: lostAt)
        else { return nil }
        session.endedAgent = nil
        var conversationID: String?
        if AgentConversation.exact.contains(marker.agent), let cwd = marker.cwd ?? session.cwd {
            conversationID = AgentConversation.afterExit(
                live: live,
                observed: AgentConversation.observe(
                    agent: marker.agent, livePID: nil, cwd: cwd,
                    argv: marker.argv, startedAt: marker.startedAt),
                last: session.lastConversationID,
                exists: { AgentConversation.exists(agent: marker.agent, id: $0, cwd: cwd) })
        }
        guard let input = AgentResumeStore.resumeInput(for: marker, knownConversationID: conversationID)
        else { return nil }
        if let conversationID { session.lastConversationID = conversationID }
        return OwedResume(agent: marker, conversationID: conversationID, input: input)
    }

    /// Whether any session actually needs its screen read: the same question
    /// the sampler asks per session.
    ///
    /// Any live agent marker is worth watching, including agents that announce
    /// themselves.
    ///
    /// This tier used to stand down the moment a session proved it had a channel
    /// of its own, which made that proof a one-way door: `onProgress` cannot tell
    /// an agent's OSC 9;4 from one emitted by something the agent *ran* (cargo,
    /// mise, systemd and winget all report progress), so a single `cargo build`
    /// through a silent agent's shell tool retired its only busy signal for the
    /// rest of the session. The same door shut on any agent whose title glyph
    /// stopped matching after a restyle, and it never reopened, because nothing
    /// re-examines a session that has been written off.
    ///
    /// Standing down is no longer how this tier stays out of the way. Ownership
    /// is: it claims busy only when nothing else has, and only ever speaks about
    /// a busy it claimed (see `sampleAgentScreensPass`). An agent that reports
    /// its own progress therefore gets sampled and still decides its own state,
    /// while an agent that goes quiet for any reason gets a spinner anyway.
    private var wantsScreenSampling: Bool {
        sessions.contains { $0.runningAgent != nil }
    }

    /// Whether to hold off App Nap for it, which is the part that actually costs
    /// something: without the assertion a backgrounded app's timers are throttled.
    ///
    /// Only a session with no channel of its own earns that, because only there
    /// is this tier the sole source of a *notification*, which has to be punctual
    /// even when the app is buried. For everyone else the tier produces a
    /// spinner, and a spinner nobody can see is not worth a wakeup: an idle agent
    /// left open overnight once kept this app awake until morning watching a
    /// screen it had already been told about.
    ///
    /// Three shapes earn it, and they are all "this tier is the one who has to
    /// say when it ends": a session with no channel of its own; a session whose
    /// busy this tier *claimed*, however it normally announces itself (a
    /// subprocess's progress report can make a silent agent look like a
    /// speaking one, and the assertion must not be fooled along with it); and a
    /// settle window already ticking towards a notification.
    private var wantsActivityAssertion: Bool {
        sessions.contains {
            guard $0.runningAgent != nil else { return false }
            return !speaksForItself($0)
                || screenInferredBusy.contains($0.id)
                || quiesceTimers[$0.id] != nil
        }
    }

    private func updateAgentScreenSampling() {
        let wanted = wantsScreenSampling
        if wanted, agentScreenTimer == nil {
            let timer = Timer.scheduledTimer(
                withTimeInterval: AgentActivity.sampleInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleAgentScreens() }
            }
            // A background poll has no deadline; the tolerance lets the OS
            // coalesce it with other timers instead of waking the CPU alone.
            timer.tolerance = AgentActivity.sampleInterval / 4
            agentScreenTimer = timer
        } else if !wanted, agentScreenTimer != nil {
            agentScreenTimer?.invalidate()
            agentScreenTimer = nil
            releaseAllAgentScreenTrackers()
        }
        // Tracked separately from the timer: which sessions need punctuality can
        // change (an agent announces itself mid-run) without the timer itself
        // starting or stopping.
        updateAgentActivityAssertion()
    }

    /// Take or drop the App Nap assertion to match `wantsActivityAssertion`.
    private func updateAgentActivityAssertion() {
        let wanted = wantsActivityAssertion
        if wanted, agentActivityAssertion == nil {
            agentActivityAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Watching a running agent so its turn-end is noticed promptly")
        } else if !wanted, let assertion = agentActivityAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            agentActivityAssertion = nil
        }
    }

    /// One pass over the sessions worth watching. A session qualifies while an
    /// agent is running in it and it has a live surface; anything else drops its
    /// tracker, so the next qualifying moment re-baselines.
    ///
    /// The session you are looking at is watched like any other. It used to be
    /// skipped, on the grounds that it needs no notification and that your own
    /// typing changes its screen — but the sidebar spinner is not a
    /// notification, and a silent agent (Pi, with its progress reporting off by
    /// default) had no busy state at all in the one session you were watching
    /// it work in. `raiseAttention` already refuses the viewed session; the
    /// typing is handled by `SurfaceView.onUserInput` re-baselining the tracker
    /// on every key, paste, click and scroll, so what you do to the screen is
    /// never counted and only what the program does after you stop is.
    private func sampleAgentScreens() {
        Signposts.interval("agent-screen-sample") { sampleAgentScreensPass() }
    }

    /// Ticks since the last stale-marker sweep. A marker normally vanishes at
    /// the agent's next prompt, and a closed session drops its own, but a shell
    /// killed outright leaves one behind — which would now keep the activity
    /// assertion alive and the sampler running against nothing. Reading the
    /// process table costs a full sysctl, far too much per tick, so it is
    /// checked about once a minute: slow enough to be free, fast enough that a
    /// stale marker can't quietly drain a battery.
    @ObservationIgnored private var livenessTicks = 0

    /// Consecutive sweeps that failed to find each session's agent. Reset the
    /// moment it is seen again, so only a sustained absence is believed.
    @ObservationIgnored private var goneSweeps: [UUID: Int] = [:]

    /// How many sweeps in a row have to miss an agent before its marker goes.
    /// Two, a minute apart: long enough that no single transient read decides
    /// it, short enough that a shell killed outright stops the sampler promptly.
    private static let sweepsBeforeDroppingMarker = 2

    private func sampleAgentScreensPass() {
        let now = Date()
        livenessTicks += 1
        if livenessTicks >= Int(60 / AgentActivity.sampleInterval) {
            livenessTicks = 0
            sweepDeadAgentMarkers()
        }
        for session in sessions {
            // A hibernated terminal has no screen; when it wakes the tracker
            // starts again from what it shows then (incident 2026-08-05).
            guard session.runningAgent != nil, let view = session.surfaceView,
                  !view.isHibernated, !view.isRestoring else {
                releaseAgentScreenTracker(session)
                continue
            }
            guard let digest = view.activeScreenDigest() else { continue }

            var tracker = agentScreenTrackers[session.id] ?? AgentActivityTracker(now: now)
            let event = tracker.sample(digest: digest, now: now)
            agentScreenTrackers[session.id] = tracker

            // Claim busy only when nothing else has. A program that reports its
            // own progress owns its state, and the moving screen this tier can
            // see is that same turn seen a second way — saying so again would
            // put this tier's name on a busy it would then feel entitled to end,
            // which is how a guess gets to overrule the thing it was guessing
            // about. `busyTimers` is checked too because `markBusy` is debounced:
            // a busy can be a runloop turn away from showing and still be
            // somebody's.
            //
            // Level-triggered, not on `.startedWorking`: see `isWorking`. The
            // whole point is the turn where the program's signal drops halfway
            // and the screen keeps moving, which produces no new edge at all.
            if tracker.isWorking, !session.isBusy, busyTimers[session.id] == nil {
                if screenInferredBusy.insert(session.id).inserted {
                    AgentStatusLog.log.debug("""
                        screen: claiming busy (\(session.runningAgent ?? "?", privacy: .public)) \
                        in \(session.name, privacy: .private)
                        """)
                }
                markBusy(session)
            }

            switch event {
            case .wentQuiet:
                // Only ever about a busy this tier claimed. For an agent with a
                // channel of its own, a screen that stops moving is not news:
                // it pauses mid-turn on a slow tool that prints nothing, and
                // announcing a finished turn there would be wrong at the loudest
                // possible moment.
                guard screenInferredBusy.contains(session.id) else { break }
                // The one moment the content itself is worth reading: is the
                // agent blocked on you, or simply done?
                let blocked = view.activeScreenTail().map(AgentPrompt.looksBlocked) ?? false
                AgentStatusLog.log.debug("""
                    screen: quiet, blocked=\(blocked, privacy: .public) \
                    (\(session.runningAgent ?? "?", privacy: .public)) \
                    in \(session.name, privacy: .private)
                    """)
                progressEnded(session, inferred: blocked ? .needsInput : .turnDone, source: "screen",
                              corroborating: speaksForItself(session), guessed: true)
            case .startedWorking, nil:
                // The start edge is not acted on here; the claim above reads the
                // level, so it covers this sample and every one after it.
                break
            }
        }
        // Claims come and go inside this loop, and a claimed busy is one this
        // tier has to see through to its end on time (see `wantsActivityAssertion`).
        updateAgentActivityAssertion()
    }

    // MARK: - Operations

    /// Create a session and select it, in the directory the request implies.
    ///
    /// Four answers, in order, and the order is the whole design:
    ///
    /// 1. **An explicit `cwd`.** The CLI's `--cwd`, a worktree checkout, the
    ///    directory ⌘O just picked. Somebody named a path; nothing outranks that.
    /// 2. **The named folder's directory.** `folder` is only ever passed when
    ///    the request was *about* that folder ("New Session in “GFPC”"), and
    ///    what it means is GFPC. This is the case that used to be silently
    ///    wrong: the session was filed under GFPC and started wherever the
    ///    selection was standing, which looked exactly like it had worked.
    /// 3. **The selected session's folder's directory.** This is the "same
    ///    folder as the one I'm in" case, which is why a plain ⌘N stays next to
    ///    what you're looking at — and *the folder* is what "next to" means, not
    ///    the selected session's own checkout. A worktree session lives in
    ///    ~/.wortel/worktrees/…, and inheriting that put a plain ⌘N inside the
    ///    worktree, on the branch's files, when what was asked for was another
    ///    shell in the project. The worktree is one session's business; the
    ///    folder's root is the project's.
    /// 4. **Where the selected session was born**, not where it is now, for a
    ///    session whose folder is still just a label or that is filed at the
    ///    top level. `cwd` follows every `cd`, so inheriting it meant a session
    ///    opened beside one you'd taken three levels deep started three levels
    ///    deep too, and the next one inherited that. `originCwd` is the
    ///    deliberate answer and doesn't drift.
    ///
    /// Falling off the end is `nil`, which lets `wortel.conf`'s
    /// `working-directory = home` answer — a first launch has no session to
    /// inherit from and starts at home, as it always has.
    ///
    /// `via` is reported and nothing else: it is the only way to learn whether
    /// the `wortel` command is used by anyone, which is the whole premise of
    /// shipping a socket instead of per-agent integrations. It defaults to the
    /// menu because that is what an unannotated caller is.
    @discardableResult
    func newSession(cwd: String? = nil, inFolder folder: String? = nil,
                    via origin: SessionOrigin = .menu, starting start: SessionStart) -> Session {
        // New sessions land next to what you're looking at: the explicit folder
        // (header context menu) or the selected session's folder, else top level.
        let dir = folder ?? selected?.folderPath
        // Each remembered answer is checked before it's used, so a project that
        // moved on disk falls through to the next one rather than starting a
        // shell in a directory that isn't there. An explicit `cwd` isn't: the
        // caller named it, the CLI already validates it, and a worktree path is
        // one git just wrote.
        let directory = cwd
            ?? existingDirectory(root(ofFolder: folder))
            ?? existingDirectory(root(ofFolder: selected?.folderPath))
            ?? existingDirectory(selected?.originCwd)
        // Through `prepare`, because selecting the row starts its shell, and
        // that is before this returns.
        return makeSession(cwd: directory, inFolder: dir, via: origin, starting: start)
    }

    /// A session in the home directory, deliberately outside every folder.
    ///
    /// Home is not a project, so filing it under whichever folder you happened
    /// to be looking at would put a `~` row inside "Wortel". This is the escape
    /// hatch from inheritance: one keystroke back to the top, from anywhere,
    /// without a `cd` and without a folder to point at first.
    @discardableResult
    func newHomeSession(via origin: SessionOrigin = .home, starting start: SessionStart) -> Session {
        makeSession(cwd: NSHomeDirectory(), inFolder: nil, via: origin, starting: start)
    }

    /// The shared tail of every way a session is made, taking a directory and
    /// a folder that have both already been decided, so "which folder" can't
    /// quietly pick up `newSession`'s inherit-from-the-selection rule on a path
    /// that decided otherwise.
    ///
    /// `start` is what the new shell is given to run: Settings' command,
    /// nothing, or a line of the caller's own (`SessionStart`). Read here and
    /// nowhere else, when the row is made, so a worktree session that is
    /// still being prepared keeps the answer it was made with.
    private func makeSession(
        cwd directory: String?, inFolder dir: String?, via origin: SessionOrigin,
        starting start: SessionStart, reported: Bool = true, prepare: ((Session) -> Void)? = nil
    ) -> Session {
        let preferred = AppSettings.shared.newSessionCommand
        let usesCommand = start.usesPreferredCommand(stored: preferred)
        // Named for where it is, not for what number it is. "Session 3" tells you
        // nothing, and it's what a session is stuck with until an agent turn ends
        // and the model gets a look — on a machine without Apple Intelligence,
        // forever. The directory is known at creation and is nearly always the
        // answer you'd have typed. Auto-naming still overrides it later: a
        // directory name isn't user-set.
        let leaf = uniqueLeaf(Self.defaultName(forCwd: directory), in: dir)
        let session = Session(name: dir.map { "\($0)/\(leaf)" } ?? leaf, cwd: directory)
        session.title = Self.defaultTitle(forCwd: session.cwd)
        noteCheckout(session)
        session.portBase = PortBlock.allocate(for: session.id, taken: Set(sessions.compactMap(\.portBase)),
                                              isFree: PortBlock.isFree)
        wire(session)
        // Before it's selected: selecting is what starts a shell, and a row
        // waiting on its worktree must not get one. A shell started there with
        // no directory yet came up in the keeper's, `/`, and the worktree it
        // was waiting for arrived too late to move it.
        session.startupInput = start.input(preferred: preferred)
        session.startedWithSettingsCommand = usesCommand
        session.createdAt = Date()
        prepare?(session)
        // Where it goes in the stored order, which is what a Manual section
        // draws (a sorted one puts it by its sort: on top, for Recent and
        // Created). At the top level, on top: a list nobody
        // arranges then reads newest first, as a list of chats does. In a folder, right after the selected
        // row when that row is in the same folder, otherwise at the folder's
        // end: a folder is arranged by hand, and the new row belongs beside
        // the one it came from. A pinned row is drawn in Pinned, not in its
        // folder, so it is no anchor for one.
        let index = SidebarLayout.indexForNew(
            inFolder: dir, rows: sessions.map { SidebarLayout.Row(id: $0.id, folder: $0.folderPath) },
            selected: selectedID, pinned: pinnedIDs)
        sessions.insert(session, at: index)
        let madeFrom = selectedID
        normalizeOrder() // slot the new row into its folder's contiguous block
        // Never select into a hidden row.
        if let dir { collapsedFolders.remove(dir) } else { setLooseCollapsed(false) }
        selectedID = session.id
        // After the selection moved, which forgot the last one.
        justMade = madeFrom.map { (session: session.id, from: $0) }
        scheduleSave()
        if reported { Telemetry.capture(.sessionCreated(via: origin, command: usesCommand)) }
        return session
    }

    /// Open `path` as a session: ⌘O, and the only way to reach a directory that
    /// no session is standing in without typing `cd`.
    ///
    /// The session is filed into the folder that already covers `path` —
    /// deepest root wins, so opening `wortel/web` lands in "Web" rather than
    /// "Wortel" when both exist. Only when nothing covers it does this create a
    /// folder, named for the directory and pointed at it, which is how a folder
    /// comes to have a directory without anyone visiting a menu.
    ///
    /// **A linked worktree goes with its repository**, whoever made it. One
    /// beside the repository (`~/work/repo-feature`) is covered by no folder
    /// of the repository's, so it would have become a folder of its own, or
    /// joined `~/work`'s; it joins the repository's folder when that root is
    /// the deeper match, or makes one for the repository. It's named for its
    /// branch, as Wortel's own worktree sessions are.
    @discardableResult
    func openFolder(_ path: String, via origin: SessionOrigin = .openFolder,
                    starting start: SessionStart) -> Session {
        let path = FolderRoot.normalize(path) ?? path
        let linked = GitWorktree.linked(containing: path)
        let target = folder(forDirectory: path)
        if let linked, linked.repoHome.flatMap(FolderRoot.normalize) != nil {
            let branch = GitWorktree.checkedOutBranch(at: linked.root)
            let leaf = branch.map(GitWorktree.sessionLeaf(forBranch:)).map { uniqueLeaf($0, in: target) }
            return makeSession(cwd: path, inFolder: target, via: origin, starting: start) { [target] session in
                if let leaf { session.name = target.map { "\($0)/\(leaf)" } ?? leaf }
                session.worktreeBranch = branch
            }
        }
        // The deepest folder covering it, or a new one named for it; `/` gets
        // a session and no folder (see `folder(forDirectory:)`).
        guard let target else { return makeSession(cwd: path, inFolder: nil, via: origin, starting: start) }
        return newSession(cwd: path, inFolder: target, via: origin, starting: start)
    }

    /// The folder for a worktree at `path`: the deepest root covering it, or
    /// its repository's folder where that root is deeper. A folder made for
    /// the worktree itself still wins, being deepest of all.
    private func folder(forWorktreeAt path: String, repoHome: String) -> String? {
        let direct = FolderRoot.folder(containing: path, in: folderRoots)
        guard let viaRepo = FolderRoot.folder(containing: repoHome, in: folderRoots) else { return direct }
        guard let direct else { return viaRepo }
        let depth = { (folder: String) in self.folderRoots[folder]?.count ?? 0 }
        return depth(viaRepo) > depth(direct) ? viaRepo : direct
    }

    /// Continue in a worktree that's already on disk: the session already
    /// standing in it if there is one, else the one archived there, else a
    /// new one, filed with its repository (`openFolder`).
    @discardableResult
    func openWorktree(at path: String) -> Session? {
        let root = GitWorktree.realPath(path)
        if let open = sessions.first(where: {
            $0.preparation == nil && ($0.linkedCheckout?.root == root || $0.homeCheckout?.root == root)
        }) {
            selectedID = open.id
            return open
        }
        if let item = archived.first(where: { GitWorktree.realPath($0.checkout) == root }) {
            return restore(archived: item.id)
        }
        // Gone since it was listed: a session there would start in `/`.
        guard FileManager.default.fileExists(atPath: root) else { return nil }
        return openFolder(root, starting: .preferred)
    }

    /// `base`, or `base 2`, `base 3`… — the first that no session in `folder`
    /// is already using. Two shells open in one repo are the common case, and
    /// two identical rows would be worse than the numbers this replaces.
    private func uniqueLeaf(_ base: String, in folder: String?) -> String {
        let taken = Set(sessions.filter { $0.folderPath == folder }.map(\.leafName))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Open a session on `branch`, in its own worktree.
    ///
    /// The point is several agents in one repository at once: each gets its own
    /// branch *and* its own files, so they can't edit over each other and no one
    /// changes the ground under a running agent by switching branches. A
    /// worktree rather than a clone — history, objects and remotes stay shared,
    /// so this costs a directory rather than a copy of the repo.
    ///
    /// Reuses the worktree if that branch already has one: creating a session
    /// for a branch you already have open should land you in it, not fail with
    /// git's "already checked out" — which is the same rule as double-clicking a
    /// file that already has a preview window.
    ///
    /// A refusal is git's own message, shown verbatim: "already checked out
    /// at …" and "not a valid object name" each tell you exactly what to do
    /// next, and a paraphrase would drop the path.
    ///
    /// **The session is there before its worktree is.** Its row appears and is
    /// selected at once, its page says the worktree is being prepared, and the
    /// shell starts when git is done; meanwhile every other session works as
    /// usual. In a large repository the checkout takes most of a minute, and
    /// it used to happen with nothing on screen and end, as often as not, in
    /// an alert. A refusal now stays on the session's own page, with git's
    /// words and a way to try again (`retryWorktree`), until it's closed.
    ///
    /// The CLI keeps `openSession`: it answers with the session's id, which
    /// can only be given once there is a session to name.
    ///
    /// `after` is a fetch to give a few seconds first, so a new branch forks
    /// from where the remote is now (see `newSessionOnBranch`); the session is
    /// on screen while it runs.
    @discardableResult
    func newSession(onBranch branch: String, base: String? = nil, from: String?,
                    inFolder folder: String? = nil, after fetch: Task<Void, Never>? = nil,
                    starting start: SessionStart, completion: WorktreeCompletion? = nil) -> Session? {
        let branch = GitWorktree.branchName(from: branch)
        guard !branch.isEmpty, let from else { return nil }
        return beginWorktreeSession(.branch(branch, base: base), branch: branch,
                                    leaf: GitWorktree.sessionLeaf(forBranch: branch),
                                    from: from, inFolder: folder, after: fetch,
                                    starting: start, completion: completion)
    }

    /// A session on pull request `pr`, in a worktree of its own on
    /// `worktree/pr-<n>`: the sheet given `#123` or a URL, or `wortel new --pr`.
    @discardableResult
    func newSession(onPullRequest pr: PullRequestRef, from: String?, inFolder folder: String? = nil,
                    after fetch: Task<Void, Never>? = nil, starting start: SessionStart,
                    completion: WorktreeCompletion? = nil) -> Session? {
        guard let from else { return nil }
        return beginWorktreeSession(.pullRequest(pr), branch: pr.branch,
                                    leaf: GitWorktree.sessionLeaf(forBranch: pr.branch),
                                    from: from, inFolder: folder, after: fetch,
                                    starting: start, completion: completion)
    }

    /// What a caller waiting on a worktree session hears once it's ready: the
    /// session, or why there isn't one, and the warnings from the way there.
    /// The CLI is that caller; the sheet isn't, it has the page.
    typealias WorktreeCompletion = (Result<Session, Failure>, [String]) -> Void
    @ObservationIgnored private var worktreeCompletions: [Session.ID: WorktreeCompletion] = [:]

    /// The row, on screen at once, for a worktree git hasn't made yet: it says
    /// it's preparing on its own page, and becomes a terminal when git is done.
    private func beginWorktreeSession(
        _ request: WorktreePreparation.Request, branch: String?, leaf: String, from: String,
        inFolder folder: String?, after fetch: Task<Void, Never>?, starting start: SessionStart,
        completion: WorktreeCompletion?
    ) -> Session {
        let session = makeSession(cwd: nil, inFolder: folder ?? self.folder(forRepositoryAt: from),
                                  via: .worktree, starting: start, reported: false) { session in
            session.name = session.folderPath.map { "\($0)/\(leaf)" } ?? leaf
            session.worktreeBranch = branch
            session.preparation = WorktreePreparation(request: request, from: from, branch: branch ?? "")
        }
        if let completion { worktreeCompletions[session.id] = completion }
        prepareWorktree(for: session, after: fetch)
        return session
    }

    /// The folder a new worktree of the repository at `directory` is filed
    /// in, when the caller named none: the one covering the repository (or
    /// the worktree itself), else the folder of a session already in that
    /// repository, else one made for it, as ⌘O makes one. Never the selected
    /// row's: that's how a worktree of one project landed in another's folder.
    private func folder(forRepositoryAt directory: String) -> String? {
        guard let home = GitWorktree.repositoryHome(containing: directory) else { return nil }
        if let covering = folder(forWorktreeAt: directory, repoHome: home) { return covering }
        let inRepository = sessions.first { session in
            guard session.folderPath != nil else { return false }
            if let other = session.linkedCheckout?.repoHome { return other == home }
            return session.originCwd.map { FolderRoot.root(home, contains: GitWorktree.realPath($0)) } ?? false
        }
        if let folder = inRepository?.folderPath { return folder }
        let leaf = (home as NSString).lastPathComponent
        guard leaf != "/", !leaf.isEmpty, home != NSHomeDirectory() else { return nil }
        let folder = addFolder(named: leaf)
        setRoot(home, ofFolder: folder)
        return folder
    }

    /// Ask git again for a session whose worktree it refused, as it was asked
    /// the first time.
    func retryWorktree(_ session: Session) {
        guard session.preparation?.failure != nil, session.preparation?.worktreeExists == false else { return }
        session.preparation?.failure = nil
        prepareWorktree(for: session)
    }

    /// Open the worktree the page has been holding: past its warnings, or as
    /// it is after a step that came after `worktree add` failed.
    func openPreparedWorktree(_ session: Session) {
        guard let resolved = session.preparation?.resolved else { return }
        attachWorktree(session, resolved)
    }

    /// The whole way from the request to a terminal: wait (briefly) for the
    /// fetch, find or make the worktree, seed a new one, then attach. Every
    /// step after the first `await` checks the row is still there: closed
    /// while git worked, the worktree stays, as any does, and nothing comes
    /// back to life.
    private func prepareWorktree(for session: Session, after fetch: Task<Void, Never>? = nil) {
        guard let preparation = session.preparation else { return }
        Task { [weak self] in
            if let fetch {
                session.preparation?.stage = .fetching
                await fetch.finishing(within: .seconds(3))
            }
            session.preparation?.stage = .checkingOut
            guard let self else { return }
            let result = await self.resolveWorktree(preparation.request, from: preparation.from,
                                                    for: session)
            guard self.sessions.contains(where: { $0 === session }) else { return }
            let resolved: ResolvedWorktree
            switch result {
            case .failure(let failure):
                session.preparation?.failure = failure.message
                self.finishWorktreeSession(session, .failure(failure), warnings: [])
                return
            case .success(let worktree):
                resolved = worktree
            }
            if let branch = resolved.branch { session.preparation?.branch = branch }
            var warnings = resolved.notes
            if resolved.created {
                session.preparation?.stage = .copying
                let report = await WorktreeInclude.copy(from: resolved.sourceRoot, to: resolved.path)
                warnings += report.warnings
                guard self.sessions.contains(where: { $0 === session }) else { return }
            }
            // A caller waiting on this (the CLI) is told the warnings; the
            // page, which is all the sheet has, holds them until they're read.
            if warnings.isEmpty || self.worktreeCompletions[session.id] != nil {
                self.attachWorktree(session, resolved, warnings: warnings)
            } else {
                session.preparation?.resolved = resolved
                session.preparation?.warnings = warnings
            }
        }
    }

    /// Give a waiting row its worktree: the terminal starts there.
    private func attachWorktree(_ session: Session, _ resolved: ResolvedWorktree, warnings: [String] = []) {
        guard sessions.contains(where: { $0 === session }) else { return }
        session.cwd = resolved.path
        session.originCwd = resolved.path
        session.worktreeBranch = resolved.branch
        noteCheckout(session)
        session.preparation = nil
        Telemetry.capture(.sessionCreated(via: .worktree, command: session.startedWithSettingsCommand))
        // Its shell starts here when it's the one on screen; otherwise when
        // it's next selected, as a restored session's does. Unless it was
        // given a command (`wortel new -- …`, or the one in Settings): a
        // caller is told it started, and a command waiting for a click is
        // one a quit would lose.
        if session.id == selectedID || session.startupInput != nil {
            session.ensureSurfaceView(runtime: runtime)
        }
        scheduleSave()
        refreshWorktreeListings()
        // Named while it was preparing (by you, or the CLI): the branch
        // couldn't be renamed then, there was none yet.
        nameBranchForWork(session)
        finishWorktreeSession(session, .success(session), warnings: warnings)
    }

    /// Tell a waiting caller how it went. A caller that asked from outside
    /// (the CLI) gets no row for a refusal: it has the message, and a script
    /// that fails shouldn't leave a page behind in the sidebar.
    private func finishWorktreeSession(_ session: Session, _ result: Result<Session, Failure>,
                                       warnings: [String]) {
        guard let completion = worktreeCompletions.removeValue(forKey: session.id) else { return }
        if case .failure = result { close(session) }
        completion(result, warnings)
    }

    /// Why a session couldn't be opened, in words meant to be shown as they are.
    /// Usually git's own message — "already checked out at …" and "not a valid
    /// object name" each tell you exactly what to do next, and a paraphrase
    /// would drop the path.
    struct Failure: Error {
        let message: String
    }

    /// Find or make the worktree `request` asks for, in the repository `cwd`
    /// is in.
    ///
    /// For a branch, `base` is the ref a *new* one forks from, and is ignored
    /// for one that already exists — that branch has its own history, and
    /// there is nothing to fork.
    ///
    /// nil means the repository's default branch, not HEAD. A caller that didn't
    /// say means trunk far more often than it means "wherever this happens to be
    /// standing", and HEAD is exactly the answer that made a new branch inherit
    /// whichever worktree the request came from. Saying `HEAD` explicitly still
    /// works and is how you stack onto the current branch on purpose.
    ///
    /// `cwd` is the caller's: the CLI passes its own working directory, which
    /// is the whole point of running the command *somewhere*: a script in one
    /// repo must not open a worktree of whichever repo the sidebar happens to
    /// be pointing at.
    private func resolveWorktree(_ request: WorktreePreparation.Request, from cwd: String,
                                 for session: Session) async -> Result<ResolvedWorktree, Failure> {
        switch request {
        case .branch(let branch, let base):
            return await resolveWorktree(onBranch: branch, base: base, from: cwd)
        case .pullRequest(let pr):
            return await resolvePullRequest(pr, from: cwd)
        }
    }

    /// A pull request's worktree, with plain git: the forge publishes every
    /// pull request's head under a ref of its own, forks' included.
    ///
    /// One pushed from this repository's own remote is checked out *as its
    /// branch*, tracking, so Push works from the session; one from a fork has
    /// no branch here to track, and lands on `worktree/pr-<n>`. Fetched without
    /// force, so commits made on that branch here are never lost to a
    /// force-push: the copy here is kept, and said so.
    private func resolvePullRequest(_ pr: PullRequestRef, from cwd: String) async
        -> Result<ResolvedWorktree, Failure> {
        guard let root = await GitService.repoRoot(for: cwd) else {
            return .failure(Failure(message: "\(cwd) isn't inside a git repository."))
        }
        let names = await GitService.run(["remote"], in: root).stdout
            .split(separator: "\n").map(String.init)
        var urls: [String: String] = [:]
        for name in names {
            urls[name] = await GitService.run(["remote", "get-url", name], in: root).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let remote: String
        if pr.host != nil {
            guard let match = names.first(where: { urls[$0].map(pr.matches(remoteURL:)) ?? false }) else {
                return .failure(Failure(message: """
                    No remote of this repository points at \(pr.host ?? "")/\(pr.path ?? "").
                    """))
            }
            remote = match
        } else {
            // Trunk's remote, which is `upstream` in a fork's checkout: that
            // is where the project's pull requests are, not your fork.
            let trunk = await GitService.defaultBase(root: root)
            let trunkRemote = trunk.flatMap { $0.split(separator: "/").first.map(String.init) }
            if let trunkRemote, names.contains(trunkRemote) {
                remote = trunkRemote
            } else if names.contains("origin") {
                remote = "origin"
            } else if let first = names.first {
                remote = first
            } else {
                return .failure(Failure(message: "This repository has no remote to fetch \(pr.label) from."))
            }
        }
        let ref = pr.ref(remoteURL: urls[remote])
        let branch = pr.branch
        let existing = await GitService.worktrees(root: root)
        if let match = existing.first(where: { $0.branch == branch && !$0.isPrunable }) {
            return .success(ResolvedWorktree(path: match.path, branch: branch, sourceRoot: root, created: false))
        }
        let listed = await GitService.run(["ls-remote", remote, ref], in: root, timeout: GitService.networkTimeout)
        guard listed.ok, let sha = listed.stdout.split(separator: "\t").first.map(String.init), !sha.isEmpty else {
            return .failure(Failure(message: listed.ok
                ? "\(remote) has no pull request \(pr.label)."
                : GitMessage.readable(listed.stderr, while: .worktree(branch: branch))))
        }
        // Pushed from this repository: check out its own branch, as typing
        // its name would.
        let pointing = await GitService.run(
            ["for-each-ref", "--points-at", sha, "--format=%(refname:short)", "refs/remotes/\(remote)/"],
            in: root).stdout.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
        if pointing.count == 1, let tracking = pointing.first {
            let local = String(tracking.dropFirst(remote.count + 1))
            return await resolveWorktree(onBranch: local, base: nil, from: cwd)
        }
        var notes: [String] = []
        let fetched = await GitService.run(["fetch", "--no-tags", remote, "\(ref):refs/heads/\(branch)"],
                                           in: root, timeout: GitService.networkTimeout)
        let haveBranch = await GitService.localBranches(root: root).contains { $0.name == branch }
        if !fetched.ok {
            guard haveBranch else {
                return .failure(Failure(message: GitMessage.readable(fetched.stderr, while: .worktree(branch: branch))))
            }
            let rejected = fetched.stderr.contains("non-fast-forward") || fetched.stderr.contains("rejected")
            notes.append(rejected
                ? "Pull request \(pr.label) was force-pushed since the copy here was made, so this opens that copy."
                : "Couldn't fetch pull request \(pr.label), so this opens the copy here from before.")
        }
        let path = await Self.newWorktreePath(forBranch: branch, repoRoot: existing.first(where: \.isPrimary)?.path ?? root)
        if let error = await GitService.addWorktree(root: root, at: path, branch: branch, source: .existingBranch) {
            return .failure(Failure(message: GitMessage.readable(error, while: .worktree(branch: branch))))
        }
        return .success(ResolvedWorktree(path: path, branch: branch, sourceRoot: root, created: true, notes: notes))
    }

    /// Where a worktree Wortel is about to create goes (`GitWorktree.newWorktreePath`):
    /// never a folder Claude already keeps a conversation history for, since
    /// a new session there would be offered the old one.
    /// In the repository's own location when it names one (`GitWorktree.locationKey`).
    private static func newWorktreePath(forBranch branch: String, repoRoot: String) async -> String {
        // A bare clone's worktrees are named for the folder holding it
        // (`repo/.bare` is "repo"), as everything else here names them.
        let repoRoot = (repoRoot as NSString).lastPathComponent == ".bare"
            ? (repoRoot as NSString).deletingLastPathComponent : repoRoot
        let location = await GitService.worktreeLocation(root: repoRoot)
        return GitWorktree.newWorktreePath(forBranch: branch, repoRoot: repoRoot, location: location) { path in
            !AgentResumeStore.claudeProjectDirectories(for: path).isEmpty
        }
    }

    private func resolveWorktree(onBranch branch: String, base: String?, from cwd: String) async
        -> Result<ResolvedWorktree, Failure> {
        // Made into a name git accepts ("Jump to" → "Jump-to"), here where the
        // sheet, the menu and `wortel new --branch` all arrive.
        let branch = GitWorktree.branchName(from: branch)
        guard !branch.isEmpty else { return .failure(Failure(message: "No branch given.")) }
        guard let root = await GitService.repoRoot(for: cwd) else {
            return .failure(Failure(message: "\(cwd) isn't inside a git repository."))
        }
        let existing = await GitService.worktrees(root: root)
        // **The repository, not this checkout.** `rev-parse --show-toplevel`
        // inside a linked worktree answers with the *worktree's* path, so a
        // session created from a worktree session would have grouped the new
        // one under the old branch's directory —
        // ~/.wortel/worktrees/feature-x/other rather than
        // ~/.wortel/worktrees/repo/other. The primary worktree is always the
        // first git lists.
        let repoRoot = existing.first(where: \.isPrimary)?.path ?? root
        let path: String
        var created = false
        // A registration whose folder is gone isn't somewhere to open a
        // session (its shell would start in `/`): the branch is checked out
        // again in a new folder, and `addWorktree` drops the stale record.
        if let match = existing.first(where: { $0.branch == branch && !$0.isPrunable }) {
            path = match.path
        } else {
            path = await Self.newWorktreePath(forBranch: branch, repoRoot: repoRoot)
            // A branch that exists gets checked out; one that doesn't is created
            // from `base` — or from HEAD when the caller named none, which is
            // what "new session on a new branch" means when you're standing on
            // the branch you want to fork.
            //
            // Naming a base also takes the *worktree you launched from* out of
            // the answer. `repoRoot(for:)` resolves to the linked worktree when
            // the selected session is in one, so `git worktree add -b … HEAD`
            // runs there and forks that branch — which is why a "new" branch
            // could silently inherit `update-website` instead of trunk. A ref
            // resolves the same in every worktree of the repository.
            let known = await GitService.localBranches(root: root)
                .contains { $0.name == branch }
            // **A branch that exists only on a remote is an existing branch.**
            // Treating it as a new one is the bug this guards: typing a
            // colleague's branch name produced a *new* branch forked from trunk
            // wearing their name, with none of their commits and no upstream,
            // and nothing on screen said so. `worktree add <path> <name>` with
            // no `-b` is git's own answer — it creates the local branch at the
            // remote one and sets it to track, which is what checking out
            // someone's branch has always meant.
            let onRemotes = known
                ? []
                : await GitService.remotesWithBranch(root: root, branch: branch)
            // Two remotes carrying the name is the one case git handles badly:
            // it refuses, with "invalid reference", which is also what it says
            // for a branch that doesn't exist anywhere. Answering it here costs
            // one message and keeps that distinction.
            //
            // **Unless git has been told which remote wins.** Someone working
            // against a fork sets `checkout.defaultRemote` precisely because
            // `origin` and `upstream` carry the same names, and with it set git
            // resolves the branch and sets up tracking without complaint. So the
            // ambiguity is only ambiguous when git has no answer either;
            // refusing regardless would break a case that works and, worse,
            // answer it with advice ("check out the one you want first") aimed
            // at a problem that person does not have.
            // A remote named with the branch settles it.
            let named = base.flatMap { base in
                onRemotes.first { base == "\($0)/\(branch)" }.map { _ in base }
            }
            if named == nil, onRemotes.count > 1,
               await GitService.defaultRemote(root: root).map({ !onRemotes.contains($0) }) ?? true {
                return .failure(Failure(message: """
                    \u{201c}\(branch)\u{201d} exists on more than one remote \
                    (\(onRemotes.joined(separator: ", "))). Check out the one \
                    you want first, then open a session on it.
                    """))
            }
            // A repository with no commits has a HEAD that resolves to
            // nothing, so it can't be a base — git infers an orphan branch
            // instead, which is exactly right for a first branch in a fresh
            // repo. Handing it `HEAD` regardless is what made "git init and
            // then a session" fail with `invalid reference: HEAD`, and a named
            // base is no better: there is no ref for it to be.
            let source: GitService.WorktreeSource
            if let named {
                source = .remoteBranch(named)
            } else if known || onRemotes.count == 1 {
                source = .existingBranch
            } else if await GitService.hasCommits(root: root) {
                // Resolved in steps rather than with `??`, which can't carry an
                // `await` on its right. The final `"HEAD"` is for a repository
                // that has commits but no branch this can name — nothing to fork
                // from but where we are.
                var resolved = base
                if resolved == nil { resolved = await GitService.defaultBase(root: root) }
                source = .newBranch(from: resolved ?? "HEAD")
            } else {
                source = .newBranch(from: nil)
            }
            if let error = await GitService.addWorktree(
                root: root, at: path, branch: branch, source: source) {
                return .failure(Failure(message: GitMessage.readable(error, while: .worktree(branch: branch))))
            }
            created = true
        }
        return .success(ResolvedWorktree(path: path, branch: branch, sourceRoot: root, created: created))
    }

    /// The directory "New Session on Branch…" takes its repository from,
    /// decided once when it starts so the dialog, the fetch and the worktree
    /// all agree, and before the new row takes the selection over.
    ///
    /// A row's own menu means that row. A folder's means the folder: the
    /// selected session if it's in that folder (it's the one you're looking
    /// at), else the folder's directory, else where its sessions are. Before
    /// this, a folder's menu forked whichever repository the selected session
    /// happened to be in, and filed the result under the folder you clicked.
    /// Otherwise it's the selected session. A session still preparing has no
    /// directory yet, but knows where it came from: forking beside it means
    /// the same repository.
    func branchSource(for session: Session? = nil, inFolder folder: String? = nil) -> String? {
        // Where the session belongs, not where its shell wandered: a `cd`
        // into another repository, a submodule or `~` would otherwise make a
        // worktree of the wrong one. The shell's own directory while it's
        // inside the one the session started in (the same checkout, deeper),
        // or when it started at home, which is no project at all.
        func directory(of session: Session) -> String? {
            guard let origin = session.originCwd, origin != NSHomeDirectory() else {
                return session.cwd ?? session.originCwd ?? session.preparation?.from
            }
            if let cwd = session.cwd, FolderRoot.root(origin, contains: cwd) { return cwd }
            return origin
        }
        if let session { return directory(of: session) }
        if let folder, selected?.folderPath != folder {
            if let root = existingDirectory(root(ofFolder: folder)) { return root }
            if let inside = sessions.first(where: { $0.folderPath == folder && directory(of: $0) != nil }) {
                return directory(of: inside)
            }
        }
        return selected.flatMap(directory(of:))
    }

    /// Local branches of the repository at `cwd`, most recently
    /// committed first — the order a picker wants, since the branch you mean is
    /// nearly always one you touched recently. Empty outside a repository.
    func localBranches(in cwd: String?) async -> [GitBranch] {
        guard let cwd,
              let root = await GitService.repoRoot(for: cwd) else { return [] }
        return await GitService.localBranches(root: root)
    }

    /// The remote-tracking branches, for the picker to fill in once it is up.
    ///
    /// Separate from `localBranches` because it is separately expensive: it is
    /// the one list whose size tracks the repository rather than the person
    /// using it, so it is asked for after the sheet is on screen and never on
    /// the way to putting it there.
    func remoteBranches(in cwd: String?) async -> [GitBranch] {
        guard let cwd,
              let root = await GitService.repoRoot(for: cwd) else { return [] }
        return await GitService.remoteBranches(root: root)
    }

    /// The repository's trunk, for the dialog's "From" default — the remote-
    /// tracking copy where there is one, so a new branch starts level with
    /// origin. nil outside a repository, or in one with no branch to name yet.
    func defaultBase(in cwd: String?) async -> String? {
        guard let cwd,
              let root = await GitService.repoRoot(for: cwd) else { return nil }
        return await GitService.defaultBase(root: root)
    }

    /// Bring `refs/remotes/*` up to date, so a branch forked from `origin/main`
    /// forks from today's `origin/main` rather than the one from the last time
    /// anybody thought to fetch.
    ///
    /// Failure is deliberately silent and deliberately not fatal: being offline,
    /// or on a repository whose remote needs credentials nobody is here to
    /// type, is not a reason to refuse to make a session. It only means the fork
    /// point is as fresh as the last successful fetch, which is where it was
    /// before. Skipped entirely without a remote, where it is a guaranteed error
    /// message about nothing.
    func fetchFromOrigin(in cwd: String?) async {
        guard let cwd,
              let root = await GitService.repoRoot(for: cwd),
              await GitService.hasRemotes(root: root) else { return }
        _ = await GitService.fetch(root: root)
    }

    /// Which of those already have a worktree — the picker says so on the row,
    /// because choosing one goes to it rather than making a second.
    func branchesWithWorktrees(in cwd: String?) async -> Set<String> {
        guard let cwd,
              let root = await GitService.repoRoot(for: cwd) else { return [] }
        return Set(await GitService.worktrees(root: root)
            .filter { !$0.isPrimary }
            .compactMap(\.branch))
    }

    /// Settings older builds wrote that nothing reads any more. The legacy
    /// panel flag still answers for a session saved before visibility was per
    /// session, so it goes only once no saved session needs it.
    private static func retireDeadDefaults(persisted: [PersistedSession]) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "inspector.widths")
        defaults.removeObject(forKey: "git.panelWidth")
        if persisted.allSatisfy({ $0.gitPanelVisible != nil }) {
            defaults.removeObject(forKey: "git.panelVisible")
        }
    }

    /// Shells the keeper is holding that no session or tab refers to.
    ///
    /// They happen when the list of sessions loses one the keeper still has: a
    /// crash inside the save's debounce, an older build rewriting the file
    /// without a tab kind it didn't know. Nothing can attach to such a shell
    /// again, or close it, so it ran on invisibly, an agent included, until
    /// logout. Killing them would be the tidy answer and the wrong one: an
    /// agent in there may be halfway through your work. So:
    ///
    /// - nothing running under the shell (it's at a prompt): closed. There is
    ///   nothing in it to lose but scrollback nobody could reach.
    /// - something running: it comes back as a session of its own, named for
    ///   what runs there, for you to look at and close.
    ///
    /// Never after a list that couldn't be read: then *every* shell looks
    /// unclaimed, and the right number of them to close is none.
    func recoverOrphanedShells() {
        guard store.loadedCleanly else { return }
        // And, with the list settled, the saved terminal modes of terminals
        // that no longer exist.
        defer {
            TerminalModeRecorder.shared.keepOnly(Set(sessions.flatMap { [$0.id] + $0.terminalTabIDs }))
            // And the agent exit log, which only ever grows.
            DispatchQueue.global(qos: .utility).async { AgentResumeStore.rotateExitLog() }
        }
        guard let keeper = GhosttyRuntime.keeper else { return }
        let known = Set(sessions.flatMap { [$0.id] + $0.terminalTabIDs })
        let orphans: [(id: UUID, pid: pid_t)] = keeper.running().compactMap { state in
            guard !state.attached, let id = UUID(uuidString: state.session),
                  !known.contains(id), state.pid > 0 else { return nil }
            return (id, state.pid)
        }
        guard !orphans.isEmpty else { return }

        let table = ProcessTable.snapshot()
        // An unreadable table says nothing about what is running, and every
        // orphan would look idle and be closed, agent and all.
        guard !table.isEmpty else { return }
        var parentOf: [pid_t: pid_t] = [:]
        for entry in table { parentOf[entry.pid] = entry.ppid }
        var recovered = false
        for orphan in orphans {
            // The keeper's pid is login; the work hangs off the shell under it.
            let shell = ProcessTable.shell(of: orphan.pid, in: table)
            // What the prompt itself keeps running doesn't count: see
            // `ProcessTable.work(under:in:)`.
            let shellName = table.first { $0.pid == shell }?.name
            // The shell's own children first: that's what was started there
            // (`claude`, `npm`), rather than something deep in its tree.
            let children = ProcessTable.work(under: shell, in: table)
            let running = table.filter {
                ProcessTable.isDescendant($0.pid, of: shell, parentOf: parentOf)
                    && !ProcessTable.isPromptHelper($0, shellName: shellName)
            }
            guard let what = (children.first ?? running.first)?.name else {
                keeper.close(session: orphan.id)
                TerminalModeRecorder.shared.forget(session: orphan.id)
                continue
            }
            let session = Session(id: orphan.id, name: "Recovered (\(what))", title: what,
                                  cwd: ProcessTable.workingDirectory(of: shell))
            // A placeholder: the agent's own title, when it pushes one, is a
            // better name than ours.
            session.nameSource = .placeholder
            // New to the sidebar now, so it sorts as new: at the top of a
            // Recent or Created section, where whoever is looking for the
            // shell that survived will look, not under everything dated.
            session.createdAt = Date()
            appendRestored(session)
            recovered = true
        }
        // Its own shell is long running, but terminals opened beside it start
        // with the session's ports.
        if recovered { assignPortBlocks(); scheduleSave() }
    }

    private func appendRestored(_ session: Session) {
        wire(session)
        sessions.append(session)
    }

    /// Give each session without a port block one (`PortBlock`): sessions from
    /// a file written before they had them, recovered shells, and the second
    /// of two that somehow hold the same block (only a hand-edited or merged
    /// file can do that). A block a session already holds is never re-checked:
    /// after a relaunch its own server may be the thing listening there.
    private func assignPortBlocks() {
        var held = Set<Int>()
        var changed = false
        for session in sessions {
            if let base = session.portBase, held.insert(base).inserted { continue }
            let reserved = held.union(sessions.compactMap(\.portBase))
            session.portBase = PortBlock.allocate(for: session.id, taken: reserved, isFree: PortBlock.isFree)
            if let base = session.portBase { held.insert(base) }
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// A folder with no sessions left, live or archived, goes, and its
    /// directory with it.
    private func dropFolderIfEmpty(_ folder: String) {
        guard !sessions.contains(where: { $0.folderPath == folder }),
              !archived.contains(where: { $0.folderPath == folder }) else { return }
        declaredFolders.removeAll { $0 == folder }
        folderOrder.removeAll { $0 == folder }
        collapsedFolders.remove(folder)
        folderRoots.removeValue(forKey: folder)
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        // Closed while git was still making its worktree: whoever is waiting
        // on it (the CLI) is told now. Removed before it's called, so
        // `finishWorktreeSession` finding nothing later is the normal case.
        if let completion = worktreeCompletions.removeValue(forKey: session.id) {
            completion(.failure(Failure(message: "The session was closed before its worktree was ready.")), [])
        }
        // On the record because its shell and agent end with it, and after
        // 2026-10-10 two sessions were gone and nothing could say how.
        KeeperLog.log.notice("""
            session \(session.id.uuidString, privacy: .public) closed\
            \(session.runningAgent.map { ", ending its \($0)" } ?? "", privacy: .public)
            """)
        let wasSelected = session.id == selectedID
        // Over the rows as drawn, so it is the row above on screen, sorted
        // or not, and never one inside a folded section. Or the session this
        // one was made from, when you never left it.
        let drawnNeighbour = SidebarStep.afterClosing(
            session.id, in: drawnRows, madeFrom: justMade?.session == session.id ? justMade?.from : nil)
        if justMade?.session == session.id || justMade?.from == session.id { justMade = nil }
        let hadAttention = session.needsAttention
        sleepTimers.removeValue(forKey: session.id)?.cancel()
        hiddenSince.removeValue(forKey: session.id)
        lastTypedAt.removeValue(forKey: session.id)
        sleptAt.removeValue(forKey: session.id)
        sleepSurvivors.removeValue(forKey: session.id)
        wantsWake.remove(session.id)
        busyTimers.removeValue(forKey: session.id)?.cancel()
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        unreadDwellTimers.removeValue(forKey: session.id)?.cancel()
        busyStartedAt.removeValue(forKey: session.id)
        progressErrored.remove(session.id)
        lastBusyInterval.removeValue(forKey: session.id)
        turnOutcomes.removeValue(forKey: session.id)
        lastBusyReports.removeValue(forKey: session.id)
        titleShowsWorking.remove(session.id)
        titleShowsActionRequired.remove(session.id)
        agentScreenTrackers.removeValue(forKey: session.id)
        screenInferredBusy.remove(session.id)
        explicitSignalAt.removeValue(forKey: session.id)
        autoNameState.removeValue(forKey: session.id)
        attentionSince.removeValue(forKey: session.id)
        attentionContent.removeValue(forKey: session.id)
        raisedWhileAway.remove(session.id)
        unreadSince.removeValue(forKey: session.id)
        seen.forget(session.id)
        // Closing ends its reminder, and takes back a banner one already showed.
        let reminded = remindedIDs.remove(session.id) != nil
        if session.remindAt != nil || reminded {
            session.remindAt = nil
            onReminderChanged?(session, nil)
            armReminderTimer()
        }
        if sidebarSelection.ids.contains(session.id) || sidebarSelection.anchor == session.id {
            var pruned = sidebarSelection
            pruned.prune(to: Set(sessions.lazy.map(\.id).filter { $0 != session.id }), lead: selectedID)
            sidebarSelection = pruned
        }
        recentSessionIDs.removeAll { $0 == session.id }
        history.forget(where: { $0.session == session.id })
        currentTabs[session.id] = nil
        pinnedIDs.removeAll { $0 == session.id }
        endPromptCapture(session)
        // The killed shell never reaches its prompt to clear its own agent
        // marker; drop it so a closed session isn't resumed on next launch.
        AgentResumeStore.remove(sessionID: session.id)
        let folder = session.folderPath
        // Before the shell goes: while it is alive its jobs are found by
        // ancestry, which needs no history at all.
        stopSessionWork?(session)
        session.close()
        sessions.remove(at: index)
        onSessionClosed?(session)
        // Closing the last session in a folder removes that section — including
        // ones made on purpose, which otherwise linger empty.
        // Its directory goes with it, as it does when the folder is ungrouped:
        // left behind, it was handed to the next folder given the same name,
        // and quietly decided where that one's sessions started.
        if let folder { dropFolderIfEmpty(folder) }
        if hadAttention { refreshDockBadge() }
        // Retract any notification still sitting in Notification Center for a
        // session that no longer exists.
        onAttentionCleared?(session)

        guard !sessions.isEmpty else {
            selectedID = nil
            saveNow()
            onAllClosed?()
            return
        }

        // The round trip (⌘N, do the thing, ⌘W) lands back where it started:
        // on the session the closed one was made from, if you never left it.
        // Otherwise the row *above*, not the one that slid into the closed
        // row's slot. Only the topmost row has nothing above it, and there
        // the row below is the only answer.
        if wasSelected {
            selectedID = drawnNeighbour ?? sessions[max(index - 1, 0)].id
        }
        scheduleSave()
    }

    /// Interactive close (menu / context menu / ⌘W): confirms first if the
    /// session still has a running process, otherwise closes immediately.
    func requestClose(_ session: Session) {
        let needsConfirm = session.needsConfirmClose || hasBackgroundWork?(session) == true
        guard needsConfirm, let confirmClose else {
            end(session)
            return
        }
        confirmClose(session) { [weak self] proceed in
            guard proceed else { return }
            // Re-check membership: the sheet is async, the session may have
            // gone away (e.g. the shell exited while it was open).
            guard let self, self.sessions.contains(where: { $0.id == session.id }) else { return }
            self.end(session)
        }
    }

    /// The way a session ends when you close it, or its shell exits: a
    /// session that lives in a worktree is archived, any other is closed.
    func end(_ session: Session) {
        if session.preparation == nil, worktreeHome(of: session) != nil {
            archive(session)
        } else {
            close(session)
        }
    }

    /// Presents one confirmation for closing several sessions, some of which
    /// (`running`) still have something running. The batch twin of
    /// `confirmClose`, set by the app layer. When nil, closes without asking.
    @ObservationIgnored var confirmCloseSessions: (([Session], _ running: [Session], @escaping (Bool) -> Void) -> Void)?

    /// Close the sidebar's selection: one question for the lot when any of
    /// them has something running, as `requestClose` asks for one.
    func requestClose(_ batch: [Session]) {
        guard batch.count > 1 else {
            if let session = batch.first { requestClose(session) }
            return
        }
        let running = batch.filter { $0.needsConfirmClose || hasBackgroundWork?($0) == true }
        guard !running.isEmpty, let confirmCloseSessions else {
            end(batch)
            return
        }
        confirmCloseSessions(batch, running) { [weak self] proceed in
            // `end` skips any that went while the sheet was up.
            guard proceed else { return }
            self?.end(batch)
        }
    }

    /// Several sessions ending as one: each as `end` would end it (a worktree
    /// session archived), but the selection moves once, and the archive and
    /// the session list are each written once.
    ///
    /// The selection moves *first*. Closing the selected session picks the row
    /// above it, which in a batch is often the next to go: it would start that
    /// session's shell and mark it read only to close it a moment later.
    func end(_ batch: [Session]) {
        let closing = batch.filter { session in sessions.contains { $0.id == session.id } }
        guard closing.count > 1 else {
            if let session = closing.first { end(session) }
            return
        }
        let closingIDs = Set(closing.map(\.id))
        if let current = selectedID, closingIDs.contains(current),
           let index = sessions.firstIndex(where: { $0.id == current }),
           let survivor = sessions[..<index].last(where: { !closingIDs.contains($0.id) })
            ?? sessions[index...].first(where: { !closingIDs.contains($0.id) }) {
            selectedID = survivor.id
        }
        let items = closing.compactMap(archivedEntry(for:))
        if !items.isEmpty {
            let ids = Set(items.map(\.id))
            archived.removeAll { ids.contains($0.id) }
            archived.insert(contentsOf: items, at: 0)
            ArchiveStore.save(archived)
        }
        closing.forEach(close)
        guard !items.isEmpty else { return }
        // Both files together, as `archive` writes them.
        saveNow()
        let usage = WorktreeUsage(manager: self)
        items.forEach { settleArchived($0, usage: usage) }
        refreshWorktreeListings()
    }

    // MARK: - New worktree session, and its branch's name

    /// A session in a worktree of its own, at once, no questions: a new
    /// branch from the repository's default branch (fetched first, for a few
    /// seconds at most), named for now with a placeholder, and for the work
    /// once the session has a name (`nameBranchForWork`). The repository is
    /// the selected session's, as for any new branch (`branchSource`).
    /// `wortel new --worktree`, and what ⇧⌘N's sheet does when Return is
    /// pressed on it as it opens (`newWorktreeSessionFromSheet`).
    @discardableResult
    func newWorktreeSession(from directory: String? = nil, inFolder folder: String? = nil,
                            starting start: SessionStart, completion: WorktreeCompletion? = nil) -> Session? {
        guard let from = directory ?? branchSource() else { return nil }
        let fetch = Task { await fetchFromOrigin(in: from) }
        return newSession(onBranch: placeholderBranch(), base: nil, from: from, inFolder: folder,
                          after: fetch, starting: start, completion: completion)
    }

    /// A placeholder branch name no session, archived one or worktree has.
    /// Taken by what's known without asking git (sessions live, preparing
    /// and archived); `resolveWorktree` would otherwise reuse a worktree
    /// already on the name, someone else's session in it.
    func placeholderBranch() -> String {
        let known = Set(sessions.compactMap { $0.worktreeBranch ?? $0.preparation?.branch }
            + archived.compactMap(\.branch)
            + worktreeListings.values.flatMap { $0.compactMap(\.branch) })
        return GitWorktree.generatedBranch { known.contains($0) }
    }

    /// Rename a worktree's placeholder branch (`worktree/brave-river-1a2f`)
    /// for what the session turned out to be about, once it has a name: a
    /// branch called `fix-login-redirect` says in `git branch`, a push and a
    /// pull request what `brave-river` never will.
    ///
    /// Only while nobody else can know the old name (`GitWorktree.mayRename`):
    /// Wortel made it, it was never pushed, and it's checked out here alone.
    /// Once, since a renamed branch isn't a placeholder any more. The folder
    /// stays where it is: agents keep their history by directory.
    private func nameBranchForWork(_ session: Session) {
        // The branch of the worktree the session lives in, read off its HEAD:
        // not `worktreeBranch`, which is whichever checkout the shell is
        // standing in, maybe another session's.
        guard session.preparation == nil, let checkout = session.homeCheckout, checkout.isOwned,
              let branch = GitWorktree.checkedOutBranch(at: checkout.root),
              GitWorktree.isGenerated(branch), renamingBranches.insert(session.id).inserted
        else { return }
        let name = session.leafName
        let root = checkout.root
        Task { [weak self] in
            defer { self?.renamingBranches.remove(session.id) }
            let created = await GitService.isCreatedByWortel(branch: branch, root: root)
            let upstream = await GitService.run(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(branch)@{upstream}"], in: root).ok
            let remotes = await GitService.remotesWithBranch(root: root, branch: branch)
            let checkouts = await GitService.worktrees(root: root).filter { $0.branch == branch }.count
            guard GitWorktree.mayRename(branch, createdByWortel: created, hasUpstream: upstream,
                                        onRemote: !remotes.isEmpty, checkouts: checkouts) else { return }
            let local = Set(await GitService.localBranches(root: root).map(\.name))
            guard let target = GitWorktree.renamedBranch(forName: name, isTaken: { local.contains($0) }),
                  target != branch,
                  await GitService.run(["branch", "-m", branch, target], in: root).ok,
                  let self
            else { return }
            self.branchRenamed(from: branch, to: target, in: root)
        }
    }
    @ObservationIgnored private var renamingBranches: Set<Session.ID> = []

    /// Everything that knows the worktree at `root` by its branch hears the
    /// new name: every session there (a ⌘T beside it too), and an archived
    /// one, which the rename may have landed after.
    private func branchRenamed(from old: String, to new: String, in root: String) {
        for session in sessions where session.worktreeBranch == old
            && (session.homeCheckout?.root == root || session.linkedCheckout?.root == root) {
            session.worktreeBranch = new
        }
        var archiveChanged = false
        for i in archived.indices where archived[i].branch == old
            && GitWorktree.realPath(archived[i].checkout) == root {
            archived[i].session.worktreeBranch = new
            archiveChanged = true
        }
        if archiveChanged { ArchiveStore.save(archived) }
        scheduleSave()
        refreshWorktreeListings()
    }

    // MARK: - Archive

    /// Worktree sessions you closed, newest first: what ⌘P lists as
    /// Archived, and what Restore brings back. Not in `sessions`, so nothing
    /// that walks the live list (⌘1-9, attention, the warm-up, saving)
    /// ever sees one.
    private(set) var archived: [ArchivedSession] = []
    /// Archived sessions whose worktree is being removed right now, which
    /// can't be restored until that's settled.
    @ObservationIgnored private var removingArchived: Set<UUID> = []

    /// Clean Up Worktrees is removing (or has finished with) the worktree at
    /// `path`: an archived session there can't be restored into it meanwhile.
    func setRemovingWorktree(_ removing: Bool, at path: String) {
        let root = GitWorktree.realPath(path)
        let ids = archived.filter { GitWorktree.realPath($0.checkout) == root }.map(\.id)
        if removing { removingArchived.formUnion(ids) } else { removingArchived.subtract(ids) }
    }

    /// Something about an archived worktree went wrong and the user should
    /// hear it (restoring one whose folder can't be made again). Set by
    /// AppDelegate.
    @ObservationIgnored var onArchiveProblem: ((String, String) -> Void)?

    /// The worktree a session lives in: the one it was opened in, not one its
    /// shell has since `cd`'d into, so a plain session that looked into a
    /// worktree is closed as the plain session it is.
    private func worktreeHome(of session: Session) -> GitWorktree.Linked? {
        session.homeCheckout ?? (session.originCwd ?? session.cwd).flatMap(GitWorktree.linked(containing:))
    }

    /// Archive a worktree session: the shell and its agent end, the worktree
    /// and branch stay, and the session (name, tabs, colour, the agent's
    /// conversation) waits to be continued from ⌘P.
    ///
    /// **Then, if there's nothing to keep, the worktree goes.** Wortel's own,
    /// clean, with nothing on its branch that isn't elsewhere or in trunk
    /// (`WorktreeCloseDecision`): the folder to the Trash, the branch with it
    /// when Wortel made it, and the archived row with them. Inspected after
    /// the row has moved, never before: a `git status` on a monorepo can
    /// take seconds, and ⌘W must not.
    func archive(_ session: Session) {
        guard let item = archivedEntry(for: session) else {
            close(session)
            return
        }
        archived.removeAll { $0.id == item.id }
        archived.insert(item, at: 0)
        ArchiveStore.save(archived)
        close(session)
        Telemetry.capture(.sessionArchived)
        // Both files at once: a crash between them would leave it live and
        // archived, or neither.
        saveNow()
        // Who else is in it, taken once this session is out of the list. Its
        // own processes aren't set aside, unlike the sheet's: whatever of
        // them is still running when the inspection looks (a `nohup`ed
        // server) is using the worktree.
        let usage = WorktreeUsage(manager: self)
        settleArchived(item, usage: usage)
        refreshWorktreeListings()
    }

    /// The record archiving `session` would keep, nil for a session that
    /// isn't archived when it ends (no worktree, or one still being made).
    /// Taken while the session is live: it reads the shell's processes.
    private func archivedEntry(for session: Session) -> ArchivedSession? {
        guard session.preparation == nil, let home = worktreeHome(of: session) else { return nil }
        noteConversation(session)
        var entry = persistedEntry(for: session, now: Date(), vouching: false, table: { ProcessTable.snapshot() })
        // The branch of the worktree it's archived in, which is what Restore
        // checks out again if the folder goes: the shell may be standing in
        // another worktree, or none.
        if let branch = GitWorktree.checkedOutBranch(at: home.root) { entry.worktreeBranch = branch }
        // Closing ends a reminder, archived or not: restored a week later, it
        // would go off at once for something long since dealt with.
        entry.remindAt = nil
        return ArchivedSession(session: entry, archivedAt: Date(), checkout: home.root,
                               repoHome: home.repoHome, isOwned: home.isOwned)
    }

    /// Inspect an archived worktree, and remove it when there's nothing to
    /// keep. A while after the close, so its processes have gone.
    private func settleArchived(_ item: ArchivedSession, usage: WorktreeUsage) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            let processes = await Task.detached { WorktreeUsage.Processes.read() }.value
            let users = usage.users(of: item.checkout, in: processes)
            let repos = item.repoHome.map { [$0] } ?? []
            let report = await WorktreeCleanup.inspect(path: item.checkout, knownRepos: repos, usedBy: users)
            guard let self, self.archived.contains(where: { $0.id == item.id }) else { return }
            guard case .remove(let deleteBranch) = WorktreeCloseDecision.decide(report),
                  !self.isShared(item) else { return }
            self.removingArchived.insert(item.id)
            let error = await WorktreeCleanup.remove(path: item.checkout, knownRepos: repos, usedBy: users,
                                                     deleteBranch: deleteBranch)
            self.removingArchived.remove(item.id)
            guard error == nil else { return }
            self.forgetArchived(item.id)
        }
    }

    /// Another session, live or archived, is in `item`'s worktree too (a ⌘T
    /// beside it, closed first or still open): it's that one's as much.
    private func isShared(_ item: ArchivedSession) -> Bool {
        let root = GitWorktree.realPath(item.checkout)
        return archived.contains { $0.id != item.id && GitWorktree.realPath($0.checkout) == root }
            || sessions.contains { $0.homeCheckout?.root == root || $0.linkedCheckout?.root == root }
    }

    /// Continue an archived session: its shell starts in its worktree again,
    /// and its agent resumes its conversation. A worktree whose folder has
    /// gone is made again from its branch first.
    @discardableResult
    func restore(archived id: UUID) -> Session? {
        guard let item = archived.first(where: { $0.id == id }) else { return nil }
        // Not while its worktree, or one it shares, is being removed.
        let root = GitWorktree.realPath(item.checkout)
        guard !archived.contains(where: { removingArchived.contains($0.id)
            && GitWorktree.realPath($0.checkout) == root }) else { return nil }
        if let live = sessions.first(where: { $0.id == id }) {
            // Already back (a crash between the two files): drop the copy.
            archived.removeAll { $0.id == id }
            ArchiveStore.save(archived)
            selectedID = live.id
            return live
        }
        guard FileManager.default.fileExists(atPath: item.checkout) else {
            recreateArchivedWorktree(item)
            return nil
        }
        archived.removeAll { $0.id == id }
        ArchiveStore.save(archived)
        let session = restoredSession(from: item.session, marker: nil, table: { ProcessTable.snapshot() })
        // In the worktree: where the shell last stood if that's still in it
        // and still there (a recreated worktree has no `build/`), else where
        // the session began, else the worktree's top. A shell given a folder
        // that doesn't exist starts in the keeper's, `/`.
        let inside = { (path: String?) -> String? in
            guard let path, FolderRoot.root(root, contains: GitWorktree.realPath(path)),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        }
        let start = inside(session.cwd) ?? inside(session.originCwd) ?? item.checkout
        if session.cwd != start { session.cwd = start }
        if inside(session.originCwd) == nil { session.originCwd = item.checkout }
        noteCheckout(session)
        appendRestored(session)
        normalizeOrder()
        assignPortBlocks()
        if let folder = session.folderPath { collapsedFolders.remove(folder) }
        selectedID = session.id
        saveNow()
        Telemetry.capture(.sessionUnarchived)
        return session
    }

    /// The folder of an archived worktree is gone (removed by hand, or by
    /// another tool): check its branch out there again, then restore.
    private func recreateArchivedWorktree(_ item: ArchivedSession) {
        guard let branch = item.branch, let repo = item.repoHome else {
            onArchiveProblem?("Couldn\u{2019}t restore \u{201c}\(item.leafName)\u{201d}",
                              "Its worktree is gone, and Wortel doesn\u{2019}t know which branch it was on.")
            return
        }
        removingArchived.insert(item.id)
        Task { [weak self] in
            let error = await GitService.addWorktree(root: repo, at: item.checkout, branch: branch,
                                                     source: .existingBranch, mark: item.isOwned)
            guard let self else { return }
            self.removingArchived.remove(item.id)
            if let error {
                self.onArchiveProblem?("Couldn\u{2019}t restore \u{201c}\(item.leafName)\u{201d}",
                                       GitMessage.readable(error, while: .worktree(branch: branch)))
                return
            }
            self.restore(archived: item.id)
        }
    }

    // MARK: - Worktree listings

    /// `git worktree list` for each repository a folder stands for, by the
    /// repository's home: what ⌘P's "Not open" rows and the git panel's
    /// worktree list come from. Read when something says it changed,
    /// never on a timer and never per row.
    private(set) var worktreeListings: [String: [GitWorktree]] = [:]
    @ObservationIgnored private var listingsInFlight: Set<String> = []
    /// Point a repository's new worktrees somewhere of its choosing, or back
    /// at Wortel's folder (nil), finished when git's config says so: the
    /// worktree sheet writes it before the worktree it's for is made there.
    /// Written to its local git config, where `wortel new --branch` and any
    /// other tool can read it too. Worktrees already made stay where they are.
    func applyWorktreeLocation(_ location: String?, forRepository home: String) async {
        _ = await GitService.setWorktreeLocation(location, root: home)
        readListing(home)
    }
    @ObservationIgnored private var listingWatchers: [String: DirectoryWatcher] = [:]

    /// The repository a folder stands for: its directory's, else the one its
    /// first session started in.
    func repositoryHome(ofFolder folder: String) -> String? {
        let directory = root(ofFolder: folder)
            ?? sessions.first(where: { $0.folderPath == folder })?.originCwd
            ?? archived.first(where: { $0.folderPath == folder })?.repoHome
        return directory.flatMap(GitWorktree.repositoryHome(containing:))
    }

    // MARK: - Put away, found with ⌘P

    /// What ⌘P lists besides the open sessions (`OpenTarget`), from what's
    /// already known, no git: every archived session, and the worktrees of
    /// every repository in the sidebar that no session is in.
    func switcherTargets() -> OpenTarget.Inputs {
        var inputs = OpenTarget.Inputs()
        inputs.archived = archived.map { .init(id: $0.id, name: $0.session.name, branch: $0.branch) }
        let taken = takenWorktrees()
        let preparing = preparingBranches()
        for home in worktreeListings.keys.sorted() {
            guard let listing = worktreeListings[home] else { continue }
            inputs.notOpen += listing.filter {
                !$0.isPrimary && !$0.isBare && !$0.isPrunable && !taken.contains(GitWorktree.realPath($0.path))
                    && !($0.branch.map(preparing.contains) ?? false)
            }.map { .init(path: $0.path, branch: $0.branch, repository: (home as NSString).abbreviatingWithTildeInPath) }
        }
        return inputs
    }

    /// The branches worktrees are being made on right now: git lists such a
    /// worktree as soon as `worktree add` starts, long before its row has it.
    private func preparingBranches() -> Set<String> {
        Set(sessions.compactMap { $0.preparation?.branch })
    }

    /// The worktrees a session (live, preparing or archived) is in.
    private func takenWorktrees() -> Set<String> {
        var taken = Set(archived.map { GitWorktree.realPath($0.checkout) })
        for session in sessions {
            if let root = session.linkedCheckout?.root { taken.insert(root) }
            if let root = session.homeCheckout?.root { taken.insert(root) }
            if let made = session.preparation?.resolved?.path { taken.insert(GitWorktree.realPath(made)) }
        }
        return taken
    }

    /// Do what ⌘P's row says.
    func perform(_ action: OpenTarget.Action) {
        switch action {
        case .restore(let id): restore(archived: id)
        case .openWorktree(let path): openWorktree(at: path)
        }
    }

    /// Read the worktrees of every repository a folder stands for, and watch
    /// each for worktrees coming and going (`.git/worktrees`, a vnode watch:
    /// an idle one costs nothing). At launch after the first frame, and when
    /// a worktree is made, archived or removed.
    func refreshWorktreeListings() {
        let homes = Set(folderNames.compactMap(repositoryHome(ofFolder:)))
        for home in homes { readListing(home) }
        for (home, _) in listingWatchers where !homes.contains(home) { listingWatchers[home] = nil }
        for home in homes where listingWatchers[home] == nil { watchListing(home) }
        worktreeListings = worktreeListings.filter { homes.contains($0.key) }
    }

    /// Watch the repository's `worktrees` folder (in its git dir, `.git` or a
    /// worktree-first clone's `.bare`). It exists only while there is a linked
    /// worktree: git makes it with the first and removes it with the last.
    /// Until then the git dir itself is watched, for it to appear, and the
    /// watch moves across whenever it comes or goes.
    private func watchListing(_ home: String) {
        guard let common = GitWorktree.commonDir(ofHome: home) else {
            listingWatchers[home] = nil
            return
        }
        let worktrees = (common as NSString).appendingPathComponent("worktrees")
        let exists = FileManager.default.fileExists(atPath: worktrees)
        listingWatchers[home] = DirectoryWatcher(path: exists ? worktrees : common) { [weak self] vanished in
            DispatchQueue.main.async {
                guard let self, self.listingWatchers[home] != nil else { return }
                self.readListing(home)
                if vanished || FileManager.default.fileExists(atPath: worktrees) != exists {
                    self.watchListing(home)
                }
            }
        }
    }

    /// One read per repository at a time; a change during one is read after.
    private func readListing(_ home: String) {
        guard listingsInFlight.insert(home).inserted else {
            listingsOwed.insert(home)
            return
        }
        Task { [weak self] in
            let listing = await GitService.worktrees(root: home)
            guard let self else { return }
            self.listingsInFlight.remove(home)
            if self.worktreeListings[home] != listing { self.worktreeListings[home] = listing }
            if self.listingsOwed.remove(home) != nil { self.readListing(home) }
        }
    }
    @ObservationIgnored private var listingsOwed: Set<String> = []

    /// Drop an archived session for good: its worktree is gone, or you
    /// deleted it. Its folder goes too when nothing else is in it.
    func forgetArchived(inWorktreeAt path: String) {
        let root = GitWorktree.realPath(path)
        for item in archived where GitWorktree.realPath(item.checkout) == root { forgetArchived(item.id) }
    }

    func forgetArchived(_ id: UUID) {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return }
        let folder = archived[index].folderPath
        archived.remove(at: index)
        ArchiveStore.save(archived)
        if let folder { dropFolderIfEmpty(folder) }
        refreshWorktreeListings()
    }

    func requestCloseSelected() {
        guard let selected else { return }
        requestClose(selected)
    }

    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.name else { return }
        session.name = trimmed
        // An explicit rename is the user's word — neither an agent's title nor
        // the model may touch this session again.
        session.nameSource = .user
        nameBranchForWork(session)
        // A rename can re-folder the session ("hello" -> "giel/hello"): keep the
        // flat order matching the render order, and make sure the row it moved
        // to is actually visible.
        normalizeOrder()
        reveal(session)
        scheduleSave()
        refreshAttentionNotification(session)
        // Whether people name sessions themselves, which is the premise of the
        // sidebar. `trimmed` is the name they chose and stays here.
        Telemetry.capture(.sessionRenamed(automatic: false))
    }

    /// Begin inline-renaming the selected session (⌘R / menu).
    func beginRenameSelected() {
        editingID = selectedID
    }

    func select(index: Int) {
        // Closed since the sidebar last drew: left out, so the rest move up
        // as their rows already have.
        let live = Set(sessions.map(\.id))
        let order = (shortcutIDs ?? sessions.prefix(9).map(\.id)).filter(live.contains)
        guard order.indices.contains(index) else { return }
        selectedID = order[index]
    }

    /// The ⌘-number shown on `id`'s row while ⌘ is held, if it has one.
    func shortcutNumber(for id: Session.ID) -> Int? {
        guard showsShortcutHints, let index = shortcutIDs?.firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// The outline drew its rows: the first nine are ⌘1…⌘9's from now on.
    func noteDrawnRows(_ drawn: [Session.ID]) {
        let first = Array(drawn.prefix(9))
        if first != shortcutIDs { shortcutIDs = first }
    }

    /// Select a session by id (e.g. from tapping its attention notification).
    func select(id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Asked for the session already in front (its reminder's banner was
        // clicked, with Wortel behind another app): nothing changes hands,
        // so the reminder is answered here, ring and banner both.
        if id == selectedID, answerReminder(session) { session.markedUnread = false }
        selectedID = id
    }

    /// Move the selection one row down the sidebar (⌘⌥↓), wrapping at the end.
    func selectNext() { selectStepping(by: 1) }

    /// Whether any session is currently waiting on the user (drives menu
    /// enablement for "Next Waiting Session").
    var hasAttention: Bool {
        sessions.contains { $0.attention != nil }
    }

    /// Jump to the session that most needs the user — "take me to whatever
    /// needs me." The loudest kind goes first (a question before a finished
    /// turn), and among equals the next one cyclically from the selection, so
    /// pressing it again walks the rest in sidebar order. No-op when nothing is
    /// waiting. Selecting it clears its attention and flashes the ring.
    func selectNextAttention() {
        guard !sessions.isEmpty,
              let loudest = sessions.compactMap(\.attention).max(by: { $0.priority < $1.priority })
        else { return }
        // In the order the sidebar shows them, so the jump goes down the rows.
        let ordered = sessionsInSidebarOrder
        let start = ordered.firstIndex { $0.id == selectedID } ?? -1
        for offset in 1...ordered.count {
            let candidate = ordered[(start + offset) % ordered.count]
            if candidate.attention == loudest {
                selectedID = candidate.id
                // Only when it actually lands. Counting the misses would report
                // the shortcut as used by someone who pressed it and got
                // nothing, which is the opposite of what the number is for.
                Telemetry.capture(.agentJumpUsed)
                return
            }
        }
    }

    /// Move the selection one row up the sidebar (⌘⌥↑), wrapping at the start.
    func selectPrevious() { selectStepping(by: -1) }

    /// Select the row `step` over from the selection, cyclically, in the rows
    /// as the sidebar draws them (`drawnRows`, `SidebarStep`): Sort Unread
    /// First is followed, so it is the next row on screen, and folded
    /// sections have no rows, so they are skipped as before.
    ///
    /// Sessions inside a collapsed folder are skipped rather than expanded into.
    /// The other selection paths (drop, rename, ⌘-number) un-collapse instead —
    /// they name a specific session, so they owe you it wherever it's buried.
    /// This one only means "one row over", and expanding a folder in passing
    /// would rearrange the sidebar as a side effect of moving through it.
    private func selectStepping(by step: Int) {
        guard let next = SidebarStep.neighbour(of: selectedID, in: drawnRows, by: step) else { return }
        selectedID = next
    }

    /// Whether a session has a row in the sidebar right now — i.e. it isn't
    /// tucked inside a collapsed folder, or a folded Pinned or Sessions.
    private func isVisibleInSidebar(_ session: Session) -> Bool {
        if isPinned(session) { return !pinnedCollapsed }
        guard let folder = session.folderPath else { return !looseCollapsed }
        return !isFolderCollapsed(folder)
    }

    /// The open sessions that have a row, top to bottom as drawn (Sort Unread
    /// First applied, folded sections left out). The outline's own list,
    /// less anything closed since it last drew; the stored order with folded
    /// sections left out when it has published nothing (before the first
    /// draw, or with every section folded, when that is empty too).
    private var drawnRows: [Session.ID] {
        let live = Set(sessions.map(\.id))
        let drawn = sidebarRowOrder.filter(live.contains)
        return drawn.isEmpty ? sessions.filter(isVisibleInSidebar).map(\.id) : drawn
    }

    /// Create surfaces for restored sessions that don't have one yet, one per
    /// runloop turn, so every session is warm within a couple of seconds.
    func warmRemainingSurfaces(limit: Int = 20) {
        guard limit > 0,
              let cold = sessions.first(where: { $0.surfaceView == nil && $0.preparation == nil })
        else { return }
        cold.ensureSurfaceView(runtime: runtime)
        DispatchQueue.main.async { [weak self] in
            self?.warmRemainingSurfaces(limit: limit - 1)
        }
    }

    // MARK: - Deep sleep
    //
    // An idle agent holds a few hundred megabytes for as long as it lives,
    // and hibernation only frees the terminal. So an agent at rest in a
    // session nobody is looking at is ended, and its exact conversation is
    // resumed when the session is selected again. When, and every reason not
    // to, is `AgentSleep.decide`. This is the part that touches a process.
    //
    // Nothing here polls. One timer per resting agent, armed when it stops
    // working or its session is left, and the look at the process table
    // happens when that timer fires: an hour after the last thing happened.

    @ObservationIgnored private var sleepTimers: [Session.ID: DispatchWorkItem] = [:]
    /// When each session was last left. A session not left since launch
    /// counts from the launch.
    @ObservationIgnored private var hiddenSince: [Session.ID: Date] = [:]
    @ObservationIgnored private let launchedAt = Date()
    /// When keys last went into each session, for "typed and not sent".
    @ObservationIgnored private var lastTypedAt: [Session.ID: Date] = [:]
    /// When each sleeping agent was seen to go, for the moment after in
    /// which its exit must not be read as a command that failed.
    @ObservationIgnored private var sleptAt: [Session.ID: Date] = [:]
    /// What an agent being ended had started, to stop once it has gone.
    @ObservationIgnored private var sleepSurvivors: [Session.ID: [(pid: pid_t, startedAt: Date)]] = [:]
    @ObservationIgnored private var wakeTimer: DispatchWorkItem?
    /// Sessions asked for while their agent was still on its way out (the
    /// seconds between the signal and the agent being seen to go): brought
    /// straight back once it has gone.
    @ObservationIgnored private var wantsWake: Set<Session.ID> = []

    /// Start the clock for `session`'s agent, unless one is running already.
    /// The earliest timer is kept, so an agent that is asked about often is
    /// not asked later for it; `replacing` is for the caller that knows the
    /// right moment.
    private func armSleep(_ session: Session, after delay: TimeInterval = AgentSleep.finishedAfter,
                          replacing: Bool = false) {
        guard let agent = session.runningAgent, AgentSleep.enabledAgents.contains(agent),
              case .awake = session.sleep else { return }
        if sleepTimers[session.id] != nil {
            guard replacing else { return }
            sleepTimers.removeValue(forKey: session.id)?.cancel()
        }
        let id = session.id
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sleepTimers[id] = nil
            guard let session = self.sessions.first(where: { $0.id == id }) else { return }
            self.considerSleep(session, pressure: false)
        }
        sleepTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, delay), execute: work)
    }

    /// Everything known about a session's agent at one moment, from one
    /// process table.
    private struct SleepCandidate {
        let inputs: AgentSleep.Inputs
        let marker: AgentMarker
        let conversationID: String
        let input: String
        /// The agent's process group, taken from the terminal.
        let group: pid_t
        /// What it started outside that group.
        let started: [(pid: pid_t, startedAt: Date)]
    }

    /// Look at `session`'s agent. nil when anything about it can't be
    /// established, which is a reason to leave it alone.
    ///
    /// **The agent is never found by its command line** (`docs/decisions.md`:
    /// a tool running out of `/tmp/claude-501/` reads as Claude that way).
    /// It is the process group that has the session's terminal, as the
    /// terminal itself says and the process table agrees; its leader is a
    /// child of the very shell the marker names; and a process in it has
    /// written Claude's own record of itself, naming its conversation.
    private func sleepCandidate(for session: Session, table shared: [ProcessEntry]? = nil,
                                markers: [UUID: AgentMarker]? = nil) -> SleepCandidate? {
        // Each way out says which, at info: "why is this agent still awake"
        // has to be answerable from the log, since nothing on screen says.
        func unsure(_ why: String) -> SleepCandidate? {
            AgentSleepLog.log.info("""
                session \(session.id.uuidString, privacy: .public) left alone: \(why, privacy: .public)
                """)
            return nil
        }
        guard let agent = session.runningAgent, let shellPID = session.runningShellPID,
              let startedAt = session.runningStartedAt else { return unsure("its marker names no shell") }
        guard let view = session.surfaceView, let pty = view.ptyHost, view.keeperSession != nil
        else { return unsure("no terminal of the keeper's") }
        // The marker on disk is still this run's.
        guard let onDisk = (markers ?? AgentResumeStore.currentMarkers())[session.id], onDisk.agent == agent,
              onDisk.shellPID == shellPID, onDisk.startedAt == startedAt
        else { return unsure("the marker on disk is another run's") }
        let table = shared ?? ProcessTable.snapshot()
        guard let shell = table.first(where: { $0.pid == shellPID }),
              ProcessTable.isShell(shell.name), !shell.isExiting
        else { return unsure("the marker's shell is not a live shell") }
        guard view.shellPID.map({ ProcessTable.shell(of: $0, in: table) }) == shellPID
        else { return unsure("the marker's shell is not this terminal's") }
        let group = shell.foregroundGroup
        guard group > 1, group != shell.pgid, group != getpgrp()
        else { return unsure("the shell has the terminal itself") }
        guard pty.foregroundProcessGroup() == group
        else { return unsure("the terminal and the process table disagree on who has it") }
        guard let leader = table.first(where: { $0.pid == group }), leader.ppid == shellPID,
              !leader.isStopped, !leader.isExiting
        else { return unsure("what has the terminal is not a running child of the shell") }
        let parentOf = Dictionary(table.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        let under = { (pid: pid_t) in ProcessTable.isDescendant(pid, of: leader.pid, parentOf: parentOf) }
        let members = table.filter { $0.pgid == group }
        guard members.allSatisfy({ $0.pid == leader.pid || under($0.pid) })
        else { return unsure("its process group holds something not its own") }

        // The agent's own word for what it is doing and which conversation
        // it is in. Claude Code only, so far (`AgentSleep.enabledAgents`).
        //
        // The record of the process that has the terminal, when it has one.
        // Started through a wrapper (`devx claude`), the leader is the
        // wrapper and has none: then the group must hold exactly one, since
        // a second Claude in the group (a hook running `claude -p`) keeps a
        // record too, and its conversation and status are not this agent's.
        guard agent == "claude" else { return unsure("not an agent whose record is read") }
        let state: AgentResumeStore.ClaudeProcessState
        if let own = AgentResumeStore.claudeProcessState(pid: leader.pid) {
            state = own
        } else {
            let records = members.compactMap { AgentResumeStore.claudeProcessState(pid: $0.pid) }
            guard records.count == 1 else {
                return unsure(records.isEmpty ? "no process in it has the agent's own record"
                                              : "more than one process in it has an agent's record")
            }
            state = records[0]
        }
        let rest = AgentRest(claudeStatus: state.status, since: state.statusChangedAt)

        let marker = AgentMarker(agent: agent, model: session.runningModel,
                                 cwd: session.runningCwd ?? session.cwd, argv: session.runningArgv,
                                 shellPID: shellPID, startedAt: startedAt)
        let input = AgentResumeStore.resumeInput(for: marker, knownConversationID: state.conversationID)
        // Exact, and one that runs: the line names this conversation and
        // ends in a Return, and the conversation is on disk to come back to.
        let resumable = input.map { $0.hasSuffix("\n") && $0.contains(state.conversationID) } == true
            && marker.cwd.map { AgentConversation.exists(agent: agent, id: state.conversationID, cwd: $0) } == true

        let id = session.id
        var restSince = Date.distantFuture
        switch rest {
        case .finished(let since), .waiting(let since): restSince = since
        case .unknown: break
        }
        let started = table.filter { $0.pgid != group && under($0.pid) && !$0.isExiting }
        let inputs = AgentSleep.Inputs(
            agent: agent,
            launchIsSimple: AgentCommandLine.isSimple(session.runningArgv ?? agent),
            resumable: resumable,
            selected: id == selectedID,
            busy: session.isBusy || busyTimers[id] != nil || quiesceTimers[id] != nil
                || titleShowsWorking.contains(id),
            rest: rest,
            quietSince: lastBusyInterval[id]?.cleared,
            hiddenSince: hiddenSince[id] ?? launchedAt,
            hasWorkUnder: !started.isEmpty,
            typedSinceRest: lastTypedAt[id].map { $0 > restSince } ?? false,
            now: Date())
        return SleepCandidate(inputs: inputs, marker: marker, conversationID: state.conversationID,
                              input: input ?? "", group: group,
                              started: started.map { (pid: $0.pid, startedAt: $0.startedAt) })
    }

    /// The timer fired, or macOS says memory is short: may this agent go?
    private func considerSleep(_ session: Session, pressure: Bool) {
        guard case .awake = session.sleep, session.runningAgent != nil else { return }
        // A resume typed and not yet answered: the agent is on its way up.
        if let owed = session.owedResume, owed.isOwed(at: Date()) {
            if !pressure { armSleep(session, replacing: true) }
            return
        }
        guard let candidate = sleepCandidate(for: session) else {
            // Nothing sure enough to act on. Asked again in an hour: the cost
            // of an agent that can't be read is one look an hour.
            if !pressure { armSleep(session, replacing: true) }
            return
        }
        switch AgentSleep.decide(candidate.inputs, pressure: pressure) {
        case .sleep(let waiting):
            beginSleep(session, candidate, waiting: waiting, pressure: pressure)
        case .notBefore(let date):
            AgentSleepLog.log.info("""
                session \(session.id.uuidString, privacy: .public) not yet:                 \(Int(date.timeIntervalSinceNow)) s to go
                """)
            armSleep(session, after: date.timeIntervalSinceNow + 1, replacing: true)
        case .never(let reason):
            AgentSleepLog.log.info("""
                session \(session.id.uuidString, privacy: .public) stays awake: \
                \(String(describing: reason), privacy: .public)
                """)
            // Working and selected come back by themselves (work ending, the
            // session being left). An agent that doesn't say it is resting
            // is asked again in an hour.
            if reason == .restUnknown, !pressure { armSleep(session, replacing: true) }
        }
    }

    /// End the agent. Its state is saved first, so a crash from here on
    /// leaves a session that knows it is asleep; then the terminal is asked
    /// once more who has it, and only then is the signal sent.
    ///
    /// SIGTERM, to the group: what Claude Code handles by leaving (seen
    /// 2026-11-18: gone in 0.13 s, status 143, the terminal's modes back to
    /// a shell's). Never SIGKILL: an agent killed mid-screen leaves the
    /// terminal in its modes. One that doesn't go is simply still awake.
    private func beginSleep(_ session: Session, _ candidate: SleepCandidate, waiting: Bool, pressure: Bool) {
        markEnding(session, candidate, waiting: waiting)
        saveNow()
        signalSleep(session, candidate, waiting: waiting, pressure: pressure)
    }

    /// The first half: `session` is recorded as on its way to sleep. Nothing
    /// is signalled until that has been saved.
    private func markEnding(_ session: Session, _ candidate: SleepCandidate, waiting: Bool) {
        let sleeper = SleepingAgent(marker: candidate.marker, conversationID: candidate.conversationID,
                                    input: candidate.input, waiting: waiting)
        session.sleep = .ending(sleeper, group: candidate.group)
        sleepSurvivors[session.id] = candidate.started
    }

    /// The second half, after the save: one last look, and the signal.
    private func signalSleep(_ session: Session, _ candidate: SleepCandidate, waiting: Bool, pressure: Bool) {
        let id = session.id
        let group = candidate.group
        guard case .ending(let sleeper, _) = session.sleep else { return }
        guard session.surfaceView?.ptyHost?.foregroundProcessGroup() == group,
              !session.isBusy, id != selectedID else {
            session.sleep = .awake
            sleepSurvivors[id] = nil
            scheduleSave()
            return
        }
        AgentSleepLog.log.notice("""
            session \(id.uuidString, privacy: .public): ending \(sleeper.marker.agent, privacy: .public) \
            (group \(group), \(waiting ? "waiting" : "finished", privacy: .public)\
            \(pressure ? ", memory pressure" : "", privacy: .public)), \
            \(candidate.started.count) started under it
            """)
        kill(-group, SIGTERM)
        Telemetry.capture(.agentSlept(agent: AgentName(command: sleeper.marker.agent),
                                      cause: pressure ? .pressure : .clock))
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSleep.exitGrace) { [weak self] in
            guard let self, let session = self.sessions.first(where: { $0.id == id }),
                  case .ending(let sleeper, let ending) = session.sleep, ending == group else { return }
            // Its marker is still there. That is the shell's to remove, at
            // its next prompt, and a slow prompt (a `precmd` running git on
            // a large repository) can take longer than this. So the process
            // is asked, not the marker: with nothing left of the group the
            // agent has gone, and counting it as awake would leave a session
            // with no agent and nothing to bring it back.
            if ProcessTable.snapshot().contains(where: { $0.pgid == group && !$0.isExiting }) {
                // It didn't go. Awake as it was, and nothing else is touched.
                session.sleep = .awake
                self.sleepSurvivors[id] = nil
                self.wantsWake.remove(id)
                AgentSleepLog.log.notice(
                    "session \(id.uuidString, privacy: .public): the agent did not exit, still awake")
                self.scheduleSave()
                self.armSleep(session)
            } else {
                self.commitSleep(session, sleeper)
            }
        }
    }

    /// The agent has gone, as asked: the session is asleep from here.
    private func commitSleep(_ session: Session, _ sleeper: SleepingAgent) {
        let id = session.id
        // Not an agent that ended: nothing is owed for it at a quit beyond
        // what `sleep` already says.
        session.sleep = .asleep(sleeper)
        session.endedAgent = nil
        sleptAt[id] = Date()
        stopWhatItStarted(in: session)
        AgentSleepLog.log.notice("session \(id.uuidString, privacy: .public): asleep")
        scheduleSave()
        // Asked for while it was going (selected, or sent to): it comes
        // straight back. Without this the session someone is looking at sat
        // on a bare shell until they left it and returned.
        if wantsWake.remove(id) != nil || id == selectedID {
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentSleep.wakeDwell) { [weak self, weak session] in
                guard let self, let session else { return }
                self.wake(session)
            }
        }
    }

    /// An agent started or ended in `session` (`refreshAgentActivity`).
    private func agentRunChanged(_ session: Session, marker: AgentMarker?, wasResume: Bool) {
        let id = session.id
        switch (session.sleep, marker) {
        case (.ending(let sleeper, _), nil):
            commitSleep(session, sleeper)
        case (.awake, .some):
            armSleep(session)
        case (.ending, .some), (.asleep, .some):
            // An agent is running here again: the resume, or one started by
            // hand. Either way nothing is asleep.
            let woke = session.sleep.agent
            session.sleep = .awake
            sleepSurvivors[id] = nil
            wantsWake.remove(id)
            if wasResume, let woke {
                AgentSleepLog.log.notice("session \(id.uuidString, privacy: .public): awake again")
                Telemetry.capture(.agentWoke(agent: AgentName(command: woke.marker.agent)))
            }
            scheduleSave()
            armSleep(session)
        case (.asleep, nil):
            // The marker of an agent already counted as gone (a slow prompt
            // removed it after the grace was up): still not one that ended.
            session.endedAgent = nil
        case (.awake, nil):
            break
        }
    }

    /// The agent has gone: end what it had started outside its own group
    /// (a tool's shell, a dev server), each by the pid and start time taken
    /// before the signal, so a pid since reused is never touched. A server
    /// that had already detached itself from the agent was never in that
    /// list: it can't be shown to be the agent's, so it is left for the
    /// running-jobs list, and for the session closing.
    private func stopWhatItStarted(in session: Session) {
        guard let recorded = sleepSurvivors.removeValue(forKey: session.id), !recorded.isEmpty else { return }
        let alive = { () -> [pid_t] in
            let table = ProcessTable.snapshot()
            return recorded.compactMap { item in
                table.contains { $0.pid == item.pid && $0.startedAt == item.startedAt && !$0.isExiting }
                    ? item.pid : nil
            }
        }
        let first = alive()
        guard !first.isEmpty else { return }
        for pid in first { kill(pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for pid in alive() { kill(pid, SIGKILL) }
        }
    }

    /// Whether `session`'s agent is being ended, or went a moment ago.
    private func sleepIsSettling(_ session: Session) -> Bool {
        if session.sleep.isEnding { return true }
        return sleptAt[session.id].map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    /// The selection moved: the session left starts counting, and the one
    /// arrived at stops and, if its agent is asleep, gets it back once the
    /// selection has stayed a moment (so stepping past rows starts nothing).
    private func noteSelectionForSleep(left: Session.ID?, arrived: Session) {
        if let left, left != arrived.id, let old = sessions.first(where: { $0.id == left }) {
            hiddenSince[left] = Date()
            armSleep(old, replacing: true)
        }
        sleepTimers.removeValue(forKey: arrived.id)?.cancel()
        wakeTimer?.cancel()
        wakeTimer = nil
        // Still on its way out: it is brought back when it has gone.
        if arrived.sleep.isEnding { wantsWake.insert(arrived.id) }
        guard arrived.sleep.sleeper != nil else { return }
        let id = arrived.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.selectedID == id,
                  let session = self.sessions.first(where: { $0.id == id }) else { return }
            self.wake(session)
        }
        wakeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSleep.wakeDwell, execute: work)
    }

    /// Bring back the agent of a sleeping session: type its exact resume
    /// into the shell, once the terminal is back and the shell is sitting at
    /// a prompt with nothing running. The session stays asleep until the
    /// agent is seen running, so a resume that never starts is typed again
    /// the next time the session is asked for, a few times at most. After
    /// that it is a plain shell with the command in its history: a session
    /// that says it is bringing an agent back, for ever, is worse.
    @discardableResult
    func wake(_ session: Session, retries: Int = 20) -> AgentWake {
        // Signalled and not yet seen to go: remembered, and done then.
        if session.sleep.isEnding {
            wantsWake.insert(session.id)
            return .starting
        }
        guard case .asleep(var sleeper) = session.sleep else { return .notAsleep }
        let now = Date()
        if let typed = sleeper.typedAt, now.timeIntervalSince(typed) < OwedResume.answerWithin {
            return .starting
        }
        guard sleeper.attempts < AgentSleep.maxWakeAttempts else {
            session.sleep = .awake
            AgentSleepLog.log.notice("""
                session \(session.id.uuidString, privacy: .public): the resume never started, \
                given up after \(sleeper.attempts) tries
                """)
            scheduleSave()
            return .gaveUp
        }
        guard let view = warmSurface(of: session) else { return .shellBusy }
        let again = { [weak self, weak session] in
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self, let session else { return }
                self.wake(session, retries: retries - 1)
            }
        }
        // Its terminal is still coming back (hibernated, or just made):
        // asked again in a moment, and that is "on its way", not "busy".
        guard !view.isHibernated, !view.isRestoring, let pty = view.ptyHost, let root = view.shellPID else {
            again()
            return .starting
        }
        let table = ProcessTable.snapshot()
        let shellPID = ProcessTable.shell(of: root, in: table)
        guard let shell = table.first(where: { $0.pid == shellPID }),
              ProcessTable.isShell(shell.name), !shell.isExiting else {
            again()
            return .shellBusy
        }
        // An agent is already running here: started by hand, or the resume
        // typed a moment ago and not yet mirrored. Nothing to type.
        guard AgentResumeStore.currentMarkers()[session.id] == nil else { return .starting }
        // The shell has its terminal and nothing under it: a prompt. A shell
        // made a moment ago for a restored session is still reading its
        // startup files (`path_helper`, `brew shellenv`), which looks the
        // same as one busy with something typed by hand, so it is asked
        // again for a few seconds before being left alone.
        guard pty.foregroundProcessGroup() == shell.pgid,
              ProcessTable.work(under: shellPID, in: table).isEmpty else {
            again()
            return .shellBusy
        }
        let line = sleeper.input.hasSuffix("\n") ? String(sleeper.input.dropLast()) : sleeper.input
        guard view.typeCommand(line) else { return .shellBusy }
        sleeper.typedAt = now
        sleeper.attempts += 1
        session.sleep = .asleep(sleeper)
        // Owed as any typed resume is, so the agent starting is recognised
        // as Wortel's doing (`AgentConversation.confirms`).
        session.owedResume = OwedResume(agent: sleeper.marker, conversationID: sleeper.conversationID,
                                        input: sleeper.input, typedAt: now)
        AgentSleepLog.log.notice("""
            session \(session.id.uuidString, privacy: .public): resume typed \
            (attempt \(sleeper.attempts))
            """)
        return .starting
    }

    /// macOS says memory is short: every agent at rest long enough goes now.
    ///
    /// One look at the process table and the markers for all of them, and
    /// one save before the first signal: this runs on the main thread at the
    /// moment the Mac has least to spare.
    private func sleepUnderPressure() {
        let table = ProcessTable.snapshot()
        let markers = AgentResumeStore.currentMarkers()
        var going: [(Session, SleepCandidate, Bool)] = []
        for session in sessions where session.runningAgent != nil {
            guard case .awake = session.sleep else { continue }
            if let owed = session.owedResume, owed.isOwed(at: Date()) { continue }
            guard let candidate = sleepCandidate(for: session, table: table, markers: markers),
                  case .sleep(let waiting) = AgentSleep.decide(candidate.inputs, pressure: true)
            else { continue }
            going.append((session, candidate, waiting))
        }
        guard !going.isEmpty else { return }
        for (session, candidate, waiting) in going { markEnding(session, candidate, waiting: waiting) }
        saveNow()
        for (session, candidate, waiting) in going {
            signalSleep(session, candidate, waiting: waiting, pressure: true)
        }
    }

    // MARK: - Busy state (debounced)

    /// A command started: show busy after a short delay so instant commands
    /// don't flicker. Coalesces repeat progress reports for a running command.
    /// Also cancels a pending quiesce-attention: the program resumed working,
    /// so its earlier "stopped" was a blip, not a prompt for the user.
    private func markBusy(_ session: Session) {
        lastBusyReports[session.id] = Date()
        // Working: whatever clock was running towards sleep is off.
        sleepTimers.removeValue(forKey: session.id)?.cancel()
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        guard busyTimers[session.id] == nil, !session.isBusy else { return }
        let id = session.id
        // A new stretch of work: how the last one ended is history. At the
        // edge, not when the debounce shows it: a turn shorter than the
        // debounce never shows, and its predecessor's outcome then read as
        // its own (`wait --idle` back at once, `list` saying finished).
        // Only at the edge, too, so a signal raised mid-turn (a bell while
        // still busy) isn't wiped by the next progress report.
        turnOutcomes[id] = nil
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.busyTimers[id] = nil
            let now = Date()
            if let last = self.lastBusyInterval[id],
               now.timeIntervalSince(last.cleared) < Self.busyContinuationWindow {
                self.busyStartedAt[id] = last.start // continuation, not a new run
            } else {
                self.busyStartedAt[id] = now
            }
            session.isBusy = true
            self.noteConversation(session)
        }
        busyTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyShowDelay, execute: work)
    }

    /// A command finished (or progress was cleared): cancel any pending show
    /// and drop busy immediately.
    private func clearBusy(_ session: Session) {
        busyTimers.removeValue(forKey: session.id)?.cancel()
        screenInferredBusy.remove(session.id)
        if let start = busyStartedAt.removeValue(forKey: session.id) {
            lastBusyInterval[session.id] = (start: start, cleared: Date())
        }
        if session.isBusy {
            session.isBusy = false
            noteConversation(session)
        }
        // At rest, perhaps: the hour starts counting (`AgentSleep`).
        armSleep(session)
    }

    /// Look at which conversation the running agent is in: when it starts,
    /// at the start and end of each turn, and at a quit (`persistedSessions`).
    /// A `/clear` or `/resume` changes it without a word to the shell, and for
    /// Claude the exact answer, its process file, is gone with the process.
    /// See `Session.liveConversationID`.
    ///
    /// The process table is the one shared across a second of these
    /// (`recentProcessTable`): a turn ending in five sessions at once reads
    /// it once. What it learns is saved, because a Force Quit takes the keeper
    /// with it and the next launch has only the last save.
    private func noteConversation(_ session: Session, table: [ProcessEntry]? = nil) {
        guard let agent = session.runningAgent, AgentConversation.exact.contains(agent),
              let cwd = session.runningCwd ?? session.cwd else { return }
        var livePID: pid_t?
        if case .running(let pid) = AgentLiveness.locate(
            agent: agent, shellPID: session.runningShellPID,
            table: table ?? GhosttyRuntime.recentProcessTable()) {
            livePID = pid
        }
        guard let id = AgentConversation.observe(agent: agent, livePID: livePID, cwd: cwd,
                                                 argv: session.runningArgv,
                                                 startedAt: session.runningStartedAt),
              id != session.liveConversationID
        else { return }
        session.liveConversationID = id
        session.lastConversationID = id
        scheduleSave()
    }

    /// Title-marker fallback for agents that signal state only through the
    /// window title. Verified conventions: Claude Code and Codex animate a
    /// braille spinner (U+2800…U+28FF) while working; Gemini CLI uses
    /// "✦/⏲ Working", "◇ Ready", and "✋ Action Required"; Codex prefixes
    /// "[ ! ] Action Required" when blocked on the user. Marker appearing →
    /// busy; marker disappearing → same quiesce machinery as OSC 9;4; explicit
    /// action-required marker → attention right away. For agents that also
    /// emit real progress (Claude Code) the two paths agree: the title spinner
    /// stops at the same moment 9;4;0 arrives.
    private func titleChanged(_ session: Session, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let wasWorking = titleShowsWorking.contains(session.id)
        // The title is the murkiest of the busy signals — log what arrived and
        // how it was read, with the leading scalars spelled out so an invisible
        // padding character can't hide. Titles are bursty (an agent animating a
        // spinner retitles several times a second, per session), so the string
        // building is gated on someone actually listening rather than done and
        // thrown away.
        if AgentStatusLog.isTracing {
            let scalars = trimmed.unicodeScalars.prefix(4)
                .map { "U+\(String($0.value, radix: 16, uppercase: true))" }
                .joined(separator: " ")
            AgentStatusLog.log.debug("""
                title \(scalars, privacy: .public) \
                working=\(Self.hasWorkingMarker(trimmed), privacy: .public) — \(trimmed, privacy: .private)
                """)
        }
        // Before the state reading: the same title carries the agent's name for
        // the conversation, whether or not it is currently working.
        adoptAgentTitle(session, title: trimmed)
        if trimmed.hasPrefix("✋") || trimmed.contains("Action Required") {
            titleShowsWorking.remove(session.id)
            // An edge, not a level. Codex blinks the marker for as long as it
            // is blocked ("[ ! ]" / "[ . ]", a retitle per blink), and each
            // arrival used to raise attention again: the app layer re-posts
            // the session's notification, and a re-post with the same id is
            // a fresh banner on screen. One pending question was a waterfall
            // of banners until it was answered.
            guard titleShowsActionRequired.insert(session.id).inserted else { return }
            // Deliberately *not* `noteExplicitSignal`. An agent proving it can
            // say "I need you" is no proof it can say "I'm working": those are
            // different titles on different code paths, and Codex and Gemini
            // emit this one while never necessarily matching `hasWorkingMarker`.
            // Counting it as proof retired the screen sampler for the whole of
            // that agent's run, so the first approval prompt of a session could
            // leave it with no busy signal at all for the rest of the day.
            clearBusy(session)
            raiseAttention(session, kind: .needsInput, title: session.name, body: "Action required",
                           source: "title")
        } else if Self.hasWorkingMarker(trimmed) {
            titleShowsActionRequired.remove(session.id)
            titleShowsWorking.insert(session.id)
            // A title spinner is this session speaking for itself; the screen
            // sampler defers to it.
            noteExplicitSignal(session)
            markBusy(session)
        } else if wasWorking {
            titleShowsActionRequired.remove(session.id)
            titleShowsWorking.remove(session.id)
            progressEnded(session, source: "title")
        } else {
            titleShowsActionRequired.remove(session.id)
        }
    }

    /// A leading braille *spinner* frame means working — but U+2800 (BRAILLE
    /// PATTERN BLANK) is not a spinner frame, it's the blank one. TUIs use it
    /// as a fixed-width spacer, and a title padded with it read as permanently
    /// working: the spinner never stopped, so the session could never go quiet
    /// and its status dot never got a chance to show. So: skip leading blanks
    /// (spaces and U+2800 alike) and judge the first character that actually
    /// draws ink.
    ///
    /// The half-circle frames (U+25D0…U+25D3, "◐◑◒◓") are Claude Code's, and
    /// they are the reason this list is a liability rather than a lookup: it
    /// used to say braille on the authority of a version that has since
    /// restyled, and a marker set that silently stops matching does not fail
    /// loudly — it just quietly hands every Claude session to the screen-
    /// guessing tier, which is exactly the tier this signal exists to spare
    /// them from. Claude's resting title is "✳ <summary>" and it animates the
    /// leading glyph only while working, so the two states are a clean edge;
    /// keep ✳ *out* of this list, since a title that never stops matching is
    /// the U+2800 bug again.
    private static func hasWorkingMarker(_ title: String) -> Bool {
        let inked = title.unicodeScalars.drop {
            $0 == "\u{2800}" || CharacterSet.whitespaces.contains($0)
        }
        guard let first = inked.first else { return false }
        return first == "✦" || first == "⏲"
            || (0x2801...0x28FF).contains(first.value)
            || (0x25D0...0x25D3).contains(first.value)
    }

    /// A progress-emitting program reported it stopped working (OSC 9;4;0).
    /// For agent CLIs (Claude Code, etc.) this is the *only* reliable "I need
    /// you now" signal — they emit it at permission prompts and at turn end,
    /// but send no bell or desktop notification under Ghostty. So: if the
    /// session was visibly busy long enough, raise attention after a short
    /// settle window (cancelled if progress resumes or a prompt returns).
    /// `inferred` is what to raise if the settle window passes quietly. The OSC
    /// path can't tell "blocked" from "done" and so leaves it at `.turnDone`;
    /// the screen path reads the stopped screen and may already know better.
    ///
    /// `corroborating` is the screen tier saying so about a session that has a
    /// channel of its own. That tier now watches such sessions too, so that a
    /// program whose signal drops mid-turn still gets a spinner — but it means
    /// two stray repaints on an *idle* one can again look like a short turn,
    /// which is the phantom-notification bug this tier was once fenced off for.
    /// A busy it merely corroborated therefore has to have lasted much longer
    /// before it is announced: real work runs for many seconds, and a spinner
    /// that quietly appears and disappears costs nothing, where a badge on a
    /// session nobody touched costs trust.
    ///
    /// `guessed` says the quiet is the screen tier's own reading rather than
    /// the program's word, so `announceTurnEnd` must check there was a turn.
    private func progressEnded(_ session: Session, inferred kind: AttentionKind = .turnDone,
                               source: String, corroborating: Bool = false, guessed: Bool = false) {
        let required = corroborating
            ? Self.minBusyForCorroboratedQuiesce : Self.minBusyForQuiesceAttention
        let startedAt = busyStartedAt[session.id]
        let busyLongEnough = startedAt.map {
            Date().timeIntervalSince($0) >= required
        } ?? false
        clearBusy(session)
        guard busyLongEnough else { return }
        let id = session.id
        quiesceTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.quiesceTimers[id] = nil
            // The settle window exists to find out whether the program really
            // stopped, and the answer is not always "progress resumed" (which
            // cancels this timer through `markBusy`): the screen tier re-claims
            // a still-moving screen on its next sample, up to a full interval
            // later, which can land *after* this fires. A session that is busy
            // again by now, or is a debounce away from it, did not finish — a
            // subprocess's `9;4;0` cleared its spinner for a second, that's all.
            guard !session.isBusy, self.busyTimers[id] == nil else { return }
            // The agent went quiet without an explicit prompt — inferred
            // turn-end. If it *did* prompt (a notification / action-required
            // title), that already raised a louder .needsInput which priority
            // keeps from being downgraded here.
            self.announceTurnEnd(session, kind: kind, startedAt: startedAt, source: source,
                                 guessed: guessed)
        }
        quiesceTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiesceSettleDelay, execute: work)
        // A pending notification is the one thing that must fire on time even
        // with the app buried; hold off App Nap for it.
        updateAgentActivityAssertion()
    }

    /// Raises the attention for a turn that went quiet. For Claude, whose
    /// terminal signals look the same however a turn ended, the end of its
    /// transcript is read first (`ClaudeTranscriptTail`): an API error is a
    /// failure, not "your move", and a question or a plan it is waiting on is
    /// input it needs. A compaction Claude ran on its own while idle was no
    /// turn, and neither was a screen-tier guess with nothing written behind
    /// it: those raise nothing. Codex's quiets all need a turn in a rollout
    /// behind them, its own title spinner included. Anything else, or a
    /// transcript that can't be found, keeps the inferred kind.
    ///
    /// The body is what the agent said: the start of its last answer, or the
    /// question it is waiting on (`AgentAnswer`), read from Claude's
    /// transcript, Codex's rollout or Pi's session file. The fixed text is
    /// what's left when there is no file to read or nothing in it to quote.
    private func announceTurnEnd(_ session: Session, kind: AttentionKind, startedAt: Date?,
                                 source: String, guessed: Bool) {
        let raise = { [weak self, weak session] (kind: AttentionKind, body: String, tag: String, seen: Bool) in
            guard let self, let session else { return }
            self.raiseAttention(session, kind: kind, title: session.name, body: body,
                                source: "\(source)-quiesce\(tag)", seen: seen)
            // A finished turn is the best moment to (re)name the session from
            // what's now on screen — even when it's the one you're watching.
            self.considerAutoName(session)
        }
        let inferredBody: String
        switch kind {
        case .needsInput: inferredBody = "Waiting on you"
        case .failed: inferredBody = "Stopped with an error"
        default: inferredBody = "Finished, your move"
        }
        // Only these quiets are the conversation file's to judge; a louder
        // kind came from a signal of the agent's own.
        let judged = kind == .turnDone || guessed
        // Codex is checked with no conversation known, too (see below).
        guard let agent = session.runningAgent, AgentConversation.exact.contains(agent),
              let cwd = session.runningCwd ?? session.cwd, let startedAt,
              session.liveConversationID != nil || agent == "codex" && judged
        else { return raise(kind, inferredBody, "", false) }
        let id = session.liveConversationID
        // Other sessions' conversations, which are never this one's evidence.
        let others = Set(sessions.compactMap { $0 === session ? nil : $0.liveConversationID })
        // Two seconds of slack: the prompt that opened the turn is stamped
        // when the agent wrote it, which can be a moment before its busy edge
        // reached us.
        let since = startedAt.addingTimeInterval(-2)
        DispatchQueue.global(qos: .userInitiated).async {
            var verdict: ClaudeTranscriptTail.Verdict?
            var answer: String?
            // When the conversation last moved: whether that was already read.
            var lastWrite: Date?
            switch (agent, id) {
            case ("claude", let id?):
                if let tail = AgentResumeStore.claudeTranscript(id: id, cwd: cwd)
                    .flatMap(ClaudeTranscriptTail.readTail(of:)) {
                    if judged { verdict = ClaudeTranscriptTail.verdict(tail, since: since, guessed: guessed) }
                    answer = ClaudeTranscriptTail.lastAnswer(tail, since: since)
                    lastWrite = ClaudeTranscriptTail.lastWrite(tail, since: since)
                }
            case ("codex", _):
                // Unlike Claude's, every quiet is checked, not only a guess:
                // Codex's title spinner also turns for things that aren't
                // turns (`AgentConversation.Codex.turnReading`). What a wrong
                // "no turn" costs is the guess only: unfocused, Codex sends
                // its own OSC 9 at a real turn end.
                switch AgentConversation.Codex.turnReading(conversation: id, cwd: cwd, since: since,
                                                           others: others) {
                case .turn(let tail, let last):
                    answer = AgentAnswer.codex(tail, since: since)
                    lastWrite = last
                case .noTurn: if judged { verdict = .noTurn }
                case .unknown: break
                }
            case ("pi", let id?):
                answer = AgentConversation.Pi.file(id: id, cwd: cwd)
                    .flatMap(ClaudeTranscriptTail.readTail(of:))
                    .flatMap { AgentAnswer.pi($0, since: since) }
            default:
                break
            }
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                // Busy again while the file was read: the turn didn't end.
                guard !session.isBusy, self.busyTimers[session.id] == nil else { return }
                if verdict == .noTurn { return self.logNoTurn(session, source: source) }
                // You read how it ended before this got here: the screen tier
                // waits for a still screen, your scrolling restarts that wait,
                // and so a turn you read to the end was "over" a few seconds
                // after you went to another app. Not news by then.
                // Only for "finished": a failure or a question that came
                // after the last write (an API retried for minutes, then gave
                // up) was never on screen to be read.
                let seen = lastWrite.map {
                    self.seen.saw(session.id, writtenAt: $0, now: Date(), present: !Self.userIsAway())
                } ?? false
                AgentStatusLog.log.debug("""
                    \(source, privacy: .public)-quiesce: last written \(lastWrite?.description ?? "unknown", privacy: .public), \
                    seen=\(seen, privacy: .public) id=\(session.id.uuidString, privacy: .public)
                    """)
                // An error's words are the error's, not the last answer's.
                let body = kind == .failed ? inferredBody : answer ?? inferredBody
                let tag = answer == nil || kind == .failed ? "" : "-answer"
                // A guess that already read the screen as blocked keeps that.
                guard kind == .turnDone else { return raise(kind, body, tag, false) }
                switch verdict {
                case .apiError(let message): raise(.failed, message, "-apierror", false)
                case .question: raise(.needsInput, answer ?? "Asking you a question", "-question", false)
                case .plan: raise(.needsInput, answer ?? "Plan ready for review", "-plan", false)
                case .noTurn, nil: raise(kind, body, tag, seen)
                }
            }
        }
    }

    /// A quiet that turned out to be no turn: nothing is raised, and the log
    /// says so, since a dot that didn't appear is otherwise invisible.
    private func logNoTurn(_ session: Session, source: String) {
        AgentStatusLog.log.debug("""
            \(source, privacy: .public)-quiesce: no turn, nothing raised \
            (\(session.runningAgent ?? "?", privacy: .public)) \
            id=\(session.id.uuidString, privacy: .public)
            """)
    }

    /// The folder a session in `path` belongs in, made if there's none: a
    /// worktree's goes with its repository (`folder(forWorktreeAt:)`, else a
    /// new folder for the repository), anything else in the deepest folder
    /// covering it, else a new folder named for the directory. nil for `/`,
    /// which is no project. ⌘O's rule (`openFolder`).
    private func folder(forDirectory path: String) -> String? {
        let path = FolderRoot.normalize(path) ?? path
        if let linked = GitWorktree.linked(containing: path),
           let home = linked.repoHome.flatMap(FolderRoot.normalize) {
            if let existing = folder(forWorktreeAt: path, repoHome: home) { return existing }
            let repo = (home as NSString).lastPathComponent
            guard repo != "/", !repo.isEmpty else { return nil }
            let folder = addFolder(named: repo)
            setRoot(home, ofFolder: folder)
            return folder
        }
        if let existing = FolderRoot.folder(containing: path, in: folderRoots) { return existing }
        // A directory's name is always a usable folder name (it cannot
        // contain the separator sidebar names are split on), with exactly one
        // exception: the filesystem root, whose last component *is* that
        // separator. `/` isn't a project, so it gets no folder rather than one
        // named "/" that `SessionName` would then have to make sense of.
        let leaf = (path as NSString).lastPathComponent
        guard leaf != "/", !leaf.isEmpty else { return nil }
        // `addFolder` makes the name unique, so a second `web` from another
        // project gets "web 2" rather than joining the first one: two
        // directories are two projects however they're spelled.
        let folder = addFolder(named: leaf)
        setRoot(path, ofFolder: folder)
        return folder
    }

    // MARK: - Attention

    /// The user can already see this session (Wortel is frontmost, the window
    /// is on screen, the session is selected, and someone is at the Mac), so
    /// it never needs to shout for attention.
    private func isActivelyViewing(_ session: Session) -> Bool {
        isOnScreen(session) && !Self.userIsAway()
    }

    /// The session is what Wortel's window shows, whether or not anyone is
    /// looking at it.
    private func isOnScreen(_ session: Session) -> Bool {
        appIsActive && windowIsVisible && session.id == selectedID
    }

    /// How long the Mac has to go without a key, a click, a scroll or the
    /// pointer moving before whoever was in front of it counts as gone.
    ///
    /// Without it, the session on screen was "seen" for as long as Wortel was
    /// frontmost: start an agent, go for coffee, and the turn it finished
    /// while you were away raised nothing at all, no dot and no banner,
    /// because Wortel took the screen for your eyes. A minute is long enough
    /// that reading an answer without touching anything still counts as
    /// watching, and short enough to cover getting up.
    static let awayAfter: TimeInterval = 60

    /// Whether nobody has touched the Mac for `awayAfter`: any input, in any
    /// app, from the window server's own count (`.combinedSessionState`).
    /// Read when a signal arrives, never polled, and it needs no permission:
    /// it is how long since an event, not what the event was.
    static func userIsAway() -> Bool {
        // `kCGAnyInputEventType`, which Swift has no case for.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            >= awayAfter
    }

    /// Sessions whose attention was raised while they were on screen and
    /// nobody was there (`userIsAway`). Such an attention is not answered by
    /// the window being on screen, since it already was: not by Wortel
    /// becoming active or the window coming back from a sleeping display, only
    /// by the user doing something in that session's terminal
    /// (`noteUserInput`). Selecting it still counts, as for any session.
    @ObservationIgnored private var raisedWhileAway: Set<Session.ID> = []

    /// Someone typed, clicked, pasted or scrolled in this session's terminal.
    /// That is the user back and in front of it, which is what an attention
    /// raised while they were away waits for. Called for every key, so it is
    /// a set lookup and nothing more until there is something to clear.
    private func noteUserInput(_ session: Session) {
        guard raisedWhileAway.contains(session.id), isOnScreen(session) else { return }
        clearAttention(session)
        scheduleCaughtUp(session)
    }

    /// Attention answered: drop the sidebar dot, re-count the Dock badge, and
    /// let the app layer retract the session's notification. The one funnel,
    /// so no way of answering leaves part of an attention behind. A batch
    /// passes `refreshingBadge: false` and counts once for the lot; returns
    /// whether there was a dot to clear.
    @discardableResult
    private func clearAttention(_ session: Session, refreshingBadge: Bool = true) -> Bool {
        raisedWhileAway.remove(session.id)
        guard session.attention != nil else { return false }
        session.attention = nil
        attentionContent[session.id] = nil
        attentionSince[session.id] = nil
        if refreshingBadge { refreshDockBadge() }
        onAttentionCleared?(session)
        return true
    }

    /// The clear for the session the window has just been put in front of
    /// someone (Wortel activated, the window uncovered): its attention is
    /// answered, unless it was raised while that someone was away from the
    /// window it was already on, in which case it waits for them to touch it.
    private func clearAttentionOnShow(_ session: Session) {
        guard !raisedWhileAway.contains(session.id) else { return }
        clearAttention(session)
    }

    /// What each session's standing notification says, kept so a rename can
    /// rewrite it. `title` is nil when the banner was titled with the session's
    /// own name, which is the part that goes stale.
    @ObservationIgnored
    private var attentionContent:
        [UUID: (kind: AttentionKind, title: String?, body: String, postedAt: Date)] = [:]
    /// When each session's current episode began: its first signal, not its
    /// latest (an agent that re-emits per tool call would otherwise always
    /// read "now"). What "waiting 4m" counts from.
    @ObservationIgnored private var attentionSince: [UUID: Date] = [:]

    /// What a waiting session said (the body of its notification, else its
    /// title when that isn't just the session's name), and since when.
    func attentionNote(for session: Session) -> (message: String?, since: Date?) {
        let content = attentionContent[session.id]
        let body = content?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = body.isEmpty ? content?.title : body
        return (message, attentionSince[session.id])
    }

    /// How late a rename may still rewrite a banner.
    ///
    /// The renames this exists for land within seconds. Past that the banner has
    /// been seen, dismissed or swept into Notification Center, and re-posting
    /// would put a fresh one on screen for an event the user already dealt with,
    /// which is a worse bug than the stale name it would be correcting.
    private static let attentionRewriteWindow: TimeInterval = 60

    /// Rewrite a renamed session's standing notification.
    ///
    /// A turn-ending notification is posted with the session's name, and then
    /// the session is very often renamed *moments later*: `progressEnded` calls
    /// `considerAutoName` on the next line, and that runs a model off-main and
    /// comes back seconds afterwards, by which point the banner is already on
    /// screen. The sidebar then says "Wortel memory usage visualization" while
    /// the notification still says "Session 3" — the same event, described by
    /// two different names, which reads as a notification about some other
    /// session. The agent-title path renames on the same terms.
    ///
    /// Re-posting is enough to fix it because the app layer keys notifications
    /// by session id, so this replaces the banner in place rather than adding a
    /// second one. `alert: false` keeps it silent: the ding belonged to the
    /// original event, and correcting a name is not a new one.
    private func refreshAttentionNotification(_ session: Session) {
        guard session.attention != nil, let content = attentionContent[session.id],
              Date().timeIntervalSince(content.postedAt) < Self.attentionRewriteWindow
        else { return }
        onNeedsAttention?(session, content.kind, content.title ?? session.name, content.body, false)
    }

    // MARK: - What a session is doing (`wortel list`, `wortel wait`)

    /// One reading of a session's activity, from the tracking the sidebar's
    /// spinner and dots already run on. Nothing new is detected for it: the
    /// CLI reports what the app believes, so `wortel list` and the sidebar
    /// can never disagree.
    struct ActivityReading {
        /// Working, or about to show as working (a start inside the debounce).
        var busy: Bool
        /// Just stopped, inside the settle window that decides whether the
        /// stop was a pause between tools or the end of the turn.
        var settling: Bool
        /// Its title says it's blocked on you (Codex's "Action Required").
        var asksForAction: Bool
        /// How its last stretch of work ended, if it said.
        var outcome: AttentionKind?
        /// When it last reported starting work.
        var lastStarted: Date?
    }

    func activity(of session: Session) -> ActivityReading {
        let id = session.id
        return ActivityReading(
            busy: session.isBusy || busyTimers[id] != nil,
            settling: quiesceTimers[id] != nil,
            asksForAction: titleShowsActionRequired.contains(id),
            outcome: turnOutcomes[id],
            lastStarted: lastBusyReports[id])
    }

    /// The session's terminal, created now if it hasn't been yet (a session
    /// restored at launch and not shown since), as the warm-up would: no
    /// selection, no focus. nil while its worktree is still being made, when
    /// there is no folder for a shell to start in.
    func warmSurface(of session: Session) -> SurfaceView? {
        guard sessions.contains(where: { $0 === session }), session.preparation == nil else { return nil }
        let view = session.ensureSurfaceView(runtime: runtime)
        // Read or typed into from outside: it needs its terminal, and goes
        // back to sleep later if it is still out of sight.
        if view.isHibernated {
            HibernationPolicy.shared.shown(view)
            if view.isHidden || view.superview == nil { HibernationPolicy.shared.hidden(view) }
        }
        return view
    }

    /// A session by id — what the CLI has, since a shell knows its session as
    /// `$WORTEL_SESSION_ID` and nothing else. A side terminal's shell carries
    /// its tab's id there (it keys that terminal's own agent marker), so a
    /// terminal's id finds the session it's in.
    func session(id: Session.ID) -> Session? {
        sessions.first { $0.id == id } ?? sessions.first { $0.owns(terminal: id) }
    }

    /// Raise attention on a session from outside: `wortel notify`.
    ///
    /// Deliberately the *same* path as a program's own OSC 9/777 — same
    /// classification of the text, same dot, same badge, same one-per-session
    /// notification. A `make && wortel notify "Build done"` should be
    /// indistinguishable from an agent that emits the escape sequence itself,
    /// because to the person across the room it is the same event.
    func notify(_ session: Session, title: String, body: String) {
        raiseAttention(session,
                       kind: AttentionKind.classify(notificationTitle: title, body: body),
                       title: title.isEmpty ? session.name : title,
                       body: body, source: "cli")
    }

    /// A session wants the user: raise the sidebar dot (which overrides the
    /// busy spinner), badge the Dock, and post a native notification — unless
    /// the user is already looking at it. A lower-priority signal never
    /// downgrades a louder one already showing (a "finished" ping can't mask a
    /// pending "needs input"). Safe to call repeatedly: a signal that says
    /// what the standing attention already says is dropped here, because the
    /// app layer keys notifications by session, and replacing one is still a
    /// banner sliding in (a program ringing the bell every few seconds, or an
    /// agent re-emitting its prompt, would otherwise be a banner each time).
    /// New words for the same kind still go out, silently, so the banner
    /// keeps up with what the agent is asking.
    ///
    /// `seen`: what it is about was already in front of the user
    /// (`SeenLedger`), so it is answered as if they were looking now.
    private func raiseAttention(_ session: Session, kind: AttentionKind, title: String, body: String,
                                source: String, seen: Bool = false) {
        // Logged before the gates, and always: when a dot shows up on a session
        // the user hasn't touched in days, the only question worth answering is
        // which signal raised it — and that used to be unanswerable, because
        // every trace line named the signal without naming the session.
        AgentStatusLog.log.debug("""
            attention \(source, privacy: .public) kind=\(String(describing: kind), privacy: .public) \
            \(seen ? "already seen " : "", privacy: .public)id=\(session.id.uuidString, privacy: .public) name=\(session.name, privacy: .private)
            """)
        // Before the viewing gate: whether anyone is looking doesn't change
        // how the turn ended, which is what `activity(of:)` reports.
        if turnOutcomes[session.id].map({ kind.priority >= $0.priority }) ?? true {
            turnOutcomes[session.id] = kind
        }
        // Play a sound only when the state actually escalates — a fresh episode
        // or a jump to a louder kind. A program that re-emits the same kind
        // (some agents fire a notification per tool call) updates the banner
        // text silently instead of spamming dings.
        let current = session.attention
        let standing = attentionContent[session.id].map {
            AttentionRaise.Standing(kind: $0.kind, title: $0.title ?? session.name, body: $0.body)
        }
        guard case .raise(let alert, let startsEpisode, let whileAway) = AttentionRaise.decide(
            kind: kind, title: title, body: body, current: current, standing: standing,
            activelyViewing: seen || isActivelyViewing(session), onScreen: isOnScreen(session))
        else { return }
        if startsEpisode { attentionSince[session.id] = Date() }
        // Past the gate while on screen means nobody is there to see it, so
        // being on screen can't answer it either (`raisedWhileAway`).
        if whileAway { raisedWhileAway.insert(session.id) }
        session.attention = kind // observed → sidebar dot
        // The quieter tier: mark it unread too, at the highest kind seen, so the
        // trail survives past the loud dot until you've actually engaged.
        if session.unread == nil { unreadSince[session.id] = Date() }
        if session.unread.map({ kind.priority > $0.priority }) ?? true {
            session.unread = kind
        }
        refreshDockBadge()
        // Remembered so a rename can rewrite the banner. nil title means "it was
        // the session's own name", which is exactly what a rename invalidates.
        attentionContent[session.id] = (kind, title == session.name ? nil : title, body, Date())
        onNeedsAttention?(session, kind, title, body, alert)
        // Past every gate, so this counts episodes a person was actually shown
        // rather than signals the detector saw. `title` and `body` are the
        // agent's own words about the user's own work and go no further than
        // this line: only the kind is reported.
        Telemetry.capture(.agentAttention(kind: AttentionCause(kind),
                                          agent: AgentName(command: session.runningAgent)))
    }

    /// Start the "caught up" clock for a session: if it stays actively-viewed
    /// for the dwell window, drop its unread mark. A glance shorter than the
    /// dwell (or navigating away) leaves the mark in place. Safe to call
    /// repeatedly — it restarts the clock.
    /// A "come back to this" flag: the quiet unread ring, set by hand. It
    /// holds while you're in the session (its caught-up clock is stopped) and
    /// clears the usual way, once you've spent time in it after coming back.
    func markUnread(_ session: Session) {
        if session.unread == nil {
            session.unread = .finished
            unreadSince[session.id] = Date()
        }
        session.markedUnread = true
        cancelCaughtUp(session.id)
    }

    /// The sidebar selection's Mark as Unread. Nothing here is saved, so one
    /// pass is already one change.
    func markUnread(_ batch: [Session]) {
        batch.forEach(markUnread)
    }

    /// The sidebar selection's Mark as Read: the dot, the ring and a mark made
    /// by hand all go, as if each had been visited, without visiting them (no
    /// shell started, the terminal stays where it is). The Dock badge and the
    /// menu bar's list are counted once for the lot.
    func markRead(_ batch: [Session]) {
        var cleared = false
        for session in batch {
            // Through the funnel the single answers take, so nothing of the
            // attention (an away mark, the banner) outlives its dot.
            if clearAttention(session, refreshingBadge: false) { cleared = true }
            if session.unread != nil { session.unread = nil }
            if session.markedUnread { session.markedUnread = false }
            cancelCaughtUp(session.id)
        }
        if cleared { refreshDockBadge() }
    }

    // MARK: - Reminders

    /// Slack's "Remind me about this", for a session: at `date` it comes back
    /// as the unread ring and a banner. nil cancels. Visiting the session in
    /// between doesn't: you asked to be reminded at that time, not the next
    /// time you happened by.
    func setReminder(_ session: Session, at date: Date?) {
        // Still open: Custom…'s sheet can be answered after its session
        // closed, and a banner for a session that's gone leads nowhere.
        guard sessions.contains(where: { $0 === session }), session.remindAt != date else { return }
        session.remindAt = date
        // Set again after it went off (a snooze): the one that went off is
        // done with, or the next visit would take the new one's banner back.
        remindedIDs.remove(session.id)
        onReminderChanged?(session, date)
        scheduleSave()
        armReminderTimer()
        if date != nil { Telemetry.capture(.reminderSet) }
    }

    /// The same for the sidebar's selection.
    func setReminder(_ batch: [Session], at date: Date?) {
        batch.forEach { setReminder($0, at: date) }
    }

    /// The one timer behind every reminder: set for the earliest, re-armed as
    /// each goes off or changes. Nothing runs for a session that has none.
    @ObservationIgnored private var reminderTimer: DispatchWorkItem?
    /// Sessions whose reminder went off and that haven't been visited since:
    /// their banner is taken back when they are.
    @ObservationIgnored private var remindedIDs: Set<Session.ID> = []

    /// Counts the midnights since launch. A row that says "Tomorrow at
    /// 09:00" reads it, so the line is written again when that becomes today.
    private(set) var reminderDay = 0
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    private func watchDayChange() {
        guard dayObserver == nil else { return }
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reminderDay += 1 }
            }
    }

    /// On the wall clock, so a Mac asleep through the time reminds you as it
    /// wakes, rather than late by however long it slept.
    private func armReminderTimer() {
        reminderTimer?.cancel()
        reminderTimer = nil
        guard let next = sessions.compactMap(\.remindAt).min() else { return }
        watchDayChange()
        let work = DispatchWorkItem { [weak self] in self?.remindersDue() }
        reminderTimer = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, next.timeIntervalSinceNow), execute: work)
    }

    /// After launch: every reminder handed to Notification Center again (a
    /// file written by another build may have ones it never heard of), and
    /// the ones that came due while Wortel was closed go off now.
    private func syncReminders() {
        let now = Date()
        scheduleReminderFallbacks(now: now)
        remindersDue(now: now, launching: true)
    }

    /// Every pending reminder handed to Notification Center again, under the
    /// session's name as it is now. At launch, and on the way out: the one
    /// left there is only ever shown with Wortel quit, and a session may have
    /// been renamed since its reminder was set.
    func scheduleReminderFallbacks(now: Date = Date()) {
        for session in sessions {
            if let date = session.remindAt, date > now { onReminderChanged?(session, date) }
        }
    }

    /// How long after a reminder's time the banner left with Notification
    /// Center comes: a running Wortel takes it back within that.
    static let reminderFallbackDelay: TimeInterval = 60

    /// Takes back what a reminder that went off left behind, once its session
    /// has been come to. False if none had.
    @discardableResult
    private func answerReminder(_ session: Session) -> Bool {
        guard remindedIDs.remove(session.id) != nil else { return false }
        onReminderChanged?(session, nil)
        return true
    }

    /// `launching`: these came due while Wortel was closed. Nobody was
    /// looking, whatever the window's flags say this early, so each gets its
    /// ring; and Notification Center has shown its own banner for any more
    /// than the fallback's delay overdue, so a second isn't posted.
    private func remindersDue(now: Date = Date(), launching: Bool = false) {
        for session in sessions {
            guard let date = session.remindAt, date <= now else { continue }
            session.remindAt = nil
            scheduleSave()
            if !launching, isActivelyViewing(session) {
                // You're already here: the ring flashes, and that's all.
                attentionFlash = AttentionFlash(kind: .finished)
                onReminderChanged?(session, nil)
            } else {
                markUnread(session)
                remindedIDs.insert(session.id)
                if !launching || now.timeIntervalSince(date) < Self.reminderFallbackDelay {
                    onReminderDue?(session)
                }
            }
        }
        armReminderTimer()
    }

    /// When each session started wanting you, for Sort Unread First's "most
    /// recent first": set as its unread mark appears, by a signal or by hand.
    /// A live dot sorts by its episode's start (`attentionSince`) instead.
    @ObservationIgnored private var unreadSince: [UUID: Date] = [:]

    /// Where a session sorts under Sort Unread First, nil for one that's read.
    /// A live dot ranks by its kind's loudness; a session only marked unread
    /// (the hollow ring, or ⇧⌘U) after every live dot, as the quieter signal
    /// it is drawn as.
    func sidebarSortKey(for session: Session) -> SidebarSort.Key? {
        if let kind = session.attention {
            return .init(rank: kind.priority,
                         since: attentionSince[session.id] ?? unreadSince[session.id] ?? .distantPast)
        }
        guard session.unread != nil else { return nil }
        return .init(rank: 0, since: unreadSince[session.id] ?? .distantPast)
    }

    /// Give a session a colour, or take it away (nil). By hand only: the menu
    /// or `wortel mark`; nothing in the app sets or clears one.
    func setColour(_ session: Session, _ colour: SessionColour?) {
        guard session.colour != colour else { return }
        session.colour = colour
        scheduleSave()
    }

    /// The same for the sidebar's selection, saved once.
    func setColour(_ batch: [Session], _ colour: SessionColour?) {
        let changing = batch.filter { $0.colour != colour }
        guard !changing.isEmpty else { return }
        changing.forEach { $0.colour = colour }
        scheduleSave()
    }

    // MARK: - Sidebar selection

    /// How a row was clicked: alone, ⌘ (toggle it), or ⇧ (a range to it).
    enum SidebarClick { case plain, toggle, extend }

    /// A click on a session's row, with the rules in `SessionSelection`. A
    /// plain click shows the row (and collapses the selection, through
    /// `selectedID`); a modifier click changes the selection and leaves the
    /// terminal where it is, unless it took the lead itself out.
    func clickSidebarRow(_ id: Session.ID, _ click: SidebarClick) {
        var selection = sidebarSelection
        var lead = selectedID
        switch click {
        case .plain:
            selection.collapse(to: id)
            lead = id
        case .toggle:
            lead = selection.toggle(id, lead: lead, in: sidebarRowOrder)
        case .extend:
            selection.extend(to: id, lead: lead, in: sidebarRowOrder)
        }
        if selection != sidebarSelection { sidebarSelection = selection }
        if lead != selectedID { selectedID = lead }
    }

    /// Esc, or typing in the terminal: back to the session on screen alone.
    func collapseSidebarSelection() {
        guard sidebarSelection.isMultiple else { return }
        var collapsed = sidebarSelection
        collapsed.collapse(to: selectedID)
        sidebarSelection = collapsed
    }

    /// Whether `session` is part of a selection of more than one: its
    /// right-click acts on all of them.
    func isInMultipleSelection(_ session: Session) -> Bool {
        sidebarSelection.isMultiple && sidebarSelection.ids.contains(session.id)
    }

    /// The selected sessions, as drawn.
    var sidebarSelectedSessions: [Session] {
        let members = sidebarSelection.members(lead: selectedID)
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        // Drawn order, then anything selected that isn't drawn (it can't be,
        // `prune` sees to that, but never drop a member silently).
        var ids = sidebarRowOrder.filter(members.contains)
        ids += members.subtracting(ids).sorted { $0.uuidString < $1.uuidString }
        return ids.compactMap { byID[$0] }
    }

    /// The rows drawn changed (a section folded): what's no longer drawn
    /// leaves the selection.
    func pruneSidebarSelection(toDrawn drawn: [Session.ID]) {
        sidebarRowOrder = drawn
        guard sidebarSelection.isMultiple else { return }
        var pruned = sidebarSelection
        pruned.prune(to: Set(drawn), lead: selectedID)
        if pruned != sidebarSelection { sidebarSelection = pruned }
    }

    private func scheduleCaughtUp(_ session: Session) {
        unreadDwellTimers.removeValue(forKey: session.id)?.cancel()
        // Marked by hand: held until you come back to it (see `selectedID`),
        // not cleared by a menu closing or the app coming forward while you're
        // still in it.
        guard !session.markedUnread else { return }
        guard session.unread != nil, isActivelyViewing(session) else { return }
        let id = session.id
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.unreadDwellTimers[id] = nil
            session.unread = nil // caught up → drop the hollow dot
        }
        unreadDwellTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unreadDwellDelay, execute: work)
    }

    /// You navigated away (or backgrounded) before the dwell elapsed — keep the
    /// unread mark.
    private func cancelCaughtUp(_ id: Session.ID?) {
        guard let id else { return }
        unreadDwellTimers.removeValue(forKey: id)?.cancel()
    }

    /// Mark the sessions whose folder no longer exists (`Session.folderIsGone`).
    /// A `stat` per session, when Wortel comes forward: that's when a folder
    /// deleted from elsewhere would be news.
    func checkFolders() {
        let fm = FileManager.default
        for session in sessions {
            guard let path = session.cwd ?? session.originCwd, !path.isEmpty else { continue }
            let gone = !fm.fileExists(atPath: path)
            if session.folderIsGone != gone { session.folderIsGone = gone }
        }
    }

    /// Wortel became frontmost: the user is now looking at the selected
    /// session, so clear its attention and start its caught-up clock. Not an
    /// attention raised while they were away from it on screen: that waits
    /// for them to touch the session (`raisedWhileAway`).
    func appDidBecomeActive() {
        appIsActive = true
        noteShowing()
        checkFolders()
        // Focus moving in or out makes every agent TUI redraw (they ask for
        // focus reports, and they answer them) — one frame of change on screens
        // that are otherwise standing still. Re-baseline before the next sample
        // so ⌘-tabbing can't manufacture a turn in a session you last touched
        // days ago.
        rebaselineAgentScreens()
        if let selected {
            clearAttentionOnShow(selected)
            scheduleCaughtUp(selected)
        }
    }

    func appDidResignActive() {
        appIsActive = false
        noteShowing()
        rebaselineAgentScreens()
        cancelCaughtUp(selectedID)
    }

    /// The main window's on-screen visibility changed (occlusion state /
    /// miniaturization). Becoming visible while frontmost means the user can
    /// now see the selected session — clear its attention, same as activate,
    /// with the same exception: a display waking from sleep uncovers the
    /// window too, and is not someone reading it.
    func windowVisibilityChanged(_ visible: Bool) {
        windowIsVisible = visible
        noteShowing()
        rebaselineAgentScreens() // uncovering the window repaints, same as focus
        if visible, appIsActive, let selected {
            clearAttentionOnShow(selected)
            scheduleCaughtUp(selected)
        } else {
            cancelCaughtUp(selectedID)
        }
    }

    /// What a collapsed folder should show on behalf of the sessions inside it.
    ///
    /// Only when collapsed: an open folder's rows carry their own dots, and
    /// repeating them on the header is noise. A rollup exists to surface what is
    /// *hidden* — a blocked agent behind a collapsed folder is otherwise
    /// completely silent in the sidebar, which is the one thing the attention
    /// system exists to prevent.
    func attention(inFolder folder: String) -> AttentionKind? {
        guard collapsedFolders.contains(folder) else { return nil }
        return AttentionKind.loudest(
            of: sessions.lazy.filter { $0.folderPath == folder }.map(\.attention))
    }

    /// Dock badge = number of background sessions waiting on the user.
    private func refreshDockBadge() {
        let count = sessions.reduce(into: 0) { $0 += $1.needsAttention ? 1 : 0 }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        // Setting the label is supposed to be enough, and mostly is; asking for
        // the redraw costs nothing and removes the one case where it isn't.
        NSApp.dockTile.display()
        onAttentionChanged?()
    }

    // MARK: - Auto-naming

    /// Something substantial just finished in `session` (an agent turn ended, or
    /// a long command exited) — a good moment to (re)summarise its terminal into
    /// a sidebar name. Heavily gated so it stays cheap and never surprises:
    /// on-device model must be available, the name must not be user-set, and the
    /// throttle / "screen unchanged" / "too little on screen" checks must pass.
    /// The model call runs off the hot path and applies its result on the main
    /// actor; a no-op everywhere Apple Intelligence is unavailable.
    private func considerAutoName(_ session: Session) {
        guard #available(macOS 26.0, *), SessionNameGenerator.isAvailable else { return }
        // The model fills in only where nobody better has spoken: a session
        // the user named, that its agent has titled, or that was named from
        // its first prompt, keeps that name.
        guard session.nameSource < .prompt else { return }
        guard let raw = session.surfaceView?.readScreenText() else { return }
        let distilled = SessionNameGenerator.distill(raw)

        let id = session.id
        let now = Date()
        guard case .proceed(let lines) = autoNameThrottle.decide(
            screen: distilled, state: autoNameState[id] ?? .init(), now: now)
        else { return }

        var state = autoNameState[id] ?? .init()
        state.inFlightSince = now
        autoNameState[id] = state

        let cwd = session.cwd
        let current = session.leafName
        // SessionManager is @MainActor, so this Task is main-actor-isolated; the
        // model does its heavy work off-main internally and resumes us here.
        Task { [weak self, weak session] in
            let name = try? await SessionNameGenerator.generate(
                screenText: distilled, cwd: cwd, currentName: current)
            guard let self else { return }
            // Recorded whether or not the model produced anything: the cooldown
            // has to anchor on the *attempt*, or a summariser that keeps failing
            // is retried at full speed forever.
            var state = self.autoNameState[id] ?? .init()
            state.inFlightSince = nil
            state.lastAttemptAt = Date()
            state.lastLines = lines
            self.autoNameState[id] = state

            guard let session, self.sessions.contains(where: { $0.id == id }),
                  session.nameSource < .prompt, // renamed, or better-named, while we waited
                  let name, !name.isEmpty, name != session.leafName else { return }
            self.applyAutoName(session, to: name, source: .model)
        }
    }

    /// Set a session's automatic name, preserving any folder prefix (the name
    /// *is* the folder membership, so only the leaf changes), and record where
    /// it came from so the precedence in `Session.NameSource` holds from here on.
    ///
    /// The leaf is made slash-free first (`SessionName.asLeaf`): every automatic
    /// name passes through here, and a slash in one would otherwise be read back
    /// as a folder. Callers compare the raw name against `leafName` to skip
    /// no-ops, which a title with a path in it defeats, so the check is repeated
    /// on the safe leaf: an agent retitles several times a second.
    private func applyAutoName(_ session: Session, to rawLeaf: String, source: Session.NameSource) {
        let leaf = SessionName.asLeaf(rawLeaf)
        guard leaf != session.leafName || session.nameSource != source else { return }
        session.name = session.folderPath.map { "\($0)/\(leaf)" } ?? leaf
        session.nameSource = source
        normalizeOrder()
        scheduleSave()
        nameBranchForWork(session)
        // The rename that races the turn-end banner: this is the one that
        // arrives seconds after `progressEnded` posted it.
        refreshAttentionNotification(session)
        // Whether automatic naming earns its keep is visible in the ratio of
        // these to hand renames, and nowhere else. `leaf` stays here.
        Telemetry.capture(.sessionRenamed(automatic: true))
    }

    /// An agent's terminal title, taken as the session's name. Claude Code
    /// titles its conversation from the first prompt and pushes that title
    /// into the terminal, so this is where a session gets its real name, a
    /// few seconds in, from the conversation itself. See `AgentTitle` for what
    /// counts as one and `docs/session-naming.md` for why it outranks the model.
    ///
    /// Titles are bursty (a working agent retitles several times a second to
    /// animate its glyph), so this is a parse and a string compare per title,
    /// and only an actual change reaches the sidebar or the store.
    private func adoptAgentTitle(_ session: Session, title: String) {
        guard session.nameSource != .user else { return }
        guard let name = AgentTitle.sessionName(
            fromTitle: title, placeholder: Self.defaultTitle(forCwd: session.cwd))
        else { return }
        guard name != session.leafName else { return }
        applyAutoName(session, to: name, source: .agent)
    }

    // MARK: - Naming from the first prompt

    /// An agent just launched in `session`: listen for the first prompt the
    /// user types into it, and name the session from that. This is how every
    /// agent gets what Claude Code's own title gives Claude sessions, with no
    /// per-agent code: the prompt is the input every AI app names from, and
    /// Wortel owns the pty it travels down. See `docs/session-naming.md`.
    ///
    /// Not started for a session the user named, an agent that has been running
    /// since before this launch (a keeper reattach: its next line is a
    /// follow-up), or a surface whose input isn't ours to see (the exec-backend
    /// escape hatch). A prompt on the agent's own command line is taken as is.
    private func beginPromptCapture(_ session: Session, marker: AgentMarker) {
        endPromptCapture(session)
        guard session.nameSource != .user else { return }
        let now = Date()
        if let started = marker.startedAt, now.timeIntervalSince(started) > 60 { return }
        let resume = marker.argv.map(FirstPrompt.isResume) ?? false

        if let argv = marker.argv, let prompt = FirstPrompt.fromCommandLine(argv) {
            promptCaptures[session.id] = PromptCapture(startedAt: now, resume: resume, tap: nil)
            nameSession(session, fromPrompt: prompt, capturedAt: now)
            return
        }
        guard let pty = session.surfaceView?.ptyHost else { return }
        let id = session.id
        let tap = PromptTap { [weak self] line in
            // The tap delivers on the main queue; say so to the compiler.
            MainActor.assumeIsolated {
                guard let self, let session = self.sessions.first(where: { $0.id == id }) else { return }
                self.promptLineTyped(session, line: line)
            }
        }
        let capture = PromptCapture(startedAt: now, resume: resume, tap: tap)
        promptCaptures[id] = capture
        pty.promptTap = tap
        let token = capture.token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptCaptureDeadline) { [weak self] in
            guard let self, let session = self.sessions.first(where: { $0.id == id }),
                  self.promptCaptures[id]?.token == token else { return }
            self.endPromptCapture(session)
        }
    }

    /// Stop listening, and let go of the tap so the pty carries nothing extra.
    private func endPromptCapture(_ session: Session) {
        guard promptCaptures.removeValue(forKey: session.id) != nil else { return }
        session.surfaceView?.ptyHost?.promptTap = nil
    }

    /// A line was typed into the agent. Dialog answers and slash commands are
    /// not prompts and keep the wait going; the first real one ends it.
    private func promptLineTyped(_ session: Session, line: String) {
        guard let capture = promptCaptures[session.id] else { return }
        guard let prompt = FirstPrompt.accept(line) else { return }
        session.surfaceView?.ptyHost?.promptTap = nil
        promptCaptures[session.id] = PromptCapture(
            startedAt: capture.startedAt, resume: capture.resume, tap: nil)
        nameSession(session, fromPrompt: prompt, capturedAt: Date())
    }

    /// Turn a first prompt into a name: the on-device model in Claude's style,
    /// or the prompt's own first sentence where there is no model. Applied only
    /// after the hold, and only if nothing better arrived meanwhile.
    private func nameSession(_ session: Session, fromPrompt prompt: String, capturedAt: Date) {
        let id = session.id
        let resume = promptCaptures[id]?.resume ?? false
        Task { [weak self] in
            var title = ""
            if #available(macOS 26.0, *), SessionNameGenerator.isAvailable {
                title = (try? await SessionNameGenerator.generate(prompt: prompt)) ?? ""
            }
            if title.isEmpty { title = FirstPrompt.fallbackTitle(prompt) }
            let remaining = Self.promptTitleHold - Date().timeIntervalSince(capturedAt)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }

            guard let self, let session = self.sessions.first(where: { $0.id == id }) else { return }
            self.promptCaptures.removeValue(forKey: id)
            // A new conversation renames a row an earlier prompt named, the same
            // rule an agent's title follows. A *resumed* conversation's first
            // line is a follow-up: it may replace a placeholder or a screen
            // guess, never a name that was right.
            let ceiling: Session.NameSource = resume ? .prompt : .agent
            guard session.nameSource < ceiling, !title.isEmpty, title != session.leafName
            else { return }
            self.applyAutoName(session, to: title, source: .prompt)
        }
    }

    /// Ask git which branch each worktree session is on, for the ones that
    /// don't know. Sessions written before the branch was persisted, and any
    /// whose checkout was switched by hand, otherwise show the directory's slug
    /// where the branch should be.
    private func resolveWorktreeBranches() {
        for session in sessions where session.isInWorktree && session.worktreeBranch == nil {
            resolveWorktreeBranch(session)
        }
    }

    /// Which linked worktree the session's shell is in, read off the disk
    /// (a stat per level and one small file), so it's current for every row
    /// whoever made the worktree.
    private func noteCheckout(_ session: Session) {
        let linked = session.cwd.flatMap(GitWorktree.linked(containing:))
        if linked != session.linkedCheckout { session.linkedCheckout = linked }
        let home = session.originCwd == session.cwd
            ? linked : session.originCwd.flatMap(GitWorktree.linked(containing:))
        if home != session.homeCheckout { session.homeCheckout = home }
    }

    /// The branch checked out in the worktree the shell is in, off its HEAD
    /// file (no git): after every command and every `cd`, so a `git switch`
    /// typed there or a checkout from the git panel shows on the row, and is
    /// what's archived and offered. False when HEAD names no branch (detached,
    /// or not a linked worktree), for git to answer.
    @discardableResult
    private func noteBranch(_ session: Session) -> Bool {
        guard let root = session.linkedCheckout?.root,
              let branch = GitWorktree.checkedOutBranch(at: root) else { return false }
        if session.worktreeBranch != branch {
            session.worktreeBranch = branch
            scheduleSave()
        }
        return true
    }

    /// The branch checked out where `session` is now: at launch for the ones
    /// that don't know, and whenever a shell lands in another worktree (one an
    /// agent made with `git worktree add`, or `cd`'d into), which is how most
    /// sessions not made by Wortel end up in one. The old answer stays on the
    /// row until the new one is in, so it doesn't flicker; a checkout with no
    /// branch (detached) clears it, and the row shows the checkout's folder.
    private func resolveWorktreeBranch(_ session: Session) {
        guard let cwd = session.cwd else { return }
        Task { [weak self, weak session] in
            let result = await GitService.run(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd)
            // Still in that checkout (a `cd macos` meanwhile is the same one).
            guard result.ok, let session,
                  session.cwd.flatMap(GitWorktree.linked(containing:))?.root
                    == GitWorktree.linked(containing: cwd)?.root
            else { return }
            let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let known: String? = branch.isEmpty || branch == "HEAD" ? nil : branch
            guard session.worktreeBranch != known else { return }
            session.worktreeBranch = known
            self?.scheduleSave()
        }
    }

    // MARK: - Persistence

    /// The addresses of the browsers a session still has, open or closed and
    /// waiting for ⌘⇧T; the rest are gone for good.
    private static func persistedBrowserAddresses(of session: Session) -> [String: String]? {
        let workspace = session.workspace
        let kept = Set((workspace.main + workspace.side + workspace.bottom
                        + workspace.closed.map(\.tab)).compactMap(\.browserID))
        let addresses = session.browserAddresses.filter { kept.contains($0.key) }
        guard !addresses.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: addresses.map { ($0.key.uuidString, $0.value) })
    }

    /// The session list as saved.
    ///
    /// **A save on the way is only a copy of what is known.** It runs after
    /// every prompt in any session (each one reports its directory), so it
    /// reads nothing: which agent runs where comes from the markers, and which
    /// conversation each is in from `noteConversation`, both kept current as
    /// they change. At quit (`vouching`), the one save the next launch most
    /// depends on, each agent is first checked against the process table and
    /// asked once more which conversation it is in.
    private func persistedSessions(vouching: Bool = false) -> [PersistedSession] {
        let now = Date()
        lazy var table = ProcessTable.snapshot()
        // A session still waiting for its worktree was never opened, and has
        // no folder to come back to.
        return sessions.filter { $0.preparation == nil }.map { session in
            persistedEntry(for: session, now: now, vouching: vouching, table: { table })
        }
    }

    /// One session as it's saved, which is also how an archived one is kept.
    private func persistedEntry(for session: Session, now: Date, vouching: Bool,
                                table: () -> [ProcessEntry]) -> PersistedSession {
        if vouching, session.runningAgent != nil { noteConversation(session, table: table()) }
        let (agent, conversationID) = agentToResume(session, now: now,
                                                    table: vouching ? table() : nil)
        return PersistedSession(
            id: session.id, name: session.name, title: session.title, cwd: session.cwd,
            originCwd: session.originCwd,
            selected: session.id == selectedID, nameSource: session.nameSource.rawValue,
            worktreeBranch: session.worktreeBranch,
            colour: session.colour?.rawValue,
            gitPanelVisible: session.gitPanelVisible,
            inspectorPane: session.inspectorPane?.rawValue,
            sideTabs: session.sideTabs.map(\.rawValue),
            activeSideTab: session.activeSideTab?.rawValue,
            sideColumnWidth: session.sideColumnWidth,
            bottomTabs: session.bottomTabs.map(\.rawValue),
            activeBottomTab: session.activeBottomTab?.rawValue,
            bottomVisible: session.bottomVisible,
            closedTabs: session.closedTabs.map(\.rawValue),
            mainTabs: session.mainTabs.map(\.rawValue),
            activeMainTab: session.activeMainTab?.rawValue,
            sideColumnLeading: session.sideColumnLeading,
            browserAddresses: Self.persistedBrowserAddresses(of: session),
            gitCheckout: session.gitCheckout,
            tabHabits: session.tabHabits.isEmpty ? nil
                : Dictionary(uniqueKeysWithValues: session.tabHabits.map { ($0.key.rawValue, $0.value.rawValue) }),
            runningAgent: agent?.agent, runningModel: agent?.model,
            runningArgv: agent?.argv,
            runningConversationID: agent == nil ? nil : conversationID,
            lastConversationID: session.lastConversationID,
            portBase: session.portBase,
            remindAt: session.remindAt,
            agentAsleep: session.sleep.agent.map { $0.waiting ? "waiting" : "finished" },
            lastTypedAt: lastTypedAt[session.id],
            createdAt: session.createdAt, lastSentAt: session.lastSentAt)
    }

    /// The agent the next launch should bring back in `session`, and its
    /// conversation, resolved as one unit so a model or command can never
    /// outlive the agent it belongs to. In order:
    ///
    /// - the agent running now. With a `table` (a quit), only if the table
    ///   still vouches for it: a marker outlives an agent killed without its
    ///   shell reaching a prompt, and resuming that would reopen a conversation
    ///   you had stopped. Unless the shell went too, which nobody does on
    ///   purpose: that one is owed.
    /// - a resume this session still owes (restored, or typed and not yet
    ///   answered), so it survives another quit instead of being dropped.
    /// - an agent that ended moments ago with its shell: a logout ends the
    ///   keeper's shells, which clear their markers, and then quits the app.
    private func agentToResume(_ session: Session, now: Date, table: [ProcessEntry]?)
        -> (AgentMarker?, String?) {
        // Asleep, or on its way: the conversation it was ended in is what
        // comes back. First, because while it is ending its marker may still
        // be there, and no table should talk this out of being saved.
        if let asleep = session.sleep.agent {
            return (AgentMarker(agent: asleep.marker.agent, model: asleep.marker.model,
                                cwd: asleep.marker.cwd, argv: asleep.marker.argv,
                                shellPID: nil, startedAt: nil),
                    asleep.conversationID)
        }
        if let running = session.runningAgent {
            var counts = true
            if let table, case .gone = AgentLiveness.locate(
                agent: running, shellPID: session.runningShellPID, table: table) {
                counts = session.runningShellPID.map {
                    AgentLiveness.shellIsGone(shellPID: $0, table: table)
                } ?? false
            }
            if counts {
                // Only what this run was seen in: `lastConversationID` may
                // be another agent's, or another folder's.
                return (AgentMarker(agent: running, model: session.runningModel,
                                    cwd: session.runningCwd ?? session.cwd, argv: session.runningArgv,
                                    shellPID: nil, startedAt: nil),
                        session.liveConversationID)
            }
        }
        if let owed = session.owedResume, owed.isOwed(at: now) {
            return (owed.agent, owed.conversationID)
        }
        if let ended = session.endedAgent, AgentConversation.endedWithItsShell(
            ended, now: now, shellIsGone: { pid in
                table.map { AgentLiveness.shellIsGone(shellPID: pid, table: $0) } ?? (kill(pid, 0) != 0)
            }) {
            return (ended.marker, ended.conversationID)
        }
        return (nil, nil)
    }

    /// A strip tab as saved: a `SideTab` raw value, or, in files from when the
    /// strip held terminals only, a bare UUID.
    private static func stripTab(_ raw: String) -> SideTab? {
        SideTab(rawValue: raw) ?? UUID(uuidString: raw).map { .terminal($0) }
    }

    private func scheduleSave() {
        guard hasRestored else { return }
        rememberProjectRoots()
        store.scheduleSave { [weak self] in self?.persistedSessions() ?? [] }
    }

    /// Whether `restore` has read the saved sessions. Nothing is saved before
    /// it has: a launch that failed before restoring (an exception thrown while
    /// building the window, 2026-09-29) had no sessions, and saved that on its
    /// way out over every session there was. The shells lived on in the
    /// keeper; the list of what they were did not.
    private(set) var hasRestored = false

    /// Where each live session's processes hang from, for `ProcessMonitor`.
    ///
    /// A session with no shell pid contributes nothing rather than a guess: that
    /// is either a session never opened, or the no-keeper fallback path where
    /// libghostty spawns the shell without telling us which pid it got.
    var processRoots: [SessionProcessRoot] {
        sessions.flatMap { session -> [SessionProcessRoot] in
            var roots: [SessionProcessRoot] = []
            if let shellPID = session.shellPID {
                let unshown = session.terminalTabIDs.filter { session.sideSurfaces[$0] == nil }
                roots.append(SessionProcessRoot(sessionID: session.id, shellPID: shellPID,
                                                agentName: session.runningAgent, tags: unshown))
            }
            // A side terminal's jobs are filed under the session it sits in.
            // No agent name: agent tracking follows the main shell only.
            for shell in session.sideShells {
                roots.append(SessionProcessRoot(sessionID: session.id, shellPID: shell.pid,
                                                agentName: nil, tags: [shell.tab]))
            }
            return roots
        }
    }

    /// Directories a stray process has to be sitting in to be counted as ours.
    ///
    /// Kept live *and* persisted, because the orphan worth finding is precisely
    /// the one whose session closed days ago — by then the live list says
    /// nothing about it. See `ProjectRoots`.
    @ObservationIgnored private(set) var projectRoots: [String] = ProjectRoots.load()

    /// Fold the current sessions' directories into the remembered list.
    ///
    /// Both `cwd` and `originCwd`, and `cwd` first, which is the opposite of
    /// what it looks like it should be. A session's birth directory reads like
    /// the better answer, but in practice almost every session is opened from
    /// home and then `cd`s into the project: on this machine every persisted
    /// `originCwd` was `/Users/giel`, which `ProjectRoots` rightly refuses as
    /// too broad, so nothing was ever remembered and no orphan could ever be
    /// attributed. Where the shell actually is *is* the project.
    private func rememberProjectRoots() {
        let live = sessions.flatMap { [$0.cwd, $0.originCwd].compactMap { $0 } }
        let merged = ProjectRoots.merge(projectRoots, adding: live)
        guard merged != projectRoots else { return }
        projectRoots = merged
        ProjectRoots.save(merged)
    }

    /// GitPanelModel flipped a session's `gitPanelVisible` or `inspectorPane`.
    /// It owns those bits (it holds the session), but persistence is ours —
    /// wired up in AppDelegate.
    func sessionStateChanged() {
        scheduleSave()
    }

    func saveNow() {
        guard hasRestored else { return }
        store.saveNow(persistedSessions(vouching: true))
    }

    // MARK: - Wiring

    private func wire(_ session: Session) {
        let id = session.id
        // Side terminals get the part of the wiring that is about a terminal:
        // their title labels their tab, a finished command may have changed the
        // work tree, a bell or a notification is the session calling for you,
        // and a ⌘-clicked path opens like anywhere else. What is about an
        // *agent* (busy detection, naming, resume) follows the main shell only.
        session.onSideSurfaceCreated = { [weak self, weak session] tabID, view in
            view.onTitleChange = { [weak session] title in
                session?.sideTerminalTitles[tabID] = title
            }
            view.onCloseRequest = { [weak self, weak session] in
                guard let self, let session else { return }
                self.onSideTerminalExited?(session, tabID)
            }
            view.onShellEnded = { [weak self, weak session, weak view] in
                guard let self, let session, let view else { return }
                self.shellEnded(view, in: session, tab: tabID)
            }
            view.onCommandFinished = { [weak self, weak session] _, _ in
                guard let self, let session else { return }
                self.onCommandFinished?(session)
            }
            view.onBell = { [weak self, weak session] in
                guard let self, let session else { return }
                self.raiseAttention(session, kind: .needsInput, title: session.name, body: "Bell",
                                    source: "bell")
            }
            view.onOpenMarkdown = { [weak self] url in self?.onOpenMarkdown?(url) }
        }
        session.onSurfaceCreated = { [weak self, weak session] view in
            guard let self, let session else { return }

            // Out of sight long enough, a terminal hibernates. Not one whose
            // agent shows it is working only by its screen changing: with no
            // terminal there is no screen, and it would never be seen to stop.
            view.mayHibernate = { [weak session] in
                guard let agent = session?.runningAgent else { return true }
                return HibernationPolicy.watchableAgents.contains(agent)
            }

            view.onTitleChange = { [weak self, weak session] title in
                guard let self, let session else { return }
                // Recorded but not displayed; bursty, so no save/UI churn.
                session.title = title
                self.titleChanged(session, title: title)
            }
            view.onPwdChange = { [weak self, weak session] pwd in
                guard let self, let session else { return }
                let previous = session.linkedCheckout?.root
                session.cwd = pwd // observed → sidebar row + navigation subtitle update
                self.noteCheckout(session)
                // Into a worktree, or from one into another: whose branch the
                // row shows has changed.
                if let checkout = session.linkedCheckout?.root {
                    if !self.noteBranch(session), checkout != previous || session.worktreeBranch == nil {
                        self.resolveWorktreeBranch(session)
                    }
                } else if session.linkedCheckout == nil, session.worktreeBranch != nil {
                    // Out of every worktree: no branch to show, or to save.
                    session.worktreeBranch = nil
                }
                // The shell moved somewhere: a folder it reports is one it's in.
                if session.folderIsGone { session.folderIsGone = !FileManager.default.fileExists(atPath: pwd) }
                self.scheduleSave()
            }
            view.onBell = { [weak self, weak session] in
                guard let self, let session else { return }
                self.raiseAttention(session, kind: .needsInput, title: session.name, body: "Bell",
                                    source: "bell")
            }
            view.onProgress = { [weak self, weak session] active, errored in
                guard let self, let session else { return }
                // An agent reporting its own progress is authoritative — note
                // it so the screen sampler stays out of this session's way.
                self.noteExplicitSignal(session)
                if active {
                    // The last state before the span ends is the one that
                    // counts: an error the program then recovered from (a
                    // later set or indeterminate) is not how it finished.
                    if errored { self.progressErrored.insert(session.id) } else { self.progressErrored.remove(session.id) }
                    self.markBusy(session)
                } else {
                    let failed = self.progressErrored.remove(session.id) != nil
                    self.progressEnded(session, inferred: failed ? .failed : .turnDone, source: "osc")
                }
            }
            // A resize re-wraps every session's screen at once, hidden ones
            // included. That is a repaint the agents had no part in, so it must
            // never be read as one of them starting work.
            view.onSizeChange = { [weak self] in
                self?.rebaselineAgentScreens()
            }
            // Your own input is the other repaint the agent had no part in.
            // Re-baselining on every key is what lets the sampler watch the
            // session you are typing into (see `sampleAgentScreens`).
            view.onUserInput = { [weak self, weak session] in
                guard let self, let session else { return }
                self.agentScreenTrackers[session.id]?.rebaseline(now: Date())
                self.lastTypedAt[session.id] = Date()
                self.noteUserInput(session)
            }
            // A Return of yours: the sidebar's Recent. Saved, so
            // the order survives a relaunch; the save is debounced.
            view.onSubmit = { [weak self, weak session] in
                guard let self, let session else { return }
                session.lastSentAt = Date()
                self.scheduleSave()
            }
            // A script's `wortel send` repaints too, but it is not you back
            // at the keyboard: an attention raised while you were away stays.
            view.onScriptedInput = { [weak self, weak session] in
                guard let self, let session else { return }
                self.agentScreenTrackers[session.id]?.rebaseline(now: Date())
            }
            view.onCommandFinished = { [weak self, weak session] exitCode, durationNs in
                guard let self, let session else { return }
                // While an agent is running here, this is not the shell coming
                // back to its prompt: nothing has, the agent still has the
                // terminal. It is the core closing a command it saw an agent's
                // OSC 133 zone marks open — Pi wraps every message it renders
                // in 133;A/B/C — and so it says nothing about whether the agent
                // is done. The busy state belongs to whichever tier owns it
                // (the agent's progress, its title, the screen sampler), and
                // clearing it here dropped Pi's spinner mid-turn and, with it,
                // the `busyStartedAt` that the turn-end attention is gated on:
                // the screen going quiet later found no busy to have lasted
                // long enough, and the finished turn went unannounced. The
                // shell returning for real is seen as the marker vanishing
                // (`refreshAgentActivity`), which clears busy itself.
                //
                // The git nudge stays: the agent has very likely just written
                // files, which is the one thing this event is still right about.
                // So is the branch: a `git switch` doesn't move the shell.
                self.noteBranch(session)
                if session.runningAgent != nil {
                    self.onCommandFinished?(session)
                    return
                }
                // An agent Wortel just ended to put it to sleep: its exit
                // (status 143) is not a command of yours that failed.
                if self.sleepIsSettling(session) {
                    self.onCommandFinished?(session)
                    return
                }
                // Note: deliberately does NOT cancel a pending quiesce raise.
                // Some shells' OSC 133 zone marks synthesize finished events
                // mid-turn; cancelling here would eat the legit "agent is done"
                // attention that a 9;4;0 just scheduled. A duplicate raise is
                // harmless, and priority keeps a "needs input" from being
                // downgraded to a plain "finished".
                self.clearBusy(session)
                // A command likely touched files — nudge the git panel to
                // re-read status/diff (it debounces and no-ops when hidden).
                self.onCommandFinished?(session)
                // A long command that finished while you were elsewhere wants
                // your eyes — and a non-zero exit is worth flagging red, not
                // just "done". Exit code -1 means the shell didn't report one.
                guard durationNs >= Self.attentionAfterNs else { return }
                // Long enough to be worth a fresh name too (agents go through
                // the quiesce path above; this covers plain long commands).
                self.considerAutoName(session)
                if exitCode > 0 {
                    self.raiseAttention(session, kind: .failed, title: session.name,
                                        body: "Command failed (exit \(exitCode))",
                                        source: "command")
                } else {
                    self.raiseAttention(session, kind: .finished, title: session.name,
                                        body: "Command finished", source: "command")
                }
            }
            view.onNotification = { [weak self, weak session] title, body in
                guard let self, let session else { return }
                // Program-authored "needs you" (OSC 9/777/99) — e.g. an agent CLI
                // on a permission or idle prompt. The most reliable signal.
                // Text tells apart a blocking request from a "task done" ping.
                let kind = AttentionKind.classify(notificationTitle: title, body: body)
                self.raiseAttention(session, kind: kind,
                                    title: title.isEmpty ? session.name : title,
                                    body: body, source: "notification")
            }
            view.onCloseRequest = { [weak self] in
                guard let self, let session = self.sessions.first(where: { $0.id == id }) else { return }
                KeeperLog.log.notice("session \(id.uuidString, privacy: .public) closed: its terminal ended")
                self.end(session)
            }
            view.onShellEnded = { [weak self, weak session, weak view] in
                guard let self, let session, let view else { return }
                self.shellEnded(view, in: session, tab: nil)
            }
            // The runtime already resolved this to a local markdown file; just
            // hand it up to the app layer, which opens the preview.
            view.onOpenMarkdown = { [weak self] url in
                self?.onOpenMarkdown?(url)
            }
        }
    }

    /// What a new session is called before anything better is known: its
    /// directory's name, and "Home" for the home folder. A row reading "~",
    /// and "~ 2" to "~ 6" beside it, looked like a path cut short rather than
    /// a name. Only the name: the title stays "~" (`defaultTitle`), since
    /// that is also what an agent title echoing the directory is checked
    /// against, and in the home folder that echo is "~".
    static func defaultName(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty, cwd != NSHomeDirectory() else { return "Home" }
        return (cwd as NSString).lastPathComponent
    }

    /// Home sessions were named "~", "~ 2"… before they were "Home". Each
    /// still on that placeholder takes the new one, in its own folder, once
    /// every saved session is back so the name can't clash with one restored
    /// later: "Home 3" for "~ 3" while that's free, else the next free "Home".
    /// A name anyone gave is left alone.
    private func renameOldHomePlaceholders() {
        var renamed = false
        defer { if renamed { scheduleSave() } }
        for session in sessions where session.nameSource == .placeholder {
            guard let leaf = Self.homeName(forOldPlaceholder: session.leafName) else { continue }
            let folder = session.folderPath
            let taken = sessions.contains { $0 !== session && $0.folderPath == folder && $0.leafName == leaf }
            let name = taken ? uniqueLeaf("Home", in: folder) : leaf
            session.name = folder.map { "\($0)/\(name)" } ?? name
            renamed = true
        }
    }

    /// "Home" for a leaf "~", "Home 2" for "~ 2"; nil for any other leaf.
    static func homeName(forOldPlaceholder name: String) -> String? {
        if name == "~" { return "Home" }
        guard name.hasPrefix("~ "), let n = Int(name.dropFirst(2)), n > 1 else { return nil }
        return "Home \(n)"
    }

    static func defaultTitle(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

}

/// Trimmed-string convenience used by the folder create/rename helpers.
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
