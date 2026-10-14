import AppKit
import Observation

/// A one-shot "you just switched into a session that was waiting on you" event.
/// The detail view watches `id` to flash a brief orienting ring in `kind`'s
/// colour, so the eye lands on why the session pinged. A fresh `id` each time
/// re-triggers the animation even for the same kind.
struct AttentionFlash: Identifiable {
    let id = UUID()
    let kind: AttentionKind
}

/// One sidebar entry = one shell = one ghostty surface.
///
/// The SurfaceView is created lazily (`ensureSurfaceView`) so restored
/// sessions don't slow down launch, and once created it stays alive until
/// the session closes — switching sessions never rebuilds views.
@Observable
@MainActor
final class Session: Identifiable {
    let id: UUID
    /// User-facing name shown as the sidebar row's primary line and the
    /// window title. Defaults to "Session N"; renamable later.
    var name: String
    /// Where `name` came from, which decides who may replace it. Persisted.
    ///
    /// The order is the precedence: the user's word is final; an agent's own
    /// title for its conversation beats anything guessed; a title made from the
    /// first prompt the user typed into the agent beats a guess from the
    /// screen; the on-device model's screen summary only fills in where nothing
    /// better has spoken; and a placeholder (the directory, a branch) is what
    /// anything may replace. See `docs/session-naming.md`.
    enum NameSource: String, Codable, Comparable {
        case placeholder, model, prompt, agent, user

        private var rank: Int {
            switch self {
            case .placeholder: return 0
            case .model: return 1
            case .prompt: return 2
            case .agent: return 3
            case .user: return 4
            }
        }
        static func < (lhs: NameSource, rhs: NameSource) -> Bool { lhs.rank < rhs.rank }
    }
    var nameSource: NameSource = .placeholder
    /// The branch this session's worktree was opened on, when Wortel opened it.
    /// Shown under the name: a worktree session is named for its task and this
    /// is where the task lives. Persisted; nil for a session that isn't in a
    /// worktree.
    var worktreeBranch: String?
    /// The linked worktree the shell is in, Wortel's or anyone's
    /// (`GitWorktree.linked`). Re-read on every `cd`, never persisted: it is
    /// what's on disk, not something the session decided.
    var linkedCheckout: GitWorktree.Linked?
    /// The colour you gave this session, drawn as a bar at the row's leading
    /// edge. Persisted, and only ever changed by hand: opening the session
    /// leaves it, which is the point of a "come back to this".
    var colour: SessionColour?
    /// The worktree this session is waiting for, while git makes it. The row
    /// and the page are there from the moment Fork is pressed; the shell
    /// starts once its folder exists. In a large repository the checkout is
    /// most of a minute, and it used to happen with nothing on screen and end
    /// in an alert. Never persisted: a session still waiting at quit was
    /// never opened.
    var preparation: WorktreePreparation?
    /// Whether the source-control panel is open while this session is selected.
    /// Per-session, and persisted: whether the panel earns its width depends on
    /// what the session is for — a manager in your home directory never needs
    /// it, the one in a repo always does. New sessions start hidden. Read and
    /// written by GitPanelModel, which mirrors it onto the inspector.
    var gitPanelVisible: Bool = false
    /// Which pane the inspector shows while this session is selected, or nil for
    /// a session that has never expressed a preference — those follow
    /// `GitPanelModel.defaultPane` (the last pane chosen anywhere), so a new
    /// session inherits your habit instead of snapping back to Changes.
    /// Per-session for the same reason visibility is: the repo session wants
    /// Changes, the one you're exploring wants Files. Persisted; read and
    /// written by GitPanelModel.
    var inspectorPane: InspectorPane?
    /// The side column's tabs, in strip order, and the one in front. Persisted.
    /// `gitPanelVisible` still says whether the column is up: hiding it keeps the
    /// tabs, and closing the last tab is what hides it. Read and written by
    /// GitPanelModel, which mirrors the focused session's onto the column.
    var sideTabs: [SideTab] = []
    var activeSideTab: SideTab?
    /// What each side terminal's shell last titled itself, for its tab's label.
    /// Observed, so the strip follows a `cd` or a program starting.
    var sideTerminalTitles: [UUID: String] = [:]
    /// Where each browser tab is: where it was opened, then wherever it last
    /// navigated to, so a relaunch or a reopen puts it back there. No entry
    /// is a new browser with nothing typed yet. Persisted.
    var browserAddresses: [UUID: String] = [:]
    /// The checkout the git panes show when it isn't the terminal's: another
    /// worktree of the same repository, where an agent in this session is
    /// actually working. nil follows the terminal. Persisted.
    var gitCheckout: String?
    /// How wide this session's side column is, the same for every tab in it;
    /// nil until its divider is first dragged, which leaves it at the last width
    /// chosen anywhere. Persisted. See `MainSplitViewController.ColumnWidth`.
    @ObservationIgnored var sideColumnWidth: Double?
    /// The main area's tabs, the session's own terminal (`.session`) among
    /// them, always exactly once; and the one in front: nil is the terminal.
    /// Persisted.
    var mainTabs: [SideTab] = [.session]
    var activeMainTab: SideTab?
    /// The side column on the terminal's leading side rather than its trailing
    /// one. Persisted.
    var sideColumnLeading = false
    /// The strip under the session's terminal: its tabs in order, the one in
    /// front, and whether it's showing. Hiding keeps them, closing the last
    /// one hides it. Persisted.
    var bottomTabs: [SideTab] = []
    var activeBottomTab: SideTab?
    var bottomVisible = false
    /// Tabs closed in this session, newest last, for ⌘⇧T. Persisted, so a
    /// relaunch (an update, a crash) doesn't quietly empty it.
    @ObservationIgnored var closedTabs: [ClosedTab] = []
    /// Where files and browsers open in this session: where you last moved
    /// one. See `WorkspaceTabs.home(for:)`. Persisted.
    @ObservationIgnored var tabHabits: [TabKind: TabRegion] = [:]
    /// Where each recently opened tab came from: `WorkspaceTabs.openers`. Not
    /// persisted.
    @ObservationIgnored var tabOpeners: [SideTab: SideTab] = [:]

