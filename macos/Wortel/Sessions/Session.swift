import AppKit
import Observation

/// Why a background session is asking for the user's eyes. Ordered by urgency
/// (`priority`) so that when several signals could apply at once the most
/// important one wins the sidebar dot; each kind also decides whether its
/// native notification makes a sound. Colours are mapped in the UI layer so the
/// model stays AppKit-only.
enum AttentionKind {
    /// A program is *blocked on the user* — it made an explicit request: a
    /// permission / confirmation prompt, an "action required" title marker, a
    /// bell, or a program-authored desktop notification. Nothing proceeds until
    /// you answer, so this is the loudest state.
    case needsInput
    /// A command exited non-zero while the session was unselected.
    case failed
    /// An agent finished its turn and went quiet, with no explicit request —
    /// inferred from its own progress reporting stopping (which only long-lived
    /// programs emit; plain commands clear via a command-finished mark instead).
    /// It's your move, but nothing is blocked, so it arrives calmly and silent.
    case turnDone
    /// A plain long-running command finished cleanly while unselected. Purely
    /// informational.
    case finished

    /// Higher wins when two signals race (see `SessionManager.raiseAttention`),
    /// so an explicit request can never be masked by an inferred turn-end.
    var priority: Int {
        switch self {
        case .needsInput: return 4
        case .failed: return 3
        case .turnDone: return 2
        case .finished: return 1
        }
    }

    /// How loud this kind's native notification should be. Two audible tiers,
    /// deliberately tellable apart with the app in the background: a blocked
    /// prompt or a failure rings the standard alert, while an agent simply
    /// finishing its turn gets a quieter, shorter chime — you want to know it's
    /// your move without it sounding like something broke. A plain command
    /// finishing stays silent; that's what the sidebar dot is for.
    var chime: Chime {
        switch self {
        case .needsInput, .failed: return .alert
        case .turnDone: return .soft
        case .finished: return .none
        }
    }

    /// Sound tier for a kind's notification, mapped to a real sound in the app
    /// layer (the model stays free of UserNotifications).
    enum Chime {
        /// The system default notification sound.
        case alert
        /// A quiet, distinct chime for "your move, nothing is blocked".
        case soft
        /// Silent.
        case none
    }

    /// Whether the sidebar dot should breathe. Anything that wants your next
    /// action pulls the eye; a plain clean finish is calm and steady.
    var pulses: Bool {
        switch self {
        case .needsInput, .failed, .turnDone: return true
        case .finished: return false
        }
    }

