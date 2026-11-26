import AppKit
import Observation
import SwiftUI

/// The main area: the session's own terminal, in front of it whatever else
/// its tab row has brought forward, and beside it the panes that were split
/// off it.
///
/// The session's terminal is never taken out: it stays mounted underneath, the
/// way TerminalHostViewController keeps every session's, and the tab in front
/// is laid over it. Switching back to the session's tab is removing a cover, so
/// it's as instant as switching sessions.
///
/// Unsplit, this is one pane filling the area with its row in the titlebar,
/// exactly as it was before there were splits. Split, the area is a
/// `SplitTreeView`: the main row's pane is one leaf of it and gets a row of
/// its own (`mainBar`, the titlebar then shows the session's name), and every
/// other leaf is a `SplitPaneController`.
@MainActor
final class MainAreaController: NSViewController {
    private let terminal: NSViewController
    private let paneHost: NSHostingController<MainAreaPane>
    private let tabHost = SideTerminalHostController()
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let home: SessionWindow
    private let git: GitPanelModel
    private let files: FileTreeModel
    private let previewTabs: PreviewTabs

    private let tree = SplitTreeView()
    /// The main row's leaf: its own row on top while the area is split, and
    /// under it the terminal and what covers it.
    private let mainLeaf = NSView()
    let mainBar = PaneBar(region: .main)
    private var mainBarHeight: NSLayoutConstraint!
    private var panes: [UUID: SplitPaneController] = [:]

    /// The rows of the panes changed (one was made or let go of): the tab
    /// drag reads them again.
    var onRowsChanged: () -> Void = {}

