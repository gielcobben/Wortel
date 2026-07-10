import AppKit
import Observation

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
    /// A background session wants your eyes: it rang the bell, posted a desktop
    /// notification, or finished a long-running command while unselected.
    /// Cleared when the session is selected. Drives the sidebar attention dot.
    var needsAttention: Bool = false
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
