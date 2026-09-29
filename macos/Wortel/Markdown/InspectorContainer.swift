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
/// It used to be three panes, with the Markdown preview taking the whole column
/// when a `.md` was opened. Markdown opens in a preview window now, so the column
/// belongs to its tabs outright.
struct InspectorContainer: View {
    let runtime: GhosttyRuntime
    @Bindable var manager: SessionManager
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        ZStack {
            SideTerminalContainer(
                runtime: runtime,
                session: manager.selected,
                terminalID: git.isVisible ? git.activeTab?.terminalID : nil,
                focusRequest: git.terminalFocusRequest,
                mainTerminal: manager.selected?.surfaceView)
            switch git.activeTab {
            case .pane(.files)?:
                FileTreePanel(model: files, focusRequest: git.listFocusRequest)
            case .pane(let pane)?:
                SourceControlPanel(panel: git, pane: pane)
            case nil:
                SourceControlPanel(panel: git)
            case .file(let path)?:
                PreviewTab(tabs: previewTabs, path: path)
                    .background(Color(nsColor: Chrome.content))
            case .web(let address)?:
                BrowserTab(page: BrowserTabs.shared.page(for: address))
            case .terminal?, .session?:
                EmptyView()
            }
        }
    }
}

/// Hosts the side terminals. One controller for the life of the column; the
/// surface on screen is swapped by hiding, never by removing.
private struct SideTerminalContainer: NSViewControllerRepresentable {
    let runtime: GhosttyRuntime
    let session: Session?
    let terminalID: UUID?
    let focusRequest: Int
    /// Where the keyboard goes when the side terminal that had it is hidden.
    let mainTerminal: SurfaceView?

    func makeNSViewController(context: Context) -> SideTerminalHostController {
        SideTerminalHostController()
    }

    func updateNSViewController(_ controller: SideTerminalHostController, context: Context) {
        let surface = terminalID.flatMap { id in session?.ensureSideSurface(id, runtime: runtime) }
        controller.show(surface, focusRequest: focusRequest, mainTerminal: mainTerminal)
    }
}

/// The side column's (and the bottom strip's) counterpart to
/// TerminalHostViewController: every terminal that has been shown here stays in
/// this view, hidden when it isn't the one in front. A terminal moved to the
/// other region is re-parented into that region's host by `show`, the same
/// `addSubview` that put it here: a new place for the same live view.
///
/// Opaque while a terminal shows. The terminal draws no background of its own
/// (`background-opacity = 0` in wortel.conf), and over the column's glass it
/// would read as text floating on a material rather than as a terminal; the
/// main terminal gets the same backing from the window.
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

    func show(_ surface: SurfaceView?, focusRequest: Int, mainTerminal: SurfaceView?) {
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
                if hadKeyboard, surface == nil || focusRequest == handledFocusRequest,
                   let mainTerminal {
                    mainTerminal.window?.makeFirstResponder(mainTerminal)
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
            view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
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