    init(terminal: NSViewController, runtime: GhosttyRuntime, manager: SessionManager, home: SessionWindow,
         git: GitPanelModel, files: FileTreeModel, previewTabs: PreviewTabs) {
        self.terminal = terminal
        self.runtime = runtime
        self.manager = manager
        self.home = home
        self.git = git
        self.files = files
        self.previewTabs = previewTabs
        paneHost = NSHostingController(rootView: MainAreaPane(git: git, files: files,
                                                              previewTabs: previewTabs))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        mainBar.translatesAutoresizingMaskIntoConstraints = false
        mainBar.isHidden = true
        mainLeaf.addSubview(mainBar)
        mainBarHeight = mainBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            mainBar.topAnchor.constraint(equalTo: mainLeaf.topAnchor),
            mainBar.leadingAnchor.constraint(equalTo: mainLeaf.leadingAnchor),
            mainBar.trailingAnchor.constraint(equalTo: mainLeaf.trailingAnchor),
            mainBarHeight,
        ])
        for child in [terminal, paneHost, tabHost] as [NSViewController] {
            addChild(child)
            let view = child.view
            view.translatesAutoresizingMaskIntoConstraints = false
            mainLeaf.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: mainBar.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: mainLeaf.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: mainLeaf.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: mainLeaf.bottomAnchor),
            ])
        }
        mainBar.wire(to: git, home: home, region: .main)
        tree.setLeaves([.main: mainLeaf])
        tree.onLayoutChanged = { [weak self] layout in self?.git.setSplitLayout(layout) }
        tree.onDividerReleased = { [weak self] in self?.git.commitSplitLayout() }
        tree.onDividerDoubleClicked = { [weak self] in self?.git.equalizeSplits() }
        view = tree
        observe()
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// The area as the selected session has it, applied and laid out now
    /// rather than a turn later by the observers: a session switch shows the
    /// terminal only once it has the size it will keep
    /// (`MainSplitViewController.show`).
    func applyNow() {
        sync()
        panes.values.forEach { $0.applyNow() }
        tree.layoutSubtreeIfNeeded()
    }

    // MARK: Panes

    /// The leaves of the tree this view doesn't lay out: the ones the model
    /// hides, and the column and the strip whether they are up or not.
    ///
    /// TODO(unify): the column and the strip are leaves of the tree now, and
    /// are still drawn by panes of their own outside this view
    /// (`MainSplitViewController`). Until this view draws them, they take no
    /// room here, and this is `git.hiddenLeaves` alone once it does.
    private var hiddenLeaves: Set<SplitLayout.Leaf> { git.hiddenLeaves.union([.side, .bottom]) }

    /// The zoom, as this view shows it: none for one on the column or the
    /// strip.
    ///
    /// TODO(unify): those two can't be shown alone by this view yet, so a
    /// zoom on one leaves the main area as it is. `git.zoomedRegion` once
    /// their leaves are drawn here.
    private var zoomedRegion: TabRegion? {
        git.zoomedRegion.flatMap { $0 == .side || $0 == .bottom ? nil : $0 }
    }

    private func syncPanes() {
        let session = home.selected
        let layout = git.splitLayout
        // TODO(unify): `hasPanes`, not `isSplit`: a column or a strip makes
        // the tree more than one leaf, and the main row gets its own bar
        // only beside a leaf this view draws.
        let split = layout.hasPanes
        // The main row's own row, only while there is another pane to tell it
        // from. One layout change for both: the row and the frames.
        if mainBar.isHidden == split {
            mainBar.isHidden = !split
            mainBarHeight.constant = split ? PaneBar.height : 0
        }
        if split {
            mainBar.strip.update(items: git.mainTabs.map { TitleBarController.stripItem(for: $0, in: session) },
                                 active: git.activeMainTab ?? .session)
        }
        mainBar.unzoom.isHidden = zoomedRegion != .main
        mainBar.strip.isKeyRow = git.keyRegion == .main

        var views: [SplitLayout.Leaf: NSView] = [.main: mainLeaf]
        var made = false
        for case .pane(let id) in layout.leaves {
            if panes[id] == nil {
                let pane = SplitPaneController(id: id, runtime: runtime, home: home, git: git,
                                               files: files, previewTabs: previewTabs)
                addChild(pane)
                panes[id] = pane
                made = true
            }
            views[.pane(id)] = panes[id]?.view
        }
        tree.setLeaves(views)
        tree.apply(layout: layout, zoomed: zoomedRegion?.leaf, hidden: hiddenLeaves)
        // A pane no session has any more is let go of. One that another
        // session of this window has stays, hidden: see `SplitPaneController`.
        let dead = panes.keys.filter { id in !manager.sessions.contains { $0.paneTabs[id] != nil } }
        for id in dead {
            guard let pane = panes.removeValue(forKey: id) else { continue }
            // Hidden now (`setLeaves`), out of the window a little later: a
            // terminal moved out of it as its last tab is still in its host
            // until the row it went to has shown it, which is another
            // observer's turn, and it must not leave the window on the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tree.discard(pane.view)
                pane.removeFromParent()
            }
        }
        if made || !dead.isEmpty { onRowsChanged() }
    }

    /// Every row in the area that takes a dropped tab, for the tab drag: the
    /// main row's own (while split) and each pane's on screen.
    var rows: [(strip: SideTabStrip, region: TabRegion)] {
        var rows: [(SideTabStrip, TabRegion)] = []
        if !mainBar.isHidden { rows.append((mainBar.strip, .main)) }
        for case .pane(let id) in git.splitLayout.leaves {
            if let pane = panes[id] { rows.append((pane.bar.strip, .pane(id))) }
        }
        return rows
    }

    /// Every row that can start a tab drag, whether or not it is on screen.
    var allStrips: [SideTabStrip] { [mainBar.strip] + panes.values.map(\.bar.strip) }

    /// The panes on screen, each with its frame in window coordinates.
    var paneFrames: [(region: TabRegion, frame: NSRect)] {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return [] }
        return tree.visibleLeaves.map { (TabRegion($0.leaf), tree.convert($0.frame, to: nil)) }
    }

    /// The pane under a point in window coordinates, and what a tab let go
    /// there asks for: a split on one of its edges (with the half of the pane
    /// the new one would take, in window coordinates), or nil for the pane
    /// itself.
    func paneDrop(at point: NSPoint) -> (region: TabRegion, frame: NSRect, edge: SplitLayout.Edge?, half: NSRect?)? {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let local = tree.convert(point, from: nil)
        guard let hit = tree.visibleLeaves.first(where: { $0.frame.contains(local) }) else { return nil }
        let edge = SplitLayout.dropEdge(at: local, in: hit.frame)
        let half = edge.map { tree.convert(newFrame(beside: hit.leaf, on: $0, in: hit.frame), to: nil) }
        return (TabRegion(hit.leaf), tree.convert(hit.frame, to: nil), edge, half)
    }

    /// Where a split made on `edge` of `leaf` would be, in the tree's
    /// coordinates: the layout asked, with a stand-in for the new split, so
    /// the drag lights up what the drop makes (a third among two equals, not
    /// half of the one it was dropped on). Half of `frame` when the layout
    /// can't say, which is while one split is zoomed.
    private func newFrame(beside leaf: SplitLayout.Leaf, on edge: SplitLayout.Edge, in frame: NSRect) -> NSRect {
        let standIn = SplitLayout.Leaf.pane(UUID())
        var layout = git.splitLayout
        guard zoomedRegion == nil, layout.insert(standIn, beside: leaf, on: edge),
              let made = layout.frames(in: tree.bounds, metrics: tree.metrics, hidden: hiddenLeaves).leaves[standIn]
        else { return SplitLayout.half(of: frame, on: edge) }
        return made
    }

    func isOnDivider(_ point: NSPoint) -> Bool { tree.isOnDivider(point) }

    /// The pane you reach from `region` by going toward `edge`, if the area
    /// has one there.
    func neighbour(of region: TabRegion, toward edge: SplitLayout.Edge) -> TabRegion? {
        guard zoomedRegion == nil else { return nil }
        return git.splitLayout.neighbour(of: region.leaf, toward: edge, in: tree.bounds, metrics: tree.metrics,
                                         hidden: hiddenLeaves)
            .map(TabRegion.init)
    }

    /// The first pane along the area's `edge`: where the keyboard, or a tab,
    /// lands coming in from the column or the strip.
    func edgeSplit(on edge: SplitLayout.Edge) -> TabRegion? {
        let leaves = tree.visibleLeaves
        let bounds = tree.bounds
        let onEdge = leaves.filter { leaf in
            switch edge {
            case .left: return leaf.frame.minX <= bounds.minX + 1
            case .right: return leaf.frame.maxX >= bounds.maxX - 1
            case .up: return leaf.frame.minY <= bounds.minY + 1
            case .down: return leaf.frame.maxY >= bounds.maxY - 1
            }
        }
        return onEdge.first.map { TabRegion($0.leaf) }
    }

    /// Whether `region` is big enough on screen to be split in two on
    /// `edge`, each half keeping the least a pane is laid out at. Out of
    /// sight (zoomed away), there is nothing to measure and it may.
    func hasRoom(toSplit region: TabRegion, on edge: SplitLayout.Edge) -> Bool {
        guard let frame = tree.frame(of: region.leaf) else { return true }
        return hasRoom(toSplit: frame, on: edge)
    }

    /// The same for a layout that is not the one laid out here: another
    /// session of this window, or this one's with a zoom over it (`wortel
    /// split`, which splits what nobody is looking at). Measured in the area
    /// as it is now. That is near enough for a session whose column or strip
    /// differs, and it is what keeps a script from halving a session out of
    /// sight until nothing in it can be used.
    func hasRoom(toSplit region: TabRegion, on edge: SplitLayout.Edge, in layout: SplitLayout) -> Bool {
        // TODO(unify): the column and the strip of that session take no room
        // in this view, shown or hidden; its own hidden leaves once they do.
        guard let frame = layout.frames(in: tree.bounds, metrics: tree.metrics,
                                        hidden: [.side, .bottom]).leaves[region.leaf] else { return true }
        return hasRoom(toSplit: frame, on: edge)
    }

    private func hasRoom(toSplit frame: NSRect, on edge: SplitLayout.Edge) -> Bool {
        let minimum = tree.metrics.minimum
        return edge.axis == .row ? frame.width >= minimum.width * 2 + tree.metrics.gap
                                 : frame.height >= minimum.height * 2 + tree.metrics.gap
    }

    /// The view of a pane, for the edge flash and for telling which pane a
    /// click was in.
    func view(of region: TabRegion) -> NSView? {
        switch region {
        case .main: return mainLeaf
        case .pane(let id): return panes[id]?.view
        default: return nil
        }
    }

    /// Which pane a view is in, if it is in one.
    func region(containing descendant: NSView) -> TabRegion? {
        if descendant.isDescendant(of: mainLeaf) { return .main }
        for (id, pane) in panes where descendant.isDescendant(of: pane.view) { return .pane(id) }
        return nil
    }

    // MARK: The main row

    /// Whether the main row is on screen in this view: not behind a zoom
    /// this view shows (`zoomedRegion`).
    private var showsMainRow: Bool { zoomedRegion == nil || zoomedRegion == .main }

    private func sync() {
        syncPanes()
        let session = home.selected
        // Zoomed on another pane, the main row is out of sight: nothing of
        // it shows, and its terminal is treated as covered.
        let showing = showsMainRow
        let active = git.activeMainTab
        // A pane, a file, a web page: anything that isn't a terminal is drawn
        // by the SwiftUI cover.
        let showsPane = showing && (active?.isPage ?? false)
        paneHost.view.isHidden = !showsPane
        // Only for the session the panel is pointed at: see `SideColumnController.sync`.
        let surface = showing && git.session === session
            ? active?.terminalID.flatMap { session?.ensureSideSurface($0, runtime: runtime) } : nil
        tabHost.show(surface, focusRequest: git.mainFocusRequest, handBack: { [weak git] in git?.focusFront(of: .main) })
        // Out of the way of clicks when it has nothing to show.
        tabHost.view.isHidden = surface == nil
        // Nor does its cursor show through what covers it.
        session?.surfaceView?.isCovered = active != nil || !showing
        // After this turn: a session switch focuses the session's terminal in
        // the same update, and the check has to come after that.
        DispatchQueue.main.async { [weak self] in self?.keepKeyboardOffCoveredTerminal() }
    }

    /// A covered terminal gives up the keyboard, to what covers it: typing
    /// into a terminal you can't see is the one thing a cover must not allow.
    /// Checked after every change here and when the window becomes key, since
    /// the session's terminal takes the keyboard at launch and on a switch.
    /// Out of sight behind a zoomed pane is covered too, and the keyboard
    /// goes to that pane.
    private func keepKeyboardOffCoveredTerminal() {
        let hidden = !showsMainRow
        guard git.activeMainTab != nil || hidden, let window = view.window,
              let main = home.selected?.surfaceView, window.firstResponder === main else { return }
        window.makeFirstResponder(nil)
        git.focusFront(of: hidden ? (zoomedRegion ?? .main) : .main)
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
        ZStack {
            // The file tabs last in front in this row stay built behind the
            // one in front, hidden and disabled. Rebuilding a preview each time
            // its tab came forward put the reader back only nearly where they
            // were: rendered Markdown is a lazy stack, whose blocks above the
            // place have estimated heights until they're on screen, so each
            // return landed a little off and a few switches added up. A view
            // that never went away is still exactly where it was. One that was
            // rebuilt (another session's row, an older tab) goes back to the
            // place its document noted, see `PreviewTab`.
            ForEach(builtFiles, id: \.self) { path in
                let front = tab == .file(path)
                PreviewTab(tabs: previewTabs, path: path)
                    .opacity(front ? 1 : 0)
                    .allowsHitTesting(front)
                    .disabled(!front)
                    .accessibilityHidden(!front)
                    .zIndex(front ? 1 : 0)
            }
            switch tab {
            case .file?:
                EmptyView()
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
        .onChange(of: tab, initial: true) { _, tab in
            if let path = tab?.filePath { previewTabs.noteShown(path) }
        }
    }

    /// The one in front, and those kept behind it (`PreviewTabs.keptBuilt`),
    /// in the row's order. Never one that hasn't been looked at: a restored
    /// row would otherwise start a document, and a file watcher, for every
    /// file tab in it.
    private var builtFiles: [String] {
        let row = git.tabs(in: region).compactMap(\.filePath)
        let kept = previewTabs.keptBuilt(of: row)
        return row.filter { tab == .file($0) || kept.contains($0) }
    }
}
