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
    /// How long a session must stay actively-viewed before its "unread" mark
    /// clears. Long enough that a quick click-through to triage doesn't count as
    /// catching up, short enough that actually landing on it clears promptly.
    private static let unreadDwellDelay: TimeInterval = 1.0
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

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        collapsedFolders = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedFoldersKey) ?? [])
        declaredFolders = UserDefaults.standard.stringArray(forKey: Self.declaredFoldersKey) ?? []
        folderOrder = UserDefaults.standard.stringArray(forKey: Self.folderOrderKey) ?? []
        folderRoots = UserDefaults.standard.dictionary(forKey: Self.folderRootsKey)
            as? [String: String] ?? [:]
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

    // MARK: - Folder directories

    /// The directory `folder` stands for, or nil for a folder that is still
    /// just a label. nil folder (the top level) never has one: the top level
    /// isn't a project, it's everything that isn't in one.
    func root(ofFolder folder: String?) -> String? {
        folder.flatMap { folderRoots[$0] }
    }

    /// Point a folder at a directory, or clear it with nil. Normalized on the
    /// way in so two spellings of one path can't become two different folders.
    func setRoot(_ path: String?, ofFolder folder: String) {
        folderRoots[folder] = path.flatMap(FolderRoot.normalize)
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
            let cwds = sessions
                .filter { $0.folderPath == folder }
                .compactMap { $0.originCwd }
            guard let root = FolderRoot.derived(
                from: cwds, excludingUnder: worktrees, home: home) else { continue }
            folderRoots[folder] = root
        }
    }

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

    /// Delete a folder: its sessions drop to the top level (nothing is closed),
    /// and the section disappears.
    func deleteFolder(_ folder: String) {
        for session in sessions where session.folderPath == folder {
            session.name = session.leafName
        }
        declaredFolders.removeAll { $0 == folder }
        collapsedFolders.remove(folder)
        folderRoots.removeValue(forKey: folder)
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
        adoptFolderRoots() // give folders that predate directories one, from where they already are
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
            let wasRunning = session.runningAgent
            if session.runningAgent != marker?.agent { session.runningAgent = marker?.agent }
            if session.runningModel != marker?.model { session.runningModel = marker?.model }
            session.runningArgv = marker?.argv
            session.runningShellPID = marker?.shellPID
            session.runningStartedAt = marker?.startedAt
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
        let wasUnproven = explicitSignalAt[session.id] == nil
        explicitSignalAt[session.id] = Date()
        // The tier's claim on this session's busy state lapses here, and it has
        // to lapse *now* rather than at the next `markBusy`: that one returns
        // early when the session is already busy, which is exactly the case —
        // the screen tier guessed busy a moment ago and the agent is only now
        // announcing the same turn. Left in the set, the session would be
        // released on the next tick (it speaks for itself, so the sampler drops
        // it) and the release would clear a busy the program owns, mid-turn,
        // right after it said so. It would also take `busyStartedAt` with it, so
        // the 9;4;0 at the end of the turn would read as too short to be worth a
        // notification and the finished turn would go unannounced.
        screenInferredBusy.remove(session.id)
        // An agent that just proved it announces itself may have been the only
        // reason the sampler was running. Ask again rather than waiting for the
        // next marker change, which for a long-lived agent is when it exits.
        if wasUnproven { updateAgentScreenSampling() }
    }

    /// Whether the agent currently running in `session` has already proved it
    /// announces its own turns (an OSC 9;4 progress report or a title spinner).
    ///
    /// Once proved, the screen tier stays out of that session **for as long as
    /// that agent runs** — not for a minute afterwards. The timeout this
    /// replaces is what put an idle Claude Code session back under the guessing
    /// tier: Claude emits one `9;4;3` per turn and no keepalive, so a session
    /// sitting at its prompt looked, after sixty seconds, exactly like an agent
    /// that had never said anything — and then the first stray repaint announced
    /// a turn nobody had taken. An agent that announced the last turn will
    /// announce the next one; if it stops announcing, `COMMAND_FINISHED` at the
    /// next shell prompt is still the backstop.
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

    /// Whether any session actually needs its screen read: the same question
    /// the sampler asks per session.
    ///
    /// The distinction matters more than it looks: an agent that announces its
    /// own turns never needs this tier, so with only such agents running (Claude
    /// Code, Codex, crush — the common case) the timer never starts, no screen is
    /// ever read, and, most importantly, the App Nap assertion below is never
    /// taken. Keyed off the marker alone, an idle agent left open overnight kept
    /// this app awake until morning to watch a screen it had already been told
    /// about.
    private var wantsScreenSampling: Bool {
        sessions.contains { $0.runningAgent != nil && !speaksForItself($0) }
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
            agentActivityAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Watching a running agent so its turn-end is noticed promptly")
        } else if !wanted, agentScreenTimer != nil {
            agentScreenTimer?.invalidate()
            agentScreenTimer = nil
            releaseAllAgentScreenTrackers()
            if let assertion = agentActivityAssertion {
                ProcessInfo.processInfo.endActivity(assertion)
                agentActivityAssertion = nil
            }
        }
    }

    /// One pass over the sessions worth watching. A session qualifies only
    /// while an agent is running in it, it has a live surface, and it hasn't
    /// recently spoken for itself — anything else drops its tracker, so the
    /// next qualifying moment re-baselines.
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

    private func sampleAgentScreensPass() {
        let now = Date()
        livenessTicks += 1
        if livenessTicks >= Int(60 / AgentActivity.sampleInterval) {
            livenessTicks = 0
            sweepDeadAgentMarkers()
        }
        for session in sessions {
            guard session.runningAgent != nil,
                  let view = session.surfaceView,
                  !speaksForItself(session)
            else {
                releaseAgentScreenTracker(session)
                continue
            }
            guard let digest = view.activeScreenDigest() else { continue }

            var tracker = agentScreenTrackers[session.id] ?? AgentActivityTracker(now: now)
            let event = tracker.sample(digest: digest, now: now)
            agentScreenTrackers[session.id] = tracker

            switch event {
            case .startedWorking:
                AgentStatusLog.log.debug("""
                    screen: working (\(session.runningAgent ?? "?", privacy: .public)) \
                    in \(session.name, privacy: .private)
                    """)
                screenInferredBusy.insert(session.id)
                markBusy(session)
            case .wentQuiet:
                // The one moment the content itself is worth reading: is the
                // agent blocked on you, or simply done?
                let blocked = view.activeScreenTail().map(AgentPrompt.looksBlocked) ?? false
                AgentStatusLog.log.debug("""
                    screen: quiet, blocked=\(blocked, privacy: .public) \
                    (\(session.runningAgent ?? "?", privacy: .public)) \
                    in \(session.name, privacy: .private)
                    """)
                progressEnded(session, inferred: blocked ? .needsInput : .turnDone, source: "screen")
            case nil:
                break
            }
        }
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
                    via origin: SessionOrigin = .menu) -> Session {
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
        return makeSession(cwd: directory, inFolder: dir, via: origin)
    }

    /// A session in the home directory, deliberately outside every folder.
    ///
    /// Home is not a project, so filing it under whichever folder you happened
    /// to be looking at would put a `~` row inside "Wortel". This is the escape
    /// hatch from inheritance: one keystroke back to the top, from anywhere,
    /// without a `cd` and without a folder to point at first.
    @discardableResult
    func newHomeSession(via origin: SessionOrigin = .home) -> Session {
        makeSession(cwd: NSHomeDirectory(), inFolder: nil, via: origin)
    }

    /// The shared tail of the two above, taking a directory and a folder that
    /// have both already been decided. Split out so "which folder" can't quietly
    /// pick up `newSession`'s inherit-from-the-selection rule on the one path
    /// that exists to escape it.
    private func makeSession(
        cwd directory: String?, inFolder dir: String?, via origin: SessionOrigin
    ) -> Session {
        // Named for where it is, not for what number it is. "Session 3" tells you
        // nothing, and it's what a session is stuck with until an agent turn ends
        // and the model gets a look — on a machine without Apple Intelligence,
        // forever. The directory is known at creation and is nearly always the
        // answer you'd have typed. Auto-naming still overrides it later: a
        // directory name isn't user-set.
        let leaf = uniqueLeaf(Self.defaultTitle(forCwd: directory), in: dir)
        let session = Session(name: dir.map { "\($0)/\(leaf)" } ?? leaf, cwd: directory)
        session.title = Self.defaultTitle(forCwd: session.cwd)
        wire(session)
        sessions.append(session)
        normalizeOrder() // slot the append into its folder's contiguous block
        if let dir { collapsedFolders.remove(dir) } // never select into a hidden row
        selectedID = session.id
        scheduleSave()
        Telemetry.capture(.sessionCreated(via: origin))
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
    @discardableResult
    func openFolder(_ path: String, via origin: SessionOrigin = .openFolder) -> Session {
        let path = FolderRoot.normalize(path) ?? path
        if let existing = FolderRoot.folder(containing: path, in: folderRoots) {
            return newSession(cwd: path, inFolder: existing, via: origin)
        }
        // A directory's name is always a usable folder name — it cannot contain
        // the separator sidebar names are split on — with exactly one
        // exception: the filesystem root, whose last component *is* that
        // separator. Opening `/` isn't opening a project, so it gets a session
        // and no folder rather than a folder named "/" that `SessionName` would
        // then have to make sense of.
        let leaf = (path as NSString).lastPathComponent
        guard leaf != "/", !leaf.isEmpty else {
            return makeSession(cwd: path, inFolder: nil, via: origin)
        }
        // `addFolder` makes the name unique, so opening a second `web` from
        // another project gets "web 2" rather than joining the first one — two
        // directories are two projects however they're spelled.
        let folder = addFolder(named: leaf)
        setRoot(path, ofFolder: folder)
        return newSession(cwd: path, inFolder: folder, via: origin)
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
    /// `onFailure` receives git's own message. They're worth showing verbatim:
    /// "already checked out at …" and "not a valid object name" each tell you
    /// exactly what to do next, and a paraphrase would drop the path.
    func newSession(
        onBranch branch: String,
        base: String? = nil,
        inFolder folder: String? = nil,
        onFailure: @escaping (String) -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            if case .failure(let failure) = await self.openSession(
                onBranch: branch, base: base, inFolder: folder) {
                onFailure(failure.message)
            }
        }
    }

    /// The same thing as a value, for callers that need the session back or have
    /// somewhere other than an alert to put the failure — the CLI is both.
    ///
    /// `from` is the directory to take the repository from, defaulting to the
    /// selected session's. The CLI passes the caller's own working directory,
    /// which is the whole point of running the command *somewhere*: a script in
    /// one repo must not open a worktree of whichever repo the sidebar happens
    /// to be pointing at.
    /// Why a session couldn't be opened, in words meant to be shown as they are.
    /// Usually git's own message — "already checked out at …" and "not a valid
    /// object name" each tell you exactly what to do next, and a paraphrase
    /// would drop the path.
    struct Failure: Error {
        let message: String
    }

    /// `base` is the ref a *new* branch forks from, and is ignored for one that
    /// already exists — that branch has its own history, and there is nothing to
    /// fork.
    ///
    /// nil means the repository's default branch, not HEAD. A caller that didn't
    /// say means trunk far more often than it means "wherever this happens to be
    /// standing", and HEAD is exactly the answer that made a new branch inherit
    /// whichever worktree the request came from. Saying `HEAD` explicitly still
    /// works and is how you stack onto the current branch on purpose.
    @discardableResult
    func openSession(
        onBranch branch: String, base: String? = nil,
        inFolder folder: String? = nil, from cwd: String? = nil
    ) async -> Result<Session, Failure> {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return .failure(Failure(message: "No branch given.")) }
        guard let cwd = cwd ?? selected?.cwd else {
            return .failure(Failure(message: "No session to take a repository from."))
        }
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
        if let match = existing.first(where: { $0.branch == branch }) {
            path = match.path
        } else {
            path = GitWorktree.path(forBranch: branch, repoRoot: repoRoot)
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
            if onRemotes.count > 1,
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
            if known || onRemotes.count == 1 {
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
                return .failure(Failure(message: error))
            }
        }
        let session = newSession(cwd: path, inFolder: folder, via: .worktree)
        // Named for the branch rather than for the slug its directory got, but
        // only as a placeholder: a worktree session is about a *task*, and the
        // agent you start in it will say what that is. The branch doesn't get
        // lost when that happens; it moves to the row's second line
        // (`worktreeBranch`), which is where "which checkout is this" belongs
        // once the name is busy saying what the work is.
        session.worktreeBranch = branch
        // The branch's *leaf*, not the branch: a name is one folder plus one
        // leaf, so dropping in `worktree/brave-river-1a2f` whole filed the
        // session under a folder called "<project>/worktree" — a sibling group
        // holding exactly the sessions that belong in the project's own.
        let leaf = GitWorktree.sessionLeaf(forBranch: branch)
        session.name = session.folderPath.map { "\($0)/\(leaf)" } ?? leaf
        scheduleSave()
        return .success(session)
    }

    /// Local branches of the selected session's repository, most recently
    /// committed first — the order a picker wants, since the branch you mean is
    /// nearly always one you touched recently. Empty outside a repository.
    func localBranches() async -> [GitBranch] {
        guard let cwd = selected?.cwd,
              let root = await GitService.repoRoot(for: cwd) else { return [] }
        return await GitService.localBranches(root: root)
    }

    /// The remote-tracking branches, for the picker to fill in once it is up.
    ///
    /// Separate from `localBranches` because it is separately expensive: it is
    /// the one list whose size tracks the repository rather than the person
    /// using it, so it is asked for after the sheet is on screen and never on
    /// the way to putting it there.
    func remoteBranches() async -> [GitBranch] {
        guard let cwd = selected?.cwd,
              let root = await GitService.repoRoot(for: cwd) else { return [] }
        return await GitService.remoteBranches(root: root)
    }

    /// The repository's trunk, for the dialog's "From" default — the remote-
    /// tracking copy where there is one, so a new branch starts level with
    /// origin. nil outside a repository, or in one with no branch to name yet.
    func defaultBase() async -> String? {
        guard let cwd = selected?.cwd,
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
    func fetchFromOrigin() async {
        guard let cwd = selected?.cwd,
              let root = await GitService.repoRoot(for: cwd),
              await GitService.hasRemotes(root: root) else { return }
        _ = await GitService.fetch(root: root)
    }

    /// Which of those already have a worktree — the picker says so on the row,
    /// because choosing one goes to it rather than making a second.
    func branchesWithWorktrees() async -> Set<String> {
        guard let cwd = selected?.cwd,
              let root = await GitService.repoRoot(for: cwd) else { return [] }
        return Set(await GitService.worktrees(root: root)
            .filter { !$0.isPrimary }
            .compactMap(\.branch))
    }

    /// The worktree a session is sitting in, when it's one Wortel created — the
    /// gate on offering to remove it. A session in the repository's own checkout,
    /// or in a worktree someone made by hand, is not ours to tidy up.
    func worktree(of session: Session) async -> GitWorktree? {
        guard let cwd = session.cwd,
              cwd.hasPrefix(GitWorktree.root.path + "/"),
              let root = await GitService.repoRoot(for: cwd) else { return nil }
        // Compared resolved: git reports real paths, and a path that crosses a
        // symlink — /var against /private/var, or a home directory on another
        // volume — would otherwise never match, quietly making "Remove
        // Worktree" decide the session wasn't in one of ours.
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return await GitService.worktrees(root: root).first {
            !$0.isPrimary
                && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolved
        }
    }

    /// Remove a session's worktree. Never forced: git refuses while there are
    /// uncommitted changes, and that refusal is the feature — a worktree is
    /// where work lives, and the branch survives the directory either way.
    func removeWorktree(of session: Session, onFailure: @escaping (String) -> Void) {
        Task { [weak self] in
            guard let self, let worktree = await self.worktree(of: session),
                  let cwd = session.cwd,
                  let root = await GitService.repoRoot(for: cwd) else {
                onFailure("This session isn't in a worktree Wortel created.")
                return
            }
            if let error = await GitService.removeWorktree(root: root, at: worktree.path) {
                onFailure(error)
                return
            }
            self.close(session)
        }
    }

    private func appendRestored(_ session: Session) {
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
        screenInferredBusy.remove(session.id)
        explicitSignalAt.removeValue(forKey: session.id)
        autoNameState.removeValue(forKey: session.id)
        endPromptCapture(session)
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

        // The row *above*, not the one that slid into the closed row's slot.
        // ⌘N files the new session right after the selected one, so the round
        // trip — ⌘N, do the thing, ⌘W — should land back where it started,
        // not one row further down. Only the topmost row has nothing above
        // it, and there the row below is the only answer.
        if wasSelected {
            selectedID = sessions[max(index - 1, 0)].id
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
        // An explicit rename is the user's word — neither an agent's title nor
        // the model may touch this session again.
        session.nameSource = .user
        // A rename can re-folder the session ("hello" -> "giel/hello"): keep the
        // flat order matching the render order, and make sure the row it moved
        // to is actually visible.
        normalizeOrder()
        if let folder = session.folderPath { collapsedFolders.remove(folder) }
        scheduleSave()
        // Whether people name sessions themselves, which is the premise of the
        // sidebar. `trimmed` is the name they chose and stays here.
        Telemetry.capture(.sessionRenamed(automatic: false))
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
        screenInferredBusy.remove(session.id)
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
        // Before the state reading: the same title carries the agent's name for
        // the conversation, whether or not it is currently working.
        adoptAgentTitle(session, title: trimmed)
        if trimmed.hasPrefix("✋") || trimmed.contains("Action Required") {
            titleShowsWorking.remove(session.id)
            noteExplicitSignal(session)
            clearBusy(session)
            raiseAttention(session, kind: .needsInput, title: session.name, body: "Action required",
                           source: "title")
        } else if Self.hasWorkingMarker(trimmed) {
            titleShowsWorking.insert(session.id)
            // A title spinner is this session speaking for itself; the screen
            // sampler defers to it.
            noteExplicitSignal(session)
            markBusy(session)
        } else if wasWorking {
            titleShowsWorking.remove(session.id)
            progressEnded(session, source: "title")
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
    private func progressEnded(_ session: Session, inferred kind: AttentionKind = .turnDone,
                               source: String) {
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
                body: kind == .needsInput ? "Waiting on you" : "Finished, your move",
                source: "\(source)-quiesce")
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

    /// A session by id — what the CLI has, since a shell knows its session as
    /// `$WORTEL_SESSION_ID` and nothing else.
    func session(id: Session.ID) -> Session? {
        sessions.first { $0.id == id }
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
    /// pending "needs input"). Safe to call repeatedly; the app layer keys
    /// notifications by session so they replace, not stack.
    private func raiseAttention(_ session: Session, kind: AttentionKind, title: String, body: String,
                                source: String) {
        // Logged before the gates, and always: when a dot shows up on a session
        // the user hasn't touched in days, the only question worth answering is
        // which signal raised it — and that used to be unanswerable, because
        // every trace line named the signal without naming the session.
        AgentStatusLog.log.debug("""
            attention \(source, privacy: .public) kind=\(String(describing: kind), privacy: .public) \
            id=\(session.id.uuidString, privacy: .public) name=\(session.name, privacy: .private)
            """)
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
        // Past every gate, so this counts episodes a person was actually shown
        // rather than signals the detector saw. `title` and `body` are the
        // agent's own words about the user's own work and go no further than
        // this line: only the kind is reported.
        Telemetry.capture(.agentAttention(kind: AttentionCause(kind)))
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
        // Focus moving in or out makes every agent TUI redraw (they ask for
        // focus reports, and they answer them) — one frame of change on screens
        // that are otherwise standing still. Re-baseline before the next sample
        // so ⌘-tabbing can't manufacture a turn in a session you last touched
        // days ago.
        rebaselineAgentScreens()
        if let selected {
            clearAttention(selected)
            scheduleCaughtUp(selected)
        }
    }

    func appDidResignActive() {
        appIsActive = false
        rebaselineAgentScreens()
        cancelCaughtUp(selectedID)
    }

    /// The main window's on-screen visibility changed (occlusion state /
    /// miniaturization). Becoming visible while frontmost means the user can
    /// now see the selected session — clear its attention, same as activate.
    func windowVisibilityChanged(_ visible: Bool) {
        windowIsVisible = visible
        rebaselineAgentScreens() // uncovering the window repaints, same as focus
        if visible, appIsActive, let selected {
            clearAttention(selected)
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
        for session in sessions where session.isInOwnWorktree && session.worktreeBranch == nil {
            guard let cwd = session.cwd else { continue }
            Task { [weak session] in
                let result = await GitService.run(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd)
                let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.ok, !branch.isEmpty, branch != "HEAD", let session else { return }
                session.worktreeBranch = branch
            }
        }
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
                originCwd: session.originCwd,
                selected: session.id == selectedID, nameSource: session.nameSource.rawValue,
                worktreeBranch: session.worktreeBranch,
                gitPanelVisible: session.gitPanelVisible,
                inspectorPane: session.inspectorPane?.rawValue,
                runningAgent: agent?.agent, runningModel: agent?.model,
                runningArgv: agent?.argv,
                runningConversationID: agent == nil ? nil : conversationID)
        }
    }

    private func scheduleSave() {
        rememberProjectRoots()
        store.scheduleSave { [weak self] in self?.persistedSessions() ?? [] }
    }

    /// Where each live session's processes hang from, for `ProcessMonitor`.
    ///
    /// A session with no shell pid contributes nothing rather than a guess: that
    /// is either a session never opened, or the no-keeper fallback path where
    /// libghostty spawns the shell without telling us which pid it got.
    var processRoots: [SessionProcessRoot] {
        sessions.compactMap { session in
            guard let shellPID = session.shellPID else { return nil }
            return SessionProcessRoot(sessionID: session.id, shellPID: shellPID,
                                      agentName: session.runningAgent)
        }
    }

    /// Directories a stray process has to be sitting in to be counted as ours.
    ///
    /// Kept live *and* persisted, because the orphan worth finding is precisely
    /// the one whose session closed days ago — by then the live list says
    /// nothing about it. See `ProjectRoots`.
    @ObservationIgnored private(set) var projectRoots: [String] = ProjectRoots.load()

    /// Fold the current sessions' birth directories into the remembered list.
    /// `originCwd` rather than `cwd`: where the session was opened is the
    /// project, where its shell has since wandered is not.
    private func rememberProjectRoots() {
        let live = sessions.compactMap { $0.originCwd ?? $0.cwd }
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
                self.raiseAttention(session, kind: .needsInput, title: session.name, body: "Bell",
                                    source: "bell")
            }
            view.onProgress = { [weak self, weak session] active in
                guard let self, let session else { return }
                // An agent reporting its own progress is authoritative — note
                // it so the screen sampler stays out of this session's way.
                self.noteExplicitSignal(session)
                if active { self.markBusy(session) } else { self.progressEnded(session, source: "osc") }
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
                if session.runningAgent != nil {
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

}

/// Trimmed-string convenience used by the folder create/rename helpers.
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
