import AppKit
import Observation
import SwiftUI

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
    /// The branch chip. Only present while the panel is open on a repo — see
    /// `syncToolbar`, which inserts and removes it. It's a real NSButton so the
    /// whole capsule is clickable; its actions live in the popover it opens.
    static let gitControls = NSToolbarItem.Identifier("wortel.gitControls")
    static let gitPane = NSToolbarItem.Identifier("wortel.gitPane")
}

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate, NSPopoverDelegate {
    private weak var splitView: NSSplitView?
    private let git: GitPanelModel
    /// Held so the control can be re-synced when the panel is opened, closed, or
    /// switched from anywhere else — ⌘⌥G, ⌘⌥L, a divider drag, a session switch.
    private weak var paneControl: NSSegmentedControl?
    /// The window's toolbar, so the branch item can be inserted and removed as
    /// the panel opens and closes. Set by AppDelegate right after it builds it.
    weak var toolbar: NSToolbar?
    /// The branch button, held so its title tracks the branch and ahead/behind.
    private weak var branchButton: NSButton?
    /// Widens the button past its content so the bezel centres it with a little
    /// air on each side — the native way to add horizontal padding, instead of
    /// padding the title string with spaces. Its constant follows the title.
    private weak var branchWidthConstraint: NSLayoutConstraint?
    /// The open branch popover, kept only so a second click while it's up doesn't
    /// stack a second one.
    private var branchPopover: NSPopover?

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
        syncToolbar()
    }

    /// A pane reads as selected only while its panel is actually up — with the
    /// panel closed, `git.pane` is just what will come back next time, not
    /// something on screen.
    private func syncToolbar() {
        if let paneControl {
            for (index, pane) in GitInspectorPane.allCases.enumerated() {
                paneControl.setSelected(git.isVisible && pane == git.pane, forSegment: index)
            }
        }
        syncBranchItem()
        updateBranchButton()
    }

    /// The branch button's title: a leading branch glyph and the branch name. The
    /// trailing chevron is the button's own image; the edge padding is the bezel's
    /// — nothing here fakes spacing. Ahead/behind aren't shown; they're in the
    /// panel already (the header, the blue dots), and the chip is for identity and
    /// the switcher, not status.
    private func updateBranchButton() {
        guard let button = branchButton, let repo = git.repo else { return }
        button.attributedTitle = Self.branchTitle(repo.status.branch ?? "detached")
        button.toolTip = "Switch branch"
        // Widen past the fitted size so the bezel centres the content with a
        // little air on each side. Deactivate the width first so `fittingSize`
        // reports the content width, not the last padded one.
        branchWidthConstraint?.isActive = false
        branchWidthConstraint?.constant = button.fittingSize.width + 28
        branchWidthConstraint?.isActive = true
    }

    /// The trailing chevron, padded on its leading edge with transparent space so
    /// there's room between it and the branch name. NSButton has no image-to-title
    /// spacing knob, so the gap lives in the image rather than in a title space.
    private static func chevronImage() -> NSImage? {
        guard let base = NSImage(
            systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: 8, weight: .medium)
                    .applying(.init(hierarchicalColor: .secondaryLabelColor)))
        else { return nil }
        base.isTemplate = false

        let gap: CGFloat = 5
        let padded = NSImage(size: NSSize(width: base.size.width + gap, height: base.size.height))
        padded.lockFocus()
        base.draw(in: NSRect(x: gap, y: 0, width: base.size.width, height: base.size.height))
        padded.unlockFocus()
        padded.isTemplate = false
        return padded
    }

    private static func branchTitle(_ branch: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let result = NSMutableAttributedString()

        // An inline symbol aligns its *bottom* to the text baseline, which leaves
        // it sitting low against the letters. Centre it instead: put the image's
        // vertical midpoint on the font's cap-height midpoint. A single space
        // sets it off the name — inter-element spacing, not edge padding.
        if let image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: 12, weight: .regular)
                    .applying(.init(hierarchicalColor: .secondaryLabelColor))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0, y: (font.capHeight - image.size.height) / 2,
                width: image.size.width, height: image.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: branch, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]))
        return result
    }

    /// Open the branch switcher below the button. The branch list is loaded
    /// *before* the popover shows — an NSPopover sizes to the content it's handed
    /// at presentation, so opening on an empty list would size it to the spinner
    /// and keep that height once the branches arrive. The read is a
    /// `for-each-ref`, fast enough that the click still feels immediate.
    @objc private func openBranchSwitcher(_ sender: NSButton) {
        guard branchPopover == nil, let repo = git.repo else { return }
        Task {
            await repo.loadBranches()
            let popover = NSPopover()
            popover.behavior = .transient
            let list = BranchList(repo: repo, dismiss: { [weak self] in
                self?.branchPopover?.performClose(nil)
            })
            let host = NSHostingController(rootView: list)
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            popover.delegate = self
            branchPopover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }

    /// Drop the held reference once it closes, so the next click opens a fresh one.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in branchPopover = nil }
    }

    /// Whether there's a branch worth showing: the panel is open, and it's
    /// pointed at something that is actually a repo.
    private var showsBranchItem: Bool { git.isVisible && git.repo != nil }

    /// Insert or remove the branch item so it exists only when the panel does.
    /// Removed rather than disabled: the user's read is right — a control for a
    /// collapsed panel has no business in the toolbar, and a greyed one still
    /// claims the panel's controls are app-wide. The pane buttons stay (they're
    /// what *opens* the panel); only the branch, which acts on open content, comes
    /// and goes. NSToolbar animates the insert/remove, so it reads as native.
    private func syncBranchItem() {
        guard let toolbar else { return }
        let present = toolbar.items.firstIndex { $0.itemIdentifier == .gitControls }
        if showsBranchItem, present == nil {
            // Just before the pane buttons, which are the item it sits left of.
            if let paneIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .gitPane }) {
                toolbar.insertItem(withItemIdentifier: .gitControls, at: paneIndex)
            }
        } else if !showsBranchItem, let present {
            toolbar.removeItem(at: present)
        }
    }

    /// Keep the buttons honest when the panel moves without them. @Observable's
    /// tracking is one-shot, so the observer re-arms itself after each change.
    private func observePanel() {
        withObservationTracking {
            _ = git.isVisible
            _ = git.pane
            // `repo` resolves a beat after the panel opens (a cwd has to be walked
            // to a work-tree root), so the branch item's presence tracks it too —
            // otherwise opening on a repo would leave the item out until the next
            // unrelated change.
            _ = git.repo
            // The branch name, so the button's title follows a checkout made in
            // the terminal.
            if let repo = git.repo {
                _ = repo.status.branch
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncToolbar()
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
    ///
    /// `.gitControls` is left out here and inserted by `syncBranchItem` only while
    /// the panel is open; the allowed set below still lists it, which is what lets
    /// it be inserted at all.
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
        var ids = identifiers
        // Present at launch if the restored session already has the panel open on
        // a repo, so it isn't missing until the first change wakes the observer.
        if showsBranchItem, let paneIndex = ids.firstIndex(of: .gitPane) {
            ids.insert(.gitControls, at: paneIndex)
        }
        return ids
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids = identifiers
        if let paneIndex = ids.firstIndex(of: .gitPane) {
            ids.insert(.gitControls, at: paneIndex)
        }
        return ids
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
        case .gitControls:
            // A real NSButton, not a hosted SwiftUI one: the whole capsule takes
            // clicks, where a hosting view leaves the glass rim around it dead.
            // The trailing chevron is the button's own image — so AppKit aligns
            // and spaces it like a stepper's, and the edge padding is the bezel's,
            // not faked with spaces. Only the leading branch glyph rides in the
            // title, since a button has one image slot and the chevron claims it.
            let button = NSButton(title: "", target: self, action: #selector(openBranchSwitcher))
            button.bezelStyle = .toolbar
            button.image = Self.chevronImage()
            button.imagePosition = .imageTrailing
            branchButton = button
            // A width constraint the title updater keeps a little wider than the
            // content, so the extra room is the bezel's own centring rather than
            // spaces baked into the title.
            let width = button.widthAnchor.constraint(equalToConstant: 0)
            width.isActive = true
            branchWidthConstraint = width
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Branch"
            item.visibilityPriority = .low
            updateBranchButton()
            return item
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
            syncToolbar()
            return item
        default:
            return nil
        }
    }
}
