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
        static let maximum: CGFloat = 760
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

    init(runtime: GhosttyRuntime, manager: SessionManager, git: GitPanelModel,
         files: FileTreeModel, titleBars: TitleBarController) {
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
        let bottomPane = BottomPaneController(runtime: runtime, manager: manager, git: git)
        let workspace = TerminalWorkspaceController(
            top: NSHostingController(rootView: DetailPane(
                runtime: runtime, manager: manager, git: git, files: files)),
            bottom: bottomPane, git: git)
        let detail = ChromePaneController(
            bar: titleBars.mainBar, content: workspace, bodyColor: Chrome.content)
        let contentItem = NSSplitViewItem(viewController: detail)
        contentItem.minimumThickness = 80
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        addSplitViewItem(contentItem)

        // The side column. collapseBehavior keeps the *window* still when the
        // column opens/closes, resizing the terminal instead.
        let inspectorContent = NSHostingController(rootView: InspectorContainer(
            runtime: runtime, manager: manager, git: git, files: files))
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

        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // Set last: NSSplitView restores saved divider positions the moment the
        // name is assigned, so every item has to exist by then. It carries the
        // sidebar's width; the column's it also carries but does not get to
        // decide, because that one is per session (see `viewDidLayout`).
        splitView.autosaveName = "main-split"
        titleBars.mainBar.setSidebarCollapsed(sidebarItem.isCollapsed)

        observeInspector()

        // Tab drags: both tab rows, and the two panes a tab can be dropped on.
        let drag = TabDragController()
        drag.strips = [
            .init(strip: titleBars.sideBar.strip, region: .side),
            .init(strip: bottomPane.bar.strip, region: .bottom),
        ]
        drag.terminalArea = { [weak workspace] in
            guard let view = workspace?.terminalView, view.window != nil else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        drag.columnArea = { [weak self, weak inspectorContent] in
            guard let self, self.git.isVisible, let view = inspectorContent?.view,
                  view.window != nil, view.bounds.width > 1 else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        drag.onDrop = { [weak self] tab, region, index in
            self?.git.move(tab, to: region, at: index)
        }
        let forward: (SideTabStrip.DragPhase, SideTab, NSView, NSPoint) -> Void = { [weak drag] phase, tab, view, point in
            drag?.handle(phase, tab: tab, view: view, point: point)
        }
        titleBars.sideBar.strip.onDrag = forward
        bottomPane.bar.strip.onDrag = forward
        tabDrag = drag
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
            guard let self, let item = self.inspectorItem, !item.isCollapsed else { return }
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
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyInspectorVisibility()
                self.observeInspector()
            }
        }
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
            NSAnimationContext.runAnimationGroup { _ in
                inspectorItem.animator().isCollapsed = !show
            } completionHandler: { [weak self] in
                // Delivered on the main thread, but as a nonisolated closure.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.suspendWidthCapture = false
                    if show { self.applyInspectorWidth() }
                }
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
        splitView.setPosition(total - target - splitView.dividerThickness,
                              ofDividerAt: splitViewItems.count - 2)
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
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let total = splitView.bounds.width
        let windowResized = total != lastSplitWidth
        lastSplitWidth = total
        captureInspectorWidth(windowResized: windowResized)

        titleBars.mainBar.setSidebarCollapsed(sidebarItem?.isCollapsed ?? false)

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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed.toggle()
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
