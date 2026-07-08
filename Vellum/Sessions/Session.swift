import AppKit

/// One sidebar entry = one shell = one ghostty surface.
///
/// The SurfaceView is created lazily (`ensureSurfaceView`) so restored
/// sessions don't slow down launch, and once created it stays alive until
/// the session closes — switching sessions never rebuilds views.
final class Session {
    let id: UUID
    var title: String
    var cwd: String?
    var hasBell: Bool = false
    private(set) var surfaceView: SurfaceView?

    /// Called whenever a surface view is created for this session (eager or
    /// lazy). The SessionManager wires the view's callbacks here.
    var onSurfaceCreated: ((SurfaceView) -> Void)?

    init(id: UUID = UUID(), title: String = "shell", cwd: String? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
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
