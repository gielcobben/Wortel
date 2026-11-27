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
    /// Every main window's host, for a session switch laid out in one go
    /// (`MainSplitViewController.show`), which runs outside SwiftUI's update.
    private static let hosts = NSHashTable<TerminalHostViewController>.weakObjects()

    /// Register a host made for a main window's terminal area.
    static func register(_ host: TerminalHostViewController) { hosts.add(host) }

    /// The host in `window`'s terminal area.
    static func main(in window: NSWindow?) -> TerminalHostViewController? {
        guard let window else { return nil }
        return hosts.allObjects.first { $0.view.window === window }
    }

    /// The terminal on screen here, unless another window has taken it (a
    /// session moved there): an NSView has one parent, and a terminal that
    /// went is no longer this host's to hide.
    private var ownCurrentView: SurfaceView? {
        guard let currentView, currentView.superview === view else { return nil }
        return currentView
    }
    /// Whether `viewDidAppear` has run before: see there.
    private var hasAppeared = false
    /// Resizes are held while a terminal wakes (`holdForWake`).
    private var holdsForWake = false
    /// Waking, to be shown as soon as its screen has been written back.
    private weak var wakingView: SurfaceView?

    /// The longest a switch waits for a hibernated terminal's screen. A
    /// session with a short scrollback is back in 10 to 30 ms; this is for a
    /// long one, which a switch would otherwise show half written and not yet
    /// taking keys.
    private static let wakePatience: TimeInterval = 0.5

    /// The empty page a session opens on while its program starts
    /// (`StartCover`): the terminal's own colour over the terminal, which is
    /// underneath at its full size, taking keys and being drawn into. Taken
    /// off in one cut when the start is over.
    private let startCover = FilledView(color: Chrome.content)
    /// On the page once a start has been going `spinnerDelay`, so a slow one
    /// (Pi, 1 to 2 s) does not read as a hang. A fast one (Claude Code,
    /// Codex) is over before it would show, and its page stays empty.
    private let startSpinner = NSProgressIndicator()
    private var spinnerTimer: DispatchWorkItem?
    private static let spinnerDelay: TimeInterval = 0.75

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        startCover.isHidden = true
        startCover.autoresizingMask = [.width, .height]
        startSpinner.style = .spinning
        startSpinner.controlSize = .small
        startSpinner.isIndeterminate = true
        startSpinner.isDisplayedWhenStopped = false
        startSpinner.sizeToFit()
        startCover.addSubview(startSpinner)
    }

    /// The page over `surfaceView` while it starts, and off otherwise.
    private func coverStart(of surfaceView: SurfaceView?) {
        hideStartSpinner()
        guard let surfaceView, surfaceView.isStarting else {
            startCover.isHidden = true
            return
        }
        // A list, not one callback: a session moved to another window while
        // it starts is covered there too, and both pages come off.
        surfaceView.afterStart { [weak self] _ in
            guard let self else { return }
            self.coverStart(of: self.ownCurrentView)
        }
        startCover.frame = view.bounds
        centreStartSpinner()
        // In front of every terminal, the one just added included.
        view.addSubview(startCover, positioned: .above, relativeTo: nil)
        startCover.isHidden = false

        // Counted from the start, not from this showing: back to a session
        // that has been starting a while, it shows at once.
        let began = surfaceView.startBegan ?? ProcessInfo.processInfo.systemUptime
        let wait = max(0, began + Self.spinnerDelay - ProcessInfo.processInfo.systemUptime)
        let item = DispatchWorkItem { [weak self, weak surfaceView] in
            guard let self, let surfaceView, surfaceView.isStarting,
                  self.ownCurrentView === surfaceView, !self.startCover.isHidden else { return }
            self.startSpinner.startAnimation(nil)
        }
        spinnerTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    /// In the middle of the page, on whole points. Again on every layout:
    /// a session restored at launch is covered before its window has a size.
    private func centreStartSpinner() {
        let size = startSpinner.frame.size
        let bounds = startCover.bounds
        startSpinner.setFrameOrigin(NSPoint(x: ((bounds.width - size.width) / 2).rounded(),
                                            y: ((bounds.height - size.height) / 2).rounded()))
    }

    private func hideStartSpinner() {
        spinnerTimer?.cancel()
        spinnerTimer = nil
        startSpinner.stopAnimation(nil)
    }

    func show(_ session: Session, runtime: GhosttyRuntime) {
        let surfaceView = session.ensureSurfaceView(runtime: runtime)

        // Called on a session switch and whenever the pane looks again
        // (`TerminalPaneController.showSelected`), not only when the session
        // changed. If we're already showing this surface, do nothing:
        // re-running would steal first responder back from the rename field.
        guard surfaceView !== wakingView else { return }

        // Another session chosen while one was waking, the one on screen
        // included: the waking one stays out of sight, and goes back on the
        // clock.
        if let waking = wakingView {
            wakingView = nil
            HibernationPolicy.shared.hidden(waking)
        }

        guard surfaceView !== ownCurrentView else { return releaseWakeHold() }

        // Asleep, or woken out of sight a moment ago and still being written
        // back: either way it is shown when its screen is whole.
        guard surfaceView.isHibernated || surfaceView.isRestoring else {
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
        guard surfaceView !== ownCurrentView else { return }
        Signposts.interval("session-switch") {
            if let currentView = ownCurrentView {
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
            coverStart(of: surfaceView)

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
        guard let currentView = ownCurrentView else {
            self.currentView = nil
            coverStart(of: nil)
            return
        }
        currentView.isHidden = true
        currentView.occlusionDidChange(visible: false)
        HibernationPolicy.shared.hidden(currentView)
        if view.window?.firstResponder === currentView { view.window?.makeFirstResponder(nil) }
        self.currentView = nil
        coverStart(of: nil)
    }

    /// The window arriving is the other chance to focus, and the reliable one.
    ///
    /// `show` first runs as the pane loads (`TerminalPaneController`), which
    /// during launch is before this controller's view is in a window. When it
    /// does, the retry below is the only thing standing between the user and a
    /// terminal that draws but does not take a keystroke.
    override func viewDidAppear() {
        super.viewDidAppear()
        // The first time only, which is the window starting. This also runs
        // each time the terminal's area comes back from being hidden (a
        // split of the main area was zoomed, and then all of them shown
        // again), and the keyboard is then wherever the split you were in
        // has it, or with nobody when that split shows a file: taking it
        // here put you in a terminal you hadn't gone to, and ⌘W closed the
        // session. Whoever ends a zoom says where the keyboard goes
        // (`GitPanelModel.toggleZoom`, `onFocusMainTerminal`).
        if !hasAppeared, let currentView = ownCurrentView { focusTerminal(currentView) }
        hasAppeared = true
        SurfaceView.settleSoon("the window appeared")
    }

    /// The terminal's own area was laid out: the one on screen is checked
    /// against it (`SurfaceView.reconcileSize`). One comparison when they
    /// agree, and nothing while a pane is animating.
    override func viewDidLayout() {
        super.viewDidLayout()
        ownCurrentView?.reconcileSize("its area was laid out")
        if !startCover.isHidden { centreStartSpinner() }
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
