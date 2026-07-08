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
        let surfaceView = session.ensureSurfaceView(runtime: runtime)

        // SwiftUI calls updateNSViewController on any observable change (pwd,
        // rename, bell…), not just session switches. If we're already showing
        // this surface, do nothing — re-running would steal first responder
        // back from the rename field.
        guard surfaceView !== currentView else { return }

        Signposts.interval("session-switch") {
            if let currentView {
                currentView.isHidden = true
                currentView.occlusionDidChange(visible: false)
            }

            if surfaceView.superview !== view {
                surfaceView.frame = view.bounds
                surfaceView.autoresizingMask = [.width, .height]
                view.addSubview(surfaceView)
            }

            surfaceView.isHidden = false
            // The shown surface is visible by definition — always render it.
            // (Gating on window.occlusionState left it paused on launch, so the
            // terminal looked frozen until a keypress woke it.)
            surfaceView.occlusionDidChange(visible: true)
            currentView = surfaceView

            focusTerminal(surfaceView)
        }
    }

    /// Make the terminal first responder so keystrokes land. During launch the
    /// view may not be in a window yet — retry on the next runloop turn.
    private func focusTerminal(_ surfaceView: SurfaceView) {
        if let window = view.window {
            window.makeFirstResponder(surfaceView)
        } else {
            DispatchQueue.main.async { [weak self, weak surfaceView] in
                guard let surfaceView, let window = self?.view.window else { return }
                window.makeFirstResponder(surfaceView)
            }
        }
    }
}
