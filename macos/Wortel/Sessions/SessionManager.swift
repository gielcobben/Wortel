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

    // MARK: Windows

    /// The main windows, in the order they were opened. Never empty once the
    /// app is up: the first is made with the manager.
    private(set) var windows: [SessionWindow] = []

    /// The main window last made key: what "the selected session" means for
    /// every command (⌘W, ⌘R, ⌘P's current row, a new session's folder).
    /// Set by the app layer as a window becomes key, and by the manager when
    /// a selection goes to a session in another window.
    private(set) var activeWindow: SessionWindow!

    /// A selection went to a session in a window that isn't the active one
    /// (a notification, ⌘P, Next Waiting Session): the app brings that window
    /// forward. The manager has already made it the active one.
    @ObservationIgnored var onActivateWindow: ((SessionWindow) -> Void)?
    /// A window's last session went, and another window is still open: it
    /// closes, as an empty Terminal window does. The last window keeps its
    /// empty page instead (`onAllClosed`).
    @ObservationIgnored var onWindowEmptied: ((SessionWindow) -> Void)?
    /// A window was added by the manager (moving a session to a new one,
    /// restore): the app makes its NSWindow.
    @ObservationIgnored var onWindowAdded: ((SessionWindow) -> Void)?

    /// A new, empty window, made active. The app shows it.
    @discardableResult
    func addWindow(id: UUID = UUID()) -> SessionWindow {
        let window = SessionWindow(id: id, manager: self)
        windows.append(window)
        if activeWindow == nil { activeWindow = window }
        return window
    }

    /// A window that has closed. Its sessions must already be gone or moved.
    func removeWindow(_ window: SessionWindow) {
        guard windows.count > 1 else { return }
        windows.removeAll { $0 === window }
        if activeWindow === window { activeWindow = windows.last }
        scheduleSave()
    }

    /// `window` became key: it is what commands act on from now.
    func activate(_ window: SessionWindow) {
        guard activeWindow !== window, windows.contains(where: { $0 === window }) else { return }
        activeWindow = window
        // A multiple selection belongs to the sidebar it was made in.
        if sidebarSelection.isMultiple {
            var collapsed = sidebarSelection
            collapsed.collapse(to: window.selectedID)
            sidebarSelection = collapsed
        }
    }

    /// Move sessions to `target`, or to a new window when nil, and show the
    /// first of them there. Their terminals go with them as they are: the
    /// same shells, the same agents, nothing restarted. A window left with
    /// nothing in it closes. Returns the window they went to, or nil when
    /// there was nothing to move (all of them already there, or a new window
    /// asked for every session of the only one).
    @discardableResult
    func moveSessions(_ ids: [Session.ID], toWindow target: SessionWindow?,
                      topLeft: CGPoint? = nil) -> SessionWindow? {
        let moving = ids.compactMap { id in sessions.first { $0.id == id } }
            .filter { target == nil || window(of: $0) !== target }
        guard !moving.isEmpty else { return nil }
        let movingIDs = Set(moving.map(\.id))
        let sources = windows.filter { window in moving.contains { self.window(of: $0) === window } }
        // A new window for everything a window has would only swap one empty
        // window for another.
        if target == nil, sources.count == 1, sessions(in: sources[0]).allSatisfy({ movingIDs.contains($0.id) }) {
            return nil
        }
        let destination: SessionWindow
        if let target {
            destination = target
        } else {
            destination = addWindow()
            destination.requestedTopLeft = topLeft
            onWindowAdded?(destination)
        }
        // The windows they leave show their next row first, so a terminal is
        // never on screen in two windows at once.
        for source in sources {
            guard let current = source.selectedID, movingIDs.contains(current) else { continue }
            let staying = drawnRows(in: source).filter { !movingIDs.contains($0) }
            let index = drawnRows(in: source).firstIndex(of: current) ?? 0
            let rows = drawnRows(in: source)
            let above = rows[..<min(index, rows.count)].last { !movingIDs.contains($0) }
            let pick = above ?? staying.first ?? sessions(in: source).first { !movingIDs.contains($0.id) }?.id
            select(pick, in: source)
            // Not a way back from here any more: it is in another window.
            source.trail.removeAll { movingIDs.contains($0) }
        }
        for session in moving { session.windowID = destination.id }
        normalizeOrder()
        activate(destination)
        select(moving[0].id, in: destination)
        onActivateWindow?(destination)
        for source in sources where sessions(in: source).isEmpty {
            onWindowEmptied?(source)
        }
        scheduleSave()
        return destination
    }

    /// Window ▸ Merge All Windows: every session into the active window.
    func mergeAllWindows() {
        guard let activeWindow, windows.count > 1 else { return }
        let others = sessions.filter { window(of: $0) !== activeWindow }.map(\.id)
        let front = activeWindow.selectedID
        moveSessions(others, toWindow: activeWindow)
        // Merging brings sessions in; it doesn't take you away from yours.
        if let front { select(front, in: activeWindow) }
    }

    /// The window `session` is in.
    func window(of session: Session) -> SessionWindow {
        session.windowID.flatMap { id in windows.first { $0.id == id } } ?? windows[0]
    }

    func window(id: UUID) -> SessionWindow? {
        windows.first { $0.id == id }
    }

    /// The sessions in `window`, in stored order.
    func sessions(in window: SessionWindow) -> [Session] {
        let first = windows.first === window
        let known = Set(windows.map(\.id))
        return sessions.filter { session in
            guard let id = session.windowID, known.contains(id) else { return first }
            return id == window.id
        }
    }

    /// Whether `session` is the one in front in its window.
    func isFront(_ session: Session) -> Bool {
        window(of: session).selectedID == session.id
    }

    func isFront(_ id: Session.ID) -> Bool {
        windows.contains { $0.selectedID == id }
    }

    /// The selected session of the active window: what the commands act on.
    /// Assigning it selects that session in *its* window, which becomes the
    /// active one and is brought forward when it wasn't already.
    var selectedID: Session.ID? {
        get { activeWindow?.selectedID }
        set {
            guard let newValue, let session = sessions.first(where: { $0.id == newValue }) else {
                if let activeWindow { select(nil, in: activeWindow) }
                return
            }
            let target = window(of: session)
            if target !== activeWindow {
                activate(target)
                onActivateWindow?(target)
                // Already in front there: nothing switches, but you have
                // come to it (⌘P, its banner, Next Waiting Session), which
                // is what clears its dot, its unread mark and its reminder.
                if target.selectedID == newValue {
                    arrive(at: session, in: target)
                    scheduleCaughtUp(session)
                    return
                }
            }
            select(newValue, in: target)
        }
    }

    /// Change `window`'s front session: everything a switch means, in one
    /// path, for clicks and for programmatic selection alike. Lazily creates
    /// the session's surface and clears its bell.
    func select(_ id: Session.ID?, in window: SessionWindow) {
        let oldValue = window.selectedID
        guard id != oldValue else { return }
        let now = Date()
        // The session you leave goes on the way back if the visit counted.
        if let oldValue, sessions.contains(where: { $0.id == oldValue }),
           SidebarStep.visitCounts(arrived: window.arrivedAt, left: now,
                                   lastInput: lastTypedAt[oldValue]) {
            noteTrail(oldValue, in: window)
        }
        window.selectedID = id
        window.arrivedAt = id == nil ? nil : now
        // The lead moved from somewhere that isn't a ⌘-click inside the
        // selection (a plain click, ⌘2, a notification): one row again.
        if window === activeWindow, !(id.map(sidebarSelection.ids.contains) ?? false) {
            var collapsed = sidebarSelection
            collapsed.collapse(to: id)
            if collapsed != sidebarSelection { sidebarSelection = collapsed }
        }
        guard let id, let session = sessions.first(where: { $0.id == id }) else { return }
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
        arrive(at: session, in: window)
        // Left the previous session before it could count as read; start the
        // caught-up clock on the one you just landed on.
        cancelCaughtUp(oldValue)
        scheduleCaughtUp(session)
        // Not while its worktree is still being made: there's no folder
        // for the shell to start in yet (see `prepareWorktree`).
        if session.preparation == nil { session.ensureSurfaceView(runtime: runtime) }
        scheduleSave()
        window.onSwitch?(session)
        noteSelectionForSleep(left: oldValue, arrived: session)
    }

    /// What coming to a session means, whether it was switched to or was
    /// already in front of the window brought forward for it.
    private func arrive(at session: Session, in window: SessionWindow) {
        // Most recent first, for ⌘P's list.
        recentSessionIDs.removeAll { $0 == session.id }
        recentSessionIDs.insert(session.id, at: 0)
        // Switching into a waiting session: flash a ring in the detail view
        // to orient the eye before the dot clears.
        if let kind = session.attention {
            window.attentionFlash = AttentionFlash(kind: kind)
        }
        clearAttention(session)
        // Coming back to a session marked unread: that's the "later" it was
        // marked for, so it clears the usual way from here.
        session.markedUnread = false
        // A reminder that went off for it has been answered the same way.
        answerReminder(session)
    }

    /// Sessions in the order they were last selected, most recent first: what
    /// ⌘P lists before you type (SessionSwitcherMatch).
    @ObservationIgnored private(set) var recentSessionIDs: [Session.ID] = []

    /// Put `id` at the front of `window`'s way back (`SessionWindow.trail`).
    private func noteTrail(_ id: Session.ID, in window: SessionWindow) {
        window.trail.removeAll { $0 == id }
        window.trail.insert(id, at: 0)
    }

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
        // Only this window's: Back never reaches into another window.
        guard activeWindow == nil || window(of: session) === activeWindow else { return false }
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
    }

    /// The preview tab moved on to another file in its place: where you are
    /// now, but not a stop of its own. Thirty files looked through would
    /// otherwise be thirty stops for Back, none of them still open.
    func noteTabReplaced(_ tab: SideTab, in session: Session) {
        currentTabs[session.id] = tab
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

    /// The active window's sessions as its sidebar draws them, top to
    /// bottom, folded sections left out: what a ⇧-click's range runs over
    /// and the order a bulk action applies in (`SessionWindow.sidebarRowOrder`).
    var sidebarRowOrder: [Session.ID] { activeWindow?.sidebarRowOrder ?? [] }

    /// ⌘1…⌘9's sessions in the active window: the first nine rows as its
    /// sidebar draws them (Pinned first, Sort Unread First applied, folded
    /// sections left out), so the number on a row is the one that selects
    /// it. nil until the sidebar has drawn, when it's the stored order.
    var shortcutIDs: [Session.ID]? { activeWindow?.shortcutIDs }

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
    @ObservationIgnored var onReminderChanged: ((_ session: Session, _ date: Date?, _ asking: Bool) -> Void)?
    /// A reminder went off for a session nobody is looking at: the banner,
    /// now, under the session's name as it is now.
    @ObservationIgnored var onReminderDue: ((Session) -> Void)?

    /// A foreground command finished in a session — its work tree may have
    /// changed. The app layer uses this to refresh the source-control panel.
    @ObservationIgnored var onCommandFinished: ((Session) -> Void)?

    /// A path ⌘-clicked in a session's terminal, resolved to something on disk
    /// (`TerminalLink`). The app layer decides where it opens.
    @ObservationIgnored var onOpenTerminalLink: ((TerminalLink.Target) -> Void)?
    /// A server on this Mac ⌘-clicked in a session's terminal
    /// (`http://localhost:3000`). The app layer opens it beside the terminal,
    /// or in the browser if that's where servers go.
    @ObservationIgnored var onOpenLocalServer: ((URL) -> Void)?
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


    /// Busy is shown only after a command has been running this long, so
    /// instant commands (ls, cd, git status) never flash the spinner.
    private static let busyShowDelay: TimeInterval = 0.15
    /// A command that ran at least this long and finished while its session was
    /// unselected raises the attention dot.
    private static let attentionAfterNs: UInt64 = 10_000_000_000 // 10s
    /// How long a program that never says `done` has to have worked for its
    /// going idle to be a turn that ended (`programStatus`). Shorter is a
    /// command that flickered `working`, not a turn.
    private static let minBusyForQuiesceAttention: TimeInterval = 2.0
    /// Pending "show busy" work items, keyed by session; cancelled if the
    /// command finishes before the delay elapses.
    @ObservationIgnored private var busyTimers: [Session.ID: DispatchWorkItem] = [:]
    /// What a program reported and Wortel is about to announce, keyed by
    /// session, for the moment it takes to be sure it stands
    /// (`announceTurnEnd`); cancelled if the program carries on first.
    @ObservationIgnored private var quiesceTimers: [Session.ID: DispatchWorkItem] = [:]
    /// When each session's busy spinner actually turned on.
    @ObservationIgnored private var busyStartedAt: [Session.ID: Date] = [:]
    /// What each session's program has said it is doing, in its own reports
    /// (`ProgramStatus`, OSC 7501): its record and those of the work it
    /// named. An entry means the session is taken at its word: see `reports`.
    @ObservationIgnored private var programRecords: [Session.ID: ProgramRecords] = [:]
    /// Sessions whose program has said `done` or `error` in its current run,
    /// and so has shown that its `idle` is not how its turns end
    /// (`ReportedStatus.saysDone`).
    @ObservationIgnored private var saidDone: Set<Session.ID> = []
    /// When each session's program first reported, in its current run: so a
    /// change of agent can tell the old run's records from the new one's.
    @ObservationIgnored private var reportsBegan: [Session.ID: Date] = [:]
    /// The attention a report raised for each session, while it stands: the
    /// only attention a later report may take back. A block answered takes
    /// back its "needs input" (`ReportedStatus.Effect.answered`); a program
    /// working again takes back the "finished" or "failed" of the turn before.
    @ObservationIgnored private var reportRaised: [Session.ID: AttentionKind] = [:]
    /// A block a program reported and Wortel is about to announce, for the
    /// moment it takes to be sure it stands. Apart from `quiesceTimers`, which
    /// holds a turn's end: a turn can end while a question is still settling,
    /// and neither announcement may cancel the other.
    @ObservationIgnored private var blockTimers: [Session.ID: DispatchWorkItem] = [:]
    /// What a reporting program last said in a notification of its own (OSC
    /// 9 and the like), and when. Never raised: it is the words for a block
    /// reported at the same moment ("Approval requested: npm test").
    @ObservationIgnored private var reportedWords: [Session.ID: (text: String, at: Date)] = [:]
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
    private static let unreadDwellDelay: TimeInterval = 1
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
    /// With several windows, each window's in turn, the active one first.
    var sessionsInSidebarOrder: [Session] {
        let ordered = activeWindow.map { [$0] + windows.filter { $0 !== activeWindow } } ?? windows
        return ordered.flatMap(sessionsInSidebarOrder(in:))
    }

    /// `sessionsInSidebarOrder` for one window's sidebar.
    func sessionsInSidebarOrder(in window: SessionWindow) -> [Session] {
        sidebarGroups(in: window).flatMap { group -> [Session] in
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
    func attention(inPinned pinned: Bool, of window: SessionWindow) -> AttentionKind? {
        guard pinned ? pinnedCollapsed : looseCollapsed else { return nil }
        return AttentionKind.loudest(of: sessionsHidden(inPinned: pinned, of: window).map(\.attention))
    }

    /// Whether a folded Pinned or Sessions header is hiding a session at
    /// work, as `isWorking(inFolder:)` does for a folder.
    func isWorking(inPinned pinned: Bool, of window: SessionWindow) -> Bool {
        guard pinned ? pinnedCollapsed : looseCollapsed else { return false }
        return sessionsHidden(inPinned: pinned, of: window).contains(where: Self.showsWorking)
    }

    private func sessionsHidden(inPinned pinned: Bool, of window: SessionWindow) -> some Sequence<Session> {
        sessions(in: window).lazy.filter {
            pinned ? self.isPinned($0) : (!self.isPinned($0) && $0.folderPath == nil)
        }
    }

    /// Folders made on purpose (⌘O, or a worktree of a repository with no
    /// folder yet). Unlike folders that emerge from a "team/…" name, these
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
    /// This is what makes "New Session in “Acme”" mean Acme. Before it, a
    /// folder was purely the part of a session's name before the last slash, so
    /// that command filed a session under Acme and started it wherever the
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
        // The first window, there before anything is restored: the app builds
        // its NSWindow around it. `restore` gives it its saved id.
        addWindow()
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

    /// `sidebarGroups` for one window: its own sessions only. A folder made
    /// on purpose and left empty is drawn in the first window, where folders
    /// always were, and not in every window at once.
    func sidebarGroups(in window: SessionWindow) -> [SidebarGroup] {
        let mine = sessions(in: window)
        let byID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SidebarLayout.groups(
            rows: mine.map { SidebarLayout.Row(id: $0.id, folder: $0.folderPath) },
            pinned: pinnedIDs, folderOrder: folderOrder,
            declaredFolders: windows.first === window ? declaredFolders : []
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
    /// and "New Session in “Acme”" would go on doing the wrong thing until then.
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
        // The agents' folder, made by an earlier build, has no guide yet, and
        // its sessions are resumed from it (a move, a wake): one stat.
        if FileManager.default.fileExists(atPath: ChatFolder.root) { ChatFolder.writeGuide(in: ChatFolder.root) }
        // What an agent here can ask Wortel for, as a Claude Code skill.
        DispatchQueue.global(qos: .utility).async { AgentSkill.sync() }
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
        // Sizes on screen are kept for sessions that are still somewhere.
        SurfaceView.keepShownSizes(only: Set(persisted.map(\.id)).union(archivedIDs))
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
        restoreWindows(persisted)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.warmRemainingSurfaces()
        }
    }

    /// Put the saved windows back, each with its sessions and the one it had
    /// in front. The first window already exists (the app built it); it
    /// takes the first saved window's id. The window whose front session the
    /// file marks `selected` is the active one, as it was at quit.
    private func restoreWindows(_ persisted: [PersistedSession]) {
        let saved = WindowStore.load()
        let first = windows[0]
        let ids = saved.isEmpty ? [first.id] : saved.map(\.id)
        let (kept, owner) = WindowStore.assign(
            sessions: persisted.map { (id: $0.id, window: $0.windowID) }, windows: ids)
        first.id = kept[0]
        first.frame = saved.first(where: { $0.id == first.id })?.frame
        for id in kept.dropFirst() {
            let window = addWindow(id: id)
            window.frame = saved.first(where: { $0.id == id })?.frame
            onWindowAdded?(window)
        }
        for session in sessions { session.windowID = owner[session.id] ?? first.id }
        let active = persisted.first(where: \.selected).flatMap { owner[$0.id] }.flatMap(window(id:)) ?? first
        for window in windows where window !== active {
            let mine = sessions(in: window)
            let wanted = saved.first(where: { $0.id == window.id })?.selected
            guard let pick = mine.first(where: { $0.id == wanted }) ?? mine.first else { continue }
            select(pick.id, in: window)
        }
        activeWindow = active
        let mine = sessions(in: active)
        let wanted = persisted.first(where: \.selected)?.id ?? saved.first(where: { $0.id == active.id })?.selected
        if let pick = mine.first(where: { $0.id == wanted }) ?? mine.first {
            select(pick.id, in: active)
        }
        // Restored, not arrived at: where you were last time counts as a
        // visit however soon you leave it (`SidebarStep.visitCounts`).
        for window in windows { window.arrivedAt = nil }
        onActivateWindow?(active)
    }

    /// The window new sessions go into while it is set: `inWindow`.
    @ObservationIgnored private var placingWindow: SessionWindow?

    /// Run `body` with every session it makes placed in `window`, rather
    /// than in the active one: a new window's first session, `wortel new`
    /// from a session in a window behind.
    /// The session in front of the window new sessions go into now: what a
    /// new one takes its folder or repository from when given none.
    var placingSelected: Session? { (placingWindow ?? activeWindow)?.selected }

    func inWindow<T>(_ window: SessionWindow?, _ body: () -> T) -> T {
        guard let window else { return body() }
        let previous = placingWindow
        placingWindow = window
        defer { placingWindow = previous }
        return body()
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
        session.windowID = entry.windowID
        // One already past is due now: `syncReminders` fires it once launch is done.
        session.remindAt = entry.remindAt
        session.createdAt = entry.createdAt
        // Saved before Returns were kept: when keys last went in is the
        // nearest thing, read once here so a click later never moves it.
        session.lastSentAt = entry.lastSentAt ?? entry.lastTypedAt
        if let typed = entry.lastTypedAt {
            lastTypedAt[session.id] = typed
            lastKeysAt[session.id] = typed
        }
        session.agentPaintedDark = entry.agentPaintedDark
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
        // Where to resume, best evidence first (`AgentConversation.resumePoint`).
        // What the agent said it was in: from its process if it is still
        // running, else as saved, if the save was of this same run (a crash
        // can leave a marker for a run that began after the last save).
        // Then what its command line names; then its start time, which a
        // fresh `claude` creates its transcript at, but which another
        // session's conversation can match; then the last one this session
        // was ever seen in. An id only counts in the directory it belongs to;
        // Claude can't resume it anywhere else.
        //
        // Claude, Pi and Codex alike: see `AgentConversation`.
        var agentIsRunning = false
        var point = AgentConversation.ResumePoint.unknown
        if let agent, AgentConversation.exact.contains(agent.agent), let cwd = agent.cwd ?? entry.cwd {
            // A surviving marker is an agent still running (the snapshot
            // drops the rest), so whatever it can tell about itself counts.
            var said: String?
            if let marker, case .running(let pid) = AgentLiveness.locate(
                agent: marker.agent, shellPID: marker.shellPID, table: table()) {
                agentIsRunning = true
                said = AgentConversation.observe(agent: marker.agent, livePID: pid, cwd: cwd,
                                                 argv: nil, startedAt: nil, guessing: false)
            }
            point = AgentConversation.resumePoint(
                said: said ?? entry.savedConversation(forRunOf: marker),
                named: AgentConversation.observe(agent: agent.agent, livePID: nil, cwd: cwd,
                                                 argv: agent.argv, startedAt: nil, guessing: false),
                guessed: AgentConversation.observe(agent: agent.agent, livePID: nil, cwd: cwd,
                                                   argv: agent.argv, startedAt: agent.startedAt),
                last: entry.lastConversationID,
                exists: { AgentConversation.exists(agent: agent.agent, id: $0, cwd: cwd) })
        }
        let conversationID = point.conversationID
        session.lastConversationID = conversationID ?? entry.lastConversationID
        session.portBase = entry.portBase
        // An agent that reported its state and is still running is still
        // taken at its word. It says nothing new until its state changes, so
        // without this a working agent would show as idle until its turn
        // ended. Whatever it did say while Wortel was closed is in the replay,
        // and overrides this.
        // Any agent seen running, not only the three whose conversations
        // are known above: opencode and crush report too.
        let markerAgentRunning = agentIsRunning || marker.map { marker in
            if case .running = AgentLiveness.locate(agent: marker.agent, shellPID: marker.shellPID,
                                                    table: table()) { return true }
            return false
        } ?? false
        if markerAgentRunning, let state = entry.reportedState.flatMap(ProgramStatus.State.init(rawValue:)) {
            programRecords[session.id] = ProgramRecords(root: ProgramStatus(state: state))
            if state == .working { markBusy(session) }
            // Still waiting on an answer it asked for before the quit: the
            // dot comes back, without a second banner. Its title would have
            // said so, and a reporting session's title is no longer read.
            if state == .blocked {
                let id = session.id
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session,
                          self.programRecords[id]?.effective?.state == .blocked else { return }
                    self.raiseReported(session, kind: .needsInput, body: ReportedStatus.blockedWords(nil),
                                       source: "status-restored", quietly: true)
                }
            }
        }
        // An agent still running is owed nothing: the marker mirrors onto
        // the session below, and its own turns say which conversation it
        // is in. Anything less certain is owed, and the shell decides
        // whether to type it (`Attachment.resumeIsOwed`).
        if let agent, !agentIsRunning,
           let input = AgentResumeStore.resumeInput(for: agent, at: point) {
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
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: GhosttyRuntime.appearanceDidChange, object: runtime, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        }
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
                // Whatever it said it was doing, it is no longer there to
                // mean it. The next one starts with nothing said. Unless what
                // is on record already is the next one's: two agents run back
                // to back can both change markers inside one refresh, and the
                // new one may have reported by then.
                let theNewRunsOwn = marker?.startedAt.flatMap { start in
                    reportsBegan[session.id].map { $0 >= start }
                } ?? false
                if !theNewRunsOwn { forgetReport(session) }
                session.endedAgent = AgentConversation.EndedAgent(
                    marker: AgentMarker(agent: wasRunning, model: session.runningModel,
                                        cwd: session.runningCwd ?? session.cwd, argv: session.runningArgv,
                                        shellPID: session.runningShellPID,
                                        startedAt: session.runningStartedAt),
                    conversationID: session.liveConversationID, at: Date())
                session.liveConversationID = nil
            }
            if session.runningAgent != marker?.agent { session.runningAgent = marker?.agent }
            // A marker on a Mac where no agent has been seen yet is a
            // reason to look again, not an agent. The shell writes it from
            // the command line, before anything has run: for `claude` typed
            // on a Mac without it, for `sudo claude` at its password prompt,
            // and for a whole `npm install -g @anthropic-ai/claude-code`.
            // Taking any of those for an agent took the Setup row away for
            // good from exactly the person it is for, and so did waiting a
            // few seconds first, which an install outlasts.
            if marker != nil, isNewRun, Permissions.shared.agent != .granted {
                Permissions.shared.lookForAgent()
            }
            if session.runningModel != marker?.model { session.runningModel = marker?.model }
            session.runningArgv = marker?.argv
            session.runningShellPID = marker?.shellPID
            session.runningStartedAt = marker?.startedAt
            session.runningCwd = marker?.cwd
            if isNewRun {
                changed = true
                session.liveConversationID = nil
                // What the last run was typed and when it worked are not
                // this one's. And this one draws itself for the appearance
                // of now. An agent that survived the last quit keeps what was
                // saved for it: it drew itself before this launch.
                workBeganAt[session.id] = nil
                repaintInPlace.remove(session.id)
                if marker == nil {
                    session.agentPaintedDark = nil
                } else if agentMarkersBaselined || session.agentPaintedDark == nil {
                    session.agentPaintedDark = runtime.isDark
                }
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
            // One that started while Wortel was there to answer it: if it is
            // an agent that can report its state, it soon will, or it is old.
            if isNewRun { watchForSilence(session, marker: agentMarkersBaselined ? marker : nil) }
            if let marker, isNewRun, agentMarkersBaselined, !isOwedResume {
                Telemetry.capture(.agentStarted(kind: AgentName(command: marker.agent)))
            }
            if marker != nil, isNewRun { noteConversation(session) }
            if isNewRun { agentRunChanged(session, marker: marker, wasResume: isOwedResume) }
            // An agent launching is the moment to start listening for its first
            // prompt; the same agent exiting, or being replaced, ends the wait.
            if let marker, marker.agent != wasRunning {
                beginPromptCapture(session, marker: marker)
            } else if marker == nil, let wasRunning {
                // What it was assumed to have switched on is nobody's now.
                TerminalModeRecorder.shared.forgetStartupModes(of: wasRunning, in: session.id)
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
        // Markers appearing and vanishing is when the sweep for dead ones
        // has work to start or stop doing.
        updateMarkerSweep()
        // And when what a crash would leave behind changes: a Force Quit takes
        // the keeper with it, and the next launch has only the last save.
        if changed { scheduleSave() }
    }

    // MARK: - Agents that have gone without saying so

    /// Held for the fraction of a second between a program reporting that it
    /// is done or blocked and Wortel announcing it (`announceTurnEnd`, `announceBlock`).
    /// Without it App Nap puts off a backgrounded app's timers, and a
    /// backgrounded app is exactly when a notification is wanted.
    /// `allowingIdleSystemSleep`, because the Mac should still be free to sleep.
    @ObservationIgnored private var agentActivityAssertion: NSObjectProtocol?

    /// Drop markers whose agent is provably gone: a shell killed outright
    /// leaves one behind, and with it a session that says it is working for
    /// ever. Fail-open: `AgentLiveness` answers `unknown` when it can't read
    /// enough to be sure, and unknown must never delete a marker for an agent
    /// that is merely hard to see.
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
        // Mirrors the markers back onto the sessions, which also stops this
        // sweep when the last one goes.
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
        let endedAt = Date()
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
                view.finishProcess(endedAt: endedAt)
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
    /// was last seen in (`AgentConversation.resumePoint`). Never the newest file
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
        var point = AgentConversation.ResumePoint.unknown
        if AgentConversation.exact.contains(marker.agent), let cwd = marker.cwd ?? session.cwd {
            point = AgentConversation.resumePoint(
                said: live,
                named: AgentConversation.observe(agent: marker.agent, livePID: nil, cwd: cwd,
                                                 argv: marker.argv, startedAt: nil, guessing: false),
                guessed: AgentConversation.observe(agent: marker.agent, livePID: nil, cwd: cwd,
                                                   argv: marker.argv, startedAt: marker.startedAt),
                last: session.lastConversationID,
                exists: { AgentConversation.exists(agent: marker.agent, id: $0, cwd: cwd) })
        }
        let conversationID = point.conversationID
        guard let input = AgentResumeStore.resumeInput(for: marker, at: point) else { return nil }
        if let conversationID { session.lastConversationID = conversationID }
        return OwedResume(agent: marker, conversationID: conversationID, input: input)
    }

    /// Whether an announcement is waiting out its settle. That short timer is
    /// the only thing here that has to be punctual: what a program reports
    /// arrives with its output, whether the app is napping or not.
    private var wantsActivityAssertion: Bool {
        !quiesceTimers.isEmpty || !blockTimers.isEmpty
    }

    /// Take or drop the App Nap assertion to match `wantsActivityAssertion`.
    private func updateAgentActivityAssertion() {
        let wanted = wantsActivityAssertion
        if wanted, agentActivityAssertion == nil {
            agentActivityAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Announcing what an agent just reported")
        } else if !wanted, let assertion = agentActivityAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            agentActivityAssertion = nil
        }
    }

    /// Once a minute while any agent is running, nil otherwise: the sweep for
    /// markers whose agent has gone (`sweepDeadAgentMarkers`). Reading the
    /// process table costs a full sysctl, so no oftener; and with no agent
    /// anywhere there is no timer at all.
    @ObservationIgnored private var markerSweepTimer: Timer?
    private static let markerSweepInterval: TimeInterval = 60

    /// Start or stop the sweep to match whether any agent is running.
    private func updateMarkerSweep() {
        let wanted = sessions.contains { $0.runningAgent != nil }
        if wanted, markerSweepTimer == nil {
            let timer = Timer.scheduledTimer(
                withTimeInterval: Self.markerSweepInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweepDeadAgentMarkers() }
            }
            // No deadline: the tolerance lets the system coalesce it.
            timer.tolerance = Self.markerSweepInterval / 4
            markerSweepTimer = timer
        } else if !wanted, markerSweepTimer != nil {
            markerSweepTimer?.invalidate()
            markerSweepTimer = nil
        }
    }

    /// Consecutive sweeps that failed to find each session's agent. Reset the
    /// moment it is seen again, so only a sustained absence is believed.
    @ObservationIgnored private var goneSweeps: [UUID: Int] = [:]

    /// How many sweeps in a row have to miss an agent before its marker goes.
    /// Two, a minute apart: long enough that no single transient read decides
    /// it, short enough that an agent killed outright stops showing as working.
    private static let sweepsBeforeDroppingMarker = 2

    // MARK: - Operations

    /// Create a session and select it, in the directory the request implies.
    ///
    /// Four answers, in order, and the order is the whole design:
    ///
    /// 1. **An explicit `cwd`.** The CLI's `--cwd`, a worktree checkout, the
    ///    directory ⌘O just picked. Somebody named a path; nothing outranks that.
    /// 2. **The named folder's directory.** `folder` is only ever passed when
    ///    the request was *about* that folder ("New Session in “Acme”"), and
    ///    what it means is Acme. This is the case that used to be silently
    ///    wrong: the session was filed under Acme and started wherever the
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
        let selected = (placingWindow ?? activeWindow)?.selected
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
        // An agent headed for the home folder, or for another agent's own
        // folder, gets one of its own. Not where the caller named the place.
        if cwd == nil, let own = agentFolder(for: directory, starting: start) {
            return makeSession(cwd: own.path, inFolder: dir, via: origin, starting: start) { [weak self] session in
                guard let self else { return }
                let leaf = self.uniqueLeaf(own.name, in: dir)
                session.name = dir.map { "\($0)/\(leaf)" } ?? leaf
            }
        }
        // Through `prepare`, because selecting the row starts its shell, and
        // that is before this returns.
        return makeSession(cwd: directory, inFolder: dir, via: origin, starting: start)
    }

    /// The folder of its own an agent session starts in instead of the home
    /// folder (`ChatFolder`), and what it is called until the agent names it.
    /// Only for Settings' command: a plain terminal still opens at home, and
    /// `wortel new -- <command>` starts where it was asked to.
    private func agentFolder(for directory: String?,
                             starting start: SessionStart) -> (path: String, name: String)? {
        let command = AppSettings.shared.newSessionCommand
        let rootInUse = sessions.contains { $0.originCwd.map { SessionMove.samePath($0, ChatFolder.root) } ?? false }
        guard start.usesPreferredCommand(stored: command), ChatFolder.wantsOwnFolder(directory),
              let path = ChatFolder.make(for: command, rootInUse: rootInUse) else { return nil }
        return (path, ChatFolder.sessionName(for: command))
    }

    /// A session in the home directory, deliberately outside every folder.
    ///
    /// Home is not a project, so filing it under whichever folder you happened
    /// to be looking at would put a `~` row inside "Wortel". This is the escape
    /// hatch from inheritance: one keystroke back to the top, from anywhere,
    /// without a `cd` and without a folder to point at first.
    @discardableResult
    func newHomeSession(via origin: SessionOrigin = .home, starting start: SessionStart) -> Session {
        // Outside every folder either way; an agent in a folder of its own.
        if let own = agentFolder(for: NSHomeDirectory(), starting: start) {
            return makeSession(cwd: own.path, inFolder: nil, via: origin, starting: start) { [weak self] session in
                guard let self else { return }
                session.name = self.uniqueLeaf(own.name, in: nil)
            }
        }
        return makeSession(cwd: NSHomeDirectory(), inFolder: nil, via: origin, starting: start)
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
        // In the window it was asked for in: the one being placed into
        // (`placing`), else the one you're in.
        session.windowID = (placingWindow ?? activeWindow)?.id
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
            selected: (placingWindow ?? activeWindow)?.selectedID, pinned: pinnedIDs)
        sessions.insert(session, at: index)
        let madeIn = placingWindow ?? activeWindow
        let madeFrom = madeIn?.selectedID
        normalizeOrder() // slot the new row into its folder's contiguous block
        // Never select into a hidden row.
        if let dir { collapsedFolders.remove(dir) } else { setLooseCollapsed(false) }
        selectedID = session.id
        // Making a session from one is using it, however short the visit:
        // ⌘N, do the thing, ⌘W lands back where ⌘N was pressed.
        if let madeFrom, let madeIn { noteTrail(madeFrom, in: madeIn) }
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
        if isFront(session.id) || session.startupInput != nil {
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
        let home = window(of: session)
        let wasSelected = session.id == home.selectedID
        // The session you were in before this one, else the row below on
        // screen. Over the rows as drawn, sorted or not, so never one inside
        // a folded section.
        let drawnNeighbour = SidebarStep.afterClosing(
            session.id, in: drawnRows(in: home), trail: home.trail)
        for window in windows { window.trail.removeAll { $0 == session.id } }
        let hadAttention = session.needsAttention
        sleepTimers.removeValue(forKey: session.id)?.cancel()
        hiddenSince.removeValue(forKey: session.id)
        lastTypedAt.removeValue(forKey: session.id)
        lastKeysAt.removeValue(forKey: session.id)
        workBeganAt.removeValue(forKey: session.id)
        reportedRestSince.removeValue(forKey: session.id)
        repaintInPlace.remove(session.id)
        cancelMove(session)
        sleptAt.removeValue(forKey: session.id)
        sleepSurvivors.removeValue(forKey: session.id)
        wantsWake.remove(session.id)
        busyTimers.removeValue(forKey: session.id)?.cancel()
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        unreadDwellTimers.removeValue(forKey: session.id)?.cancel()
        busyStartedAt.removeValue(forKey: session.id)
        lastBusyInterval.removeValue(forKey: session.id)
        turnOutcomes.removeValue(forKey: session.id)
        lastBusyReports.removeValue(forKey: session.id)
        programRecords.removeValue(forKey: session.id)
        saidDone.remove(session.id)
        reportRaised.removeValue(forKey: session.id)
        blockTimers.removeValue(forKey: session.id)?.cancel()
        reportedWords.removeValue(forKey: session.id)
        silenceChecks.removeValue(forKey: session.id)?.cancel()
        autoNameState.removeValue(forKey: session.id)
        attentionSince.removeValue(forKey: session.id)
        attentionContent.removeValue(forKey: session.id)
        lastBanner.removeValue(forKey: session.id)
        reportsBegan.removeValue(forKey: session.id)
        raisedWhileAway.remove(session.id)
        unreadSince.removeValue(forKey: session.id)
        // Closing ends its reminder, and takes back a banner one already showed.
        let reminded = remindedIDs.remove(session.id) != nil
        if session.remindAt != nil || reminded {
            session.remindAt = nil
            onReminderChanged?(session, nil, false)
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

        let left = sessions(in: home)
        guard !left.isEmpty else {
            select(nil, in: home)
            if windows.count > 1 {
                // Another window is open: this one goes, as an empty
                // Terminal window does.
                scheduleSave()
                onWindowEmptied?(home)
            } else {
                saveNow()
                onAllClosed?()
            }
            return
        }

        // Back to the session you were in before (⌘N, do the thing, ⌘W lands
        // where it started), else the row that slid into the closed one's
        // place, else the row above. Within the window it was in. The stored
        // order is the answer only when nothing was drawn to go by.
        if wasSelected {
            let neighbour = drawnNeighbour.flatMap { id in left.contains { $0.id == id } ? id : nil }
            let below = sessions[min(index, sessions.count)...].first { window(of: $0) === home }
            select(neighbour ?? below?.id ?? left.last?.id, in: home)
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
    /// The selection moves *first*, by the rule a single close follows
    /// (`SidebarStep.afterClosing`) with every session in the batch stepped
    /// over: chosen one at a time, the answer is often the next to go, which
    /// would start that session's shell and mark it read only to close it a
    /// moment later.
    func end(_ batch: [Session]) {
        let closing = batch.filter { session in sessions.contains { $0.id == session.id } }
        guard closing.count > 1 else {
            if let session = closing.first { end(session) }
            return
        }
        let closingIDs = Set(closing.map(\.id))
        for window in windows {
            guard let current = window.selectedID, closingIDs.contains(current) else { continue }
            let mine = sessions(in: window)
            guard let index = mine.firstIndex(where: { $0.id == current }) else { continue }
            // None left in it (the window is closing with all of them):
            // nothing in front, rather than each next one's shell started
            // only to be closed. The stored order only when nothing drawn
            // answers.
            let drawn = SidebarStep.afterClosing(
                current, in: drawnRows(in: window), trail: window.trail, closingToo: Array(closingIDs))
            let survivor = drawn
                ?? mine[index...].first(where: { !closingIDs.contains($0.id) })?.id
                ?? mine[..<index].last(where: { !closingIDs.contains($0.id) })?.id
            select(survivor, in: window)
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
    /// `wortel new --worktree`, and what ⌥⇧⌘N's sheet does when Return is
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
        // Back in the window you're in, wherever it was archived from.
        session.windowID = (placingWindow ?? activeWindow)?.id
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
        // A rename can re-folder the session ("hello" -> "team/hello"): keep the
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
        guard let activeWindow else { return }
        let mine = sessions(in: activeWindow)
        let live = Set(mine.map(\.id))
        let order = (shortcutIDs ?? mine.prefix(9).map(\.id)).filter(live.contains)
        guard order.indices.contains(index) else { return }
        selectedID = order[index]
    }

    /// The ⌘-number shown on `id`'s row while ⌘ is held, if it has one.
    func shortcutNumber(for id: Session.ID) -> Int? {
        guard showsShortcutHints, let index = shortcutIDs?.firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// A window's outline drew its rows: the first nine are ⌘1…⌘9's there
    /// from now on.
    func noteDrawnRows(_ drawn: [Session.ID], in window: SessionWindow) {
        window.sidebarRowOrder = drawn
        let first = Array(drawn.prefix(9))
        if first != window.shortcutIDs { window.shortcutIDs = first }
    }

    /// Select a session by id (e.g. from tapping its attention notification).
    func select(id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Asked for the session already in front (its reminder's banner was
        // clicked, with Wortel behind another app): nothing changes hands,
        // so the reminder is answered here, ring and banner both.
        if id == selectedID, answerReminder(session) { session.markedUnread = false }
        // In front of another window, the setter's arrival answers it.
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
        drawnRows(in: activeWindow)
    }

    /// `window`'s rows, as `drawnRows` is the active window's.
    private func drawnRows(in window: SessionWindow?) -> [Session.ID] {
        guard let window else { return [] }
        let mine = sessions(in: window)
        let live = Set(mine.map(\.id))
        let drawn = window.sidebarRowOrder.filter(live.contains)
        return drawn.isEmpty ? mine.filter(isVisibleInSidebar).map(\.id) : drawn
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
    /// When text last went into each session's program: keys, a paste, a
    /// drop, a script's text. Not clicks or scrolls, which `lastTypedAt`
    /// also holds. After a relaunch it starts from `lastTypedAt`, the only
    /// thing saved, which errs towards "something was typed".
    @ObservationIgnored private var lastKeysAt: [Session.ID: Date] = [:]
    /// When each reporting agent last went from not working to working, live
    /// (not from a replay): text that went in before that was that turn's.
    @ObservationIgnored private var workBeganAt: [Session.ID: Date] = [:]
    /// Since when each reporting agent has not said `working`.
    @ObservationIgnored private var reportedRestSince: [Session.ID: Date] = [:]
    /// The sessions that were in front (one per window) when light and dark
    /// last changed, while their agents are still owed a restart where they
    /// stand. Each given up the moment anything happens in it: its window
    /// moving on, text going in, work.
    @ObservationIgnored private var repaintInPlace: Set<Session.ID> = []
    @ObservationIgnored private var appearanceObserver: NSObjectProtocol?

    /// Start the clock for `session`'s agent, unless one is running already.
    /// The earliest timer is kept, so an agent that is asked about often is
    /// not asked later for it; `replacing` is for the caller that knows the
    /// right moment.
    ///
    /// With no `delay`, the hour, or the short wait of an agent painted for
    /// the other appearance.
    private func armSleep(_ session: Session, after delay: TimeInterval? = nil,
                          replacing: Bool = false) {
        let repaint = isPaintedForTheOtherAppearance(session)
        guard let agent = session.runningAgent, AgentSleep.enabledAgents.contains(agent) || repaint,
              case .awake = session.sleep else { return }
        let delay = delay ?? (repaint ? AgentSleep.repaintAfter : AgentSleep.finishedAfter)
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
        // it is in.
        let id = session.id
        let marker = AgentMarker(agent: agent, model: session.runningModel,
                                 cwd: session.runningCwd ?? session.cwd, argv: session.runningArgv,
                                 shellPID: shellPID, startedAt: startedAt)
        let reported = programRecords[id]
        var rest: AgentRest
        let conversationID: String
        var remoteControl = false
        // Text went in since it last set to work: maybe a prompt half
        // written. An agent that reports nothing has no "set to work" to
        // count from, so any text since it started is that.
        //
        // The marker's start is in whole seconds, so the Return that started
        // the agent falls up to a second after it: that much is the launch.
        let launched = startedAt.addingTimeInterval(1)
        let keys = lastKeysAt[id]
        var keysSinceWork = keys.map { $0 > (workBeganAt[id] ?? launched) } ?? false
        if agent == "claude" {
            // The record of the process that has the terminal, when it has
            // one. Started through a wrapper (`devx claude`), the leader is
            // the wrapper and has none: then the group must hold exactly one,
            // since a second Claude in the group (a hook running `claude -p`)
            // keeps a record too, and its conversation and status are not
            // this agent's.
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
            rest = AgentRest(claudeStatus: state.status, since: state.statusChangedAt)
            conversationID = state.conversationID
            remoteControl = state.remoteControl
        } else {
            // No record of its own: what it says in its status reports (OSC
            // 7501), and the conversation Wortel has seen it in. Only ever
            // for a repaint (`AgentSleep.repaintAgents`).
            guard AgentSleep.repaintAgents.contains(agent) else { return unsure("not an agent whose state is read") }
            guard reported != nil else { return unsure("it has not said what it is doing") }
            guard let known = session.liveConversationID, let cwd = marker.cwd
            else { return unsure("its conversation is not known") }
            rest = AgentRest(reported: reported, since: reportedRestSince[id])
            conversationID = known
            // Which conversation it is in, it does not say, and a `/new` or a
            // `/resume` inside it moves it without a word. Either takes keys.
            // So text that went in after the last sign of it being in this
            // one (its command line naming it, or a write to the file) is
            // text that may have moved it, and it is left.
            let seen = AgentConversation.lastSeenIn(agent: agent, id: known, cwd: cwd,
                                                    argv: marker.argv, startedAt: launched)
            if let keys, keys > (seen ?? .distantPast) { keysSinceWork = true }
        }
        // A piece of its work waiting on the person, or still going, while
        // the agent itself reads as finished: not at rest.
        if let reported, case .finished(let since) = rest,
           reported.block != nil || reported.childrenInOrder.contains(where: { $0.state == .working }) {
            rest = .waiting(since: since)
        }

        let input = AgentResumeStore.resumeInput(for: marker, knownConversationID: conversationID)
        // Exact, and one that runs: the line names this conversation and
        // ends in a Return, and the conversation is on disk to come back to.
        let resumable = input.map { $0.hasSuffix("\n") && $0.contains(conversationID) } == true
            && marker.cwd.map { AgentConversation.exists(agent: agent, id: conversationID, cwd: $0) } == true

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
            inHomeFolder: marker.cwd.map { AgentSleep.isHomeFolder($0) } ?? false,
            selected: isFront(id),
            busy: session.isBusy || busyTimers[id] != nil || quiesceTimers[id] != nil,
            rest: rest,
            quietSince: lastBusyInterval[id]?.cleared,
            hiddenSince: hiddenSince[id] ?? launchedAt,
            hasWorkUnder: !started.isEmpty,
            typedSinceRest: lastTypedAt[id].map { $0 > restSince } ?? false,
            remoteControl: remoteControl,
            repaint: isPaintedForTheOtherAppearance(session),
            keysSinceWork: keysSinceWork,
            inPlace: repaintInPlace.contains(id),
            now: Date())
        return SleepCandidate(inputs: inputs, marker: marker, conversationID: conversationID,
                              input: input ?? "", group: group,
                              started: started.map { (pid: $0.pid, startedAt: $0.startedAt) })
    }

    /// The timer fired, or macOS says memory is short: may this agent go?
    private func considerSleep(_ session: Session, pressure: Bool) {
        guard case .awake = session.sleep, session.runningAgent != nil else { return }
        // A resume typed and not yet answered: the agent is on its way up.
        if let owed = session.owedResume, owed.isOwed(at: Date()) {
            if !pressure { armSleep(session, after: AgentSleep.finishedAfter, replacing: true) }
            return
        }
        guard let candidate = sleepCandidate(for: session) else {
            // Nothing sure enough to act on. Asked again in an hour: the cost
            // of an agent that can't be read is one look an hour.
            if !pressure { armSleep(session, after: AgentSleep.finishedAfter, replacing: true) }
            return
        }
        switch AgentSleep.decide(candidate.inputs, pressure: pressure) {
        case .sleep(let waiting):
            beginSleep(session, candidate, waiting: waiting, cause: pressure ? .pressure : .clock)
        case .repaint:
            beginSleep(session, candidate, waiting: false, cause: .appearance)
        case .notBefore(let date):
            AgentSleepLog.log.info("""
                session \(session.id.uuidString, privacy: .public) not yet: \
                \(Int(date.timeIntervalSinceNow)) s to go
                """)
            armSleep(session, after: date.timeIntervalSinceNow + 1, replacing: true)
        case .never(let reason):
            AgentSleepLog.log.info("""
                session \(session.id.uuidString, privacy: .public) stays awake: \
                \(String(describing: reason), privacy: .public)
                """)
            // Working and selected come back by themselves (work ending, the
            // session being left). An agent that doesn't say it is resting
            // is asked again in an hour: the hour, whatever it is painted
            // for, since one that never says would be asked for ever.
            if reason == .restUnknown, !pressure {
                armSleep(session, after: AgentSleep.finishedAfter, replacing: true)
            }
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
    private func beginSleep(_ session: Session, _ candidate: SleepCandidate, waiting: Bool, cause: SleepCause) {
        markEnding(session, candidate, waiting: waiting)
        saveNow()
        signalSleep(session, candidate, waiting: waiting, cause: cause)
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
    private func signalSleep(_ session: Session, _ candidate: SleepCandidate, waiting: Bool, cause: SleepCause,
                             moving: Bool = false) {
        let id = session.id
        let group = candidate.group
        guard case .ending(let sleeper, _) = session.sleep else { return }
        // In front, only the one being restarted where it stands, which
        // `commitSleep` brings straight back, or one being moved: you asked.
        let inPlace = cause == .appearance && repaintInPlace.contains(id)
        if inPlace { repaintInPlace.remove(id) }
        guard session.surfaceView?.ptyHost?.foregroundProcessGroup() == group,
              !session.isBusy, !isFront(id) || inPlace || moving else {
            session.sleep = .awake
            sleepSurvivors[id] = nil
            scheduleSave()
            return
        }
        AgentSleepLog.log.notice("""
            session \(id.uuidString, privacy: .public): ending \(sleeper.marker.agent, privacy: .public) \
            (group \(group), \(waiting ? "waiting" : "finished", privacy: .public)\
            \(cause == .pressure ? ", memory pressure" : "", privacy: .public)\
            \(cause == .appearance ? (inPlace ? ", to repaint it where it stands" : ", to repaint it") : "",
               privacy: .public)), \
            \(candidate.started.count) started under it
            """)
        // What it switched on in the terminal is taken back first, in case
        // it does not do so itself: Codex is gone the moment it is signalled
        // and would leave the shell on the alternate screen with the mouse
        // reported. Before the signal, so the shell's own prompt comes after.
        let modes = TerminalModeRecorder.shared.modes(for: id)
        session.surfaceView?.writeAsOutput(modes.undo)
        kill(-group, SIGTERM)
        // A move is not a sleep, and isn't counted as one.
        if !moving {
            Telemetry.capture(.agentSlept(agent: AgentName(command: sleeper.marker.agent), cause: cause))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSleep.exitGrace) { [weak self] in
            guard let self, let session = self.sessions.first(where: { $0.id == id }),
                  case .ending(let sleeper, let ending) = session.sleep, ending == group else { return }
            // Its marker is still there. That is the shell's to remove, at
            // its next prompt, and a slow prompt (a `precmd` running git on
            // a large repository) can take longer than this. So the process
            // is asked, not the marker: with nothing left of the group the
            // agent has gone, and counting it as awake would leave a session
            // with no agent and nothing to bring it back.
            //
            // The agent is the group's leader. Something else of the group
            // outliving it (a helper slow to stop) is not the agent still
            // being there: counted so, a bare shell was handed the dead
            // agent's modes back.
            let table = ProcessTable.snapshot()
            let leaderLives = table.contains { $0.pid == group && !$0.isExiting }
            if leaderLives {
                // It didn't go. Awake as it was, with the modes that were
                // taken back from it put back if it still has the terminal;
                // nothing else is touched.
                if session.surfaceView?.ptyHost?.foregroundProcessGroup() == group {
                    session.surfaceView?.writeAsOutput(modes.prelude)
                }
                session.sleep = .awake
                self.sleepSurvivors[id] = nil
                self.wantsWake.remove(id)
                AgentSleepLog.log.notice(
                    "session \(id.uuidString, privacy: .public): the agent did not exit, still awake")
                self.scheduleSave()
                // The hour, whatever it is painted for: one that does not
                // go when asked is not asked again every half minute.
                self.armSleep(session, after: AgentSleep.finishedAfter)
                if moving { self.failMove(session, because: "the agent didn't quit when asked") }
            } else {
                self.commitSleep(session, sleeper)
            }
        }
    }

    /// The agent has gone, as asked: the session is asleep from here.
    private func commitSleep(_ session: Session, _ sleeper: SleepingAgent) {
        let id = session.id
        // Ended to be moved: resumed straight away, built for where it goes.
        var sleeper = sleeper
        if let move = pendingMoves[id] {
            if let moved = movedSleeper(sleeper, to: move.path) {
                sleeper = moved
                wantsWake.insert(id)
            } else {
                // Still resumed, where it was: an agent ended for nothing is
                // worse than a move that didn't happen.
                wantsWake.insert(id)
                failMove(session, because: "its conversation can't be resumed there")
            }
        }
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
        if wantsWake.remove(id) != nil || isFront(id) {
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
        // No longer in front: its agent goes by the rule for one out of sight.
        if let left, left != arrived.id { repaintInPlace.remove(left) }
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
            guard let self, self.isFront(id),
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
            failMove(session, because: "the agent didn't start again")
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
        // Being moved: into the new directory first, on a line of its own.
        if let path = sleeper.moveTo, let cd = SessionMove.cdLine(path) {
            guard view.typeCommand(cd) else { return .shellBusy }
            pendingMoves[session.id]?.typed = true
        }
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

    // MARK: - Moving a session (`wortel cd`)
    //
    // Deep sleep's road with a `cd` in it: wait for the agent's turn to end,
    // end it as a sleep would, type `cd <dir>` into the same shell and resume
    // the exact conversation there. The move is done when the shell reports
    // the new directory; then the row is filed where ⌘O would put it.

    @ObservationIgnored private var pendingMoves: [Session.ID: PendingMove] = [:]
    @ObservationIgnored private var moveChecks: [Session.ID: DispatchWorkItem] = [:]

    /// Move `session` to `path`. Answered at once; the move itself waits for
    /// the agent's turn to end when it is working (it is, when it asked).
    func changeDirectory(_ session: Session, to path: String) -> WortelResponse {
        let path = FolderRoot.normalize(path) ?? path
        let shown = SessionMove.display(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("No such directory: \(shown)")
        }
        guard SessionMove.cdLine(path) != nil else {
            return .failure("Wortel can't type \(shown) into a shell safely.")
        }
        // Under way: the agent is going or gone, and nothing can change that.
        if let move = pendingMoves[session.id], move.ending {
            return .failure("This session is already being moved to \(SessionMove.display(move.path)).")
        }
        // Where it already is: a waiting move is called off, which is how an
        // agent takes one back (`wortel cd .`).
        if let current = session.cwd, SessionMove.samePath(current, path) {
            guard pendingMoves[session.id] != nil else { return .failure("Already in \(shown).") }
            cancelMove(session)
            return .success("Move cancelled. This session stays in \(shown).", value: path)
        }
        guard let agent = session.runningAgent else {
            return .failure("No agent is running in this session. In a shell, use cd.")
        }
        guard agent == "claude" else {
            return .failure("Wortel can only move a Claude Code conversation so far.")
        }
        guard case .awake = session.sleep else {
            return .failure("This session's agent is asleep. Select the session, then try again.")
        }
        guard let candidate = sleepCandidate(for: session) else {
            return .failure("Wortel can't stop and resume this agent safely right now.")
        }
        guard candidate.inputs.resumable, candidate.inputs.launchIsSimple else {
            return .failure(candidate.inputs.launchIsSimple
                ? "Wortel can't tell which conversation this is, so it can't carry it over."
                : "This agent was started with more on its command line than the agent, "
                    + "so quitting it would run the rest. Start it on its own to be able to move it.")
        }
        let idle: Bool
        if case .finished = candidate.inputs.rest, !session.isBusy { idle = true } else { idle = false }
        let previous = pendingMoves[session.id].map(\.path).flatMap { SessionMove.samePath($0, path) ? nil : $0 }
        pendingMoves[session.id] = PendingMove(path: path, requestedAt: Date(), idleWhenAsked: idle)
        AgentSleepLog.log.notice("""
            session \(session.id.uuidString, privacy: .public): move asked\
            \(idle ? ", agent at rest" : ", after this turn", privacy: .public)
            """)
        scheduleMoveCheck(session, after: idle ? 0.3 : 1)
        return .success(SessionMove.acceptedMessage(to: path, waitsForTurn: !idle, instead: previous),
                        value: path)
    }

    /// Look again soon. One check pending per session.
    private func scheduleMoveCheck(_ session: Session, after delay: TimeInterval = 2) {
        let id = session.id
        moveChecks.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.moveChecks[id] = nil
            guard let session = self.sessions.first(where: { $0.id == id }) else {
                self.pendingMoves[id] = nil
                return
            }
            self.tryMove(session)
        }
        moveChecks[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// End the agent for its move, if its turn is over and nothing holds it.
    private func tryMove(_ session: Session) {
        let id = session.id
        guard let move = pendingMoves[id], !move.ending else { return }
        if Date().timeIntervalSince(move.requestedAt) > PendingMove.patience {
            return failMove(session, because: "the agent's turn didn't end within an hour")
        }
        guard session.runningAgent != nil else {
            return failMove(session, because: "the agent quit before it could be moved")
        }
        // Asked again in a moment for anything that may pass: still working,
        // a draft typed and not sent, a question waiting, a command running.
        guard case .awake = session.sleep, !session.isBusy,
              let candidate = sleepCandidate(for: session), !candidate.inputs.busy,
              case .finished(let since) = candidate.inputs.rest,
              move.idleWhenAsked || since > move.requestedAt,
              !candidate.inputs.typedSinceRest
        else { return scheduleMoveCheck(session) }
        pendingMoves[id]?.ending = true
        // From here only the shell reporting the new folder ends it. If that
        // never comes (the resume never starts, the `cd` fails, the folder
        // went), the move is called off rather than left pending for good.
        let requested = move.requestedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + PendingMove.arrivalGrace) { [weak self, weak session] in
            guard let self, let session, self.pendingMoves[id]?.requestedAt == requested else { return }
            self.failMove(session, because: "it didn't arrive there")
        }
        AgentSleepLog.log.notice("session \(id.uuidString, privacy: .public): ending the agent to move it")
        markEnding(session, candidate, waiting: false)
        saveNow()
        signalSleep(session, candidate, waiting: false, cause: .clock, moving: true)
        // The last look before the signal found a reason to wait.
        if case .awake = session.sleep, pendingMoves[id] != nil {
            pendingMoves[id]?.ending = false
            scheduleMoveCheck(session)
        }
    }

    /// The sleeping agent as it resumes in `path`: the same conversation,
    /// its resume built for that directory (by the transcript's path, since
    /// the transcript stays where it was written).
    private func movedSleeper(_ sleeper: SleepingAgent, to path: String) -> SleepingAgent? {
        let old = sleeper.marker
        let marker = AgentMarker(agent: old.agent, model: old.model, cwd: path, argv: old.argv,
                                 shellPID: old.shellPID, startedAt: old.startedAt)
        guard let input = AgentResumeStore.resumeInput(for: marker, knownConversationID: sleeper.conversationID),
              input.hasSuffix("\n"), AgentConversation.exists(agent: old.agent, id: sleeper.conversationID, cwd: path)
        else { return nil }
        return SleepingAgent(marker: marker, conversationID: sleeper.conversationID, input: input,
                             waiting: false, moveTo: path)
    }

    /// The shell is in the new directory: the row follows, filed as ⌘O would
    /// file it, and ⌘N beside it starts there.
    private func finishMove(_ session: Session, to path: String) {
        pendingMoves[session.id] = nil
        moveChecks.removeValue(forKey: session.id)?.cancel()
        session.originCwd = path
        let folder = folder(forDirectory: path)
        if folder != session.folderPath {
            // Not a second "Claude" beside one already there.
            let leaf = uniqueLeaf(session.leafName, in: folder)
            if leaf != session.leafName {
                session.name = session.folderPath.map { "\($0)/\(leaf)" } ?? leaf
            }
            moveSessions([session.id], toFolder: folder)
        }
        AgentSleepLog.log.notice("session \(session.id.uuidString, privacy: .public): moved")
        scheduleSave()
    }

    /// A waiting move forgotten: asked for, or the session closed.
    private func cancelMove(_ session: Session) {
        pendingMoves[session.id] = nil
        moveChecks.removeValue(forKey: session.id)?.cancel()
    }

    /// The move is off: the session stays (or is resumed) where it was, and
    /// the person is told, since whoever asked may be gone.
    private func failMove(_ session: Session, because why: String) {
        guard let move = pendingMoves.removeValue(forKey: session.id) else { return }
        moveChecks.removeValue(forKey: session.id)?.cancel()
        AgentSleepLog.log.notice("""
            session \(session.id.uuidString, privacy: .public): move given up: \(why, privacy: .public)
            """)
        raiseAttention(session, kind: .failed, title: session.name,
                       body: "Didn't move to \(SessionMove.display(move.path)): \(why).", source: "move")
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
            signalSleep(session, candidate, waiting: waiting, cause: .pressure)
        }
    }

    // MARK: - Repainting an agent when light and dark change
    //
    // A program that painted itself in colours of its own keeps them when the
    // Mac goes from light to dark: Codex reads the terminal's colours once,
    // when it starts. No terminal can repaint that, and nothing a terminal
    // sends makes the program look again. A new process does. So an agent at
    // rest is ended and its conversation brought back, by deep sleep's own
    // means and under its checks (`docs/appearance.md`).

    /// Whether `session`'s agent drew itself for the appearance the Mac no
    /// longer has. An agent started since the last change, or after a change
    /// there and back, did not. Nor did one that repaints itself when told
    /// (Claude Code fullscreen): it was told with every terminal, or is told
    /// when its terminal wakes, and a restart would only end its process.
    /// Only by what is on record, never `assuming(agent:)`: a woken terminal
    /// sends the report only for a `?2031` on record, and one that is not
    /// told does not repaint. A record that missed either mode errs towards
    /// the restart.
    private func isPaintedForTheOtherAppearance(_ session: Session) -> Bool {
        guard let agent = session.runningAgent, AgentSleep.repaintAgents.contains(agent),
              let painted = session.agentPaintedDark, painted != runtime.isDark else { return false }
        return !TerminalModeRecorder.shared.modes(for: session.id).repaintsItselfOnSchemeChange
    }

    /// Light and dark changed (`GhosttyRuntime.appearanceDidChange`), and
    /// every terminal has been told. Each agent painted for the other one is
    /// looked at, once, from one process table: at rest and out of sight
    /// long enough, it goes now; the one in front is restarted where it
    /// stands; any other gets a timer for when it may. One that is working,
    /// waiting on an answer, running something or has text typed is not
    /// touched, and is looked at again when it next comes to rest or its
    /// session is left (`armSleep`).
    private func appearanceChanged() {
        repaintInPlace = []
        let stale = sessions.filter { session in
            guard case .awake = session.sleep else { return false }
            return isPaintedForTheOtherAppearance(session)
        }
        // A timer armed for a repaint that is no longer wanted (changed
        // there and back) is left: it looks once, finds the ordinary clock,
        // and arms that.
        guard !stale.isEmpty else { return }
        AgentSleepLog.log.notice("the appearance changed: \(stale.count) agents are painted for the other one")
        // The one in front of each window is offered a restart where it
        // stands, for this look only: kept below if it may have one now or
        // in a moment, and taken back if not. One at work in front when the
        // Mac changed is not restarted under the answer it then gives.
        let fronts = Set(stale.filter { isFront($0.id) }.map(\.id))
        repaintInPlace = fronts
        let table = ProcessTable.snapshot()
        let markers = AgentResumeStore.currentMarkers()
        var going: [(Session, SleepCandidate)] = []
        var mayRestart: Set<Session.ID> = []
        defer { repaintInPlace.subtract(fronts.subtracting(mayRestart)) }
        for session in stale {
            if let owed = session.owedResume, owed.isOwed(at: Date()) { continue }
            guard let candidate = sleepCandidate(for: session, table: table, markers: markers) else { continue }
            let verdict = AgentSleep.decide(candidate.inputs)
            if fronts.contains(session.id) {
                switch verdict {
                case .repaint, .notBefore: mayRestart.insert(session.id)
                case .sleep, .never: break
                }
            }
            switch verdict {
            case .repaint:
                going.append((session, candidate))
            case .notBefore(let date):
                AgentSleepLog.log.info("""
                    session \(session.id.uuidString, privacy: .public) not yet: \
                    \(Int(date.timeIntervalSinceNow)) s to go
                    """)
                armSleep(session, after: date.timeIntervalSinceNow + 1, replacing: true)
            case .never(let reason):
                AgentSleepLog.log.info("""
                    session \(session.id.uuidString, privacy: .public) is not repainted: \
                    \(String(describing: reason), privacy: .public)
                    """)
            case .sleep:
                // Its ordinary clock was up as well, and has its own timer.
                break
            }
        }
        guard !going.isEmpty else { return }
        for (session, candidate) in going { markEnding(session, candidate, waiting: false) }
        saveNow()
        for (session, candidate) in going {
            signalSleep(session, candidate, waiting: false, cause: .appearance)
        }
    }

    // MARK: - Busy state (debounced)

    /// A command started: show busy after a short delay so instant commands
    /// don't flicker. Coalesces repeat progress reports for a running command.
    /// Also cancels a pending quiesce-attention: the program resumed working,
    /// so its earlier "stopped" was a blip, not a prompt for the user.
    private func markBusy(_ session: Session) {
        lastBusyReports[session.id] = Date()
        // Working: whatever clock was running towards sleep is off, and so
        // is a restart where it stands.
        sleepTimers.removeValue(forKey: session.id)?.cancel()
        repaintInPlace.remove(session.id)
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
        if let start = busyStartedAt.removeValue(forKey: session.id) {
            lastBusyInterval[session.id] = (start: start, cleared: Date())
        }
        if session.isBusy {
            session.isBusy = false
            noteConversation(session)
        }
        // At rest, perhaps: the hour starts counting (`AgentSleep`).
        armSleep(session)
        if pendingMoves[session.id] != nil { scheduleMoveCheck(session, after: 0.5) }
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

    /// A terminal's title is read for one thing: the name an agent gave its
    /// conversation (`adoptAgentTitle`). It used to be read for state too, a
    /// spinner glyph for "working" and "Action Required" for "blocked". Every
    /// agent restyled its spinner sooner or later, and a list of glyphs that
    /// stops matching fails without a sound. An agent says what it is doing in
    /// a status report (`programStatus`), or Wortel does not claim to know.
    private func titleChanged(_ session: Session, title: String) {
        adoptAgentTitle(session, title: title.trimmingCharacters(in: .whitespaces))
    }

    /// Announce a turn the program said it finished, in the agent's own
    /// words: the start of its last answer (`AgentAnswer`), read from Claude
    /// Code's transcript, Codex's rollout or Pi's session file, off the main
    /// thread. The file is asked for words and nothing else. It used to be
    /// asked whether there had been a turn at all, to check a guess; a program
    /// that says `done` is not second-guessed, and a file that can't be found
    /// costs the quote, never the announcement.
    ///
    /// The fixed text is what is left for another agent, a conversation not
    /// known, or an answer that is only code.
    private func announceFinishedTurn(_ session: Session, startedAt: Date?) {
        let raise = { [weak self, weak session] (answer: String?) in
            guard let self, let session else { return }
            self.raiseReported(session, kind: .turnDone, body: answer ?? Self.fixedWords(for: .turnDone),
                               source: answer == nil ? "status" : "status-answer")
            // A finished turn is the best moment to (re)name the session from
            // what's now on screen, even when it's the one you're watching.
            self.considerAutoName(session)
        }
        guard let agent = session.runningAgent, AgentConversation.exact.contains(agent),
              let cwd = session.runningCwd ?? session.cwd, let startedAt,
              session.liveConversationID != nil || agent == "codex"
        else { return raise(nil) }
        let id = session.liveConversationID
        // Other sessions' conversations, which are never this one's to quote.
        let others = Set(sessions.compactMap { $0 === session ? nil : $0.liveConversationID })
        // Two seconds of slack: the prompt that opened the turn is stamped
        // when the agent wrote it, which can be a moment before it said
        // `working`.
        let since = startedAt.addingTimeInterval(-2)
        DispatchQueue.global(qos: .userInitiated).async {
            var answer: String?
            switch (agent, id) {
            case ("claude", let id?):
                answer = AgentResumeStore.claudeTranscript(id: id, cwd: cwd)
                    .flatMap(ClaudeTranscriptTail.readTail(of:))
                    .flatMap { ClaudeTranscriptTail.lastAnswer($0, since: since) }
            case ("codex", _):
                // Through `turnReading` for which rollout, not for whether: a
                // `/new` or `/resume` inside Codex leaves the known id behind.
                if case .turn(let tail, _) = AgentConversation.Codex.turnReading(
                    conversation: id, cwd: cwd, since: since, others: others) {
                    answer = AgentAnswer.codex(tail, since: since)
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
                // Working again while the file was read: it carried on.
                guard !session.isBusy, self.busyTimers[session.id] == nil else { return }
                raise(answer)
            }
        }
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

    // MARK: - What a program says it is doing (OSC 7501)

    /// Whether the program in `session` reports its own state, and so is
    /// taken at its word. For as long as it does, its reports are all that is
    /// heard from it: progress and bells from it raise nothing, and a
    /// notification of its own is only words (`reportedNotification`). Ends when the
    /// program says it has gone, its agent's marker goes, or the shell is back
    /// at its prompt (`forgetReport`).
    private func reports(_ session: Session) -> Bool {
        programRecords[session.id] != nil
    }

    /// One report from the program in `session` (`SurfaceView.onProgramStatus`).
    /// What it comes to is decided in `ReportedStatus.effects`; this carries
    /// it out.
    private func programStatus(_ session: Session, _ report: ProgramStatusReport, replayed: Bool) {
        let id = session.id
        let before = programRecords[id]
        // A program that says what it is doing is an agent, whatever its
        // name: this Mac has one.
        Permissions.shared.noteAgent()
        AgentStatusLog.log.debug("""
            status \(report.logDescription, privacy: .public) \(replayed ? "replayed " : "", privacy: .public)\
            after \(before?.effective?.state.rawValue ?? "nothing", privacy: .public) \
            id=\(id.uuidString, privacy: .public)
            """)
        let gone = report == .clear
        var after = before
        if gone {
            // From a program that never said anything, there is nothing to
            // take back, and its busy is not this path's to clear.
            guard before != nil else { return }
            after = nil
        } else {
            if after == nil {
                // A child cleared by a program that has said nothing else is
                // no reason to start taking it at its word.
                if case .clearRecord = report { return }
                beganReporting(session)
                after = ProgramRecords()
            }
            after?.apply(report)
        }
        programRecords[id] = after
        // Since when it has been at rest, and when it last set to work: what
        // ending it to repaint it goes by (`sleepCandidate`). A replay's
        // `working` is not counted as work begun: it was written while
        // nobody was here, and when is not known.
        switch after?.root?.state {
        case .working?:
            if before?.root?.state != .working, !replayed { workBeganAt[id] = Date() }
            reportedRestSince[id] = nil
        case .some:
            if reportedRestSince[id] == nil { reportedRestSince[id] = Date() }
        case nil:
            reportedRestSince[id] = nil
        }
        // Remembered across a relaunch (`PersistedSession.reportedState`).
        if before?.said?.state != after?.said?.state { scheduleSave() }
        // A program that never says `done` ends its turns by going idle
        // (opencode). One that has said it, or is known to, does not. Only
        // after two seconds of work, so a command that flickers `working` is
        // not a turn.
        let root = after?.root
        if root?.state == .done || root?.state == .error { saidDone.insert(id) }
        let tellsFinishFromStop = saidDone.contains(id)
            || (root?.app ?? before?.root?.app).map(ReportedStatus.saysDone.contains) ?? false
        let worked = replayed || busyStartedAt[id].map {
            Date().timeIntervalSince($0) >= Self.minBusyForQuiesceAttention
        } ?? false
        for effect in ReportedStatus.effects(from: before, to: after, gone: gone, replayed: replayed,
                                             idleEndsTurn: !tellsFinishFromStop && worked) {
            switch effect {
            case .working:
                // Cancels a turn's end still waiting out its settle: the
                // program carried on.
                markBusy(session)
                // And it is working again, so the turn it finished or failed
                // before is no longer the news. Left up, the row showed
                // "finished" over a session that was busy, and the next
                // turn's end, saying the same, raised nothing.
                if let kind = reportRaised[id], kind != .needsInput, session.attention == kind {
                    clearAttention(session)
                }
            case .resting:
                quiesceTimers.removeValue(forKey: id)?.cancel()
                clearBusy(session)
            case .announce(.needsInput, let words):
                announceBlock(session, words: words)
            case .announce(let kind, let words):
                announceTurnEnd(session, kind: kind, words: words)
            case .announceAfterWork(let kind):
                announceTurnEnd(session, kind: kind, words: nil, settle: ReportedStatus.settleAfterWork)
            case .mark(let kind, let words):
                raiseReported(session, kind: kind, body: words ?? Self.fixedWords(for: kind),
                              source: "status-replayed", quietly: true)
            case .answered:
                // An announcement of the block that has not gone out yet, and
                // the dot of one that has.
                blockTimers.removeValue(forKey: id)?.cancel()
                if reportRaised[id] == .needsInput, session.attention == .needsInput {
                    clearAttention(session)
                }
                // Nor is "needs you" how its last stretch of work ended any
                // more, for `wortel list` and `wait --idle`.
                if turnOutcomes[id] == .needsInput { turnOutcomes[id] = nil }
            case .gone:
                // Not `forgetReport`: a program that reports `done` and exits
                // at once is still owed its announcement.
                reportedWords[id] = nil
                reportsBegan[id] = nil
                saidDone.remove(id)
                clearBusy(session)
            }
        }
        updateAgentActivityAssertion()
    }

    /// The first report of a program's run. It is not an old version after
    /// all: the wait to say so is off, and so is the mark if it was up.
    private func beganReporting(_ session: Session) {
        let id = session.id
        reportsBegan[id] = Date()
        silenceChecks.removeValue(forKey: id)?.cancel()
        if session.silentAgent != nil { session.silentAgent = nil }
    }

    /// The program that was reporting is gone: its agent ended, or the shell
    /// is back at its prompt. A block it was waiting on is over with it; what
    /// a finished or failed turn raised stays, since the result is still
    /// there to look at.
    private func forgetReport(_ session: Session) {
        let id = session.id
        reportedRestSince[id] = nil
        guard let last = programRecords.removeValue(forKey: id) else { return }
        reportsBegan[id] = nil
        reportedWords[id] = nil
        saidDone.remove(id)
        if last.block != nil {
            blockTimers.removeValue(forKey: id)?.cancel()
            if reportRaised[id] == .needsInput, session.attention == .needsInput {
                clearAttention(session)
            }
            if turnOutcomes[id] == .needsInput { turnOutcomes[id] = nil }
        }
        updateAgentActivityAssertion()
    }

    /// Raise what a report came to, and remember that a report raised it:
    /// that, and nothing else on the session, is what a later report may take
    /// back (`reportRaised`).
    private func raiseReported(_ session: Session, kind: AttentionKind, body: String, source: String,
                               quietly: Bool = false) {
        raiseAttention(session, kind: kind, title: session.name, body: body, source: source, quietly: quietly)
        if session.attention == kind { reportRaised[session.id] = kind }
    }

    /// Announce that a program is waiting on the user, once that has stood
    /// for `ReportedStatus.settle`: one that asks and is answered by a rule of
    /// its own never wanted anyone. The block ending before then cancels it
    /// (`programStatus`, `.answered`).
    private func announceBlock(_ session: Session, words: String?) {
        let id = session.id
        blockTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.blockTimers[id] = nil
            self.updateAgentActivityAssertion()
            // Its own notification, sent in the same breath, says what it is
            // asking for ("Approval requested: npm test").
            let own = self.reportedWords[id].flatMap {
                Date().timeIntervalSince($0.at) < Self.reportedWordsWindow ? $0.text : nil
            }
            self.raiseReported(session, kind: .needsInput,
                               body: own.map(ReportedStatus.banner) ?? words ?? Self.fixedWords(for: .needsInput),
                               source: "status", quietly: self.reportIsTooSoon(session, kind: .needsInput))
        }
        blockTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ReportedStatus.settle, execute: work)
        // Must not be put off by App Nap.
        updateAgentActivityAssertion()
    }

    /// Announce a turn a program finished or failed, once that has stood for
    /// `ReportedStatus.settle`: one that finishes and starts its next queued
    /// message at once passed through `done` without wanting anyone. A
    /// `working` or `idle` before then cancels it (`programStatus`).
    private func announceTurnEnd(_ session: Session, kind: AttentionKind, words: String?,
                                 settle: TimeInterval = ReportedStatus.settle) {
        let id = session.id
        quiesceTimers[id]?.cancel()
        // Since when its conversation is this turn's, for the answer to
        // quote: when the work began, which `.resting` has just filed as the
        // last busy stretch. Not the latest `working`, which a program sends
        // again with every new message, after its answer was written too.
        let startedAt = lastBusyInterval[id]?.start ?? busyStartedAt[id] ?? lastBusyReports[id]
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.quiesceTimers[id] = nil
            self.updateAgentActivityAssertion()
            guard kind == .turnDone else {
                self.raiseReported(session, kind: kind, body: words ?? Self.fixedWords(for: kind),
                                   source: "status", quietly: self.reportIsTooSoon(session, kind: kind))
                self.considerAutoName(session)
                return
            }
            self.announceFinishedTurn(session, startedAt: startedAt)
        }
        quiesceTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        // Must not be put off by App Nap.
        updateAgentActivityAssertion()
    }

    // MARK: An agent too old to report

    /// How long an agent that can report its state gets to do so before it
    /// is taken for a version that can't. Codex reports at its first draw,
    /// Claude Code and Pi as soon as their question is answered: all inside a
    /// second or two.
    private static let silencePatience: TimeInterval = 20
    @ObservationIgnored private var silenceChecks: [Session.ID: DispatchWorkItem] = [:]

    /// An agent run began in `session` (`marker`), or ended (nil). If it is an
    /// agent known to report its state and it says nothing, the sidebar's bar
    /// and its row say so for as long as it runs: with nothing guessed, an
    /// old Codex shows no spinner and no dot, and nothing else tells someone
    /// why (`docs/decisions.md`, 2026-11-19).
    ///
    /// Only an agent seen starting, because one that was already running may
    /// have asked its question of a Wortel that could not answer yet. And
    /// only one that has its interface up (it turned on bracketed paste):
    /// `codex exec` and `claude -p` report nothing however new they are.
    private func watchForSilence(_ session: Session, marker: AgentMarker?) {
        let id = session.id
        silenceChecks.removeValue(forKey: id)?.cancel()
        if session.silentAgent != nil { session.silentAgent = nil }
        guard let marker, ReportedStatus.knownReporters[marker.agent] != nil else { return }
        let agent = marker.agent, started = marker.startedAt
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.silenceChecks[id] = nil
            guard session.runningAgent == agent, session.runningStartedAt == started,
                  !self.reports(session),
                  let terminal = session.surfaceView?.keeperSession,
                  TerminalModeRecorder.shared.modes(for: terminal).bracketedPaste else { return }
            session.silentAgent = agent
            // How often the triangle is really shown, per agent: what decides
            // whether helping with the update is worth building.
            Telemetry.capture(.agentOutdated(agent: AgentName(command: agent)))
            AgentStatusLog.log.debug("""
                status: \(agent, privacy: .public) said nothing in \(Int(Self.silencePatience))s, saying so \
                id=\(id.uuidString, privacy: .public)
                """)
        }
        silenceChecks[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silencePatience, execute: work)
    }

    /// The agents running somewhere in a version too old to report, each
    /// once, in the order of the sessions they run in. What the sidebar's
    /// bar shows its icon for (`AgentUpdateIndicator`).
    var silentAgents: [String] {
        var seen = Set<String>()
        return sessions.compactMap(\.silentAgent).filter { seen.insert($0).inserted }
    }

    /// How close to a reported block a program's own notification has to be
    /// to be the words for it.
    private static let reportedWordsWindow: TimeInterval = 2

    /// A notification (OSC 9, 777, 99) from a program that reports its state.
    /// It raises nothing: the report is the news, and Codex's turn-end
    /// notification is the start of its answer with no fixed wording, which
    /// is how a finished turn used to arrive as the loudest kind. For a block
    /// it is what the program is asking for, so it becomes the banner's words.
    private func reportedNotification(_ session: Session, title: String, body: String) {
        let id = session.id
        let text = (body.isEmpty ? title : body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reportedWords[id] = (text, Date())
        // The block is already announced: the banner takes the better words,
        // silently, as any new words for a standing kind do.
        guard programRecords[id]?.block != nil, reportRaised[id] == .needsInput,
              session.attention == .needsInput else { return }
        raiseReported(session, kind: .needsInput, body: ReportedStatus.banner(text),
                      source: "status-words", quietly: reportIsTooSoon(session, kind: .needsInput))
    }

    /// How often a program's reports may put a banner on screen for one
    /// session. A program can change state as fast as it can write, and the
    /// spec asks a terminal to limit what that causes outside itself.
    private static let reportedBannerInterval: TimeInterval = 3

    private func reportIsTooSoon(_ session: Session, kind: AttentionKind) -> Bool {
        bannerIsTooSoon(session, kind: kind, within: Self.reportedBannerInterval)
    }

    /// Whether a banner for `kind` would follow the session's last one
    /// inside `interval`. Never for something louder than what is showing:
    /// that is news whenever it comes. Too soon, it still changes the dot and
    /// what the session is noted as saying; it only does not slide a banner
    /// in.
    private func bannerIsTooSoon(_ session: Session, kind: AttentionKind, within interval: TimeInterval) -> Bool {
        guard let last = lastBanner[session.id], kind.priority <= last.kind.priority else { return false }
        return Date().timeIntervalSince(last.at) < interval
    }

    /// What a kind's banner says when neither the program nor its
    /// conversation gave it words.
    private static func fixedWords(for kind: AttentionKind) -> String {
        switch kind {
        case .needsInput: return "Waiting on you"
        case .failed: return "Stopped with an error"
        case .turnDone: return "Finished, your move"
        case .finished: return "Command finished"
        }
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
        // AppKit's word for frontmost before the flag's. The flag starts out
        // true and is only corrected when Wortel resigns, so an app that was
        // never in front (opened in the background, as a login item is, or a
        // relaunch behind another app) took its selected session for watched
        // and raised nothing for it, however long you were elsewhere. Found
        // 2026-11-19 running a background copy: the selected session's
        // question raised nothing while another app was being typed in.
        // Every window's front session counts: two windows side by side are
        // two sessions in view.
        guard NSApp?.isActive ?? appIsActive else { return false }
        let window = window(of: session)
        return window.isVisible && window.selectedID == session.id
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
        reportRaised.removeValue(forKey: session.id)
        guard session.attention != nil else { return false }
        AgentStatusLog.log.debug("attention cleared id=\(session.id.uuidString, privacy: .public)")
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
        [UUID: (kind: AttentionKind, title: String?, body: String, postedAt: Date, bannered: Bool)] = [:]
    /// The last banner each session actually put on screen, and when. Not
    /// cleared with the attention: a program that blocks and is answered
    /// every second has its attention cleared every second, and its banners
    /// still have to keep to one per interval (`bannerIsTooSoon`).
    @ObservationIgnored private var lastBanner: [UUID: (kind: AttentionKind, at: Date)] = [:]
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
    /// the session is very often renamed *moments later*: `announceFinishedTurn`
    /// calls `considerAutoName` on the next line, and that runs a model off-main and
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
        // Only a banner that is there: one raised quietly (old news from
        // before a relaunch, or held back as too soon) has none to rewrite,
        // and posting one now would be the banner it was kept from.
        guard session.attention != nil, let content = attentionContent[session.id], content.bannered,
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
            settling: quiesceTimers[id] != nil || blockTimers[id] != nil,
            asksForAction: programRecords[id]?.block != nil,
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

    /// Put `line` on a prompt for the person to run: there, unsent, as if they
    /// had typed it and not yet pressed Return. For a command that is theirs
    /// to read first (an agent's own installer, `AgentInstall`).
    ///
    /// In the session in front when its shell is at a prompt. Otherwise in a
    /// new plain session, typed before the shell has read a byte, so it is
    /// waiting on the first prompt: a line pasted into whatever is running
    /// there (an editor, a build asking a question) would be typed into that.
    func offerCommand(_ line: String) {
        // A second press on the heels of the first (a button that stays on
        // screen, a double click) would type the line onto itself.
        let now = Date()
        if let last = lastOffer, last.line == line, now.timeIntervalSince(last.at) < 2 { return }
        lastOffer = (line, now)
        // And only where it will be seen: with a file or a browser tab in
        // front of the terminal the line would be typed out of sight, and
        // the keyboard handed to a terminal nobody is looking at.
        if let session = (placingWindow ?? activeWindow)?.selected, let view = session.surfaceView,
           session.activeMainTab ?? .session == .session,
           let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
           shellIsAtPrompt(session, view) {
            view.sendText(line, scripted: true)
            view.window?.makeFirstResponder(view)
            return
        }
        _ = newSession(starting: .line(line))
    }

    @ObservationIgnored private var lastOffer: (line: String, at: Date)?

    /// The shell of `session` has its terminal and nothing under it. The
    /// same reading a resume is typed on (`wake`), asked once and not again:
    /// a no here costs a new session, not a wrong keystroke.
    private func shellIsAtPrompt(_ session: Session, _ view: SurfaceView) -> Bool {
        guard session.runningAgent == nil, !view.isHibernated, !view.isRestoring,
              let pty = view.ptyHost, let root = view.shellPID else { return false }
        let table = ProcessTable.snapshot()
        let shellPID = ProcessTable.shell(of: root, in: table)
        guard let shell = table.first(where: { $0.pid == shellPID }),
              ProcessTable.isShell(shell.name), !shell.isExiting else { return false }
        return pty.foregroundProcessGroup() == shell.pgid
            && ProcessTable.work(under: shellPID, in: table).isEmpty
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
    /// `quietly`: the dot and the badge, with no banner and no sound. For what
    /// happened while Wortel was closed, which is worth finding and not worth
    /// a banner per session at launch.
    private func raiseAttention(_ session: Session, kind: AttentionKind, title: String, body: String,
                                source: String, quietly: Bool = false) {
        // Logged before the gates, and always: when a dot shows up on a session
        // the user hasn't touched in days, the only question worth answering is
        // which signal raised it — and that used to be unanswerable, because
        // every trace line named the signal without naming the session.
        AgentStatusLog.log.debug("""
            attention \(source, privacy: .public) kind=\(String(describing: kind), privacy: .public) \
            id=\(session.id.uuidString, privacy: .public) name=\(session.name, privacy: .private)
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
            activelyViewing: isActivelyViewing(session), onScreen: isOnScreen(session))
        else {
            // Said as well as the signal above: a dot that did not appear is
            // otherwise invisible, and so is the reason.
            AgentStatusLog.log.debug("""
                attention not raised (someone is looking, something louder is showing, or it says the same) \
                id=\(session.id.uuidString, privacy: .public)
                """)
            return
        }
        AgentStatusLog.log.debug("""
            attention raised kind=\(String(describing: kind), privacy: .public) \
            banner=\(!quietly, privacy: .public) sound=\(alert && !quietly, privacy: .public) \
            id=\(session.id.uuidString, privacy: .public)
            """)
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
        attentionContent[session.id] = (kind, title == session.name ? nil : title, body, Date(), !quietly)
        if !quietly {
            lastBanner[session.id] = (kind, Date())
            onNeedsAttention?(session, kind, title, body, alert)
        }
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
        onReminderChanged?(session, date, true)
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
            if let date = session.remindAt, date > now { onReminderChanged?(session, date, false) }
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
        onReminderChanged?(session, nil, false)
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
                window(of: session).attentionFlash = AttentionFlash(kind: .finished)
                onReminderChanged?(session, nil, false)
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

    /// Give the keyboard back to the selected session: its terminal, when that
    /// is in front of its row; otherwise what is in front of the main area,
    /// as a switch to it would. The active window's, which the app layer
    /// sets (`SessionWindow.onReturnKeyboard`): a click or a rename in a
    /// sidebar made its window the active one.
    func returnKeyboardToSession() {
        activeWindow?.onReturnKeyboard?()
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
    func pruneSidebarSelection(toDrawn drawn: [Session.ID], in window: SessionWindow) {
        window.sidebarRowOrder = drawn
        guard window === activeWindow, sidebarSelection.isMultiple else { return }
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
        checkFolders()
        for window in windows where window.isVisible {
            guard let selected = window.selected else { continue }
            clearAttentionOnShow(selected)
            scheduleCaughtUp(selected)
        }
    }

    func appDidResignActive() {
        appIsActive = false
        windows.forEach { cancelCaughtUp($0.selectedID) }
    }

    /// The main window's on-screen visibility changed (occlusion state /
    /// miniaturization). Becoming visible while frontmost means the user can
    /// now see the selected session — clear its attention, same as activate,
    /// with the same exception: a display waking from sleep uncovers the
    /// window too, and is not someone reading it.
    func windowVisibilityChanged(_ window: SessionWindow, visible: Bool) {
        window.isVisible = visible
        if visible, appIsActive, let selected = window.selected {
            clearAttentionOnShow(selected)
            scheduleCaughtUp(selected)
        } else {
            cancelCaughtUp(window.selectedID)
        }
    }

    /// What a collapsed folder should show on behalf of the sessions inside it.
    ///
    /// Only when collapsed: an open folder's rows carry their own dots, and
    /// repeating them on the header is noise. A rollup exists to surface what is
    /// *hidden* — a blocked agent behind a collapsed folder is otherwise
    /// completely silent in the sidebar, which is the one thing the attention
    /// system exists to prevent.
    func attention(inFolder folder: String, of window: SessionWindow) -> AttentionKind? {
        guard collapsedFolders.contains(folder) else { return nil }
        return AttentionKind.loudest(of: sessionsHidden(inFolder: folder, of: window).map(\.attention))
    }

    /// Whether a collapsed folder is hiding a session at work: the three dots
    /// its header shows when nothing in it is louder (`attention(inFolder:)`).
    /// Without it a folded folder of working agents looked exactly like one
    /// of idle shells, and the only way to see that something was under way
    /// was to open it.
    func isWorking(inFolder folder: String, of window: SessionWindow) -> Bool {
        guard collapsedFolders.contains(folder) else { return false }
        return sessionsHidden(inFolder: folder, of: window).contains(where: Self.showsWorking)
    }

    /// The sessions a folder's header speaks for: those drawn under it, in
    /// that window's sidebar. A pinned one is drawn in Pinned, whose header
    /// speaks for it. Folding is shared by every window, but each lists only
    /// its own sessions, so a folder folded in two windows speaks for
    /// different ones in each.
    private func sessionsHidden(inFolder folder: String, of window: SessionWindow) -> some Sequence<Session> {
        sessions(in: window).lazy.filter { $0.folderPath == folder && !self.isPinned($0) }
    }

    /// Whether a session's row shows the three dots: at work, or a worktree on
    /// its way (`SessionStatusIndicator`).
    static func showsWorking(_ session: Session) -> Bool {
        session.isBusy || (session.preparation.map { $0.failure == nil } ?? false)
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
        // arrives seconds after `announceFinishedTurn` posted it.
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
            colour: session.colour?.rawValue, windowID: session.windowID,
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
            runningStartedAt: agent == nil ? nil : agent?.startedAt,
            lastConversationID: session.lastConversationID,
            portBase: session.portBase,
            remindAt: session.remindAt,
            agentAsleep: session.sleep.agent.map { $0.waiting ? "waiting" : "finished" },
            lastTypedAt: lastTypedAt[session.id],
            createdAt: session.createdAt, lastSentAt: session.lastSentAt,
            // Only an agent's: a plain command's report ends with the command.
            // A program that reports and has said nothing that amounts to a
            // state is at rest.
            reportedState: agent == nil ? nil : programRecords[session.id].map {
                ($0.said?.state ?? .idle).rawValue
            },
            agentPaintedDark: session.runningAgent == nil ? nil : session.agentPaintedDark)
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
                                    shellPID: nil, startedAt: session.runningStartedAt),
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
        store.scheduleSave { [weak self] in
            self?.saveWindows()
            return self?.persistedSessions() ?? []
        }
    }

    /// `windows.json`: each window's place and the session it had in front,
    /// in the order they were opened. Beside `sessions.json`, written with it.
    private func saveWindows() {
        WindowStore.save(windows.map {
            PersistedWindow(id: $0.id, frame: $0.frame, selected: $0.selectedID)
        })
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
    /// `originCwd` was the home directory, which `ProjectRoots` rightly refuses as
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
        saveWindows()
        store.saveNow(persistedSessions(vouching: true))
    }

    /// A link ⌘-clicked in one of `session`'s terminals. A server on this Mac
    /// goes to the app layer as it is. A path is tried relative to that
    /// terminal's own folder first, then the session's, then where it was
    /// born, then the repository each is in. A path that resolves nowhere is
    /// dropped: there is nothing to open and nothing worth a dialog. Any
    /// other link is `TerminalLink.external`'s: a web or mail link opens in
    /// its app, another scheme asks first, a malformed one does nothing.
    /// libghostty opens none of them itself any more (GhosttyRuntime).
    private func openLink(_ link: String, from view: SurfaceView, in session: Session) {
        if let server = TerminalLink.localServer(link) {
            onOpenLocalServer?(server)
            return
        }
        if TerminalLink.isPath(link) {
            let bases = TerminalLink.bases([view.reportedPwd, session.cwd, session.originCwd])
            guard let target = TerminalLink.resolve(link, bases: bases) else { return }
            onOpenTerminalLink?(target)
            return
        }
        switch TerminalLink.external(link) {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .ask(let url):
            askToOpen(url, over: view.window)
        case .refuse:
            break
        }
    }

    /// A link to another app (`vscode:`, `tel:`) says which app, and waits
    /// for a yes: the program printing it chose the scheme, not you.
    private func askToOpen(_ url: URL, over window: NSWindow?) {
        guard let window, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let name = FileManager.default.displayName(atPath: app.path)
        let alert = NSAlert()
        alert.messageText = "Open \u{201c}\(name)\u{201d}?"
        alert.informativeText = "This link opens in \(name):\n\(url.absoluteString)"
        // Cancel is the default: a program's output chose this link, so
        // Return out of habit doesn't open it (as Ghostty.app does).
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
        }
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
            view.onOpenLink = { [weak self, weak session, weak view] link in
                guard let self, let session, let view else { return }
                self.openLink(link, from: view, in: session)
            }
        }
        session.onSurfaceCreated = { [weak self, weak session] view in
            guard let self, let session else { return }

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
                if let move = self.pendingMoves[session.id], move.typed, SessionMove.samePath(pwd, move.path) {
                    self.finishMove(session, to: move.path)
                }
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
                // A program that reports has said everything a bell could.
                guard !self.reports(session) else { return }
                self.raiseAttention(session, kind: .needsInput, title: session.name, body: "Bell",
                                    source: "bell")
            }
            view.onProgramStatus = { [weak self, weak session] report, replayed in
                guard let self, let session else { return }
                self.programStatus(session, report, replayed: replayed)
            }
            // Progress (OSC 9;4) is a spinner and nothing more: a command
            // the shell integration announced, or a program reporting its own.
            // Its end is not read as a turn that finished. That was a guess,
            // and what a program has to say about itself it says in a status
            // report (`programStatus`).
            view.onProgress = { [weak self, weak session] active, _ in
                guard let self, let session else { return }
                // From a session that reports its state it is something the
                // program ran (a build, an install), not the program.
                guard !self.reports(session) else { return }
                if active { self.markBusy(session) } else { self.clearBusy(session) }
            }
            // Your own keys, clicks and scrolls answer an attention raised
            // while you were away (`noteUserInput`). A script's `wortel send`
            // does not: `onScriptedInput` is left unset on purpose.
            view.onUserInput = { [weak self, weak session] in
                guard let self, let session else { return }
                self.lastTypedAt[session.id] = Date()
                self.noteUserInput(session)
            }
            view.onTextInput = { [weak self, weak session] in
                guard let self, let session else { return }
                self.lastKeysAt[session.id] = Date()
                // Somebody is using it: no restart under their hands.
                self.repaintInPlace.remove(session.id)
            }
            // A Return of yours: the sidebar's Recent. Saved, so
            // the order survives a relaunch; the save is debounced.
            view.onSubmit = { [weak self, weak session] in
                guard let self, let session else { return }
                session.lastSentAt = Date()
                self.scheduleSave()
            }
            view.onCommandFinished = { [weak self, weak session] exitCode, durationNs in
                guard let self, let session else { return }
                // While an agent is running here, this is not the shell coming
                // back to its prompt: nothing has, the agent still has the
                // terminal. It is the core closing a command it saw an agent's
                // OSC 133 zone marks open — Pi wraps every message it renders
                // in 133;A/B/C — and so it says nothing about whether the agent
                // is done. Whether it is working is the agent's to say
                // (`programStatus`), and clearing it here dropped Pi's spinner
                // in the middle of a turn. The shell returning for real is
                // seen as the marker vanishing (`refreshAgentActivity`), which
                // clears busy itself.
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
                // The shell is back: what a program here said it was doing
                // ended with it. What its `done` or `error` raised stays.
                self.forgetReport(session)
                // A command likely touched files — nudge the git panel to
                // re-read status/diff (it debounces and no-ops when hidden).
                self.onCommandFinished?(session)
                // A long command that finished while you were elsewhere wants
                // your eyes — and a non-zero exit is worth flagging red, not
                // just "done". Exit code -1 means the shell didn't report one.
                guard durationNs >= Self.attentionAfterNs else { return }
                // Long enough to be worth a fresh name too (an agent's turn
                // names it in `announceFinishedTurn`; this is for a plain
                // long command).
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
            view.onNotification = { [weak self, weak session] title, body, replayed in
                guard let self, let session else { return }
                // A notification the program wrote itself (OSC 9/777/99): an
                // older agent on a permission prompt or at the end of a turn,
                // or a script. How it opens tells a request from a "done".
                // From a program that reports its state it is never the news,
                // only the words for it (`reportedNotification`).
                if self.reports(session) { return self.reportedNotification(session, title: title, body: body) }
                let kind = AttentionKind.classify(notificationTitle: title, body: body)
                // One it sent while Wortel was closed is the dot and no
                // banner, as a report from then is. And a program that sends
                // them faster than one a second gets one banner a second:
                // the limit libghostty's core has for the whole app, kept
                // here per session, so one session's cannot cost another's.
                self.raiseAttention(session, kind: kind,
                                    title: title.isEmpty ? session.name : title,
                                    body: body, source: "notification",
                                    quietly: replayed || self.bannerIsTooSoon(session, kind: kind, within: 1))
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
            view.onOpenLink = { [weak self, weak session, weak view] link in
                guard let self, let session, let view else { return }
                self.openLink(link, from: view, in: session)
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
