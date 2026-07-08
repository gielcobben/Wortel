import AppKit

/// One sidebar entry = one shell = one ghostty surface.
///
/// The SurfaceView is created lazily (`ensureSurfaceView`) so restored
/// sessions don't slow down launch, and once created it stays alive until
/// the session closes — switching sessions never rebuilds views.
final class Session {
    let id: UUID
    /// User-facing name shown as the sidebar row's primary line and the
    /// window title. Defaults to "Session N"; renamable later.
    var name: String
    /// Full title reported by the shell (user@host:cwd, or the running
    /// program). Kept for reference; not currently shown.
    var title: String
    var cwd: String?
    var hasBell: Bool = false
    private(set) var surfaceView: SurfaceView?

    /// Called whenever a surface view is created for this session (eager or
    /// lazy). The SessionManager wires the view's callbacks here.
    var onSurfaceCreated: ((SurfaceView) -> Void)?

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
