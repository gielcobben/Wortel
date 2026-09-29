import AppKit
import Observation
import SwiftUI

/// The main area: the session's own terminal, and in front of it whatever
/// else its tab row has brought forward, a pane or another terminal.
///
/// The session's terminal is never taken out: it stays mounted underneath, the
/// way TerminalHostViewController keeps every session's, and the tab in front
/// is laid over it. Switching back to the session's tab is removing a cover, so
/// it's as instant as switching sessions.
@MainActor
final class MainAreaController: NSViewController {
    private let terminal: NSViewController
    private let paneHost: NSHostingController<MainAreaPane>
    private let tabHost = SideTerminalHostController()
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let git: GitPanelModel

    init(terminal: NSViewController, runtime: GhosttyRuntime, manager: SessionManager,
         git: GitPanelModel, files: FileTreeModel, previewTabs: PreviewTabs) {
        self.terminal = terminal
        self.runtime = runtime
        self.manager = manager
        self.git = git
        paneHost = NSHostingController(rootView: MainAreaPane(git: git, files: files,
                                                              previewTabs: previewTabs))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        for child in [terminal, paneHost, tabHost] as [NSViewController] {
            addChild(child)
            let view = child.view
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        observe()
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        let session = manager.selected
        let active = git.activeMainTab
        // A pane, a file, a web page: anything that isn't a terminal is drawn
        // by the SwiftUI cover.
        let showsPane = active?.isPage ?? false
        paneHost.view.isHidden = !showsPane
        let surface = active?.terminalID.flatMap { session?.ensureSideSurface($0, runtime: runtime) }
        tabHost.show(surface, focusRequest: git.mainFocusRequest, mainTerminal: session?.surfaceView)
        // Out of the way of clicks when it has nothing to show.
        tabHost.view.isHidden = surface == nil
        // A covered terminal gives up the keyboard: typing into a terminal you
        // can't see is the one thing a cover must not allow.
        if showsPane, let window = view.window, let main = session?.surfaceView,
           window.firstResponder === main {
            window.makeFirstResponder(nil)
        }
    }
}

/// A pane in the main area, on the page's colour so it covers the terminal.
struct MainAreaPane: View {
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        TabContent(tab: git.activeMainTab, git: git, files: files, previewTabs: previewTabs)
    }
}

/// What any row shows for a tab that isn't a terminal: a pane or a file, on
/// the page's colour. Terminals are the hosts' job (they must never be
/// rebuilt), so for those, and for nothing in front, this is clear.
struct TabContent: View {
    let tab: SideTab?
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        Group {
            switch tab {
            case .file(let path)?:
                PreviewTab(tabs: previewTabs, path: path)
            case .browser(let id)?:
                BrowserTab(page: BrowserTabs.shared.page(for: id),
                           openInWindow: { BrowserTabs.shared.openInWindow(id) })
            case .pane(.files)?:
                FileTreePanel(model: files, focusRequest: git.listFocusRequest)
            case .pane(let pane)?:
                SourceControlPanel(panel: git, pane: pane)
            default:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
    }
}
