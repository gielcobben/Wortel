import AppKit
import Observation

/// The window toolbar.
///
/// The whole point of this file is the two `NSTrackingSeparatorToolbarItem`s.
/// They bind titlebar sections to the split view's dividers, which is what makes
/// the window title start at the sidebar's trailing edge and the trailing control
/// stop at the git panel's leading edge — the alignment is a real constraint on a
/// real divider, not padding that happens to look right.
///
/// Item order defines the sections:
///
///     [ sidebar section ] |divider 0| [ content section ] |divider 1| [ inspector ]
///
/// On macOS 26 these items pick up Liquid Glass automatically (it keys off the
/// linked SDK, not the deployment target) and AppKit groups adjacent items onto
/// shared glass capsules by control type. Nothing here asks for that.
extension NSToolbarItem.Identifier {
    static let trackingSidebar = NSToolbarItem.Identifier("wortel.tracking.sidebar")
    static let trackingInspector = NSToolbarItem.Identifier("wortel.tracking.inspector")
    static let gitPane = NSToolbarItem.Identifier("wortel.gitPane")
}

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    private weak var splitView: NSSplitView?
    private let git: GitPanelModel
    /// Held so the control can be re-synced when the panel is opened, closed, or
    /// switched from anywhere else — ⌘⌥G, ⌘⌥L, a divider drag, a session switch.
    private weak var paneControl: NSSegmentedControl?

    init(splitView: NSSplitView, git: GitPanelModel) {
        self.splitView = splitView
        self.git = git
        super.init()
        observePanel()
    }

    /// The pane buttons are the *only* control over the panel — there is no
    /// separate show/hide button — so each click means both "show this pane" and
    /// "toggle, if this pane is already what's on screen":
    ///
    /// - hidden → open on the clicked pane
    /// - showing the *other* pane → swap in place, don't close
    /// - showing the clicked pane → close
    ///
    /// Selection is asserted from the model afterwards rather than left to the
    /// control, because `.selectAny` tracking lets a click land the control on a
    /// state the model would never hold (both selected, or none while visible).
    @objc private func paneChanged(_ sender: NSSegmentedControl) {
        let panes = GitInspectorPane.allCases
        let clicked = sender.selectedSegment
        // `.selectAny` reports -1 when the click *deselected* a segment, which can
        // only be the pane already on screen. Guarding on the index too keeps the
        // close working if AppKit reports the clicked index instead.
        if clicked < 0 {
            git.isPresented = false
        } else if panes.indices.contains(clicked) {
            if git.isVisible && git.pane == panes[clicked] {
                git.isPresented = false
            } else {
                git.pane = panes[clicked]
                git.isPresented = true
            }
        }
        syncPaneControl()
    }

    /// A pane reads as selected only while its panel is actually up — with the
    /// panel closed, `git.pane` is just what will come back next time, not
    /// something on screen.
    private func syncPaneControl() {
        guard let paneControl else { return }
        for (index, pane) in GitInspectorPane.allCases.enumerated() {
            paneControl.setSelected(git.isVisible && pane == git.pane, forSegment: index)
        }
    }

    /// Keep the buttons honest when the panel moves without them. @Observable's
    /// tracking is one-shot, so the observer re-arms itself after each change.
    private func observePanel() {
        withObservationTracking {
            _ = git.isVisible
            _ = git.pane
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncPaneControl()
                self.observePanel()
            }
        }
    }

    /// The flexible spaces do the aligning, and each one only stretches within its
    /// own section because the tracking separators bound them: the first pushes
    /// the sidebar toggle to the sidebar's trailing edge (clear of the traffic
    /// lights), the second pushes anything after it against divider 1 (the git
    /// panel's leading edge), the third pushes the panel's own control to the
    /// window's trailing edge rather than leaving it at the panel's leading edge.
    ///
    /// `.toggleSidebar` is a system item — AppKit builds it and routes its action
    /// to NSSplitViewController, which implements `toggleSidebar(_:)` natively, so
    /// it needs no case in `itemForItemIdentifier` and stays in sync with ⌘⌥S.
    private var identifiers: [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .toggleSidebar,
            .trackingSidebar,
            .flexibleSpace,
            .trackingInspector,
            .flexibleSpace,
            .gitPane,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let splitView else { return nil }
        switch itemIdentifier {
        case .trackingSidebar:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)
        case .trackingInspector:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)
        case .gitPane:
            // A plain NSSegmentedControl rather than an NSToolbarItemGroup: the
            // group's selection is index-based and would need mirroring back onto
            // the enum anyway, and on macOS 26 AppKit already gives segmented
            // controls their own glass capsule based on the control's type.
            // Nothing here has to ask for that.
            //
            // `.selectAny`, not `.selectOne`, is what buys the close-on-reclick:
            // `.selectOne` refuses to let go of its selection, so clicking the pane
            // already on screen would be swallowed and the panel could never be
            // dismissed from here. The cost is that the control can land on states
            // the model doesn't have — `paneChanged` re-asserts it.
            let panes = GitInspectorPane.allCases
            let segmented = NSSegmentedControl(
                images: panes.map {
                    NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)
                        ?? NSImage()
                },
                trackingMode: .selectAny,
                target: self,
                action: #selector(paneChanged(_:)))
            segmented.segmentStyle = .automatic
            // Neutral gray rather than the accent tint AppKit gives a selected
            // segment. These buttons say "this is the pane you're looking at",
            // which is the same thing an inactive-window selection says — so they
            // borrow its color, and the symbol keeps its own contrast instead of
            // being knocked out to white on blue.
            segmented.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
            for (index, pane) in panes.enumerated() {
                segmented.setToolTip(pane.title, forSegment: index)
            }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = segmented
            item.label = "Source Control"
            paneControl = segmented
            syncPaneControl()
            return item
        default:
            return nil
        }
    }
}
