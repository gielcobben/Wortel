import AppKit

/// The window toolbar.
///
/// The whole point of this file is the two `NSTrackingSeparatorToolbarItem`s.
/// They bind titlebar sections to the split view's dividers, which is what makes
/// the window title start at the sidebar's trailing edge and the trailing buttons
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
    static let toggleGitPanel = NSToolbarItem.Identifier("wortel.toggleGitPanel")
}

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    private weak var splitView: NSSplitView?

    init(splitView: NSSplitView) {
        self.splitView = splitView
    }

    /// The flexible spaces do the aligning, and each one only stretches within its
    /// own section because the tracking separators bound them: the first pushes
    /// the sidebar toggle to the sidebar's trailing edge (clear of the traffic
    /// lights), the second pushes anything after it against divider 1 (the git
    /// panel's leading edge), the third pushes the panel's own items to the
    /// window's trailing edge rather than leaving them at the panel's leading edge.
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
            .toggleGitPanel,
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
        case .toggleGitPanel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Source Control"
            item.toolTip = "Source Control (⌘⌥G)"
            item.image = NSImage(
                systemSymbolName: "sidebar.right", accessibilityDescription: "Source Control")
            // nil target → the action walks the responder chain to AppDelegate,
            // the same route the ⌘⌥G menu item takes.
            item.target = nil
            item.action = #selector(AppDelegate.toggleSourceControl(_:))
            item.isNavigational = false
            return item
        default:
            return nil
        }
    }
}