    /// Every terminal tab id the session holds, wherever it sits.
    var terminalTabIDs: [UUID] { workspace.terminalIDs }

    /// The tab layout above as one value, for the rules in `WorkspaceTabs`.
    /// Written back field by field and only where something changed: each of
    /// these is observed, and an unchanged write still wakes its observers.
    var workspace: WorkspaceTabs {
        get {
            WorkspaceTabs(main: mainTabs, activeMain: activeMainTab,
                          side: sideTabs, activeSide: activeSideTab, sideVisible: gitPanelVisible,
                          bottom: bottomTabs, activeBottom: activeBottomTab,
                          bottomVisible: bottomVisible, closed: closedTabs, habits: tabHabits,
                          openers: tabOpeners)
        }
        set {
            if mainTabs != newValue.main { mainTabs = newValue.main }
            if activeMainTab != newValue.activeMain { activeMainTab = newValue.activeMain }
            if sideTabs != newValue.side { sideTabs = newValue.side }
            if activeSideTab != newValue.activeSide { activeSideTab = newValue.activeSide }
            if gitPanelVisible != newValue.sideVisible { gitPanelVisible = newValue.sideVisible }
            if bottomTabs != newValue.bottom { bottomTabs = newValue.bottom }
            if activeBottomTab != newValue.activeBottom { activeBottomTab = newValue.activeBottom }
            if bottomVisible != newValue.bottomVisible { bottomVisible = newValue.bottomVisible }
            closedTabs = newValue.closed
            tabHabits = newValue.habits
            tabOpeners = newValue.openers
        }
    }
    /// Full title reported by the shell (user@host:cwd, or the running
    /// program). Kept for reference; not currently shown.
    var title: String
    var cwd: String?

