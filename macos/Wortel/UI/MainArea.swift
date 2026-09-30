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
        tabHost.show(surface, focusRequest: git.mainFocusRequest, handBack: { [weak git] in git?.focusFront(of: .main) })
        // Out of the way of clicks when it has nothing to show.
        tabHost.view.isHidden = surface == nil
        // Nor does its cursor show through what covers it.
        session?.surfaceView?.isCovered = active != nil
        // After this turn: a session switch focuses the session's terminal in
        // the same update, and the check has to come after that.
        DispatchQueue.main.async { [weak self] in self?.keepKeyboardOffCoveredTerminal() }
    }

    /// A covered terminal gives up the keyboard, to what covers it: typing
    /// into a terminal you can't see is the one thing a cover must not allow.
    /// Checked after every change here and when the window becomes key, since
    /// the session's terminal takes the keyboard at launch and on a switch.
    private func keepKeyboardOffCoveredTerminal() {
        guard git.activeMainTab != nil, let window = view.window,
              let main = manager.selected?.surfaceView, window.firstResponder === main else { return }
        window.makeFirstResponder(nil)
        git.focusFront(of: .main)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window = view.window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        }
        keepKeyboardOffCoveredTerminal()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.keepKeyboardOffCoveredTerminal() }
    }
}

/// A pane in the main area, on the page's colour so it covers the terminal.
struct MainAreaPane: View {
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        TabContent(tab: git.activeMainTab, region: .main, git: git, files: files, previewTabs: previewTabs)
    }
}

/// What any row shows for a tab that isn't a terminal: a pane or a file, on
/// the page's colour. Terminals are the hosts' job (they must never be
/// rebuilt), so for those, and for nothing in front, this is clear.
struct TabContent: View {
    let tab: SideTab?
    let region: TabRegion
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        Group {
            switch tab {
            case .file(let path)?:
                PreviewTab(tabs: previewTabs, path: path)
            case .browser(let id)?:
                BrowserTab(page: BrowserTabs.shared.page(for: id))
            case .pane(.files)?:
                FileTreePanel(model: files, focusRequest: git.listFocusRequest(in: region))
            case .pane(let pane)?:
                SourceControlPanel(panel: git, pane: pane, region: region)
            default:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
    }
}
