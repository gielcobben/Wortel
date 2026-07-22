import AppKit
import SwiftUI
import Observation

/// The window's content: three real split panes — session sidebar, terminal,
/// source-control inspector.
///
/// This is deliberately AppKit rather than SwiftUI's `NavigationSplitView` +
/// `.inspector`. That pairing gives the same *look* for free (Icon Composer is
/// built exactly that way), but an inspector is not a split pane: AppKit defines
/// it as a fixed-thickness auxiliary panel that holds its width and resizes the
/// *window* instead of its siblings. That makes the window jump when the panel is
/// dragged, and folds the terminal's current width into the window's resize
/// floor. Owning the `NSSplitViewController` buys back `minimumThickness`,
/// `maximumThickness`, `holdingPriority`, and `collapseBehavior` — which is what
/// makes all three panes independently resizable — while `.sidebar`/`.inspector`
/// *behaviors* still supply the system material (Liquid Glass on macOS 26) and
/// full-height layout automatically.
///
/// Deliberately do NOT add an NSVisualEffectView to either pane: as of macOS 26
/// that sits on top of the glass and blocks it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let git: GitPanelModel
    private let markdown: MarkdownPreviewModel
    private let browser: BrowserModel

    private var inspectorItem: NSSplitViewItem!
    /// Guards against the observer→collapse→observer feedback loop.
    private var syncingInspector = false
    /// Whether the markdown preview was open at the last visibility apply, so we
    /// can tell a preview-driven column change (animate) from a git one.
    private var lastMarkdownOpen = false
    /// Whether the git panel was visible at the last apply, so showing it can
    /// reclaim the column from a preview (they're mutually exclusive views of it).
    private var lastGitVisible = false

    init(runtime: GhosttyRuntime, manager: SessionManager, git: GitPanelModel, markdown: MarkdownPreviewModel, browser: BrowserModel) {
        self.runtime = runtime
        self.manager = manager
        self.git = git
        self.markdown = markdown
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar. `.sidebar` behavior supplies the material and full-height
        // layout (paired with the window's .fullSizeContentView).
        // NSSplitView takes each pane's starting width from its view's frame, so
        // the frame is the only place to state a default (the autosave below wins
        // on every launch after the first drag).
        let sidebar = NSHostingController(rootView: SidebarPane(manager: manager))
        sidebar.view.setFrameSize(NSSize(width: 220, height: sidebar.view.frame.height))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        // Terminal. Lowest holding priority of the three, so it's the pane that
        // absorbs every divider drag and every window resize — the sides keep
        // their width, the terminal gives. An 80pt floor keeps the window
        // shrinkable; ghostty reflows to whatever width it gets, so a narrow
        // terminal is cramped rather than broken.
        let detail = NSHostingController(rootView: DetailPane(runtime: runtime, manager: manager, git: git))
        let contentItem = NSSplitViewItem(viewController: detail)
        contentItem.minimumThickness = 80
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        addSplitViewItem(contentItem)

        // Inspector. `inspector(viewController:)` hard-codes a non-resizable 270pt
        // thickness, so min/max are overridden right after to make it draggable.
        // collapseBehavior keeps the *window* still when the panel opens/closes,
        // resizing the terminal instead.
        let inspector = NSHostingController(rootView: InspectorContainer(git: git, markdown: markdown, browser: browser))
        inspector.view.setFrameSize(NSSize(width: 420, height: inspector.view.frame.height))
        let item = NSSplitViewItem(inspectorWithViewController: inspector)
        item.minimumThickness = 260
        // Generous cap so the Browser pane can be dragged wide enough to render a
        // real page — a diff was happy at 680, a web app isn't. The terminal's low
        // holding priority and 80pt floor still let it give up the room.
        item.maximumThickness = 1600
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.holdingPriority = NSLayoutConstraint.Priority(260)
        item.isCollapsed = !(git.isVisible || markdown.isOpen)
        addSplitViewItem(item)
        inspectorItem = item

        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // Set last: NSSplitView restores saved divider positions the moment the
        // name is assigned, so every item has to exist by then.
        splitView.autosaveName = "main-split"

        observeInspector()
    }

    // MARK: - Inspector visibility

    /// Mirror the inspector's want-to-be-open state onto the split item. The
    /// column is up when the git panel is visible *or* a markdown preview is
    /// open — they share it. @Observable's tracking is one-shot, so the observer
    /// re-arms itself after each change.
    private func observeInspector() {
        withObservationTracking {
            _ = git.isVisible
            _ = markdown.isOpen
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
        // Showing the git panel (⌘⌥G, a pane click, a focus that reveals it)
        // reclaims the column from a preview — the two never share it, and
        // without this the git state would flip while the preview sat unmoved on
        // top, making the next toggle feel inverted.
        if git.isVisible && !lastGitVisible && markdown.isOpen {
            markdown.close()
        }
        lastGitVisible = git.isVisible

        let show = git.isVisible || markdown.isOpen
        let markdownChanged = markdown.isOpen != lastMarkdownOpen
        lastMarkdownOpen = markdown.isOpen
        guard let inspectorItem, inspectorItem.isCollapsed == show else { return }
        syncingInspector = true
        if markdownChanged || git.animatesVisibilityChange {
            inspectorItem.animator().isCollapsed = !show
        } else {
            inspectorItem.isCollapsed = !show
        }
        syncingInspector = false
    }

    /// The panel can also be collapsed by dragging its divider to the edge, which
    /// bypasses GitPanelModel entirely — reflect that back so the menu item's
    /// Show/Hide title and the persisted state don't drift out of sync.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !syncingInspector, let inspectorItem else { return }
        let visible = !inspectorItem.isCollapsed
        guard visible != (git.isVisible || markdown.isOpen) else { return }
        if visible {
            // Dragged open — there's nothing to restore a preview to, so this
            // means the git panel.
            if !markdown.isOpen { git.isPresented = true }
        } else if markdown.isOpen {
            // Dragged shut while a preview covered the column — the user is
            // dismissing the *preview*, not the git panel underneath. Close only
            // the preview and leave the session's git state alone; if git was
            // visible it simply re-takes the column.
            markdown.close()
        } else if git.isVisible {
            git.isPresented = false
        }
    }
}