    /// Where this session was **born**, as opposed to where its shell has since
    /// wandered. Fixed at creation and never updated by the pwd reports that
    /// keep `cwd` live.
    ///
    /// This is the directory a new session next to this one inherits when its
    /// folder has no directory of its own (the folder's root wins otherwise: a
    /// worktree session's origin is its checkout, and ⌘N beside it means the
    /// project, not the branch). Not `cwd`: that follows every `cd`, so opening
    /// a session beside one you'd taken three levels deep started the new shell
    /// three levels deep too, and every session after it inherited the drift.
    /// The birth directory is the deliberate answer — it's the folder's root,
    /// or the worktree, or the path `wortel new --cwd` was handed — and it's
    /// stable for as long as the session lives. Persisted, so it survives a
    /// relaunch.
    /// Set again once, by a session whose worktree was still being made
    /// when it was created (`preparation`): it was born before its folder.
    var originCwd: String?
    /// A background session wants your eyes *now*, and *why*: it's blocked on
    /// you, something failed, or a long command finished while unselected. `nil`
    /// once you select it (you've seen the ping). Drives the loud sidebar dot
    /// (colour + pulse per kind), the Dock badge, and the notification.
    var attention: AttentionKind?
    /// The quieter second tier: this session had activity you haven't actually
    /// *engaged* with yet. Set whenever attention is raised, but — unlike
    /// `attention` — it survives a mere glance and only clears once you've
    /// dwelled on the session. Drives a small hollow "unread" dot so a quick
    /// click-through to triage doesn't lose track of what you skipped past.
    var unread: AttentionKind?
    /// Marked unread by hand (⇧⌘U): the ring shows even on the selected row,
    /// and nothing clears it until you've left the session and come back.
    var markedUnread = false
    /// Convenience for the count-based Dock badge and close bookkeeping.
    var needsAttention: Bool { attention != nil }
    /// A foreground command is currently running in this session. Debounced by
    /// the manager so instant commands never flicker, and cleared
    /// authoritatively on command-finished so it can never get stuck. Drives
    /// the sidebar busy spinner.
    var isBusy: Bool = false
    /// The agent CLI currently running in this session (its command basename,
    /// e.g. `claude`), or nil when none is. Mirrors the live shell-integration
    /// marker, kept in sync by `SessionManager`'s agents-directory watcher.
    /// Drives agent tracking, resume and naming; nothing draws it today.
    var runningAgent: String?
    /// The model the running agent was launched with (`--model`/`-m` value), when
    /// it carried one, so a resume carries it too. nil for the agent's default.
    var runningModel: String?
    /// The running agent's exact launch command, kept so a quit can record it for
    /// agents with no "continue last" flag. Not shown, so not observed.
    @ObservationIgnored var runningArgv: String?
    /// The pid of the shell the running agent was launched from, so a quit can
    /// confirm against the process table that it is genuinely still running
    /// before recording it for resume. See `AgentLiveness`.
    @ObservationIgnored var runningShellPID: pid_t?
    /// When the running agent launched, used to identify which transcript it
    /// created and so which conversation it is in.
    @ObservationIgnored var runningStartedAt: Date?
    /// Where the running agent was started, by its marker. Usually `cwd`, but
    /// not after `cd ~/proj && claude` in bash, which reports its directory
    /// only at a prompt: the agent's conversations are filed under its own
    /// folder, and a resume has to be typed there.
    @ObservationIgnored var runningCwd: String?

    /// The live terminal view. Not observed by SwiftUI (it's an NSView we host
    /// directly), so exclude it from observation tracking.
    @ObservationIgnored private(set) var surfaceView: SurfaceView?

    /// The agent this session owes a resume, from the moment it is known (a
    /// restore, a lost keeper) until the agent is seen running here again. See
    /// `OwedResume`. Transient: a quit persists it as the agent to resume.
    @ObservationIgnored var owedResume: OwedResume?

    /// The input for this session's first shell: the owed resume, if it hasn't
    /// been typed yet.
    var pendingResumeInput: String? {
        owedResume?.typedAt == nil ? owedResume?.input : nil
    }

    /// The last conversation this session was seen in, kept across the agent's
    /// exit. What a resume falls back on when nothing about the agent itself
    /// is left to read, instead of guessing by the newest file in the folder.
    /// See `PersistedSession.lastConversationID`.
    @ObservationIgnored var lastConversationID: String?
    /// The first of this session's ten TCP ports (`PortBlock`), exported to
    /// its shells as `WORTEL_PORT`. Chosen once and kept; nil only when every
    /// block was taken.
    @ObservationIgnored var portBase: Int?
    /// What every shell of this session gets added to its environment.
    var shellEnvironment: [String: String] { PortBlock.environment(base: portBase) }

    /// The conversation the running agent was last seen in, observed while it
    /// ran: at its start, at every turn, and at a quit. Best evidence first,
    /// which for Claude is its own process file (`~/.claude/sessions/<pid>.json`).
    /// After a `/clear` or `/resume` inside Claude that file is the only thing
    /// that knows: the command line still names the conversation Claude
    /// started in, and the file goes when Claude exits, which on a lost keeper
    /// is before Wortel can look. Cleared when the agent changes.
    @ObservationIgnored var liveConversationID: String?

    /// The agent that last left this session, for a moment after. See
    /// `AgentConversation.EndedAgent`.
    @ObservationIgnored var endedAgent: AgentConversation.EndedAgent?

    /// Called whenever a surface view is created for this session (eager or
    /// lazy). The SessionManager wires the view's callbacks here.
    @ObservationIgnored var onSurfaceCreated: ((SurfaceView) -> Void)?

