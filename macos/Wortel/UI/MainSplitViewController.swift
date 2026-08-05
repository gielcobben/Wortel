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
    /// What currently owns the inspector column — which is *not* the same
    /// question as `InspectorPane`, because the Markdown preview takes the whole
    /// column and is a view of no pane at all.
    ///
    /// The distinction earns its keep because width is remembered per occupant:
    /// the four things that share this column want visibly different widths, and
    /// one width for all of them means every switch is followed by a divider
    /// drag back to where you had it.
    enum InspectorOccupant: String {
        case changes, history, files, preview

        @MainActor init(git: GitPanelModel, markdown: MarkdownPreviewModel) {
            if markdown.isOpen {
                self = .preview
            } else {
                switch git.pane {
                case .changes: self = .changes
                case .history: self = .history
                case .files: self = .files
                }
            }
        }

        /// Width before the user has ever dragged this occupant's divider. A file
        /// tree is a column of short names; a diff is code with a gutter and needs
        /// half again as much; a rendered Markdown page wants a readable measure.
        var defaultWidth: CGFloat {
            switch self {
            case .files: return 260
            case .changes, .history: return 420
            case .preview: return 520
            }
        }

        /// How narrow this occupant may be dragged. The tree stays useful far
        /// narrower than a diff does, and refusing to let it get there is most of
        /// why one shared width felt wrong.
        var minimumThickness: CGFloat {
            switch self {
            case .files: return 180
            case .changes, .history: return 260
            case .preview: return 320
            }
        }
    }

    /// The width each occupant was last left at. App state, like the expanded
    /// directories and the session list — UserDefaults, not a config file Wortel
    /// deliberately doesn't have.
    enum InspectorWidthStore {
        private static let key = "inspector.widths"

        static func width(for occupant: InspectorOccupant) -> CGFloat {
            let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
            guard let saved = stored?[occupant.rawValue], saved > 0 else {
                return occupant.defaultWidth
            }
            return CGFloat(saved)
        }

        static func save(_ width: CGFloat, for occupant: InspectorOccupant) {
            var stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
            stored[occupant.rawValue] = Double(width)
            UserDefaults.standard.set(stored, forKey: key)
        }
    }

    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let git: GitPanelModel
    private let markdown: MarkdownPreviewModel
    private let files: FileTreeModel

    private var inspectorItem: NSSplitViewItem!
    /// Guards against the observer→collapse→observer feedback loop.
    private var syncingInspector = false
    /// Whether the markdown preview was open at the last visibility apply, so we
    /// can tell a preview-driven column change (animate) from a git one.
    private var lastMarkdownOpen = false
    /// Whether the git panel was visible at the last apply, so showing it can
    /// reclaim the column from a preview (they're mutually exclusive views of it).
    private var lastGitVisible = false
    /// What was in the column at the last apply, so a pane swap can be told from
    /// a mere visibility change and given its own width.
    private var lastOccupant: InspectorOccupant?
    /// The inspector width we last set or observed, so opening the column can
    /// tell "same width as last time" (animate) from "this occupant is a
    /// different size" (snap — see `applyInspectorVisibility`).
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

    init(runtime: GhosttyRuntime, manager: SessionManager, git: GitPanelModel,
         markdown: MarkdownPreviewModel, files: FileTreeModel) {
        self.runtime = runtime
        self.manager = manager
        self.git = git
        self.markdown = markdown
        self.files = files
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
        let detail = NSHostingController(rootView: DetailPane(runtime: runtime, manager: manager, git: git, files: files))
        let contentItem = NSSplitViewItem(viewController: detail)
        contentItem.minimumThickness = 80
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
        addSplitViewItem(contentItem)

        // Inspector. `inspector(viewController:)` hard-codes a non-resizable 270pt
        // thickness, so min/max are overridden right after to make it draggable.
        // collapseBehavior keeps the *window* still when the panel opens/closes,
        // resizing the terminal instead.
        let inspector = NSHostingController(rootView: InspectorContainer(git: git, markdown: markdown, files: files))
        let occupant = InspectorOccupant(git: git, markdown: markdown)
        let width = InspectorWidthStore.width(for: occupant)
        inspector.view.setFrameSize(NSSize(width: width, height: inspector.view.frame.height))
        lastOccupant = occupant
        lastAppliedWidth = width
        let item = NSSplitViewItem(inspectorWithViewController: inspector)
        item.minimumThickness = occupant.minimumThickness
        item.maximumThickness = 680
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.holdingPriority = NSLayoutConstraint.Priority(260)
        item.isCollapsed = !(git.isVisible || markdown.isOpen)
        addSplitViewItem(item)
        inspectorItem = item

        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // Set last: NSSplitView restores saved divider positions the moment the
        // name is assigned, so every item has to exist by then. It carries the
        // sidebar's width; the inspector's it also carries but does not get to
        // decide, because that one is per occupant (see `viewDidLayout`).
        splitView.autosaveName = "main-split"

        observeInspector()
    }

    /// The autosave restore above happens before the split view has a width, and
    /// it restores one inspector width for all four occupants. Take the column
    /// back on the first real layout pass and give it the width this occupant
    /// was left at.
    private var didApplyInitialWidth = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialWidth, splitView.bounds.width > 0 else { return }
        didApplyInitialWidth = true
        lastSplitWidth = splitView.bounds.width
        // A turn later, deliberately: NSSplitView applies its autosaved divider
        // positions during this same layout pass, and the per-occupant width is
        // the one that has to win. Doing it inline is a race with that restore.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.inspectorItem, !item.isCollapsed else { return }
            self.applyInspectorWidth(for: InspectorOccupant(git: self.git, markdown: self.markdown))
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
            _ = markdown.isOpen
            // Which pane is showing decides how wide the column should be, so a
            // swap has to reach here too — including the one a session switch
            // makes, since the pane is per session.
            _ = git.pane
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
        let occupant = InspectorOccupant(git: git, markdown: markdown)
        defer { lastOccupant = occupant }
        guard let inspectorItem else { return }

        guard inspectorItem.isCollapsed == show else {
            // Already up: a swap between panes is the only thing left to answer,
            // and it answers in width.
            if show, occupant != lastOccupant { applyInspectorWidth(for: occupant) }
            return
        }

        // A collapsed item comes back at the thickness it had when it went away,
        // which belongs to whatever was in the column *then*. When that isn't
        // this occupant's width we snap instead of animating: sliding open at the
        // wrong width and then jumping to the right one reads as a glitch, where
        // an instant open just reads as instant.
        let target = InspectorWidthStore.width(for: occupant)
        let widthChanges = show && abs(target - lastAppliedWidth) > 1
        let animates = (markdownChanged || git.animatesVisibilityChange) && !widthChanges

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
                    if show { self.applyInspectorWidth(for: occupant) }
                }
            }
        } else {
            inspectorItem.isCollapsed = !show
            suspendWidthCapture = false
            if show { applyInspectorWidth(for: occupant) }
        }
        syncingInspector = false
    }

    // MARK: - Inspector width (per occupant)

    /// Give the column the width this occupant was last left at, and the floor it
    /// is allowed to be dragged to. Both are per occupant, which is the whole
    /// point: a file tree that can't go below a diff's minimum is a file tree
    /// wasting a third of its width on nothing.
    private func applyInspectorWidth(for occupant: InspectorOccupant) {
        guard let inspectorItem, !inspectorItem.isCollapsed else { return }
        let total = splitView.bounds.width
        guard total > 0, splitViewItems.count >= 2 else { return }

        inspectorItem.minimumThickness = occupant.minimumThickness
        let target = min(max(InspectorWidthStore.width(for: occupant), occupant.minimumThickness),
                         inspectorItem.maximumThickness)
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

    /// Record the width the user just dragged the column to, against whatever is
    /// in it. Only a *divider* drag counts: a window resize moves the split view's
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
        let occupant = InspectorOccupant(git: git, markdown: markdown)
        widthCaptureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let item = self.inspectorItem, !item.isCollapsed else { return }
            let settled = item.viewController.view.frame.width
            guard settled > 1 else { return }
            self.lastAppliedWidth = settled
            InspectorWidthStore.save(settled, for: occupant)
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