    /// Classify a program-authored desktop notification (OSC 9 / 777 / 99). An
    /// explicit notification usually means the program wants you *now*, so the
    /// default is the blocking `.needsInput`; it's only softened to `.turnDone`
    /// when the text clearly reads as a completion with nothing left to approve.
    /// Keyword matching only has to break the tie for this one ambiguous source —
    /// every other signal is classified by where it comes from.
    static func classify(notificationTitle title: String, body: String) -> AttentionKind {
        let text = (title + " " + body).lowercased()
        let blocking = ["permission", "approve", "allow", "confirm", "authoriz",
                        "waiting", "input", "action required", "review",
                        "continue", "proceed", "respond", "y/n", "question"]
        if blocking.contains(where: text.contains) { return .needsInput }
        let completion = ["completed", "complete", "finished", "done", "success"]
        if completion.contains(where: text.contains) { return .turnDone }
        return .needsInput
    }
}

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
    /// The user explicitly named this session (an inline rename), so auto-naming
    /// must never overwrite it. Default "Session N" names and auto-generated
    /// ones leave this false and stay eligible for (re)naming as work shifts.
    /// Persisted. See SessionNameGenerator.
    var nameIsUserSet: Bool = false
    /// Whether the source-control panel is open while this session is selected.
    /// Per-session, and persisted: whether the panel earns its width depends on
    /// what the session is for — a manager in your home directory never needs
    /// it, the one in a repo always does. New sessions start hidden. Read and
    /// written by GitPanelModel, which mirrors it onto the inspector.
    var gitPanelVisible: Bool = false
    /// Full title reported by the shell (user@host:cwd, or the running
    /// program). Kept for reference; not currently shown.
    var title: String
    var cwd: String?
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
    /// Convenience for the count-based Dock badge and close bookkeeping.
    var needsAttention: Bool { attention != nil }
    /// A foreground command is currently running in this session. Debounced by
    /// the manager so instant commands never flicker, and cleared
    /// authoritatively on command-finished so it can never get stuck. Drives
    /// the sidebar busy spinner.
    var isBusy: Bool = false
    /// The agent CLI currently running in this session (its command basename,
    /// e.g. `claude`), or nil when none is. Mirrors the live shell-integration
    /// marker, kept in sync by `SessionManager`'s agents-directory watcher, and
    /// drives the sidebar's small "which agent" line. Observed so it updates live.
    var runningAgent: String?
    /// The model the running agent was launched with (`--model`/`-m` value), when
    /// it carried one — shown next to `runningAgent`. nil for the agent's default.
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

    /// The live terminal view. Not observed by SwiftUI (it's an NSView we host
    /// directly), so exclude it from observation tracking.
    @ObservationIgnored private(set) var surfaceView: SurfaceView?

    /// A command to auto-run when this session's shell first spawns — set during
    /// restore to resume an agent CLI (e.g. "claude --continue\n") that was
    /// running at quit. Consumed once by `ensureSurfaceView`. Transient (not
    /// persisted, not observed). See AgentResumeStore.
    @ObservationIgnored var pendingResumeInput: String?

    /// The agent behind a not-yet-delivered `pendingResumeInput`. Kept so that a
    /// quit *before* the session's shell is ever created — it may never be warmed
    /// (`warmRemainingSurfaces` stops at 20) or clicked — re-persists the agent
    /// instead of dropping it, which would strand that session cold forever.
    /// Cleared together with `pendingResumeInput` once the surface takes it.
    @ObservationIgnored var pendingResumeAgent: AgentMarker?

    /// The exact conversation id restored alongside `pendingResumeAgent`, carried
    /// for the same reason: a quit before the shell is ever created must re-persist
    /// it rather than fall back to guessing by modification time.
    @ObservationIgnored var pendingResumeConversationID: String?

    /// Called whenever a surface view is created for this session (eager or
    /// lazy). The SessionManager wires the view's callbacks here.
    @ObservationIgnored var onSurfaceCreated: ((SurfaceView) -> Void)?

    init(id: UUID = UUID(), name: String = "Session", title: String = "shell", cwd: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.cwd = cwd
    }

    /// Sidebar grouping derived from the name: "giel/hello" lives in folder
    /// "giel" and displays as "hello". nil folder means a top-level session.
    /// Renaming is the only way to move a session between folders — the grouping
    /// is purely a view of the name. See `SessionName` for the split itself.
    var folderPath: String? { SessionName.folder(of: name) }

    /// The name with any folder prefix stripped — what the sidebar row shows.
    var leafName: String { SessionName.leaf(of: name) }

    /// Short, Finder-like label: the working directory's last path component
    /// (~ for home). Falls back to the shell title.
    var displayName: String {
        guard let cwd, !cwd.isEmpty else { return title }
        if cwd == NSHomeDirectory() { return "~" }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? "/" : base
    }

    /// Tilde-abbreviated working directory, shown under the session name in
    /// the sidebar. Empty only when the cwd is unknown (before the shell's
    /// first prompt reports it).
    var abbreviatedPath: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Whether closing this session would kill a still-running process, so the
    /// UI should confirm first. A session with no surface (never opened) has
    /// nothing to confirm.
    var needsConfirmClose: Bool {
        surfaceView?.needsConfirmClose ?? false
    }

    @discardableResult
    func ensureSurfaceView(runtime: GhosttyRuntime) -> SurfaceView {
        if let surfaceView { return surfaceView }
        let view = SurfaceView(runtime: runtime, workingDirectory: cwd,
                               sessionID: id, initialInput: pendingResumeInput)
        pendingResumeInput = nil // consumed once
        pendingResumeAgent = nil // the resume has been dispatched; the live marker takes over
        pendingResumeConversationID = nil
        surfaceView = view
        onSurfaceCreated?(view)
        return view
    }

    func close() {
        surfaceView?.close()
        surfaceView?.removeFromSuperview()
        surfaceView = nil
    }
}

/// A sidebar group: the sessions sharing one folder prefix (or the top-level
/// group when `folder` is nil). Derived on the fly from session names by
/// `SessionManager.sidebarGroups` — nothing here is persisted.
struct SidebarGroup: Identifiable {
    let folder: String?
    let sessions: [Session]
    /// Stable across renders; "" is safe because a real folder is never empty.
    var id: String { folder ?? "" }
}
