import AppKit
import SwiftUI
import Observation

/// The window's content: two real split panes, the session sidebar and
/// everything beside it (`MainAreaController`, the tree of splits).
///
/// There were three: the side column was a pane of its own here, and the
/// strip one inside the middle pane. Since 2026-11-26 both are splits of the
/// tree like any other, so what is left for AppKit's split view is the one
/// thing that isn't a split, the sidebar.
///
/// This is deliberately AppKit rather than SwiftUI's `NavigationSplitView`:
/// owning the `NSSplitViewController` buys back `minimumThickness`,
/// `holdingPriority` and `collapseBehavior`. The items are plain ones, not
/// the `.sidebar` behavior. That supplies the system's Liquid Glass material,
/// and the look here is the ChatGPT app's instead: flat pages in a grey
/// frame, hairlines between them. Each pane paints its own colour, and
/// collapsing the sidebar is implemented here because AppKit's only acts on a
/// `.sidebar` item.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    /// How wide the side split opens. A split's size is a share of the area
    /// once it is there (a window resize keeps every split's share), so this
    /// is only where it starts: the width its session last dragged it to, or
    /// for a session that never has, the last width chosen anywhere, so a new
    /// session inherits your habit. That default is app state (UserDefaults);
    /// the session's own width is session state (sessions.json).
    enum ColumnWidth {
        static let minimum: CGFloat = 260
        static let maximum: CGFloat = 10_000
        private static let fallback: CGFloat = 440
        private static let key = "sideColumn.lastWidth"

        static var lastChosen: CGFloat {
            let stored = UserDefaults.standard.double(forKey: key)
            return stored > 0 ? CGFloat(stored) : fallback
        }

        static func remember(_ width: CGFloat) {
            UserDefaults.standard.set(Double(width), forKey: key)
        }

        @MainActor static func width(for session: Session?) -> CGFloat {
            let width = session?.sideColumnWidth.map { CGFloat($0) } ?? lastChosen
            return min(max(width, minimum), maximum)
        }
    }

    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    /// The window's share of the sessions: whose session this split shows.
    let home: SessionWindow
    private let git: GitPanelModel
    private let files: FileTreeModel

    private let titleBars: TitleBarController
    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    /// Everything beside the sidebar (`MainAreaController`).
    private(set) weak var mainArea: MainAreaController?
    private weak var blinkView: NSView?

    private let previewTabs: PreviewTabs

    init(runtime: GhosttyRuntime, manager: SessionManager, home: SessionWindow, git: GitPanelModel,
         files: FileTreeModel, titleBars: TitleBarController, previewTabs: PreviewTabs) {
        self.previewTabs = previewTabs
        self.runtime = runtime
        self.manager = manager
        self.home = home
        self.git = git
        self.files = files
        self.titleBars = titleBars
        super.init(nibName: nil, bundle: nil)
        // Before the view loads: the split view is the controller's to replace
        // only until it's been used. Hairline dividers in the chrome's colour.
        let split = ChromeSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The split view's autosave: the sidebar's width. A name of its own
    /// since the window went from three panes to two, so a build with three
    /// (they share the defaults) and this one never read each other's.
    private static let autosave = "window-split"

    override func viewDidLoad() {
        super.viewDidLoad()

        // NSSplitView takes each pane's starting width from its view's frame, so
        // the frame is the only place to state a default (the autosave below wins
        // on every launch after the first drag).
        // No sizing from its SwiftUI content: the split view decides how big
        // the sidebar is. By default a hosting controller turns its content's
        // minimum and ideal size into constraints, and once the sidebar held a
        // stack of rows (the Needs You section) rather than only a scrolling
        // list, those fought the split and squeezed the terminal to a few
        // columns in a corner: every session came up blank.
        let sidebarHost = NSHostingController(rootView: SidebarPane(manager: manager, home: home))
        sidebarHost.sizingOptions = []
        let sidebar = ChromePaneController(
            bar: titleBars.sidebarBar,
            content: sidebarHost,
            bodyColor: Chrome.sidebar,
            colorsUnderBar: true)
        sidebar.view.setFrameSize(NSSize(width: Self.startingSidebarWidth, height: sidebar.view.frame.height))
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        self.sidebarItem = sidebarItem
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        // Everything else. The lower holding priority, so it's the pane that
        // absorbs a sidebar drag and every window resize: the sidebar keeps
        // its width, the splits share what is left. An 80pt floor keeps the
        // window shrinkable; ghostty reflows to whatever width it gets, so a
        // narrow terminal is cramped rather than broken.
        let bottomPane = BottomPaneController(runtime: runtime, manager: manager, home: home, git: git,
                                              files: files, previewTabs: previewTabs)
        let sideColumn = SideColumnController(
            runtime: runtime, manager: manager, home: home, git: git, files: files, previewTabs: previewTabs)
        let mainArea = MainAreaController(
            terminal: TerminalPaneController(runtime: runtime, manager: manager, home: home, git: git, files: files),
            side: sideColumn, bottom: bottomPane, titleBars: titleBars,
            runtime: runtime, manager: manager, home: home, git: git, files: files, previewTabs: previewTabs)
        self.mainArea = mainArea
        let contentItem = NSSplitViewItem(viewController: mainArea)
        contentItem.minimumThickness = 80
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        self.contentItem = contentItem
        addSplitViewItem(contentItem)
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(270)

        // Set last: NSSplitView restores saved divider positions the moment the
        // name is assigned, so every item has to exist by then.
        splitView.autosaveName = Self.autosave
        updateLeadingInsets()
        mainArea.onPlaced = { [weak self] in self?.updateLeadingInsets() }

        // Tab drags: every row, and every split a tab can be dropped on.
        let drag = TabDragController()
        drag.paneStrips = { [weak mainArea] in
            (mainArea?.rows ?? []).map { .init(strip: $0.strip, region: $0.region) }
        }
        drag.paneDrop = { [weak mainArea] point, tab in mainArea?.paneDrop(at: point, dragging: tab) }
        drag.hasRoom = { [weak mainArea] region, edge in mainArea?.hasRoom(toSplit: region, on: edge) ?? true }
        drag.tabCount = { [weak self] region in self?.git.tabs(in: region).count ?? 0 }
        drag.regionOf = { [weak self] tab in self?.git.session?.workspace.region(of: tab) }
        // ⌘D, ⇧⌘D and Split Right / Split Down in any menu: where the new
        // split's room comes from, and the system's sound where there is
        // none to be had.
        git.roomToSplit = { [weak mainArea] region, edge in
            let room = mainArea?.room(toSplit: region, on: edge) ?? .halves
            if room == .none { NSSound.beep() }
            return room
        }
        drag.onDrop = { [weak self] tab, region, index in
            self?.git.move(tab, to: region, at: index)
        }
        drag.onSplit = { [weak self] tab, region, edge in
            self?.git.splitDropped(tab, beside: region, on: edge, isNew: false)
        }
        drag.onFileDrop = { [weak self] urls, region, index in
            self?.openDroppedFiles(urls, region, index)
        }
        drag.onFileSplit = { [weak self] urls, region, edge in self?.openSplitFiles(urls, region, edge) }
        drag.onTearOff = { [weak self] tab, topLeft in
            guard case .file(let path) = tab else { return }
            self?.previewTabs.openInWindow(path, at: topLeft)
        }
        // A tab dragged out of this window: the other windows' rows, asked
        // by the app, which knows them.
        drag.elsewhere = { [weak self] phase, tab, dragged, point, picture in
            self?.tabDragElsewhere(phase, tab, dragged, point, picture) ?? .nothing
        }
        let forward: (SideTabStrip.DragPhase, SideTab, NSView, NSPoint) -> Void = { [weak drag] phase, tab, view, point in
            drag?.handle(phase, tab: tab, view: view, point: point)
        }
        // A split's row is made with its split, so each is given the drag
        // when the rows change.
        let wireRows: () -> Void = { [weak mainArea] in
            for strip in mainArea?.allStrips ?? [] { strip.onDrag = forward }
        }
        mainArea.onRowsChanged = wireRows
        wireRows()
        tabDrag = drag
    }

    /// Where the sidebar starts the first time this window's split is laid
    /// out with nothing saved for it: the width the three-pane window had
    /// saved, so going to two panes doesn't reset it, or 220.
    private static var startingSidebarWidth: CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "NSSplitView Subview Frames \(autosave)") == nil,
              let old = defaults.stringArray(forKey: "NSSplitView Subview Frames main-split")?.first
        else { return 220 }
        let fields = old.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count > 2, let width = Double(fields[2]), width >= 180, width <= 400 else { return 220 }
        return CGFloat(width)
    }

    /// A preview window dragged by its row, the pointer at `screenPoint`: over
    /// one of this window's tab rows, and with nothing else in between, it
    /// shows as the tab it would become (TabDragController.handleDock).
    /// Returns the row and place it's over; on `.ended`, where the tab goes.
    func dockWindowDrag(_ phase: TabDragController.DockPhase, url: URL,
                        dragged: NSWindow, at screenPoint: NSPoint) -> (region: TabRegion, index: Int)? {
        let tab = SideTab.file(url.resolvingSymlinksInPath().standardizedFileURL.path)
        return dock(phase, tab: tab, dragged: dragged, at: screenPoint, picture: nil)
    }

    /// A tab from somewhere else over this window: a preview window dragged
    /// by its row, or a file or browser tab dragged out of another window.
    /// Shows where it would land in this window's rows; on `.ended`, says
    /// where it goes. `picture` is the tab as it will look, or nil to draw
    /// it as this window's session would.
    func dock(_ phase: TabDragController.DockPhase, tab: SideTab, dragged: NSWindow?,
              at screenPoint: NSPoint, picture: NSImage?) -> (region: TabRegion, index: Int)? {
        guard let window = view.window, let tabDrag else { return nil }
        // The window under the pointer, looking past the one being dragged,
        // which is under the pointer by definition.
        let under = NSWindow.windowNumber(at: screenPoint,
                                          belowWindowWithWindowNumber: dragged?.windowNumber ?? 0)
        guard phase != .cancelled, under == window.windowNumber else {
            return tabDrag.handleDock(.cancelled, tab: tab, window: window, point: .zero) { nil }
        }
        let point = window.convertPoint(fromScreen: screenPoint)
        return tabDrag.handleDock(phase, tab: tab, window: window, point: point) { [home] in
            if let picture { return picture }
            let item = TitleBarController.stripItem(for: tab, in: home.selected)
            return SideTabStrip.picture(of: item, in: window)
        }
    }

    /// Set by AppDelegate: the other windows, for a tab dragged out of this one
    /// (`TabDragController.elsewhere`).
    var tabDragElsewhere: (TabDragController.DockPhase, SideTab, NSWindow?, NSPoint, NSImage?)
        -> TabDragController.Elsewhere = { _, _, _, _, _ in .nothing }

    /// A file dragged out of a list, over this window: the tab drag's landing
    /// spots, at `point` in this window. AppDelegate says which window it is
    /// over (`RowClickCatcher.onFileDrag`).
    func fileDrag(_ phase: RowClickCatcher.FileDragPhase, urls: [URL], at point: NSPoint) {
        guard let window = view.window else { return }
        tabDrag?.handleFileDrag(phase, urls: urls, window: window, point: point)
    }

    /// Resolves tab drags across every row. Held for the window's life.
    private var tabDrag: TabDragController?

    #if DEBUG
    /// For `SplitProbe`: a tab let go at a point in the window.
    func probeDrop(_ tab: SideTab, at point: NSPoint) -> String {
        tabDrag?.probeDrop(tab, at: point) ?? "no drag controller"
    }
    #endif

    /// Open files dropped on a row or a split, from `index` in that row: set by
    /// AppDelegate, which decides what each file's tab shows (its diff).
    var openDroppedFiles: ([URL], TabRegion, Int) -> Void = { _, _, _ in }
    /// Open files dropped on an edge of a split, in a split made there: set
    /// by AppDelegate, as `openDroppedFiles` is.
    var openSplitFiles: ([URL], TabRegion, SplitLayout.Edge) -> Void = { _, _, _ in }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Every pass, not only on a resize notification: the split view lays
        // its panes out without one at launch, and the sidebar's controls
        // were left where the zero-width panes before it had put them.
        updateLeadingInsets()
    }

    // MARK: - A session switch

    /// Show `session`: its splits first, then its terminal.
    ///
    /// Called in the same turn as the selection (`SessionManager.onSwitch`),
    /// because what follows a selection by itself is two things a turn apart:
    /// SwiftUI shows the new session's terminal in its next update, and the
    /// observers lay the splits out in the turn after. For that turn the new
    /// terminal was laid out in the session before's arrangement and then
    /// took its own, in front of you: drawn at the wrong size and then a
    /// jump, sometimes twice (722, 787, back to 722), and its program redrew
    /// for each.
    ///
    /// Resizes are held for all of it, so the terminal being left keeps its
    /// size while the layout moves under it and the one arriving takes its
    /// new size once, when the hold is released. The observers still run a
    /// turn later and find nothing left to do.
    func show(_ session: Session) {
        guard isViewLoaded, view.window != nil, session.preparation == nil,
              let host = TerminalHostViewController.main(in: view.window)
        else { return }
        SurfaceView.holdResizes()
        defer { SurfaceView.releaseResizes() }
        git.focus(session: session)
        files.focus(session: session)
        // The splits' frames and the main row's own layout only. The sidebar
        // and the pages of the other splits lay out with everything else
        // when the frame is drawn; the whole window laid out here as well
        // made a switch up to 130 ms slower (measured).
        mainArea?.applyNow()
        host.show(session, runtime: runtime)
        // The rest of the window lays out when the frame is drawn, after
        // this returns and the hold with it. If that moves the terminal's
        // area again, the terminal follows: by its own area being laid out
        // (`TerminalHostViewController.viewDidLayout`), and by the one check
        // the hold's release has already asked for.
    }

    // MARK: - The sidebar's controls

    /// Where the sidebar's controls go, and how much room the row under them
    /// has to make. They are one set laid over the whole titlebar
    /// (`WindowControls`): the toggle stays beside the traffic lights and
    /// the arrows ride the sidebar's edge. Whichever titlebar row starts
    /// under them makes room by its `leadingClearance`: the leftmost split
    /// along the top, whatever it holds.
    private func updateLeadingInsets() {
        guard let sidebarItem, let contentItem else { return }
        let controls = titleBars.windowControls
        // Not before the controls and the panes share a window (viewDidLoad
        // runs before BackdropController adds the controls): converting
        // between unrelated views gives nothing meaningful.
        guard let window = controls.window, window === splitView.window else { return }
        // In the controls' coordinates, through the window: what a pane's
        // frame is relative to is the split view's business.
        let content = contentItem.viewController.view
        let onScreen = !content.isHidden && content.frame.width > 0.5
        let edge = onScreen
            ? max(0, controls.convert(content.bounds, from: content).minX - splitView.dividerThickness)
            : controls.bounds.width
        let clearsTo = controls.place(sidebarEdge: edge, collapsed: sidebarItem.isCollapsed) + 8
        // And at the other end: the session's controls, over the end of
        // whichever row reaches under them.
        let sessionControls = controls.bounds.width - controls.trailingWidth
        for row in mainArea?.titlebarRows ?? [] {
            let minX = controls.convert(NSPoint(x: row.minX, y: 0), from: nil).x
            let maxX = controls.convert(NSPoint(x: row.maxX, y: 0), from: nil).x
            let clearance = max(0, clearsTo - minX)
            if abs(row.bar.leadingClearance - clearance) > 0.01 { row.bar.leadingClearance = clearance }
            let trailing = max(0, maxX - sessionControls)
            if abs(row.bar.trailingClearance - trailing) > 0.01 { row.bar.trailingClearance = trailing }
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        updateLeadingInsets()
    }

    // MARK: - Sidebar and dividers

    /// Whether the session sidebar is showing, for the menu's Show/Hide title.
    var isSidebarVisible: Bool { sidebarItem.map { !$0.isCollapsed } ?? true }

    /// ⌘⌥S and the titlebar's sidebar buttons. NSSplitViewController's own
    /// implementation only acts on an item with the `.sidebar` behavior, which
    /// this one deliberately isn't (see `viewDidLoad`).
    override func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem else { return }
        let collapsing = !sidebarItem.isCollapsed
        Motion.pane(opening: !collapsing) {
            sidebarItem.animator().isCollapsed = collapsing
        }
    }

    /// NSSplitViewController disables its own sidebar command when no item has
    /// the `.sidebar` behavior, which would grey out ⌘⌥S here.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// A one-point divider is hard to hit, so the grab area is wider than what's
    /// drawn: 4pt either side, the ChatGPT app's 16px handle in points.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                   forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return rect.insetBy(dx: -4, dy: 0)
    }
}

