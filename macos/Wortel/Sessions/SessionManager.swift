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
            guard selectedID != oldValue, let session = selected else { return }
            // Switching into a waiting session: flash a ring in the detail view
            // to orient the eye before the dot clears.
            if let kind = session.attention {
                attentionFlash = AttentionFlash(kind: kind)
            }
            clearAttention(session)
            // Left the previous session before it could count as read; start the
            // caught-up clock on the one you just landed on.
            cancelCaughtUp(oldValue)
            scheduleCaughtUp(session)
            session.ensureSurfaceView(runtime: runtime)
            scheduleSave()
        }
    }

    /// The most recent "switched into a waiting session" event; the detail view
    /// flashes an orienting ring on each fresh value. Never cleared — at rest
    /// the overlay is simply invisible.
    private(set) var attentionFlash: AttentionFlash?

    /// The session whose name is being edited inline (nil = none). Observed by
    /// the sidebar so double-click, the context menu, and ⌘R all drive one path.
    var editingID: Session.ID?

    /// The session row the pointer is over (nil = none). Transient view state
    /// like `editingID` — never persisted. The sidebar's close button appears on
    /// this row, and the row's status indicator steps aside to make room for it.
    var hoveredID: Session.ID?

    /// Called when the last session closes (the window should close).
    @ObservationIgnored var onAllClosed: (() -> Void)?

    /// Presents a modal confirmation for closing a session that still has a
    /// running process, calling back with `true` to proceed. Set by the app
    /// layer (it owns the window to sheet onto). When nil, closes without
    /// asking.
    @ObservationIgnored var confirmClose: ((Session, @escaping (Bool) -> Void) -> Void)?

    /// A background session raised attention (a program asked for you — e.g.
    /// Claude Code emits OSC 777 on a permission/idle prompt, or a bell). The
    /// app layer turns this into a native macOS notification. `title`/`body`
    /// come from the program when it's a notification, or are synthesized.
    @ObservationIgnored var onNeedsAttention: ((Session, _ kind: AttentionKind, _ title: String, _ body: String, _ alert: Bool) -> Void)?

    /// A session's attention was answered (selected / app came front / closed).
    /// The app layer uses this to retract the session's notification from
    /// Notification Center so stale "needs you" banners don't linger.
    @ObservationIgnored var onAttentionCleared: ((Session) -> Void)?

    /// A foreground command finished in a session — its work tree may have
    /// changed. The app layer uses this to refresh the source-control panel.
    @ObservationIgnored var onCommandFinished: ((Session) -> Void)?

    /// A markdown file was clicked in a session's terminal (already resolved to
    /// an absolute file URL). The app layer opens it in the right-hand preview.
    @ObservationIgnored var onOpenMarkdown: ((URL) -> Void)?

    /// Whether Wortel is the frontmost app. A session the user is *actively
    /// viewing* (app active + window visible + selected) never raises
    /// attention — they can see it. Set by the app layer on activate/resign.
    @ObservationIgnored var appIsActive = true

    /// Whether the main window is actually on screen (not miniaturized or
    /// fully occluded). An active app with a minimized window is *not*
    /// "actively viewing" anything. Set by the app layer on occlusion changes.
    @ObservationIgnored var windowIsVisible = true

    @ObservationIgnored private var sessionCounter = 0

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
    /// Pending "show busy" work items, keyed by session; cancelled if the
    /// command finishes before the delay elapses.
    @ObservationIgnored private var busyTimers: [Session.ID: DispatchWorkItem] = [:]
    /// Pending "agent stopped → raise attention" work items, keyed by session;
    /// cancelled if progress resumes first.
    @ObservationIgnored private var quiesceTimers: [Session.ID: DispatchWorkItem] = [:]
    /// When each session's busy spinner actually turned on; drives the
    /// minimum-duration gate above.
    @ObservationIgnored private var busyStartedAt: [Session.ID: Date] = [:]
    /// The last (start, cleared) busy interval per session. If busy re-arms
    /// shortly after clearing, it's a continuation of the same run of work —
    /// e.g. Pi's OSC 133 zone marks make the core synthesize a command-finished
    /// mid-turn, then its 1s progress keepalive re-marks busy — so the original
    /// start is restored to keep the duration gate honest.
    @ObservationIgnored private var lastBusyInterval: [Session.ID: (start: Date, cleared: Date)] = [:]
    /// Re-arming busy within this window of the last clear counts as a
    /// continuation (see `lastBusyInterval`).
    private static let busyContinuationWindow: TimeInterval = 3.0
    /// Sessions whose terminal title currently shows a "working" marker
    /// (see `titleChanged`).
    @ObservationIgnored private var titleShowsWorking: Set<Session.ID> = []
    /// How long a session must stay actively-viewed before its "unread" mark
    /// clears. Long enough that a quick click-through to triage doesn't count as
    /// catching up, short enough that actually landing on it clears promptly.
    private static let unreadDwellDelay: TimeInterval = 1.0
    /// Pending "you've now caught up → drop the unread mark" work items, keyed
    /// by session; cancelled the moment you navigate away.
    @ObservationIgnored private var unreadDwellTimers: [Session.ID: DispatchWorkItem] = [:]

    /// Auto-naming throttle: don't re-summarise a session more often than this.
    /// Naming happens on turn/command end, which is already sparse; this just
    /// stops a burst of quick turns from relabelling on every one.
    private static let autoNameMinInterval: TimeInterval = 45
    /// The distilled-screen text must have at least this many characters — below
    /// it there's too little on screen to name from.
    private static let autoNameMinChars = 80
    /// When each session was last auto-named (throttle clock).
    @ObservationIgnored private var autoNamedAt: [Session.ID: Date] = [:]
    /// Hash of the distilled screen text each session was last named from, so an
    /// unchanged screen doesn't spend a model call to produce the same name.
    @ObservationIgnored private var autoNameSignature: [Session.ID: Int] = [:]
    /// Sessions with an auto-name request in flight — one at a time each.
    @ObservationIgnored private var autoNaming: Set<Session.ID> = []

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

    /// Folders the user created explicitly (the "+ → New Folder" menu). Unlike
    /// folders that emerge from a "giel/…" name, these persist as sections even
    /// when empty, so you can make a folder first and drag sessions in after —
    /// Apple Mail style. Ordered; persisted to UserDefaults.
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

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        collapsedFolders = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedFoldersKey) ?? [])
        declaredFolders = UserDefaults.standard.stringArray(forKey: Self.declaredFoldersKey) ?? []
        folderOrder = UserDefaults.standard.stringArray(forKey: Self.folderOrderKey) ?? []
    }

    // MARK: - Sidebar folders (derived from session names)

    /// The sidebar's rows, grouped into folders. A `nil` folder is the top-level
    /// (headerless) group, always pinned to the root. Folder sections follow the
    /// user's `folderOrder`; any folder not yet tracked there falls back to
    /// first-appearance (populated) / declaration (empty) order so nothing is
    /// ever dropped. Sessions keep their array order within a group. Purely a
    /// view of `sessions` + folder state — nothing here is stored.
    var sidebarGroups: [SidebarGroup] {
        var byKey: [String: [Session]] = [:]
        for session in sessions {
            byKey[session.folderPath ?? "", default: []].append(session)
        }

        var groups: [SidebarGroup] = []
        if let top = byKey[""], !top.isEmpty {
            groups.append(SidebarGroup(folder: nil, sessions: top))
        }
        var emitted = Set<String>()
        func emit(_ folder: String) {
            guard !emitted.contains(folder),
                  byKey[folder] != nil || declaredFolders.contains(folder) else { return }
            emitted.insert(folder)
            groups.append(SidebarGroup(folder: folder, sessions: byKey[folder] ?? []))
        }
        for folder in folderOrder { emit(folder) }
        for session in sessions { if let f = session.folderPath { emit(f) } }
        for folder in declaredFolders { emit(folder) }
        return groups
    }

    func isFolderCollapsed(_ folder: String) -> Bool { collapsedFolders.contains(folder) }

    func setFolder(_ folder: String, collapsed: Bool) {
        if collapsed { collapsedFolders.insert(folder) } else { collapsedFolders.remove(folder) }
    }

    /// Every folder shown in the sidebar (populated or empty) in render order.
    /// Drives the "Move To" menu and name-collision checks.
    var folderNames: [String] { sidebarGroups.compactMap(\.folder) }

    /// Create a new, empty folder (the "+ → New Folder" menu). Name is made
    /// unique; the folder is left expanded and its name returned.
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
        for session in sessions where session.folderPath == folder {
            session.name = "\(trimmed)/\(session.leafName)"
        }
        if let i = declaredFolders.firstIndex(of: folder) {
            if declaredFolders.contains(trimmed) { declaredFolders.remove(at: i) }
            else { declaredFolders[i] = trimmed }
        }
        if collapsedFolders.remove(folder) != nil { collapsedFolders.insert(trimmed) }
        // Rename in place so the folder keeps its position instead of jumping to
        // the end when syncFolderOrder drops the old name and appends the new.
        if let i = folderOrder.firstIndex(of: folder) { folderOrder[i] = trimmed }
        normalizeOrder()
        scheduleSave()
    }

    /// Delete a folder: its sessions drop to the top level (nothing is closed),
    /// and the section disappears.
    func deleteFolder(_ folder: String) {
        for session in sessions where session.folderPath == folder {
            session.name = session.leafName
        }
        declaredFolders.removeAll { $0 == folder }
        collapsedFolders.remove(folder)
        normalizeOrder()
        scheduleSave()
    }

    /// Move a session into `folder` (nil = top level) at `position` within that
    /// group (clamped; pass .max to append). Serves both drag-and-drop and the
    /// "Move To" menu. Crossing folders re-prefixes the name — the name *is*
    /// the folder membership.
    func moveSession(id: Session.ID, toFolder folder: String?, at position: Int) {
        guard let fromIdx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[fromIdx]
        var target = position
        if session.folderPath == folder {
            // Drop indices are as rendered mid-drag, i.e. they still count the
            // row's own old position — compensate after it's removed.
            let group = sessions.filter { $0.folderPath == folder }
            if let current = group.firstIndex(where: { $0.id == id }), current < target {
                target -= 1
            }
        } else {
            session.name = folder.map { "\($0)/\(session.leafName)" } ?? session.leafName
        }
        sessions.remove(at: fromIdx)
        let members = sessions.indices.filter { sessions[$0].folderPath == folder }
        let clamped = max(0, min(target, members.count))
        let flatIdx = clamped < members.count
            ? members[clamped]
            : (members.last.map { $0 + 1 } ?? sessions.count)
        sessions.insert(session, at: flatIdx)
        normalizeOrder()
        // Show the result of the drop, even into a collapsed folder.
        if let folder { collapsedFolders.remove(folder) }
        scheduleSave()
    }

    /// Re-flatten `sessions` to match the rendered order (groups contiguous, in
    /// the folder order). Keeps flat-index consumers — the Session menu, ⌘-number
    /// select — agreeing with what the sidebar shows.
    private func normalizeOrder() {
        syncFolderOrder()
        sessions = sidebarGroups.flatMap(\.sessions)
    }

    /// Reconcile `folderOrder` with the folders that actually exist: drop any
    /// that vanished, append newly-appeared ones (by first appearance), and
    /// dedupe — preserving the user's arrangement for everything already tracked.
    private func syncFolderOrder() {
        var present: [String] = []
        var seen = Set<String>()
        for session in sessions {
            if let f = session.folderPath, seen.insert(f).inserted { present.append(f) }
        }
        for f in declaredFolders where seen.insert(f).inserted { present.append(f) }

        var order: [String] = []
        var added = Set<String>()
        for f in folderOrder where seen.contains(f) && added.insert(f).inserted { order.append(f) }
        for f in present where added.insert(f).inserted { order.append(f) }
        if order != folderOrder { folderOrder = order }
    }

    /// Reorder folder sections: move `folder` to `index` among the folder
    /// sections (an insertion index as rendered pre-move, the NSOutlineView
    /// drop convention — it may count the folder's own current position).
    func moveFolder(_ folder: String, toFolderIndex index: Int) {
        syncFolderOrder()
        guard let from = folderOrder.firstIndex(of: folder) else { return }
        var target = index
        if from < target { target -= 1 } // the drop index counted its old slot
        var order = folderOrder
        order.remove(at: from)
        order.insert(folder, at: max(0, min(target, order.count)))
        guard order != folderOrder else { return }
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
        let persisted = store.load()
        guard !persisted.isEmpty else {
            newSession()
            return
        }
        // Markers left by agents that were still running at quit — resume them.
        let resume = AgentResumeStore.consumeSnapshot()
        for entry in persisted {
            let session = Session(id: entry.id, name: entry.name, title: entry.title, cwd: entry.cwd)
            session.nameIsUserSet = entry.nameIsUserSet
            // nil means the file predates per-session visibility — inherit the
            // old app-wide flag just this once.
            session.gitPanelVisible = entry.gitPanelVisible ?? SessionStore.legacyGitPanelVisible
            // A surviving marker means the app died without cleaning up (a crash),
            // and is the most direct evidence. A clean quit leaves none — killing
            // the agent hands control back to the shell, whose last prompt clears
            // it on the way down — so fall back to what we recorded at termination.
            let agent = resume[entry.id] ?? entry.runningAgent.map {
                // No pid: the shell that ran it died with the last launch. Liveness
                // was already checked when this was recorded at quit.
                AgentMarker(agent: $0, model: entry.runningModel,
                            cwd: entry.cwd, argv: entry.runningArgv,
                            shellPID: nil, startedAt: nil)
            }
            session.pendingResumeInput = agent.flatMap {
                AgentResumeStore.resumeInput(for: $0,
                                             knownConversationID: entry.runningConversationID)
            }
            session.pendingResumeAgent = session.pendingResumeInput == nil ? nil : agent
            session.pendingResumeConversationID =
                session.pendingResumeInput == nil ? nil : entry.runningConversationID
            appendRestored(session)
        }
        syncFolderOrder() // seed/prune the persisted folder order for the restored set
        selectedID = (persisted.first(where: \.selected) ?? persisted[0]).id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.warmRemainingSurfaces()
        }
    }

    // MARK: - Live agent activity

    /// Watches the shared `agents/` directory the shell integration writes its
    /// markers into, so the sidebar can show which agent (and model) is running
    /// in each session while it runs. Markers appear at an agent's preexec and
    /// vanish at the next prompt, so a directory change is exactly the moment the
    /// badges need refreshing. Fail-safe: if the watch can't be set up the badges
    /// simply never appear.
    private var agentWatchSource: DispatchSourceFileSystemObject?

    private func startAgentActivityWatch() {
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
        for session in sessions {
            let marker = live[session.id]
            if session.runningAgent != marker?.agent { session.runningAgent = marker?.agent }
            if session.runningModel != marker?.model { session.runningModel = marker?.model }
            session.runningArgv = marker?.argv
            session.runningShellPID = marker?.shellPID
            session.runningStartedAt = marker?.startedAt
        }
        // Markers appearing/vanishing is exactly when the screen sampler has
        // work to start or stop doing.
        updateAgentScreenSampling()
    }

    // MARK: - Agent screen activity (fallback for agents that emit nothing)

    /// Per-session sampling state. Only holds entries for sessions currently
    /// being watched; the sampler drops a session's state the moment it stops
    /// qualifying, so becoming eligible again always starts from a fresh
    /// baseline and grace window.
    @ObservationIgnored private var agentScreenTrackers: [Session.ID: AgentActivityTracker] = [:]
    /// When a session last produced an explicit signal (OSC progress, title
    /// spinner). Those agents speak for themselves and are left alone.
    @ObservationIgnored private var explicitSignalAt: [Session.ID: Date] = [:]
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
    }

    /// Drop markers whose agent is provably gone, which stops the sampler and
    /// releases the assertion. Fail-open: `AgentLiveness` answers `unknown` when
    /// it can't read enough to be sure, and unknown must never delete a marker
    /// for an agent that is merely hard to see.
    private func sweepDeadAgentMarkers() {
        var removedAny = false
        for session in sessions where session.runningAgent != nil {
            guard let agent = session.runningAgent,
                  !AgentLiveness.isRunning(agent: agent, shellPID: session.runningShellPID)
            else { continue }
            AgentStatusLog.log.debug("dropping stale marker for \(agent, privacy: .public)")
            AgentResumeStore.remove(sessionID: session.id)
            removedAny = true
        }
        // Mirrors the markers back onto the sessions, which also stops the
        // sampler and releases the assertion when the last one goes.
        if removedAny { refreshAgentActivity() }
    }

    private func updateAgentScreenSampling() {
        let wanted = sessions.contains { $0.runningAgent != nil }
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
            agentActivityAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Watching a running agent so its turn-end is noticed promptly")
        } else if !wanted, agentScreenTimer != nil {
            agentScreenTimer?.invalidate()
            agentScreenTimer = nil
            agentScreenTrackers.removeAll()
            if let assertion = agentActivityAssertion {
                ProcessInfo.processInfo.endActivity(assertion)
                agentActivityAssertion = nil
            }
        }
    }

    /// One pass over the sessions worth watching. A session qualifies only
    /// while an agent is running in it, you are not looking at it, it has a
    /// live surface, and it hasn't recently spoken for itself — anything else
    /// drops its tracker, so the next qualifying moment re-baselines.
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

    private func sampleAgentScreensPass() {
        let now = Date()
        livenessTicks += 1
        if livenessTicks >= Int(60 / AgentActivity.sampleInterval) {
            livenessTicks = 0
            sweepDeadAgentMarkers()
        }
        for session in sessions {
            guard session.runningAgent != nil,
                  !isActivelyViewing(session),
                  let view = session.surfaceView,
                  explicitSignalAt[session.id].map({
                      now.timeIntervalSince($0) >= AgentActivity.explicitSignalTrust
                  }) ?? true
            else {
                agentScreenTrackers.removeValue(forKey: session.id)
                continue
            }
            guard let digest = view.activeScreenDigest() else { continue }

            var tracker = agentScreenTrackers[session.id] ?? AgentActivityTracker(now: now)
            let event = tracker.sample(digest: digest, now: now)
            agentScreenTrackers[session.id] = tracker

            switch event {
            case .startedWorking:
                AgentStatusLog.log.debug("screen: working (\(session.runningAgent ?? "?", privacy: .public))")
                markBusy(session)
            case .wentQuiet:
                // The one moment the content itself is worth reading: is the
                // agent blocked on you, or simply done?
                let blocked = view.activeScreenTail().map(AgentPrompt.looksBlocked) ?? false
                AgentStatusLog.log.debug(
                    "screen: quiet, blocked=\(blocked, privacy: .public) (\(session.runningAgent ?? "?", privacy: .public))")
                progressEnded(session, inferred: blocked ? .needsInput : .turnDone)
            case nil:
                break
            }
        }
    }

    // MARK: - Operations

    /// Create a session and select it; new sessions inherit the current
    /// working directory.
    @discardableResult
    func newSession(cwd: String? = nil, inFolder folder: String? = nil) -> Session {
        sessionCounter += 1
        let leaf = "Session \(sessionCounter)"
        // New sessions land next to what you're looking at: the explicit folder
        // (header context menu) or the selected session's folder, else top level.
        let dir = folder ?? selected?.folderPath
        let session = Session(name: dir.map { "\($0)/\(leaf)" } ?? leaf, cwd: cwd ?? selected?.cwd)
        session.title = Self.defaultTitle(forCwd: session.cwd)
        wire(session)
        sessions.append(session)
        normalizeOrder() // slot the append into its folder's contiguous block
        if let dir { collapsedFolders.remove(dir) } // never select into a hidden row
        selectedID = session.id
        scheduleSave()
        return session
    }

    private func appendRestored(_ session: Session) {
        // Keep the default-name counter ahead of any restored "Session N"
        // (parse the leaf: the folder prefix isn't part of the number).
        if let n = Self.sessionNumber(from: session.leafName) {
            sessionCounter = max(sessionCounter, n)
        }
        wire(session)
        sessions.append(session)
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasSelected = session.id == selectedID
        let hadAttention = session.needsAttention
        busyTimers.removeValue(forKey: session.id)?.cancel()
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        unreadDwellTimers.removeValue(forKey: session.id)?.cancel()
        busyStartedAt.removeValue(forKey: session.id)
        lastBusyInterval.removeValue(forKey: session.id)
        titleShowsWorking.remove(session.id)
        agentScreenTrackers.removeValue(forKey: session.id)
        explicitSignalAt.removeValue(forKey: session.id)
        autoNamedAt.removeValue(forKey: session.id)
        autoNameSignature.removeValue(forKey: session.id)
        autoNaming.remove(session.id)
        // The killed shell never reaches its prompt to clear its own agent
        // marker; drop it so a closed session isn't resumed on next launch.
        AgentResumeStore.remove(sessionID: session.id)
        let folder = session.folderPath
        session.close()
        sessions.remove(at: index)
        // Closing the last session in a folder removes that section — including
        // explicitly-created ("New Folder") ones, which otherwise linger empty.
        if let folder, !sessions.contains(where: { $0.folderPath == folder }) {
            declaredFolders.removeAll { $0 == folder }
            folderOrder.removeAll { $0 == folder }
            collapsedFolders.remove(folder)
        }
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

        if wasSelected {
            selectedID = sessions[min(index, sessions.count - 1)].id
        }
        scheduleSave()
    }

    /// Interactive close (menu / context menu / ⌘W): confirms first if the
    /// session still has a running process, otherwise closes immediately.
    func requestClose(_ session: Session) {
        guard session.needsConfirmClose, let confirmClose else {
            close(session)
            return
        }
        confirmClose(session) { [weak self] proceed in
            guard proceed else { return }
            // Re-check membership: the sheet is async, the session may have
            // gone away (e.g. the shell exited while it was open).
            guard let self, self.sessions.contains(where: { $0.id == session.id }) else { return }
            self.close(session)
        }
    }

    func requestCloseSelected() {
        guard let selected else { return }
        requestClose(selected)
    }

    func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.name else { return }
        session.name = trimmed
        // An explicit rename is the user's word — auto-naming must never touch
        // this session again.
        session.nameIsUserSet = true
        // A rename can re-folder the session ("hello" -> "giel/hello"): keep the
        // flat order matching the render order, and make sure the row it moved
        // to is actually visible.
        normalizeOrder()
        if let folder = session.folderPath { collapsedFolders.remove(folder) }
        scheduleSave()
    }

    /// Begin inline-renaming the selected session (⌘R / menu).
    func beginRenameSelected() {
        editingID = selectedID
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    /// Select a session by id (e.g. from tapping its attention notification).
    func select(id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Move the selection one row down the sidebar (⌘⌥↓), wrapping at the end.
    func selectNext() { selectStepping(by: 1) }

    /// Whether any session is currently waiting on the user (drives menu
    /// enablement for "Next Waiting Session").
    var hasAttention: Bool {
        sessions.contains { $0.attention != nil }
    }

    /// Jump to the next session (cyclically from the current selection) that's
    /// waiting on the user — "take me to whatever needs me." No-op when nothing
    /// is waiting. Selecting it clears its attention and flashes the ring.
    func selectNextAttention() {
        guard !sessions.isEmpty else { return }
        let start = selectedIndex ?? -1
        for offset in 1...sessions.count {
            let candidate = sessions[(start + offset) % sessions.count]
            if candidate.attention != nil {
                selectedID = candidate.id
                return
            }
        }
    }

    /// Move the selection one row up the sidebar (⌘⌥↑), wrapping at the start.
    func selectPrevious() { selectStepping(by: -1) }

    /// Walk `sessions` from the selection in `step` direction, cyclically, and
    /// select the first row that's actually on screen.
    ///
    /// Sessions inside a collapsed folder are skipped rather than expanded into.
    /// The other selection paths (drop, rename, ⌘-number) un-collapse instead —
    /// they name a specific session, so they owe you it wherever it's buried.
    /// This one only means "one row over", and expanding a folder in passing
    /// would rearrange the sidebar as a side effect of moving through it.
    private func selectStepping(by step: Int) {
        guard let i = selectedIndex, sessions.count > 1 else { return }
        let n = sessions.count
        for offset in 1..<n {
            let candidate = sessions[((i + step * offset) % n + n) % n]
            if isVisibleInSidebar(candidate) {
                selectedID = candidate.id
                return
            }
        }
    }

    /// Whether a session has a row in the sidebar right now — i.e. it isn't
    /// tucked inside a collapsed folder.
    private func isVisibleInSidebar(_ session: Session) -> Bool {
        guard let folder = session.folderPath else { return true }
        return !isFolderCollapsed(folder)
    }

    private var selectedIndex: Int? {
        sessions.firstIndex { $0.id == selectedID }
    }

    /// Create surfaces for restored sessions that don't have one yet, one per
    /// runloop turn, so every session is warm within a couple of seconds.
    func warmRemainingSurfaces(limit: Int = 20) {
        guard limit > 0, let cold = sessions.first(where: { $0.surfaceView == nil }) else { return }
        cold.ensureSurfaceView(runtime: runtime)
        DispatchQueue.main.async { [weak self] in
            self?.warmRemainingSurfaces(limit: limit - 1)
        }
    }

    // MARK: - Busy state (debounced)

    /// A command started: show busy after a short delay so instant commands
    /// don't flicker. Coalesces repeat progress reports for a running command.
    /// Also cancels a pending quiesce-attention: the program resumed working,
    /// so its earlier "stopped" was a blip, not a prompt for the user.
    private func markBusy(_ session: Session) {
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        guard busyTimers[session.id] == nil, !session.isBusy else { return }
        let id = session.id
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
        if session.isBusy { session.isBusy = false }
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
        if trimmed.hasPrefix("✋") || trimmed.contains("Action Required") {
            titleShowsWorking.remove(session.id)
            noteExplicitSignal(session)
            clearBusy(session)
            raiseAttention(session, kind: .needsInput, title: session.name, body: "Action required")
        } else if Self.hasWorkingMarker(trimmed) {
            titleShowsWorking.insert(session.id)
            // A title spinner is this session speaking for itself; the screen
            // sampler defers to it.
            noteExplicitSignal(session)
            markBusy(session)
        } else if wasWorking {
            titleShowsWorking.remove(session.id)
            progressEnded(session)
        }
    }

    /// A leading braille *spinner* frame means working — but U+2800 (BRAILLE
    /// PATTERN BLANK) is not a spinner frame, it's the blank one. TUIs use it
    /// as a fixed-width spacer, and a title padded with it read as permanently
    /// working: the spinner never stopped, so the session could never go quiet
    /// and its status dot never got a chance to show. So: skip leading blanks
    /// (spaces and U+2800 alike) and judge the first character that actually
    /// draws ink.
    private static func hasWorkingMarker(_ title: String) -> Bool {
        let inked = title.unicodeScalars.drop {
            $0 == "\u{2800}" || CharacterSet.whitespaces.contains($0)
        }
        guard let first = inked.first else { return false }
        return first == "✦" || first == "⏲" || (0x2801...0x28FF).contains(first.value)
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
    private func progressEnded(_ session: Session, inferred kind: AttentionKind = .turnDone) {
        let busyLongEnough = busyStartedAt[session.id].map {
            Date().timeIntervalSince($0) >= Self.minBusyForQuiesceAttention
        } ?? false
        clearBusy(session)
        guard busyLongEnough else { return }
        let id = session.id
        quiesceTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.quiesceTimers[id] = nil
            // The agent went quiet without an explicit prompt — inferred
            // turn-end. If it *did* prompt (a notification / action-required
            // title), that already raised a louder .needsInput which priority
            // keeps from being downgraded here.
            self.raiseAttention(
                session, kind: kind, title: session.name,
                body: kind == .needsInput ? "Waiting on you" : "Finished — your move")
            // A finished turn is the best moment to (re)name the session from
            // what's now on screen — even when it's the one you're watching.
            self.considerAutoName(session)
        }
        quiesceTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiesceSettleDelay, execute: work)
    }

    // MARK: - Attention

    /// The user can already see this session (Wortel is frontmost, the window
    /// is on screen, and the session is selected), so it never needs to shout
    /// for attention.
    private func isActivelyViewing(_ session: Session) -> Bool {
        appIsActive && windowIsVisible && session.id == selectedID
    }

    /// Attention answered: drop the sidebar dot, re-count the Dock badge, and
    /// let the app layer retract the session's notification.
    private func clearAttention(_ session: Session) {
        guard session.attention != nil else { return }
        session.attention = nil
        refreshDockBadge()
        onAttentionCleared?(session)
    }

    /// A session wants the user: raise the sidebar dot (which overrides the
    /// busy spinner), badge the Dock, and post a native notification — unless
    /// the user is already looking at it. A lower-priority signal never
    /// downgrades a louder one already showing (a "finished" ping can't mask a
    /// pending "needs input"). Safe to call repeatedly; the app layer keys
    /// notifications by session so they replace, not stack.
    private func raiseAttention(_ session: Session, kind: AttentionKind, title: String, body: String) {
        guard !isActivelyViewing(session) else { return }
        let current = session.attention
        if let current, current.priority > kind.priority { return }
        // Play a sound only when the state actually escalates — a fresh episode
        // or a jump to a louder kind. A program that re-emits the same kind
        // (some agents fire a notification per tool call) updates the banner
        // text silently instead of spamming dings.
        let alert = current.map { kind.priority > $0.priority } ?? true
        session.attention = kind // observed → sidebar dot
        // The quieter tier: mark it unread too, at the highest kind seen, so the
        // trail survives past the loud dot until you've actually engaged.
        if session.unread.map({ kind.priority > $0.priority }) ?? true {
            session.unread = kind
        }
        refreshDockBadge()
        onNeedsAttention?(session, kind, title, body, alert)
    }

    /// Start the "caught up" clock for a session: if it stays actively-viewed
    /// for the dwell window, drop its unread mark. A glance shorter than the
    /// dwell (or navigating away) leaves the mark in place. Safe to call
    /// repeatedly — it restarts the clock.
    private func scheduleCaughtUp(_ session: Session) {
        unreadDwellTimers.removeValue(forKey: session.id)?.cancel()
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

    /// Wortel became frontmost: the user is now looking at the selected
    /// session, so clear its attention and start its caught-up clock.
    func appDidBecomeActive() {
        appIsActive = true
        if let selected {
            clearAttention(selected)
            scheduleCaughtUp(selected)
        }
    }

    func appDidResignActive() {
        appIsActive = false
        cancelCaughtUp(selectedID)
    }

    /// The main window's on-screen visibility changed (occlusion state /
    /// miniaturization). Becoming visible while frontmost means the user can
    /// now see the selected session — clear its attention, same as activate.
    func windowVisibilityChanged(_ visible: Bool) {
        windowIsVisible = visible
        if visible, appIsActive, let selected {
            clearAttention(selected)
            scheduleCaughtUp(selected)
        } else {
            cancelCaughtUp(selectedID)
        }
    }

    /// Dock badge = number of background sessions waiting on the user.
    private func refreshDockBadge() {
        let count = sessions.reduce(into: 0) { $0 += $1.needsAttention ? 1 : 0 }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
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
        guard !session.nameIsUserSet, !autoNaming.contains(session.id) else { return }
        if let last = autoNamedAt[session.id],
           Date().timeIntervalSince(last) < Self.autoNameMinInterval { return }
        guard let raw = session.surfaceView?.readScreenText() else { return }
        let distilled = SessionNameGenerator.distill(raw)
        guard distilled.count >= Self.autoNameMinChars else { return }
        let signature = distilled.hashValue
        guard autoNameSignature[session.id] != signature else { return }

        autoNaming.insert(session.id)
        let id = session.id
        let cwd = session.cwd
        let current = session.leafName
        // SessionManager is @MainActor, so this Task is main-actor-isolated; the
        // model does its heavy work off-main internally and resumes us here.
        Task { [weak self, weak session] in
            let name = try? await SessionNameGenerator.generate(
                screenText: distilled, cwd: cwd, currentName: current)
            guard let self, let session else { return }
            self.autoNaming.remove(id)
            self.autoNamedAt[id] = Date()
            self.autoNameSignature[id] = signature
            guard self.sessions.contains(where: { $0.id == id }),
                  !session.nameIsUserSet, // may have been renamed while we waited
                  let name, !name.isEmpty, name != session.leafName else { return }
            self.applyAutoName(session, to: name)
        }
    }

    /// Set a session's auto-generated name, preserving any folder prefix (the
    /// name *is* the folder membership, so only the leaf changes). Does not set
    /// `nameIsUserSet` — an auto-name stays eligible for later refinement.
    private func applyAutoName(_ session: Session, to leaf: String) {
        session.name = session.folderPath.map { "\($0)/\(leaf)" } ?? leaf
        normalizeOrder()
        scheduleSave()
    }

    // MARK: - Persistence

    private func persistedSessions() -> [PersistedSession] {
        sessions.map { session in
            // What to record as "the agent to resume next launch", resolved as one
            // unit so a model or command can never outlive the agent it belongs to.
            //
            // A live agent only counts if the process table still vouches for it:
            // a marker outlives an agent killed without its shell reaching another
            // prompt, and resuming from that reopens a conversation the user had
            // already stopped. Failing that, a resume we restored but haven't
            // delivered yet still counts, so it survives another quit instead of
            // being silently dropped.
            var conversationID = session.pendingResumeConversationID
            let agent: AgentMarker? = {
                if let running = session.runningAgent,
                   AgentLiveness.isRunning(agent: running, shellPID: session.runningShellPID) {
                    // Ask the live agent which conversation it's actually writing to,
                    // while it's still there to ask — after it dies only a guess is left.
                    // Ask which transcript this agent created, while it's still
                    // running. Nil means it resumed an existing conversation
                    // (a resume appends rather than creating), so the id we already
                    // know for this session stands.
                    if running == "claude", let cwd = session.cwd,
                       let startedAt = session.runningStartedAt {
                        conversationID = AgentResumeStore.claudeConversationID(
                            cwd: cwd, startedAt: startedAt) ?? conversationID
                    }
                    return AgentMarker(agent: running, model: session.runningModel,
                                       cwd: session.cwd, argv: session.runningArgv,
                                       shellPID: nil, startedAt: nil)
                }
                return session.pendingResumeAgent
            }()
            return PersistedSession(
                id: session.id, name: session.name, title: session.title, cwd: session.cwd,
                selected: session.id == selectedID, nameIsUserSet: session.nameIsUserSet,
                gitPanelVisible: session.gitPanelVisible,
                runningAgent: agent?.agent, runningModel: agent?.model,
                runningArgv: agent?.argv,
                runningConversationID: agent == nil ? nil : conversationID)
        }
    }

    private func scheduleSave() {
        store.scheduleSave { [weak self] in self?.persistedSessions() ?? [] }
    }

    /// GitPanelModel flipped a session's `gitPanelVisible`. It owns that bit (it
    /// holds the session), but persistence is ours — wired up in AppDelegate.
    func sessionStateChanged() {
        scheduleSave()
    }

    func saveNow() {
        store.saveNow(persistedSessions())
    }

    // MARK: - Wiring

    private func wire(_ session: Session) {
        let id = session.id
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
                session.cwd = pwd // observed → sidebar row + navigation subtitle update
                self.scheduleSave()
            }
            view.onBell = { [weak self, weak session] in
                guard let self, let session else { return }
                self.raiseAttention(session, kind: .needsInput, title: session.name, body: "Bell")
            }
            view.onProgress = { [weak self, weak session] active in
                guard let self, let session else { return }
                // An agent reporting its own progress is authoritative — note
                // it so the screen sampler stays out of this session's way.
                self.noteExplicitSignal(session)
                if active { self.markBusy(session) } else { self.progressEnded(session) }
            }
            view.onCommandFinished = { [weak self, weak session] exitCode, durationNs in
                guard let self, let session else { return }
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
                                        body: "Command failed (exit \(exitCode))")
                } else {
                    self.raiseAttention(session, kind: .finished, title: session.name,
                                        body: "Command finished")
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
                                    body: body)
            }
            view.onCloseRequest = { [weak self] in
                guard let self, let session = self.sessions.first(where: { $0.id == id }) else { return }
                self.close(session)
            }
            // The runtime already resolved this to a local markdown file; just
            // hand it up to the app layer, which opens the preview.
            view.onOpenMarkdown = { [weak self] url in
                self?.onOpenMarkdown?(url)
            }
        }
    }

    static func defaultTitle(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    private static func sessionNumber(from name: String) -> Int? {
        let prefix = "Session "
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}

/// Trimmed-string convenience used by the folder create/rename helpers.
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
