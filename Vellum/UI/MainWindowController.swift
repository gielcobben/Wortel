import AppKit

/// M1: a single window hosting one terminal surface. The session sidebar
/// (M3) will slot a split view controller in here.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let runtime: GhosttyRuntime
    private var surfaceView: SurfaceView?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.center()
        window.setFrameAutosaveName("main")
        window.title = "Vellum"
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self

        let surfaceView = SurfaceView(runtime: runtime)
        self.surfaceView = surfaceView

        surfaceView.onTitleChange = { [weak window] title in
            window?.title = title
        }
        surfaceView.onCloseRequest = { [weak self] in
            self?.surfaceView?.close()
            self?.close()
        }

        window.contentView = surfaceView
        window.makeFirstResponder(surfaceView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let surfaceView else { return }
        window?.makeFirstResponder(surfaceView)
        surfaceView.focusDidChange(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        surfaceView?.focusDidChange(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        surfaceView?.occlusionDidChange(visible: window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        surfaceView?.close()
    }
}
