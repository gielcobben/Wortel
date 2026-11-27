import AppKit
import Observation
import SwiftUI

/// Everything beside the sidebar: the window's tree of splits.
///
/// Every part of it is a split, a leaf of one tree (`SplitLayout`) drawn by
/// one view (`SplitTreeView`), each a `SplitLeafView`: its row on top and its
/// page below. The main row (the session's own terminal and what shares its
/// row), the side split (Changes, History, Files) and the strip are leaves
/// like any split somebody makes with ⌘D. What is still theirs is where they
/// open and at what size. ⌥⌘B opens Changes and Files in the side split and
/// closes them; ⌘J opens a terminal in the strip, or goes to it. Until
/// 2026-11-26 those two keys hid the side split and the strip with their tabs
/// kept, and nothing is hidden that way now. They used to be separate
/// AppKit split panes around a main area that could itself be split, which
/// made two kinds of thing out of one: a column that couldn't be split or
/// dragged onto, beside splits that could.
///
/// A leaf along the top of the window has its row in the titlebar, so the
/// terminal with Changes beside it looks as it always did; one lower down
/// has the strip's kind of row.
///
/// The session's terminal is never taken out: it stays mounted in the main
/// row's leaf, the way TerminalHostViewController keeps every session's, and
/// the tab in front of that row is laid over it. Switching back to the
/// session's tab is removing a cover, so it's as instant as switching
/// sessions.
@MainActor
final class MainAreaController: NSViewController {
    private let terminal: NSViewController
    private let paneHost: NSHostingController<MainAreaPane>
    private let tabHost = SideTerminalHostController()
    private let side: SideColumnController
    private let bottom: BottomPaneController
    private let titleBars: TitleBarController
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let home: SessionWindow
    private let git: GitPanelModel
    private let files: FileTreeModel
    private let previewTabs: PreviewTabs

    private let tree = SplitTreeView()
    /// The main row's page: the terminal and what covers it.
    private let mainBody = NSView()
    private lazy var mainLeaf = SplitLeafView(bar: titleBars.mainBar, body: mainBody)
    private lazy var sideLeaf = SplitLeafView(bar: titleBars.sideBar, body: side.view)
    private var panes: [UUID: SplitPaneController] = [:]

    /// The rows of the splits changed (one was made or let go of): the tab
    /// drag reads them again.
    var onRowsChanged: () -> Void = {}
    /// The tree was laid out: which leaves are along the top may have
    /// changed, and with it who makes room for the sidebar's controls.
    var onPlaced: () -> Void = {}

