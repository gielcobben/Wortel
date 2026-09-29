import AppKit
import SwiftUI
import Observation

/// The window's content: three real split panes — session sidebar, terminal,
/// side column — each wrapped with its own titlebar row (TitleBars.swift).
///
/// This is deliberately AppKit rather than SwiftUI's `NavigationSplitView` +
/// `.inspector`: an inspector is not a split pane (AppKit defines it as a
/// fixed-thickness panel that resizes the *window*), and owning the
/// `NSSplitViewController` buys back `minimumThickness`, `maximumThickness`,
/// `holdingPriority`, and `collapseBehavior` — which is what makes all three
/// panes independently resizable.
///
/// The items are plain ones, not the `.sidebar` / `.inspector` behaviors. Those
/// supply the system's Liquid Glass material, and the look here is the ChatGPT
/// app's instead: flat pages in a grey frame, hairlines between them. Each pane
/// paints its own colour (see ChromePaneController), and collapsing the sidebar
/// is implemented here because AppKit's only acts on a `.sidebar` item.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    /// How wide the side column is. **Per session, and the same for every tab
    /// in it.** It used to be per pane (a file tree and a diff want different
    /// widths), but with tabs that made the divider jump on every tab switch,
    /// which is exactly what makes tabs feel heavy. What does differ is the
    /// session: the one running a dev server beside an agent wants a wide
    /// column, the one you glance at Changes in doesn't.
    ///
    /// A session whose column has never been dragged opens at the last width
    /// chosen anywhere, so a new session inherits your habit. That default is
    /// app state (UserDefaults); the session's own width is session state
    /// (sessions.json).
    enum ColumnWidth {
        static let minimum: CGFloat = 260
        /// No fixed cap: the column may take everything but the terminal's
        /// `terminalMinimum`, as ChatGPT's content pane may take everything but
        /// 320pt of chat. That is how a diff gets the window and the agent a
        /// narrow strip beside it, without the terminal ever leaving its area.
        static let maximum: CGFloat = 10_000
        static let terminalMinimum: CGFloat = 320
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
    private let git: GitPanelModel
    private let files: FileTreeModel

    private var inspectorItem: NSSplitViewItem!
    /// Guards against the observer→collapse→observer feedback loop.
    private var syncingInspector = false
    /// Whose width the column had at the last apply, so a session switch can be
    /// told from a mere visibility change and given that session's width.
    private var lastOwner: UUID?
    /// The column width we last set or observed, so opening the column can
    /// tell "same width as last time" (animate) from "this session's column is
    /// a different size" (snap — see `applyInspectorVisibility`).
    private var lastAppliedWidth: CGFloat = 0
    /// The split view's own width at the last resize notification. A divider
    /// drag changes the inspector's width while this stays put; a *window*
    /// resize changes both — and only the first is the user stating a preference.
    private var lastSplitWidth: CGFloat = 0
    /// Held while we're the ones moving the divider (including for the length of
    /// a collapse animation), so the intermediate widths that produces are never
    /// mistaken for a drag and saved.
    private var suspendWidthCapture = false
    /// The pending "the drag has settled, keep this width" commit.
    private var widthCaptureWork: DispatchWorkItem?

    private let titleBars: TitleBarController
    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!

    private let previewTabs: PreviewTabs

    init(runtime: GhosttyRuntime, manager: SessionManager, git: GitPanelModel,
         files: FileTreeModel, titleBars: TitleBarController, previewTabs: PreviewTabs) {
        self.previewTabs = previewTabs
        self.runtime = runtime
        self.manager = manager
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

    override func viewDidLoad() {
        super.viewDidLoad()

        // Every pane is a plain split item wrapped with its own titlebar row
        // (see TitleBars.swift). Not the `.sidebar` / `.inspector` behaviors:
        // those bring the system's Liquid Glass material, and the look here is
        // flat pages in a grey frame. What they did for sizing and collapsing is
        // stated on the items directly.
        //
        // NSSplitView takes each pane's starting width from its view's frame, so
        // the frame is the only place to state a default (the autosave below wins
        // on every launch after the first drag).
        let sidebar = ChromePaneController(
            bar: titleBars.sidebarBar,
            content: NSHostingController(rootView: SidebarPane(manager: manager)),
            bodyColor: Chrome.sidebar)
        sidebar.view.setFrameSize(NSSize(width: 220, height: sidebar.view.frame.height))
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        self.sidebarItem = sidebarItem
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        // Terminal. Lowest holding priority of the three, so it's the pane that
        // absorbs every divider drag and every window resize — the sides keep
        // their width, the terminal gives. An 80pt floor keeps the window
        // shrinkable; ghostty reflows to whatever width it gets, so a narrow
        // terminal is cramped rather than broken.
        let bottomPane = BottomPaneController(runtime: runtime, manager: manager, git: git,
                                              files: files, previewTabs: previewTabs)
        let mainArea = MainAreaController(
            terminal: NSHostingController(rootView: DetailPane(
                runtime: runtime, manager: manager, git: git, files: files)),
            runtime: runtime, manager: manager, git: git, files: files, previewTabs: previewTabs)
        let workspace = TerminalWorkspaceController(top: mainArea, bottom: bottomPane, git: git)
        let detail = ChromePaneController(
            bar: titleBars.mainBar, content: workspace, bodyColor: Chrome.content)
        let contentItem = NSSplitViewItem(viewController: detail)
        contentItem.minimumThickness = 80
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        self.contentItem = contentItem
        addSplitViewItem(contentItem)

        // The side column. collapseBehavior keeps the *window* still when the
        // column opens/closes, resizing the terminal instead.
        let inspectorContent = NSHostingController(rootView: InspectorContainer(
            runtime: runtime, manager: manager, git: git, files: files, previewTabs: previewTabs))
        let inspector = ChromePaneController(
            bar: titleBars.sideBar, content: inspectorContent, bodyColor: Chrome.content)
        let width = ColumnWidth.width(for: manager.selected)
        inspector.view.setFrameSize(NSSize(width: width, height: inspector.view.frame.height))
        lastOwner = manager.selectedID
        lastAppliedWidth = width
        let item = NSSplitViewItem(viewController: inspector)
        item.minimumThickness = ColumnWidth.minimum
        item.maximumThickness = ColumnWidth.maximum
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.holdingPriority = NSLayoutConstraint.Priority(260)
        item.isCollapsed = !git.isVisible
        addSplitViewItem(item)
        inspectorItem = item

        // The highest of the three: whatever else moves (the column opening,
        // moving sides, a window resize), the sidebar keeps its width. At the
        // column's own priority it would sometimes absorb part of a change.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(270)

        // Set last: NSSplitView restores saved divider positions the moment the
        // name is assigned, so every item has to exist by then. It carries the
        // sidebar's width; the column's it also carries but does not get to
        // decide, because that one is per session (see `viewDidLayout`).
        splitView.autosaveName = "main-split"
        updateLeadingInsets()

        observeInspector()

        // Tab drags: both tab rows, and the two panes a tab can be dropped on.
        let drag = TabDragController()
        drag.strips = [
            .init(strip: titleBars.sideBar.strip, region: .side),
            .init(strip: titleBars.mainBar.strip, region: .main),
            .init(strip: bottomPane.bar.strip, region: .bottom),
        ]
        drag.terminalArea = { [weak workspace] in
            guard let view = workspace?.terminalView, view.window != nil,
                  !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 1 else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        drag.columnLeading = { [weak self] in self?.git.columnLeading ?? false }
        drag.bottomArea = { [weak self, weak bottomPane] in
            guard let self, self.git.bottomVisible, let view = bottomPane?.view,
                  view.window != nil, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.height > 1 else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        drag.onSwap = { [weak self] tab, leading in
            if tab != .session { self?.bringIntoColumn(tab) }
            self?.git.setColumnLeading(leading)
        }
        drag.columnArea = { [weak self, weak inspectorContent] in
            guard let self, self.git.isVisible, let view = inspectorContent?.view,
                  view.window != nil, view.bounds.width > 1 else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        drag.onDrop = { [weak self] tab, region, index in
            self?.git.move(tab, to: region, at: index)
        }
        titleBars.mainBar.strip.onDrag = { [weak drag] phase, tab, view, point in
            drag?.handle(phase, tab: tab, view: view, point: point)
        }
        let forward: (SideTabStrip.DragPhase, SideTab, NSView, NSPoint) -> Void = { [weak drag] phase, tab, view, point in
            drag?.handle(phase, tab: tab, view: view, point: point)
        }
        titleBars.sideBar.strip.onDrag = forward
        bottomPane.bar.strip.onDrag = forward
        tabDrag = drag
    }

    /// A tab dropped somewhere that means "the column": already there, it
    /// comes to the front; from the bottom strip, it moves in.
    private func bringIntoColumn(_ tab: SideTab) {
        if git.tabs.contains(tab) {
            git.select(tab)
        } else {
            git.move(tab, to: .side, at: .max)
        }
    }

    /// Resolves tab drags across both tab rows. Held for the window's life.
    private var tabDrag: TabDragController?

    /// The autosave restore above happens before the split view has a width, and
    /// it restores one column width for every session. Take the column back on
    /// the first real layout pass and give it the selected session's width.
    private var didApplyInitialWidth = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialWidth, splitView.bounds.width > 0 else { return }
        didApplyInitialWidth = true
        lastSplitWidth = splitView.bounds.width
        // A turn later, deliberately: NSSplitView applies its autosaved divider
        // positions during this same layout pass, and the session's width is the
        // one that has to win. Doing it inline is a race with that restore.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The restored session's side and full view, which no change
            // notification will ever announce: they were already true at launch.
            self.applyLayout()
            guard let item = self.inspectorItem, !item.isCollapsed else { return }
            self.applyInspectorWidth()
        }
    }

    // MARK: - Inspector visibility

    /// Mirror the inspector's want-to-be-open state onto the split item. The
    /// column is up when the git panel is visible *or* a markdown preview is
    /// open — they share it. @Observable's tracking is one-shot, so the observer
    /// re-arms itself after each change.
    private func observeInspector() {
        withObservationTracking {
            _ = git.isVisible
            // The width is the session's, so a session switch has to reach here
            // even when the column stays up on both sides of it.
            _ = manager.selectedID
            _ = git.columnLeading
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyLayout()
                self.observeInspector()
            }
        }
    }

    /// Everything about the column's place in the window: which side it's on,
    /// whether it's up, and how wide.
    private func applyLayout() {
        applySide()
        applyInspectorVisibility()
        updateLeadingInsets()
    }

    /// Put the column on the side the session wants it: re-inserted at index 1
    /// (before the terminal) or at the end. Only when it changes, since moving
    /// a split item takes its views out of the window and puts them back.
    private func applySide() {
        guard let inspectorItem, let index = splitViewItems.firstIndex(of: inspectorItem) else { return }
        let wanted = git.columnLeading ? 1 : splitViewItems.count - 1
        guard index != wanted else { return }
        syncingInspector = true
        suspendWidthCapture = true
        removeSplitViewItem(inspectorItem)
        insertSplitViewItem(inspectorItem, at: git.columnLeading ? 1 : splitViewItems.count)
        syncingInspector = false
        DispatchQueue.main.async { [weak self] in
            self?.applyInspectorWidth()
            self?.suspendWidthCapture = false
        }
    }

    /// Room for the traffic lights goes to whichever pane is leftmost once the
    /// sidebar is collapsed: the terminal's row, or the column's when the
    /// column is on the leading side (or has the window, in full view).
    private func updateLeadingInsets() {
        let sidebarCollapsed = sidebarItem?.isCollapsed ?? false
        let firstVisible = splitViewItems.dropFirst().first { !$0.isCollapsed }
        let columnFirst = firstVisible === inspectorItem
        titleBars.mainBar.setSidebarCollapsed(sidebarCollapsed && !columnFirst)
        titleBars.sideBar.setSidebarCollapsed(sidebarCollapsed && columnFirst)
    }

    /// Show the column when either side wants it. Animate when the user asked —
    /// a markdown preview opening/closing (always a click) or the git panel being
    /// toggled — but snap when a *session switch* drove the git side, since
    /// switching sessions is meant to be instant and an animated collapse would
    /// reflow the terminal every frame.
    private func applyInspectorVisibility() {
        let show = git.isVisible
        let owner = manager.selectedID
        defer { lastOwner = owner }
        guard let inspectorItem else { return }

        guard inspectorItem.isCollapsed == show else {
            // Already up: a session switch is the only thing left to answer, and
            // it answers in width. A tab switch never gets here: it changes
            // neither of the two things observed.
            if show, owner != lastOwner { applyInspectorWidth() }
            return
        }

        // A collapsed item comes back at the thickness it had when it went away,
        // which belongs to whichever session had the column *then*. When that
        // isn't this session's width we snap instead of animating: sliding open
        // at the wrong width and then jumping to the right one reads as a
        // glitch, where an instant open just reads as instant.
        let target = ColumnWidth.width(for: manager.selected)
        let widthChanges = show && abs(target - lastAppliedWidth) > 1
        let animates = git.animatesVisibilityChange && !widthChanges

        syncingInspector = true
        suspendWidthCapture = true
        if animates {
            Motion.pane(opening: show) {
                inspectorItem.animator().isCollapsed = !show
            } completion: { [weak self] in
                guard let self else { return }
                self.suspendWidthCapture = false
                if show { self.applyInspectorWidth() }
            }
        } else {
            inspectorItem.isCollapsed = !show
            suspendWidthCapture = false
            if show { applyInspectorWidth() }
        }
        syncingInspector = false
    }

    // MARK: - Column width (per session)

    /// Give the column the width the selected session left it at.
    private func applyInspectorWidth() {
        guard let inspectorItem, !inspectorItem.isCollapsed else { return }
        let total = splitView.bounds.width
        guard total > 0, splitViewItems.count >= 2 else { return }

        let target = ColumnWidth.width(for: manager.selected)
        guard abs(target - inspectorItem.viewController.view.frame.width) > 0.5 else {
            lastAppliedWidth = target
            return
        }
        suspendWidthCapture = true
        guard let index = splitViewItems.firstIndex(of: inspectorItem) else { return }
        if index == splitViewItems.count - 1 {
            // Trailing: the divider before it sits the column's width from the end.
            splitView.setPosition(total - target - splitView.dividerThickness,
                                  ofDividerAt: index - 1)
        } else {
            // Leading: the divider after it sits the column's width past its start.
            let start = inspectorItem.viewController.view.frame.minX
            splitView.setPosition(start + target, ofDividerAt: index)
        }
        lastAppliedWidth = target
        // Cleared a turn later: the resize notification this provokes may not
        // arrive until the next layout pass, and it must not be read as a drag.
        DispatchQueue.main.async { [weak self] in self?.suspendWidthCapture = false }
    }

    /// Record the width the user just dragged the column to, on the session it
    /// was dragged in. Only a *divider* drag counts: a window resize moves the split view's
    /// own width, and squeezing the terminal to its floor is the window telling
    /// the inspector what to do, not the user telling us what they want.
    ///
    /// Committed once the drag settles rather than on every frame of it, for one
    /// reason: dragging the divider to the edge is how you close the panel, and
    /// the last width before it goes is the minimum — saving that would reopen
    /// the column pinned shut. A drag that ends collapsed records nothing.
    private func captureInspectorWidth(windowResized: Bool) {
        guard !windowResized, !suspendWidthCapture,
              let inspectorItem, !inspectorItem.isCollapsed else { return }
        let width = inspectorItem.viewController.view.frame.width
        guard width > 1, abs(width - lastAppliedWidth) > 1 else { return }
        let session = manager.selected
        widthCaptureWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, session.id == self.manager.selectedID,
                  let item = self.inspectorItem, !item.isCollapsed else { return }
            let settled = item.viewController.view.frame.width
            guard settled > 1 else { return }
            self.lastAppliedWidth = settled
            session.sideColumnWidth = Double(settled)
            ColumnWidth.remember(settled)
            self.manager.sessionStateChanged()
        }
        widthCaptureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// The panel can also be collapsed by dragging its divider to the edge, which
    /// bypasses GitPanelModel entirely — reflect that back so the menu item's
    /// Show/Hide title and the persisted state don't drift out of sync.
    /// The column may grow until the terminal is `terminalMinimum` wide. Stated
    /// as the item's maximum, so a divider drag stops there by itself.
    private func updateColumnMaximum() {
        guard let inspectorItem else { return }
        let sidebar = (sidebarItem?.isCollapsed ?? true) ? 0 : (sidebarItem?.viewController.view.frame.width ?? 0)
        let room = splitView.bounds.width - sidebar - ColumnWidth.terminalMinimum
            - splitView.dividerThickness * 2
        let maximum = max(ColumnWidth.minimum, room)
        if abs(inspectorItem.maximumThickness - maximum) > 0.5 {
            inspectorItem.maximumThickness = maximum
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        updateColumnMaximum()
        let total = splitView.bounds.width
        let windowResized = total != lastSplitWidth
        lastSplitWidth = total
        captureInspectorWidth(windowResized: windowResized)

        updateLeadingInsets()

        guard !syncingInspector, let inspectorItem else { return }
        let visible = !inspectorItem.isCollapsed
        guard visible != git.isVisible else { return }
        git.isPresented = visible
    }

    // MARK: - Sidebar and dividers

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
