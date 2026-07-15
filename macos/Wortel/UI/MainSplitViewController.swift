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

    private var inspectorItem: NSSplitViewItem!
    /// Guards against the observer→collapse→observer feedback loop.
    private var syncingInspector = false

    init(runtime: GhosttyRuntime, manager: SessionManager, git: GitPanelModel) {
        self.runtime = runtime
        self.manager = manager
        self.git = git
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar. `.sidebar` behavior supplies the material and full-height
        // layout (paired with the window's .fullSizeContentView).
        let sidebar = NSHostingController(rootView: SidebarPane(manager: manager))
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
        let inspector = NSHostingController(rootView: SourceControlPanel(panel: git))
        let item = NSSplitViewItem(inspectorWithViewController: inspector)
        item.minimumThickness = 260
        item.maximumThickness = 680
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.holdingPriority = NSLayoutConstraint.Priority(260)
        item.isCollapsed = !git.isVisible
        addSplitViewItem(item)
        inspectorItem = item

        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        observeGitVisibility()
    }

    // MARK: - Inspector visibility

    /// Mirror `GitPanelModel.isVisible` onto the inspector item. @Observable's
    /// tracking is one-shot, so the observer re-arms itself after each change.
    private func observeGitVisibility() {
        withObservationTracking {
            _ = git.isVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyGitVisibility()
                self.observeGitVisibility()
            }
        }
    }

    private func applyGitVisibility() {
        guard let inspectorItem, inspectorItem.isCollapsed == git.isVisible else { return }
        syncingInspector = true
        inspectorItem.animator().isCollapsed = !git.isVisible
        syncingInspector = false
    }

    /// The panel can also be collapsed by dragging its divider to the edge, which
    /// bypasses GitPanelModel entirely — reflect that back so the menu item's
    /// Show/Hide title and the persisted state don't drift out of sync.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !syncingInspector, let inspectorItem else { return }
        let visible = !inspectorItem.isCollapsed
        if visible != git.isVisible { git.isPresented = visible }
    }
}