extension MainSplitViewController {
    /// Where the keyboard just went, said once: a thin accent edge around the
    /// split that comes up at once and fades over half a second, then nothing
    /// stays. The one focus treatment every split shares, for moves made from
    /// the keyboard (a click already shows where you are). A frame rather
    /// than a fill so nothing under it changes colour, and gone before it could
    /// be read as a state.
    ///
    /// Drawn *inside* the split and sized with it, not over the window at the
    /// frame it had: ⌘J moves the keyboard as the strip opens, and an edge
    /// placed once drew the main row at its old height. A split still too
    /// small to draw around, or not laid out yet, blinks a moment later.
    func blink(_ region: TabRegion, waited: Bool = false) {
        guard git.isShowing(region), let target = mainArea?.view(of: region), target.window != nil else { return }
        guard !target.isHiddenOrHasHiddenAncestor,
              target.bounds.width > 40, target.bounds.height > 40 else {
            if !waited {
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.opening) { [weak self] in
                    self?.blink(region, waited: true)
                }
            }
            return
        }
        blinkView?.removeFromSuperview()
        let blink = PassthroughView(frame: target.bounds.insetBy(dx: 1, dy: 1))
        blink.autoresizingMask = [.width, .height]
        blink.wantsLayer = true
        guard let layer = blink.layer else { return }
        layer.borderWidth = 2
        layer.cornerRadius = 6
        layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        layer.opacity = 0
        target.addSubview(blink, positioned: .above, relativeTo: nil)
        blinkView = blink

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.3, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                CAMediaTimingFunction(name: .linear),
                                CAMediaTimingFunction(name: .easeIn)]
        fade.duration = 0.6
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak blink] in blink?.removeFromSuperview() }
        layer.add(fade, forKey: "blink")
        CATransaction.commit()
    }

    /// Drawn over everything, clicked through.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Which split a point in the window is in, its row included. nil for
    /// the session list, which isn't a place with tabs, and for a divider
    /// between two splits: a press on that drags it, and you stay where you
    /// were.
    ///
    /// What a click anywhere in a split means for the keyboard commands: ⌘W,
    /// ⌘T and the rest act in the split you last clicked or typed in, and a
    /// web page, a pane or the file tree never report typing of their own.
    func region(at point: NSPoint) -> TabRegion? {
        guard let mainArea, !mainArea.isOnDivider(point) else { return nil }
        // Nor for the window's own controls, laid over the end of whichever
        // row is under them: a press on Split Right is not you going to the
        // split in the corner, and it would split that one instead of yours.
        let controls = titleBars.windowControls
        if let above = controls.superview, controls.hitTest(above.convert(point, from: nil)) != nil { return nil }
        return mainArea.paneDrop(at: point)?.region
    }
}
