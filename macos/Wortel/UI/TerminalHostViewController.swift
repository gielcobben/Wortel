import AppKit

/// Hosts every session's SurfaceView. Views are added once and stay in the
/// hierarchy until their session closes; switching is isHidden + occlusion +
/// first responder — never a rebuild, never removeFromSuperview. The hidden
/// views keep their last frame in their IOSurface layer, so switching back
/// shows content instantly with zero flash.
///
/// Except a hibernated one (`HibernationPolicy`), which has no frame left to
/// show: it wakes first, and the switch happens once its screen is back and
/// it takes keys again, or after `wakePatience` at the most. The click lands
/// a few milliseconds late instead of on an empty terminal.
final class TerminalHostViewController: NSViewController {
    private(set) weak var currentView: SurfaceView?
    /// The main window's, for a session switch laid out in one go
    /// (`MainSplitViewController.show`), which runs outside SwiftUI's update.
    static weak var main: TerminalHostViewController?
    /// Resizes are held while a terminal wakes (`holdForWake`).
    private var holdsForWake = false
    /// Waking, to be shown as soon as its screen has been written back.
    private weak var wakingView: SurfaceView?

    /// The longest a switch waits for a hibernated terminal's screen. A
    /// session with a short scrollback is back in 10 to 30 ms; this is for a
    /// long one, which a switch would otherwise show half written and not yet
    /// taking keys.
    private static let wakePatience: TimeInterval = 0.5

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
        guard surfaceView !== wakingView else { return }

        // Another session chosen while one was waking, the one on screen
        // included: the waking one stays out of sight, and goes back on the
        // clock.
        if let waking = wakingView {
            wakingView = nil
            HibernationPolicy.shared.hidden(waking)
        }

        guard surfaceView !== currentView else { return releaseWakeHold() }

        guard surfaceView.isHibernated else {
            HibernationPolicy.shared.shown(surfaceView)
            swap(to: surfaceView)
            return
        }
        wakingView = surfaceView
        holdForWake()
        var done = false
        let swapWhenReady = { [weak self, weak surfaceView] in
            guard !done, let self, let surfaceView, self.wakingView === surfaceView else { return }
            done = true
            self.wakingView = nil
            self.swap(to: surfaceView)
        }
        HibernationPolicy.shared.shown(surfaceView, onRestored: swapWhenReady)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakePatience) { [weak self] in
            swapWhenReady()
            // Nothing is waking any more (its session closed meanwhile, say):
            // the hold must not outlive it.
            if let self, self.wakingView == nil { self.releaseWakeHold() }
        }
    }

    /// The new session's column and strip are laid out as soon as it's
    /// chosen, but a hibernated terminal takes 10 to 100 ms to come back, and
    /// until then the one being left is still on screen. Held, it keeps its
    /// size while the layout moves under it, instead of reflowing (and its
    /// program redrawing) for a layout that isn't its own. Released once the
    /// woken one is in front, which then takes its size.
    private func holdForWake() {
        guard !holdsForWake else { return }
        holdsForWake = true
        SurfaceView.holdResizes()
    }

    private func releaseWakeHold() {
        guard holdsForWake else { return }
        holdsForWake = false
        SurfaceView.releaseResizes()
    }

    private func swap(to surfaceView: SurfaceView) {
        // After the swap: the terminal being left is hidden by then, so only
        // the one arriving takes a size when the hold lets go.
        defer { releaseWakeHold() }
        guard surfaceView !== currentView else { return }
        Signposts.interval("session-switch") {
            if let currentView {
                currentView.isHidden = true
                currentView.occlusionDidChange(visible: false)
                HibernationPolicy.shared.hidden(currentView)
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

    /// Nothing in front: the selected session has no terminal yet (its
    /// worktree is still being made). The last one shown is hidden, not
    /// removed, and comes back instantly as usual.
    func showNothing() {
        defer { releaseWakeHold() }
        if let waking = wakingView {
            wakingView = nil
            HibernationPolicy.shared.hidden(waking)
        }
        guard let currentView else { return }
        currentView.isHidden = true
        currentView.occlusionDidChange(visible: false)
        HibernationPolicy.shared.hidden(currentView)
        if view.window?.firstResponder === currentView { view.window?.makeFirstResponder(nil) }
        self.currentView = nil
    }

    /// The window arriving is the other chance to focus, and the reliable one.
    ///
    /// `show` runs from SwiftUI's `updateNSViewController`, which during launch
    /// can happen before this controller's view is in a window at all. When it
    /// does, the retry below is the only thing standing between the user and a
    /// terminal that draws but does not take a keystroke.
    override func viewDidAppear() {
        super.viewDidAppear()
        if let currentView { focusTerminal(currentView) }
    }

    /// Make the terminal first responder so keystrokes land.
    ///
    /// During launch the view may not be in a window yet. This used to try
    /// exactly once more, on the next runloop turn, and then **give up in
    /// silence** — and a terminal nobody told about the keyboard is a window you
    /// can look at and not type into, with nothing on screen saying why. One
    /// extra turn is a guess about how long a window takes to exist; it is not a
    /// guarantee, and losing that race costs the whole session.
    ///
    /// So: keep asking for a few turns, and `viewDidAppear` catches the case
    /// where the window takes longer than that.
    private func focusTerminal(_ surfaceView: SurfaceView, attemptsLeft: Int = 10) {
        if let window = view.window {
            window.makeFirstResponder(surfaceView)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.async { [weak self, weak surfaceView] in
            guard let self, let surfaceView, surfaceView === self.currentView else { return }
            self.focusTerminal(surfaceView, attemptsLeft: attemptsLeft - 1)
        }
    }
}