    /// The live views of this session's side terminals, by tab id. Created the
    /// first time their tab is shown and kept, like `surfaceView`, until the tab
    /// closes: switching tabs or sessions hides them, never rebuilds them.
    @ObservationIgnored private(set) var sideSurfaces: [UUID: SurfaceView] = [:]
    /// Called when a side terminal's view is created, so the manager can wire its
    /// callbacks. The id is the tab's.
    @ObservationIgnored var onSideSurfaceCreated: ((UUID, SurfaceView) -> Void)?

    init(id: UUID = UUID(), name: String = "Session", title: String = "shell",
         cwd: String? = nil, originCwd: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.cwd = cwd
        // A new session starts where it starts: only `restore` has an origin to
        // pass that differs from the current directory.
        self.originCwd = originCwd ?? cwd
    }

    /// Sidebar grouping derived from the name: "giel/hello" lives in folder
    /// "giel" and displays as "hello". nil folder means a top-level session.
    /// Renaming is the only way to move a session between folders — the grouping
    /// is purely a view of the name. See `SessionName` for the split itself.
    var folderPath: String? { SessionName.folder(of: name) }

    /// The name with any folder prefix stripped — what the sidebar row shows.
    var leafName: String { SessionName.leaf(of: name) }

    /// Whether the sidebar row is two lines tall: a worktree session named for
    /// its task, with its branch under the name. Waiting on you doesn't add one:
    /// the dot says it, and what the session said is on the row's tooltip.
    var hasSecondLine: Bool { showsBranchLine || folderIsGone }

    /// The folder this session stands in has been deleted (a removed worktree,
    /// a demo repo, a branch's folder cleaned up by an agent). Said on the row
    /// rather than acted on: the shell is still there, and so is what it
    /// printed. Checked by the manager when Wortel comes forward
    /// (`SessionManager.checkFolders`), not stored.
    var folderIsGone = false

    /// Short, Finder-like label: the working directory's last path component
    /// (~ for home). Falls back to the shell title.
    var displayName: String {
        guard let cwd, !cwd.isEmpty else { return title }
        if cwd == NSHomeDirectory() { return "~" }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? "/" : base
    }

    /// Whether this session lives in a worktree Wortel made: its marker
    /// (`GitWorktree.Ownership`, read with the checkout on every `cd`), or
    /// Wortel's own folder, which is what made one before markers. Cheap, no
    /// git call: the authoritative check happens before anything is removed.
    var isInOwnWorktree: Bool {
        linkedCheckout?.isOwned == true || cwd?.hasPrefix(GitWorktree.root.path + "/") == true
    }

    /// What the row's second line says for a worktree session: the branch, or
    /// until that's known (or with no branch checked out), the checkout's own
    /// directory. Never the shell's: that follows `cd`, and a row reading
    /// "macos" or "src" under its name said where the prompt was, not which
    /// checkout. nil outside a worktree.
    var worktreeLabel: String? {
        guard isInWorktree else { return nil }
        if let worktreeBranch { return worktreeBranch }
        return (GitWorktree.checkout(containing: cwd) ?? linkedCheckout?.root)
            .map { ($0 as NSString).lastPathComponent } ?? displayName
    }

    /// In a linked worktree, whoever made it: what the row's glyph and branch
    /// line follow. Removing one is still `isInOwnWorktree`'s alone.
    var isInWorktree: Bool { isInOwnWorktree || linkedCheckout != nil }

    /// A worktree session shows its branch under the name, unless the name
    /// *is* the branch, which is what a fresh one is called until an agent or
    /// the model says what it's for. Drives the row's two-line layout.
    var showsBranchLine: Bool {
        guard let label = worktreeLabel else { return false }
        // Against the branch's leaf, because that is what the name is made of.
        // Comparing the whole branch would print `worktree/brave-river-1a2f`
        // under a row already reading `brave-river-1a2f`. A branch with no
        // namespace is its own leaf, so the old check is still in here.
        return GitWorktree.sessionLeaf(forBranch: label) != leafName
    }

    /// Tilde-abbreviated working directory. Empty only when the cwd is unknown
    /// (before the shell's first prompt reports it).
    var abbreviatedPath: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Whether closing this session would kill a still-running process, so the
    /// UI should confirm first. A session with no surface (never opened) has
    /// nothing to confirm.
    var needsConfirmClose: Bool {
        (surfaceView?.needsConfirmClose ?? false)
            || sideSurfaces.values.contains { $0.needsConfirmClose }
    }

