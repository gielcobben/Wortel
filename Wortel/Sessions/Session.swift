import AppKit
import Observation

/// Why a background session is asking for the user's eyes. Ordered by urgency
/// (`priority`) so that when several signals could apply at once the most
/// important one wins the sidebar dot; each kind also decides whether its
/// native notification makes a sound. Colours are mapped in the UI layer so the
/// model stays AppKit-only.
enum AttentionKind {
    /// A program is blocked on the user: a permission / confirmation prompt, an
    /// "action required" marker, a bell, a program-authored desktop
    /// notification, or an agent that finished its turn and is now waiting. The
    /// user is the bottleneck — the loudest state.
    case needsInput
    /// A command exited non-zero while the session was unselected.
    case failed
    /// A long-running command finished cleanly while the session was
    /// unselected. Purely informational.
    case finished

    /// Higher wins when two signals race (see `SessionManager.raiseAttention`).
    var priority: Int {
        switch self {
        case .needsInput: return 3
        case .failed: return 2
        case .finished: return 1
        }
    }

    /// Informational "it's done" arrives silently; a blocked prompt or an
    /// outright failure is worth a sound.
    var playsSound: Bool {
        switch self {
        case .needsInput, .failed: return true
        case .finished: return false
        }
    }

    /// Whether the sidebar dot should breathe. Urgent states pull the eye; a
    /// clean finish is calm and steady.
    var pulses: Bool {
        switch self {
        case .needsInput, .failed: return true
        case .finished: return false
        }
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
    /// Full title reported by the shell (user@host:cwd, or the running
    /// program). Kept for reference; not currently shown.
    var title: String
    var cwd: String?
    /// A background session wants your eyes, and *why*: it's blocked on you,
    /// something failed, or a long command finished while unselected. `nil` when
    /// the session is caught up. Cleared when the session is selected. Drives
    /// the sidebar attention dot (colour + pulse per kind).
    var attention: AttentionKind?
    /// Convenience for the count-based Dock badge and close bookkeeping.
    var needsAttention: Bool { attention != nil }
    /// A foreground command is currently running in this session. Debounced by
    /// the manager so instant commands never flicker, and cleared
    /// authoritatively on command-finished so it can never get stuck. Drives
    /// the sidebar busy spinner.
    var isBusy: Bool = false
    /// The live terminal view. Not observed by SwiftUI (it's an NSView we host
    /// directly), so exclude it from observation tracking.
    @ObservationIgnored private(set) var surfaceView: SurfaceView?

    /// Called whenever a surface view is created for this session (eager or
    /// lazy). The SessionManager wires the view's callbacks here.
    @ObservationIgnored var onSurfaceCreated: ((SurfaceView) -> Void)?

    init(id: UUID = UUID(), name: String = "Session", title: String = "shell", cwd: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.cwd = cwd
    }

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
        let view = SurfaceView(runtime: runtime, workingDirectory: cwd)
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