    init(terminal: NSViewController, side: SideColumnController, bottom: BottomPaneController,
         titleBars: TitleBarController, runtime: GhosttyRuntime, manager: SessionManager,
         home: SessionWindow, git: GitPanelModel, files: FileTreeModel, previewTabs: PreviewTabs) {
        self.terminal = terminal
        self.side = side
        self.bottom = bottom
        self.titleBars = titleBars
        self.runtime = runtime
        self.manager = manager
        self.home = home
        self.git = git
        self.files = files
        self.previewTabs = previewTabs
        paneHost = NSHostingController(rootView: MainAreaPane(git: git, files: files,
                                                              previewTabs: previewTabs))
        // The leaf's frame is set by hand (`SplitTreeView`), and the default
        // turns the page's minimum size into required constraints: a page
        // taller than its leaf (an empty tab's in a main row squeezed by
        // ⇧⌘D twice) broke one and drew past the leaf. As the other pages'
        // hosts do.
        paneHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for child in [terminal, paneHost, tabHost] as [NSViewController] {
            addChild(child)
            let view = child.view
            view.translatesAutoresizingMaskIntoConstraints = false
            mainBody.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: mainBody.topAnchor),
                view.leadingAnchor.constraint(equalTo: mainBody.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: mainBody.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: mainBody.bottomAnchor),
            ])
        }
        addChild(side)
        addChild(bottom)
        titleBars.mainBar.wire(to: git, home: home, region: .main)
        titleBars.sideBar.wire(to: git, home: home, region: .side)
        for (region, leaf) in [(TabRegion.main, mainLeaf), (.side, sideLeaf), (.bottom, bottom.leaf)] {
            wire(leaf.bar, region: region)
        }
        tree.setLeaves(fixedLeaves)
        // Before the divider moves. Taken in `onLayoutChanged` it was the
        // frame after the first step, which the tree has already made: a
        // flick of one step was never remembered.
        tree.onDividerPressed = { [weak self] in
            guard let self else { return }
            self.framesBeforeDrag = self.rememberedFrames
        }
        tree.onLayoutChanged = { [weak self] layout in
            guard let self else { return }
            // A drag that came without a press (the probe's).
            if self.framesBeforeDrag == nil { self.framesBeforeDrag = self.rememberedFrames }
            self.git.setSplitLayout(layout)
        }
        tree.onDividerReleased = { [weak self] in
            self?.git.commitSplitLayout()
            self?.rememberSizes()
        }
        tree.onDividerDoubleClicked = { [weak self] in self?.git.equalizeSplits() }
        tree.onPlaced = { [weak self] in self?.placed() }
        view = tree
        observe()
    }

    /// The three leaves the window always has views for, shown or not.
    private var fixedLeaves: [SplitLayout.Leaf: NSView] {
        [.main: mainLeaf, .side: sideLeaf, .bottom: bottom.leaf]
    }

    /// What every row has beyond its own buttons: the zoom, from its empty
    /// part (when it isn't in the titlebar) and back from its button.
    private func wire(_ bar: any LeafBar, region: TabRegion) {
        bar.onRowDoubleClick = { [weak git] in git?.toggleZoom(region) }
        bar.unzoom.target = self
        bar.unzoom.action = #selector(showAllSplits)
    }

    @objc private func showAllSplits() {
        guard let zoomed = git.zoomedRegion else { return }
        git.toggleZoom(zoomed)
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
        side.applyNow()
        bottom.applyNow()
        panes.values.forEach { $0.applyNow() }
        // The splits' frames now, and the main row's own layout: the
        // terminal has its size before it is shown. The pages of the other
        // splits lay out when the frame is drawn.
        tree.placeNow()
        mainLeaf.layoutSubtreeIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A leaf waiting for its size could not be given one before the
        // area had a size of its own.
        if !git.unsizedLeaves.isEmpty { sizeNewLeaves() }
    }

    // MARK: The tree

    private func syncTree() {
        var views = fixedLeaves
        var made = false
        for case .pane(let id) in git.splitLayout.leaves {
            if panes[id] == nil {
                let pane = SplitPaneController(id: id, runtime: runtime, home: home, git: git,
                                               files: files, previewTabs: previewTabs)
                addChild(pane)
                wire(pane.bar, region: .pane(id))
                panes[id] = pane
                made = true
            }
            views[.pane(id)] = panes[id]?.leaf
        }
        tree.setLeaves(views)
        sizeNewLeaves()
        let zoomed = git.zoomedRegion
        tree.apply(layout: git.splitLayout, zoomed: zoomed?.leaf, hidden: git.hiddenLeaves,
                   slides: slides(zoomed: zoomed))
        dressRows(zoomed: zoomed)

        // Which splits no session has any more, asked a turn later, outside
        // this observer. Asked here, every session's `paneTabs` was read
        // inside it, and any split change of any session in any window
        // synced this window again. The list of sessions is still read
        // here, so a session that closes is noticed.
        _ = manager.sessions
        DispatchQueue.main.async { [weak self] in self?.letGoOfDeadPanes() }
        if made { onRowsChanged() }
    }

    /// A split no session has any more is let go of. One that another
    /// session of this window has stays, hidden: see `SplitPaneController`.
    private func letGoOfDeadPanes() {
        let dead = panes.keys.filter { id in !manager.sessions.contains { $0.paneTabs[id] != nil } }
        for id in dead {
            guard let pane = panes.removeValue(forKey: id) else { continue }
            // Hidden now (`setLeaves`), out of the window a little later: a
            // terminal moved out of it as its last tab is still in its host
            // until the row it went to has shown it, which is another
            // observer's turn, and it must not leave the window on the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tree.discard(pane.leaf)
                pane.removeFromParent()
            }
        }
        if !dead.isEmpty { onRowsChanged() }
    }

    /// The side split and the strip as they were at the last sync, for
    /// `slides`.
    private var shownBefore = Set<SplitLayout.Leaf>()
    private weak var sessionBefore: Session?
    private var zoomedBefore: TabRegion?

    /// Whether this change slides: the side split or the strip opened by
    /// hand (⌥⌘B, ⌘J, a tab opened there), as they always have. Not when
    /// one goes with its last tab, which cuts (a close is mirrored without
    /// animation), not a session switch, which is instant, and not with a
    /// zoom in it.
    private func slides(zoomed: TabRegion?) -> Bool {
        let hidden = git.hiddenLeaves
        let shown = Set(git.splitLayout.leaves.filter { ($0 == .side || $0 == .bottom) && !hidden.contains($0) })
        defer {
            shownBefore = shown
            sessionBefore = git.session
            zoomedBefore = zoomed
        }
        guard git.session === sessionBefore, zoomed == nil, zoomedBefore == nil else { return false }
        let changed = shown.symmetricDifference(shownBefore)
        return (changed.contains(.side) && git.animatesVisibilityChange)
            || (changed.contains(.bottom) && git.animatesBottomChange)
    }

    /// The side split and the strip, the first time this window lays them
    /// out: the model put them in the tree at a guessed share, and here they
    /// get the size they have always opened at (the session's column width,
    /// or the last one chosen anywhere; the strip's height), no more than
    /// half the area for the one and six tenths for the other.
    private func sizeNewLeaves() {
        let bounds = tree.bounds
        guard bounds.width > 1, bounds.height > 1, git.session === home.selected,
              git.zoomedRegion == nil else { return }
        for leaf in git.unsizedLeaves where !git.hiddenLeaves.contains(leaf) {
            let extent: CGFloat
            switch leaf {
            case .side:
                extent = min(MainSplitViewController.ColumnWidth.width(for: home.selected), bounds.width / 2)
            case .bottom:
                extent = min(max(BottomPaneController.Height.chosen, BottomPaneController.Height.minimum),
                             bounds.height * 0.6)
            default:
                git.markLeafSized(leaf)
                continue
            }
            git.resizeLeaf(leaf, to: extent, in: bounds, metrics: tree.metrics)
        }
    }

    /// The rows' own state: the zoomed one says so, and with more than two
    /// splits on screen the tab in front of one you're not in has a quiet
    /// title. With two (the terminal and Changes beside it, as always) the
    /// cursor says where you are, and nothing is dimmed.
    private func dressRows(zoomed: TabRegion?) {
        let key = git.keyRegion
        let dims = tree.visibleLeaves.count > 2
        func dress(_ bar: any LeafBar, _ region: TabRegion) {
            bar.unzoom.isHidden = zoomed != region
            bar.strip.isKeyRow = !dims || key == region
        }
        dress(titleBars.mainBar, .main)
        dress(titleBars.sideBar, .side)
        dress(bottom.bar, .bottom)
        for (id, pane) in panes { dress(pane.bar, .pane(id)) }
    }

    /// After each layout: a leaf along the top has its row in the titlebar.
    private func placed() {
        for entry in tree.visibleLeaves {
            leafView(of: entry.leaf)?.isAtTop = entry.frame.minY < 0.5
        }
        onPlaced()
    }

    private func leafView(of leaf: SplitLayout.Leaf) -> SplitLeafView? {
        switch leaf {
        case .main: return mainLeaf
        case .side: return sideLeaf
        case .bottom: return bottom.leaf
        case .pane(let id): return panes[id]?.leaf
        }
    }

    // MARK: Sizes worth remembering

    /// The side split's width and the strip's height before a divider's
    /// drag, to tell afterwards whether the drag was about them.
    private var framesBeforeDrag: (side: NSRect?, bottom: NSRect?)?
    private var rememberedFrames: (side: NSRect?, bottom: NSRect?) {
        (tree.frame(of: .side), tree.frame(of: .bottom))
    }

    /// A divider's drag that changed the side split's width or the strip's
    /// height is somebody choosing it: the next session that opens one gets
    /// that size, as a new session has always inherited the last width
    /// chosen anywhere.
    private func rememberSizes() {
        defer { framesBeforeDrag = nil }
        guard let before = framesBeforeDrag else { return }
        let now = rememberedFrames
        if let side = now.side, let was = before.side, abs(side.width - was.width) > 0.5 {
            MainSplitViewController.ColumnWidth.remember(side.width)
            home.selected?.sideColumnWidth = Double(side.width)
        }
        if let strip = now.bottom, let was = before.bottom, abs(strip.height - was.height) > 0.5 {
            BottomPaneController.Height.remember(strip.height)
        }
    }

    // MARK: For the window

    /// The rows of the splits on screen, which take a dropped tab: for the
    /// tab drag.
    var rows: [(strip: SideTabStrip, region: TabRegion)] {
        tree.visibleLeaves.compactMap { entry in
            leafView(of: entry.leaf).map { ($0.bar.strip, TabRegion(entry.leaf)) }
        }
    }

    /// Every row that can start a tab drag, whether or not it is on screen.
    var allStrips: [SideTabStrip] {
        [titleBars.mainBar.strip, titleBars.sideBar.strip, bottom.bar.strip] + panes.values.map(\.bar.strip)
    }

    /// The rows along the top of the window, each with where it starts and
    /// ends in window coordinates: the leftmost makes room for the sidebar's
    /// controls when they are laid over it, the rightmost for the session's.
    var titlebarRows: [(bar: any LeafBar, minX: CGFloat, maxX: CGFloat)] {
        guard view.window != nil else { return [] }
        return tree.visibleLeaves.compactMap { entry in
            guard entry.frame.minY < 0.5, let leaf = leafView(of: entry.leaf) else { return nil }
            let frame = tree.convert(entry.frame, to: nil)
            return (leaf.bar, frame.minX, frame.maxX)
        }
    }

    /// The splits on screen, each with its frame in window coordinates.
    var paneFrames: [(region: TabRegion, frame: NSRect)] {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return [] }
        return tree.visibleLeaves.map { (TabRegion($0.leaf), tree.convert($0.frame, to: nil)) }
    }

    /// The split under a point in window coordinates, and what a tab let go
    /// there asks for: a split on one of its edges, or nil for the split
    /// itself. With an edge comes the half of the split on that side, in
    /// window coordinates, for the drag to light up: the half of what is
    /// under the pointer, as every app with splits shows it, which never
    /// reaches across a divider. (It was the exact frame the new split would
    /// end up with for a morning, a third among equals: true, and it lay
    /// across two splits, which read as a mistake.) An edge with no half is
    /// one where dropping `tab` would change nothing.
    func paneDrop(at point: NSPoint, dragging tab: SideTab? = nil)
        -> (region: TabRegion, frame: NSRect, edge: SplitLayout.Edge?, half: NSRect?)? {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let local = tree.convert(point, from: nil)
        guard let hit = tree.visibleLeaves.first(where: { $0.frame.contains(local) }) else { return nil }
        let edge = SplitLayout.dropEdge(at: local, in: hit.frame)
        let half = edge.flatMap { edge -> NSRect? in
            guard changesSomething(tab, beside: hit.leaf, on: edge) else { return nil }
            return tree.convert(SplitLayout.half(of: hit.frame, on: edge), to: nil)
        }
        return (TabRegion(hit.leaf), tree.convert(hit.frame, to: nil), edge, half)
    }

    /// Whether dropping `tab` on `edge` of `leaf` would move anything. It
    /// would not when the tab is its split's only one and that split already
    /// sits on that edge: the split it leaves closes, the one it makes takes
    /// its place, and every frame is what it was. Asked of the rules
    /// themselves, on a copy.
    private func changesSomething(_ tab: SideTab?, beside leaf: SplitLayout.Leaf, on edge: SplitLayout.Edge) -> Bool {
        guard let tab, let session = git.session, git.zoomedRegion == nil else { return true }
        let now = session.workspace
        guard let from = now.region(of: tab), now.tabs(in: from).count == 1 else { return true }
        var after = now
        guard let made = after.split(TabRegion(leaf), on: edge, placing: tab, recordsHabit: false) else { return false }
        let bounds = tree.bounds
        let before = now.layout.frames(in: bounds, metrics: tree.metrics, hidden: now.hiddenLeaves).leaves
        let then = after.layout.frames(in: bounds, metrics: tree.metrics, hidden: after.hiddenLeaves).leaves
        func same(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5
                && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5
        }
        guard let was = before[from.leaf], let will = then[made.leaf], same(was, will) else { return true }
        for (other, frame) in then where other != made.leaf {
            guard let old = before[other], same(old, frame) else { return true }
        }
        return false
    }

    func isOnDivider(_ point: NSPoint) -> Bool { tree.isOnDivider(point) }

    /// The split you reach from `region` by going toward `edge`, if there
    /// is one there on screen.
    func neighbour(of region: TabRegion, toward edge: SplitLayout.Edge) -> TabRegion? {
        guard git.zoomedRegion == nil else { return nil }
        return git.splitLayout.neighbour(of: region.leaf, toward: edge, in: tree.bounds, metrics: tree.metrics,
                                         hidden: git.hiddenLeaves).map(TabRegion.init)
    }

    /// Whether `region` is big enough on screen to be split in two on
    /// `edge`, each half keeping the least a split is laid out at. Out of
    /// sight (zoomed away, or hidden), there is nothing to measure and it
    /// may.
    ///
    /// Measured in the layout without its zoom, as `room(toSplit:on:)` does,
    /// since a drop on a zoomed split ends the zoom and halves the split at
    /// the size it has then, not at the whole area it fills now.
    func hasRoom(toSplit region: TabRegion, on edge: SplitLayout.Edge) -> Bool {
        guard let frame = unzoomedFrame(of: region) else { return true }
        return hasRoom(toSplit: frame, on: edge)
    }

    /// Where `region` is in the layout without its zoom, with the splits
    /// that are hidden left out; nil when it is not in it.
    private func unzoomedFrame(of region: TabRegion) -> NSRect? {
        git.splitLayout.frames(in: tree.bounds, metrics: tree.metrics, hidden: git.hiddenLeaves).leaves[region.leaf]
    }

    /// Where a split asked of `region` on `edge` finds its room: in the
    /// split itself when it is big enough to be two; in the row or column it
    /// is a part of when that can give the new split an equal share with
    /// nobody left under the least a split is laid out at (⌘D in a side
    /// split 280 points wide used to do nothing but beep); and nowhere
    /// otherwise.
    ///
    /// Measured in the layout without its zoom, which is the one the split
    /// is made in: a split made by a key ends the zoom. Measured on screen,
    /// the zoomed split was the whole area and always had room, and a side
    /// split 300 points wide was halved into two of about 145.
    func room(toSplit region: TabRegion, on edge: SplitLayout.Edge) -> GitPanelModel.SplitRoom {
        let before = git.splitLayout.frames(in: tree.bounds, metrics: tree.metrics, hidden: git.hiddenLeaves).leaves
        // Not in the layout: nothing to measure, and it may.
        guard let here = unzoomedFrame(of: region) else { return .halves }
        if hasRoom(toSplit: here, on: edge) { return .halves }
        var layout = git.splitLayout
        let standIn = SplitLayout.Leaf.pane(UUID())
        guard layout.insertSpreading(standIn, beside: region.leaf, on: edge) else { return .none }
        let after = layout.frames(in: tree.bounds, metrics: tree.metrics, hidden: git.hiddenLeaves).leaves
        let minimum = tree.metrics.minimum
        // Everybody the new split took from, and the new split: none of
        // them under the minimum along the way it was made.
        for (leaf, frame) in after where before[leaf] != frame {
            let extent = edge.axis == .row ? frame.width : frame.height
            let least = edge.axis == .row ? minimum.width : minimum.height
            if extent < least { return .none }
        }
        return .spreads
    }

    /// The same for a layout that is not the one laid out here: another
    /// session of this window, or this one's with a zoom over it (`wortel
    /// split`, which splits what nobody is looking at). Measured in the area
    /// as it is now. That is near enough for a session whose splits differ,
    /// and it is what keeps a script from halving a session out of sight
    /// until nothing in it can be used.
    func hasRoom(toSplit region: TabRegion, on edge: SplitLayout.Edge, in layout: SplitLayout,
                 hidden: Set<SplitLayout.Leaf> = []) -> Bool {
        guard let frame = layout.frames(in: tree.bounds, metrics: tree.metrics, hidden: hidden).leaves[region.leaf]
        else { return true }
        return hasRoom(toSplit: frame, on: edge)
    }

    private func hasRoom(toSplit frame: NSRect, on edge: SplitLayout.Edge) -> Bool {
        let minimum = tree.metrics.minimum
        // A leaf's row is part of it: what is split is the page under it.
        return edge.axis == .row ? frame.width >= minimum.width * 2 + tree.metrics.gap
                                 : frame.height >= minimum.height * 2 + tree.metrics.gap
    }

    /// The size `session`'s own terminal has when the session is shown in
    /// this window as the window is now: its main row's page in its own
    /// tree. Behind a zoom on another split, the size it has when the zoom
    /// ends, which is the next size it is shown at: nil there sent the
    /// terminal back to following the window by the whole of its change,
    /// and it was resized again when the zoom ended. For a terminal out of
    /// sight to follow a window resize with (`SurfaceView.sizeWhenShown`).
    func terminalSize(of session: Session) -> NSSize? {
        let workspace = session.workspace
        let bounds = tree.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let frame: NSRect?
        switch workspace.zoomed {
        case .main?: frame = bounds
        default: frame = workspace.layout.frames(in: bounds, metrics: tree.metrics,
                                                 hidden: workspace.hiddenLeaves).leaves[.main]
        }
        guard let frame else { return nil }
        let row = frame.minY < 0.5 ? Chrome.titlebarHeight : SplitLeafView.rowHeight
        return NSSize(width: frame.width, height: max(0, frame.height - row))
    }

    /// The view of a split, for the edge flash.
    func view(of region: TabRegion) -> NSView? {
        leafView(of: region.leaf)
    }

    /// Which split a view is in, if it is in one.
    func region(containing descendant: NSView) -> TabRegion? {
        for entry in tree.visibleLeaves {
            if let leaf = leafView(of: entry.leaf), descendant.isDescendant(of: leaf) { return TabRegion(entry.leaf) }
        }
        return nil
    }

    #if DEBUG
    /// For the probes: the tree itself.
    var treeView: SplitTreeView { tree }
    #endif

    // MARK: The main row

    private func sync() {
        syncTree()
        let session = home.selected
        // Zoomed on another split, the main row is out of sight: nothing of
        // it shows, and its terminal is treated as covered.
        let showing = git.isShowing(.main)
        let active = git.activeMainTab
        // A pane, a file, a web page: anything that isn't a terminal is drawn
        // by the SwiftUI cover.
        let showsPane = showing && (active?.isPage ?? false)
        paneHost.view.isHidden = !showsPane
        // Only for the session the panel is pointed at: see `SideColumnController.sync`.
        let surface = showing && git.session === session
            ? active?.terminalID.flatMap { session?.ensureSideSurface($0, runtime: runtime) } : nil
        tabHost.show(surface, focusRequest: git.mainFocusRequest,
                     handBack: { [weak git] in git?.handBackKeyboard(from: .main) })
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
    /// Out of sight behind a zoomed split is covered too, and the keyboard
    /// goes to that split. A switch to a hibernated terminal shows it after
    /// this has run, and the host asks the same of `GitPanelModel.focusCover`
    /// itself then (`TerminalHostViewController.swap`).
    private func keepKeyboardOffCoveredTerminal() {
        let hidden = !git.isShowing(.main)
        guard git.activeMainTab != nil || hidden, let window = view.window,
              let main = home.selected?.surfaceView, window.firstResponder === main else { return }
        window.makeFirstResponder(nil)
        git.focusCover()
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
            case .blank?:
                if let tab { NewTabPage(git: git, tab: tab, region: region).id(tab) }
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