    /// The pid of this session's shell, and so the root of every process the
    /// session is running. See `SurfaceView.shellPID`.
    ///
    /// nil for a session that was never opened, and on the no-keeper fallback
    /// path where libghostty spawns the shell without telling us its pid.
    var shellPID: pid_t? { surfaceView?.shellPID }

    /// The shells of the side terminals that have been opened this launch. Their
    /// work is the session's work: a dev server started beside an agent belongs
    /// in the same running list as one the agent started.
    /// Each side terminal's shell, by its tab id (the `WORTEL_SESSION_ID` it
    /// was started with).
    var sideShells: [(tab: UUID, pid: pid_t)] {
        sideSurfaces.compactMap { id, view in view.shellPID.map { (id, $0) } }
    }

    /// Whether `id` is this session or one of its terminals: what a command's
    /// `$WORTEL_SESSION_ID` can be.
    func owns(terminal id: UUID) -> Bool {
        id == self.id || terminalTabIDs.contains(id)
    }

    @discardableResult
    func ensureSurfaceView(runtime: GhosttyRuntime) -> SurfaceView {
        if let surfaceView { return surfaceView }
        let view = SurfaceView(runtime: runtime, workingDirectory: cwd,
                               sessionID: id, initialInput: pendingResumeInput,
                               environment: shellEnvironment)
        // Typed, not settled: still owed until the agent shows up running,
        // which it already is if its shell survived with it.
        if owedResume != nil, owedResume?.typedAt == nil, !view.initialInputDropped {
            owedResume?.typedAt = Date()
        }
        if let owed = owedResume, owed.typedAt != nil, owed.agent.agent == runningAgent {
            owedResume = nil
        }
        surfaceView = view
        onSurfaceCreated?(view)
        return view
    }

    /// The view for one of this session's side terminals, made on first use.
    ///
    /// Its id doubles as the keeper's session id, which is what brings the same
    /// shell back after a relaunch. It starts where the session's shell is now
    /// rather than where it was born: a terminal opened beside an agent is for
    /// the thing the agent is working on.
    @discardableResult
    func ensureSideSurface(_ id: UUID, runtime: GhosttyRuntime) -> SurfaceView {
        if let view = sideSurfaces[id] { return view }
        // The session's ports, not a block of its own: a terminal beside an
        // agent is for the thing the agent is working on.
        let view = SurfaceView(runtime: runtime, workingDirectory: cwd ?? originCwd, sessionID: id,
                               environment: shellEnvironment)
        sideSurfaces[id] = view
        onSideSurfaceCreated?(id, view)
        return view
    }

    /// End one side terminal's shell. A tab restored from the last launch but
    /// never shown in this one has no view, and its shell is still being kept
    /// alive for it, so that one is closed at the keeper directly.
    func closeSideSurface(_ id: UUID) {
        // Like a closed session's: an agent marker left for this tab would be
        // offered for resume, or swept only at some later launch.
        AgentResumeStore.remove(sessionID: id)
        if let view = sideSurfaces.removeValue(forKey: id) {
            view.close()
            view.removeFromSuperview()
        } else {
            GhosttyRuntime.keeper?.close(session: id)
            // What `SurfaceView.close` does for a terminal that has a view.
            TerminalModeRecorder.shared.forget(session: id)
        }
        sideTerminalTitles[id] = nil
    }

    func close() {
        for id in terminalTabIDs { closeSideSurface(id) }
        if let surfaceView {
            surfaceView.close()
            surfaceView.removeFromSuperview()
        } else {
            // Never shown since launch (past the warm-up's limit, or closed
            // before it got there): its shell is still in the keeper, kept
            // alive for a view that will now never come. Without this it ran
            // on, agent and all, invisible and unreachable until logout. The
            // same as `closeSideSurface` does for a tab without a view.
            GhosttyRuntime.keeper?.close(session: id)
            TerminalModeRecorder.shared.forget(session: id)
        }
        surfaceView = nil
    }
}

/// A sidebar group: the sessions sharing one folder prefix (or the top-level
/// group when `folder` is nil). Derived on the fly from session names by
/// `SessionManager.sidebarGroups` — nothing here is persisted.
struct SidebarGroup: Identifiable {
    let folder: String?
    let sessions: [Session]
    /// The Pinned section at the top: folder nil like the top level, but a
    /// section with a header of its own.
    var isPinned = false
    /// Stable across renders; "" is safe because a real folder is never empty,
    /// and the pinned section's can't be a folder name (it starts with NUL).
    var id: String { isPinned ? "\u{0}pinned" : folder ?? "" }
}
