import AppKit

/// Hosts every session's SurfaceView. Views are added once and stay in the
/// hierarchy until their session closes; switching is isHidden + occlusion +
/// first responder — never a rebuild, never removeFromSuperview. The hidden
/// views keep their last frame in their IOSurface layer, so switching back
/// shows content instantly with zero flash.
final class TerminalHostViewController: NSViewController {
    private(set) weak var currentView: SurfaceView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    func show(_ session: Session, runtime: GhosttyRuntime) {
        Signposts.interval("session-switch") {
            let surfaceView = session.ensureSurfaceView(runtime: runtime)

            if let currentView, currentView !== surfaceView {
                currentView.isHidden = true
                currentView.occlusionDidChange(visible: false)
            }

            if surfaceView.superview !== view {
                surfaceView.frame = view.bounds
                surfaceView.autoresizingMask = [.width, .height]
                view.addSubview(surfaceView)
            }

            surfaceView.isHidden = false
            surfaceView.occlusionDidChange(visible: view.window?.occlusionState.contains(.visible) ?? true)
            currentView = surfaceView

            // Synchronously in the same runloop turn: keystrokes land immediately.
            view.window?.makeFirstResponder(surfaceView)
        }
    }
}
