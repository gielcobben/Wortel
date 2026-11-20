import AppKit
import SwiftUI

/// What the right column shows: the tab in front of the focused session's strip.
///
/// A pane tab is the file tree or the source-control panel, as before. A terminal
/// tab is one of the session's side shells, and those live in a host that is
/// **always mounted** underneath, whatever tab is in front: taking a libghostty
/// surface out of the window and putting it back is exactly what the main
/// terminal's host refuses to do (see TerminalHostViewController), and a tab
/// switch should cost what a session switch costs, which is nothing.
///
/// AppKit, like the strip (`BottomPaneController`) and the main area: the
/// host of the terminals fills this view by its own constraints, and the page
/// that is not a terminal is SwiftUI's in a view on top, hidden while a
/// terminal is in front. It was one SwiftUI view with the host inside it as a
/// representable, which leaves it to SwiftUI where a terminal is; the main
/// terminal's pane was the same, and SwiftUI fell a layout behind there
/// (`TerminalPaneController`, 2026-11-19). This one was never caught at it
/// (`scripts/try-switch.sh --side`, 0 of 72 before and after), and no longer
/// can be.
@MainActor
final class SideColumnController: NSViewController {
    private let host = SideTerminalHostController()
    private let pageHost: NSHostingController<SideColumnPage>
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    /// The window this column is in: whose session it shows.
    private let home: SessionWindow
    private let git: GitPanelModel

    init(runtime: GhosttyRuntime, manager: SessionManager, home: SessionWindow, git: GitPanelModel,
         files: FileTreeModel, previewTabs: PreviewTabs) {
        self.runtime = runtime
        self.manager = manager
        self.home = home
        self.git = git
        pageHost = NSHostingController(rootView: SideColumnPage(git: git, files: files,
                                                                previewTabs: previewTabs))
        // The page has no say in how big the column is. With a terminal in
        // front it is empty, and an empty SwiftUI view left to size its
        // hosting view asks for no height at all: pinned to this view's
        // edges, that took the whole row of panes down to nothing.
        pageHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(host)
        addChild(pageHost)
        for body in [host.view, pageHost.view] {
            body.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: root.topAnchor),
                body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        observe()
    }

    /// The column as the selected session has it, applied now rather than a
    /// turn later by the observer (see `MainSplitViewController.show`).
    func applyNow() { sync() }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        let tab = git.activeTab
        // A hidden column shows no terminal: it would keep the keyboard.
        let terminal = git.isVisible ? tab?.terminalID : nil
        // Only for the session the panel is pointed at: its tabs are that
        // session's. The two differ for a moment whenever the panel follows
        // a turn later (a session whose worktree is still being made is
        // selected before the panel is given it), and a terminal made then
        // would be the old session's tab on the new session: a second reader
        // on that shell's pty.
        let session = home.selected
        let surface = git.session === session
            ? terminal.flatMap { id in session?.ensureSideSurface(id, runtime: runtime) } : nil
        host.show(surface, focusRequest: git.terminalFocusRequest,
                  handBack: { [weak git] in git?.focusFront(of: .main) })
        // In front of the terminals, so out of the way of one: it would take
        // every click meant for it.
        pageHost.view.isHidden = !(tab?.isPage ?? false)
    }
}

/// A pane, a file or a web page in the column. What it shows is `TabContent`'s,
/// the same as in the main area and the strip. A hidden column builds no
/// browser page or file document it doesn't already have: they're made when
/// first on screen.
struct SideColumnPage: View {
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        ZStack {
            if let tab = git.activeTab, tab.isPage, git.isVisible || isBuilt(tab) {
                TabContent(tab: tab, region: .side, git: git, files: files, previewTabs: previewTabs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether a page or document for this tab exists already. A hidden
    /// column keeps showing those (it slides shut with them in it) but makes
    /// none: a restored column that's hidden would otherwise start a web page
    /// or a file watcher nobody can see.
    private func isBuilt(_ tab: SideTab) -> Bool {
        switch tab {
        case .browser(let id): return BrowserTabs.shared.existingPage(for: id) != nil
        case .file(let path): return previewTabs.hasDocument(for: path)
        default: return true
        }
    }
}

/// The side column's, the bottom strip's and the main area's row's counterpart to
/// TerminalHostViewController: every terminal that has been shown here stays in
/// this view, hidden when it isn't the one in front. A terminal moved to the
/// other region is re-parented into that region's host by `show`, the same
/// `addSubview` that put it here: a new place for the same live view.
///
/// Opaque while a terminal shows. The terminal draws the page under its text
/// (wortel.conf), but not the strip a frame pinned at its old size leaves
/// uncovered during a resize, and over the column's glass that strip would
/// show the material; the main terminal gets the same backing from the window.
final class SideTerminalHostController: NSViewController {
    private weak var current: SurfaceView?
    /// The last focus request acted on, so an unrelated SwiftUI update doesn't
    /// pull the keyboard back into the side terminal.
    private var handledFocusRequest = 0

    override func loadView() {
        let view = AppearanceTrackingView()
        view.wantsLayer = true
        view.onAppearanceChange = { [weak self] in self?.applyBackground() }
        self.view = view
    }

    /// `handBack` gives the keyboard to the main area when the terminal that
    /// had it is hidden: to what's in front there, which is not the session's
    /// own terminal when a tab covers it.
    func show(_ surface: SurfaceView?, focusRequest: Int, handBack: @escaping () -> Void) {
        if surface !== current {
            // Only a view this host still holds. A terminal dragged to the
            // other region has been re-parented into that region's host, and
            // hiding it here would blank it there.
            if let current, current.superview === view {
                // A hidden view keeps first responder if nobody takes it, and
                // then every keystroke goes to a terminal you can't see: the
                // column was hidden, or another tab came to the front, while
                // this one had the keyboard.
                let hadKeyboard = current.window?.firstResponder === current
                current.isHidden = true
                current.occlusionDidChange(visible: false)
                if hadKeyboard, surface == nil || focusRequest == handledFocusRequest {
                    // Not now: this runs inside a view update, and handing
                    // back changes what the views observe.
                    let window = current.window
                    window?.makeFirstResponder(nil)
                    // Only if nothing took the keyboard meanwhile: a new
                    // browser's address field does, in this same update.
                    DispatchQueue.main.async {
                        guard let window, window.firstResponder === window else { return }
                        handBack()
                    }
                }
            }
            if let surface {
                if surface.superview !== view {
                    surface.frame = view.bounds
                    surface.autoresizingMask = [.width, .height]
                    view.addSubview(surface)
                }
                surface.isHidden = false
                surface.occlusionDidChange(visible: true)
            }
            current = surface
            applyBackground()
        }
        if focusRequest != handledFocusRequest {
            handledFocusRequest = focusRequest
            if let surface { focus(surface) }
        }
    }

    /// A tab opened from a menu or a shortcut is shown in the same update that
    /// asks for focus, which can be before the view is in the window. A few
    /// turns of patience, as the main terminal's host gives itself.
    private func focus(_ surface: SurfaceView, attemptsLeft: Int = 10) {
        if let window = view.window {
            window.makeFirstResponder(surface)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface, surface === self.current else { return }
            self.focus(surface, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Resolved per appearance: a `cgColor` taken once would keep the light
    /// background after the Mac switched to dark.
    private func applyBackground() {
        guard current != nil else {
            view.layer?.backgroundColor = nil
            return
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = Chrome.content.cgColor
        }
    }
}

/// A plain view that says when light and dark change under it.
private final class AppearanceTrackingView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
