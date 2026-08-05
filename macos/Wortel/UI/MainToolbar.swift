import AppKit
import Observation
import SwiftUI
import os

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
    /// `syncRepoItems`, which inserts and removes it. It's a real NSButton so the
    /// whole capsule is clickable; its actions live in the popover it opens.
    static let gitControls = NSToolbarItem.Identifier("wortel.gitControls")
    /// The repo-actions "···" button — fetch, push, and room for more. A narrow
    /// icon button rather than a row of controls precisely so it can't overflow
    /// into the toolbar's `»` menu the way a wider cluster did in the panel's
    /// cramped strip. Present alongside the branch chip.
    static let gitMenu = NSToolbarItem.Identifier("wortel.gitMenu")
    static let gitPane = NSToolbarItem.Identifier("wortel.gitPane")
}

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate, NSPopoverDelegate {
    private weak var splitView: NSSplitView?
    private let git: GitPanelModel
    private let markdown: MarkdownPreviewModel
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
    /// The last branch the chip was sized for, so `updateBranchButton` only
    /// touches the width constraint on an actual change — re-fitting on every
    /// observation tick made the chip (and everything after it) jitter.
    private var lastBranchTitle: String?
    /// The toolbar items with custom views, held so their overflow-menu forms
    /// can track live state. Without a `menuFormRepresentation`, a view item
    /// that lands in the toolbar's `»` menu is a dead, disabled label.
    private weak var paneItem: NSToolbarItem?
    private weak var gitControlsItem: NSToolbarItem?
    private weak var gitMenuItem: NSToolbarItem?
    /// The chip stops growing here and truncates the branch name instead — the
    /// inspector section is 260pt at its narrowest, and an unbounded chip was
    /// what shoved the whole section into the `»` menu.
    private static let maxBranchChipWidth: CGFloat = 180
    /// Below this the chip stops being a name at all and becomes the branch glyph
    /// alone. A name squeezed under this is two characters and an ellipsis —
    /// it identifies nothing, and it's still wide enough to push the section into
    /// the `»` menu, which is the worse outcome of the two: an icon that opens the
    /// switcher is a control, and a `»` menu is a control you have to go looking
    /// for.
    private static let minBranchChipWidth: CGFloat = 96
    /// The glyph-only chip: one symbol in a toolbar bezel.
    private static let iconOnlyChipWidth: CGFloat = 34
    /// Whether the chip is currently in that glyph-only state, so the title is
    /// only rebuilt when the mode actually flips.
    private var branchChipIsIconOnly = false
    /// The chip's width with the name at full length, recomputed only when the
    /// name or the mode changes — `fittingSize` needs the width constraint off,
    /// and toggling that on every observation tick is what used to make the whole
    /// section jitter.
    private var branchNaturalWidth: CGFloat = 0
    /// The width last written to the constraint, so a resize that doesn't move the
    /// chip doesn't touch layout at all.
    private var lastChipWidth: CGFloat = -1
    /// The widest inspector section the chip has actually been seen to overflow
    /// at. Everything at or below it shows the glyph alone — see `verifyChipFits`,
    /// which is what turns the width estimate below from a promise into a guess
    /// that gets corrected.
    private var overflowedAtSection: CGFloat = 0
    private static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "toolbar")

    /// Observer for the split view's resizes, which is what changes how much room
    /// the branch chip has. Kept so it can be removed with the delegate.
    private var resizeObserver: NSObjectProtocol?

    init(splitView: NSSplitView, git: GitPanelModel, markdown: MarkdownPreviewModel) {
        self.splitView = splitView
        self.git = git
        self.markdown = markdown
        super.init()
        observePanel()
        // The chip's room is the inspector's width, so a divider drag or a window
        // resize is as much a reason to re-fit it as a checkout is. Straight off
        // the notification rather than plumbed through the split controller: this
        // is the toolbar's own business. `updateBranchButton` no-ops unless the
        // width it computes actually moved, so a drag costs a comparison a frame.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBranchButton() }
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    /// The pane buttons are the *only* control over the panel — there is no
    /// separate show/hide button — so each click means both "show this pane" and
    /// "toggle, if this pane is already what's on screen". The rule itself lives
    /// on `GitPanelModel.activate(_:)` so the View menu's ⌘⌥G / ⌘⌥E drive the
    /// identical behaviour.
    ///
    /// Selection is asserted from the model afterwards rather than left to the
    /// control, because `.selectAny` tracking lets a click land the control on a
    /// state the model would never hold (both selected, or none while visible).
    @objc private func paneChanged(_ sender: NSSegmentedControl) {
        activatePane(at: sender.selectedSegment)
    }

    /// The shared pane-click behavior, also the action behind the overflow (`»`)
    /// menu's pane entries — which is why it's index-based rather than reading
    /// the segmented control.
    private func activatePane(at index: Int) {
        let panes = InspectorPane.allCases
        // While the markdown preview owns the column, a pane click means "give me
        // that pane back" — close the preview and show the pane, never toggle
        // the column shut.
        if markdown.isOpen {
            markdown.close()
            // `show`, not `activate`: the pane clicked may be the one the model
            // already holds, and toggling would read that as "close" when the
            // click meant "replace the preview with this".
            if panes.indices.contains(index) { git.show(panes[index]) }
            syncToolbar()
            return
        }
        // `.selectAny` reports -1 when the click *deselected* a segment, which can
        // only be the pane already on screen. Guarding on the index too keeps the
        // close working if AppKit reports the clicked index instead.
        if index < 0 {
            git.isPresented = false
        } else if panes.indices.contains(index) {
            git.activate(panes[index])
        }
        syncToolbar()
    }

    /// A pane reads as selected only while its panel is actually up — with the
    /// panel closed, `git.pane` is just what will come back next time, not
    /// something on screen.
    private func syncToolbar() {
        if let paneControl {
            for (index, pane) in InspectorPane.allCases.enumerated() {
                // A pane reads selected only when its git pane is actually on
                // screen — not while the markdown preview has taken the column.
                paneControl.setSelected(git.isVisible && !markdown.isOpen && pane == git.pane, forSegment: index)
            }
        }
        syncRepoItems()
        updateBranchButton()
        updateMenuForms()
    }

    /// Keep each custom-view item's `menuFormRepresentation` current. This is
    /// what the toolbar's overflow (`»`) menu shows when the window or inspector
    /// is too narrow for the item itself — without it, AppKit lists the item as
    /// a disabled label and the control is simply lost. Rebuilt on every sync so
    /// the entries reflect live state (selected pane, repo actions).
    private func updateMenuForms() {
        if let paneItem {
            let submenu = NSMenu()
            for (index, pane) in InspectorPane.allCases.enumerated() {
                let entry = ClosureMenuItem(title: pane.title) { [weak self] in
                    self?.activatePane(at: index)
                }
                entry.state = (git.isVisible && !markdown.isOpen && pane == git.pane) ? .on : .off
                submenu.addItem(entry)
            }
            let form = NSMenuItem(title: "Source Control", action: nil, keyEquivalent: "")
            form.submenu = submenu
            paneItem.menuFormRepresentation = form
        }
        if let gitControlsItem {
            // Anchor on the pane control when the chip itself is overflowed (a
            // popover needs an on-screen view); the chip when it's visible.
            gitControlsItem.menuFormRepresentation = ClosureMenuItem(title: "Switch Branch…") { [weak self] in
                guard let self else { return }
                let anchor = branchButton?.window != nil ? branchButton : paneControl
                if let anchor { presentBranchSwitcher(from: anchor) }
            }
        }
        if let gitMenuItem {
            let form = NSMenuItem(title: "Repository", action: nil, keyEquivalent: "")
            form.submenu = repoActionsMenu()
            gitMenuItem.menuFormRepresentation = form
        }
    }

    /// Pop the repo-actions menu — fetch, push — below the "···" button. Built
    /// fresh on each click so it reads live state (an in-flight op, whether
    /// there's a remote, the ahead count) without any observation wiring; a
    /// disabled item just can't be chosen. `autoenablesItems = false` so our
    /// explicit `isEnabled` wins over AppKit's target/action validation.
    @objc private func openGitMenu(_ sender: NSButton) {
        guard let menu = repoActionsMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The fetch/push menu, shared by the "···" click and the overflow (`»`)
    /// form. nil when no repo is open.
    private func repoActionsMenu() -> NSMenu? {
        guard let repo = git.repo else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let busy = repo.isFetching || repo.isPushing

        let fetch = ClosureMenuItem(title: repo.isFetching ? "Fetching…" : "Fetch") {
            Task { await repo.fetch() }
        }
        fetch.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        fetch.isEnabled = !busy && repo.canFetch
        menu.addItem(fetch)

        // Name what push will actually do: publish a fresh branch, or push a known
        // number of commits.
        let pushTitle: String
        if repo.isPushing {
            pushTitle = "Pushing…"
        } else if repo.status.upstream == nil {
            pushTitle = "Publish Branch"
        } else {
            let ahead = repo.status.ahead
            pushTitle = ahead > 0 ? "Push \(ahead) Commit\(ahead == 1 ? "" : "s")" : "Push"
        }
        let push = ClosureMenuItem(title: pushTitle) { Task { await repo.push() } }
        push.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        push.isEnabled = !busy && repo.canPush
        menu.addItem(push)
        return menu
    }

    /// The branch button's title: a leading branch glyph and the branch name. The
    /// trailing chevron is the button's own image; the edge padding is the bezel's
    /// — nothing here fakes spacing. Ahead/behind aren't shown; they're in the
    /// panel already (the header, the blue dots), and the chip is for identity and
    /// the switcher, not status.
    private func updateBranchButton() {
        guard let button = branchButton, let repo = git.repo else { return }
        let branch = repo.status.branch ?? "detached"
        let section = inspectorSectionWidth()
        let available = availableBranchChipWidth(section: section)
        // Two ways to end up as a glyph: the estimate says there's no room for a
        // name, or we have watched the chip overflow at this width before and
        // know the estimate was optimistic.
        let iconOnly = available < Self.minBranchChipWidth || section <= overflowedAtSection

        // Re-title only on an actual change of name or mode: this runs on every
        // observation tick *and* on every frame of a divider drag, and toggling
        // the width constraint to re-measure is what used to make the chip (and
        // the controls beside it) jitter.
        if branch != lastBranchTitle || iconOnly != branchChipIsIconOnly {
            lastBranchTitle = branch
            branchChipIsIconOnly = iconOnly
            if iconOnly {
                // No room for a name worth reading: the chip becomes the branch
                // glyph, and the name moves to the tooltip. The chevron goes too
                // — it's an affordance, and an affordance that costs half the
                // control's width at this size isn't one.
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.branchGlyphImage()
                button.imagePosition = .imageOnly
            } else {
                button.attributedTitle = Self.branchTitle(branch)
                button.image = Self.chevronImage()
                button.imagePosition = .imageTrailing
            }
            // Widen past the fitted size so the bezel centres the content with a
            // little air on each side. Deactivate the width first so
            // `fittingSize` reports the content width, not the last padded one.
            branchWidthConstraint?.isActive = false
            branchNaturalWidth = button.fittingSize.width + 28
            branchWidthConstraint?.isActive = true
        }
        button.toolTip = iconOnly ? "\(branch) — switch branch" : "Switch branch"

        // The chip takes what the name needs, bounded by its own cap and by the
        // room the inspector section actually has. Truncation (the title's
        // paragraph style) takes it from there, so the name shortens as the
        // column narrows rather than the whole section dropping into `»`.
        let width = iconOnly
            ? Self.iconOnlyChipWidth
            : max(Self.minBranchChipWidth,
                  min(branchNaturalWidth, Self.maxBranchChipWidth, available))
        guard abs(width - lastChipWidth) > 0.5 else { return }
        lastChipWidth = width
        branchWidthConstraint?.constant = width
        Self.log.debug("""
            branch chip: section=\(section, privacy: .public) \
            available=\(available, privacy: .public) width=\(width, privacy: .public) \
            iconOnly=\(iconOnly, privacy: .public) \
            overflowedAt=\(self.overflowedAtSection, privacy: .public)
            """)
        verifyChipFits(section: section)
    }

    /// The width of the toolbar's trailing section: the chip sits *after* the
    /// tracking separator on divider 1, so what it competes for is the
    /// inspector's width, not the window's. That's the whole reason a fixed chip
    /// misbehaved — 180pt is fine on a wide column and impossible on a narrow
    /// one, and the toolbar's answer to impossible is to hide the section behind
    /// `»`.
    private func inspectorSectionWidth() -> CGFloat {
        splitView?.arrangedSubviews.last?.frame.width ?? 0
    }

    /// How much room the branch chip can take without pushing anything into the
    /// overflow menu. An estimate, and knowingly so: AppKit publishes neither the
    /// spacing between toolbar items nor the width the `»` button claims once it
    /// appears — and that last one is what makes an optimistic guess
    /// self-fulfilling. Deliberately pessimistic, with `verifyChipFits` behind it
    /// to correct what's left.
    private func availableBranchChipWidth(section: CGFloat) -> CGFloat {
        // Before the first layout there's nothing to measure; don't let that read
        // as "no room" and start the chip out as a glyph.
        guard section > 1 else { return Self.maxBranchChipWidth }
        let panes = paneControl.map { max($0.frame.width, $0.fittingSize.width) } ?? 110
        let actions = gitMenuItem?.view.map { max($0.frame.width, $0.fittingSize.width) } ?? 34
        return section - panes - actions - Self.sectionChrome
    }

    /// Item spacing, the window's trailing margin, and room for the `»` button
    /// itself. Guessing high costs a few points of branch name; guessing low
    /// costs the whole section.
    private static let sectionChrome: CGFloat = 96

    /// Check the one thing that isn't a guess: whether the chip is in the toolbar
    /// or in the `»` menu. If it overflowed, this section width is now known to
    /// be too small for a name, and never gets one again until the column is
    /// genuinely wider — which makes the estimate above self-correcting rather
    /// than something that has to be right first time on every Mac.
    ///
    /// Checked late enough to clear the insert animation, and only while the
    /// column hasn't moved on, because recording a width the user was merely
    /// dragging through would pin the chip to a glyph at widths that fit.
    private func verifyChipFits(section: CGFloat) {
        guard !branchChipIsIconOnly, section > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.showsBranchItem, let item = self.gitControlsItem else { return }
            guard !item.isVisible, abs(self.inspectorSectionWidth() - section) < 1 else { return }
            Self.log.debug("branch chip overflowed at section=\(section, privacy: .public)")
            self.overflowedAtSection = max(self.overflowedAtSection, section)
            self.updateBranchButton()
            // Shrinking a view the toolbar has already banished doesn't
            // necessarily bring it back — that was decided at its last layout,
            // and the item isn't in the toolbar any more to prompt another.
            // Taking it out and putting it back is what makes the decision
            // happen again, and the replacement is built as a glyph from the
            // start because `overflowedAtSection` now says so.
            if let toolbar = self.toolbar,
               let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .gitControls }) {
                toolbar.removeItem(at: index)
                toolbar.insertItem(withItemIdentifier: .gitControls, at: index)
            }
        }
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

    /// The whole chip when there's no room for a name: the same branch symbol the
    /// title carries inline, as the button's own template image so the toolbar
    /// tints it like every other icon button up there.
    private static func branchGlyphImage() -> NSImage? {
        NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Switch branch")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
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
        // Truncate rather than clip when the chip hits its width cap.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        result.append(NSAttributedString(string: branch, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    /// Open the branch switcher below the button. The branch list is loaded
    /// *before* the popover shows — an NSPopover sizes to the content it's handed
    /// at presentation, so opening on an empty list would size it to the spinner
    /// and keep that height once the branches arrive. The read is a
    /// `for-each-ref`, fast enough that the click still feels immediate.
    @objc private func openBranchSwitcher(_ sender: NSButton) {
        presentBranchSwitcher(from: sender)
    }

    private func presentBranchSwitcher(from anchor: NSView) {
        guard branchPopover == nil, let repo = git.repo else { return }
        Task {
            await repo.loadBranches()
            // The anchor can leave the window while branches load (the item can
            // overflow or be removed) — a popover on a windowless view throws.
            guard anchor.window != nil else { return }
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
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    /// Drop the held reference once it closes, so the next click opens a fresh one.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in branchPopover = nil }
    }

    /// Whether there's a branch worth showing: the panel is open, pointed at an
    /// actual repo, and showing something the branch and repo-action controls
    /// actually apply to — not the markdown preview, and not the file tree.
    ///
    /// Dropping them on the Files pane is not only tidiness. This whole section
    /// is bounded by the tracking separator on divider 1, so the space it has is
    /// the *inspector's* width, not the window's — at the pane's 260pt minimum,
    /// three segments plus a 180pt branch chip plus "···" cannot fit however
    /// wide the window is, and the surplus goes to the `»` menu. Reclaiming
    /// ~210pt exactly when the tree is up is what keeps that from being the
    /// normal state of the toolbar.
    private var showsBranchItem: Bool {
        git.isVisible && git.repo != nil && !markdown.isOpen && git.pane.isSourceControl
    }

    /// Insert or remove the repo-scoped items — the branch chip and the "···"
    /// actions button — so they exist only when the panel does. Removed rather
    /// than disabled: the user's read is right — a control for a collapsed panel
    /// has no business in the toolbar, and a greyed one still claims the panel's
    /// controls are app-wide. The pane buttons stay (they're what *opens* the
    /// panel); only these two, which act on open content, come and go. NSToolbar
    /// animates the insert/remove, so it reads as native.
    ///
    /// Each is inserted just before `.gitPane`, "···" first then branch, so the
    /// order lands `[···] [branch] [pane]` — recomputing the pane index per insert
    /// keeps that true whichever was already there.
    private func syncRepoItems() {
        guard let toolbar else { return }
        if showsBranchItem {
            for id in [NSToolbarItem.Identifier.gitMenu, .gitControls]
            where !toolbar.items.contains(where: { $0.itemIdentifier == id }) {
                if let paneIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .gitPane }) {
                    toolbar.insertItem(withItemIdentifier: id, at: paneIndex)
                }
            }
        } else {
            for id in [NSToolbarItem.Identifier.gitControls, .gitMenu] {
                if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) {
                    toolbar.removeItem(at: index)
                }
            }
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
            // The markdown preview displaces the git controls while it's up, so
            // their presence tracks it.
            _ = markdown.isOpen
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
    /// `.gitControls` and `.gitMenu` are left out here and inserted by
    /// `syncRepoItems` only while the panel is open; the allowed set below still
    /// lists them, which is what lets them be inserted at all.
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
            ids.insert(contentsOf: [.gitMenu, .gitControls], at: paneIndex)
        }
        return ids
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids = identifiers
        if let paneIndex = ids.firstIndex(of: .gitPane) {
            ids.insert(contentsOf: [.gitMenu, .gitControls], at: paneIndex)
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
            gitControlsItem = item
            // A fresh button starts at width 0, so the change-guard in
            // `updateBranchButton` must not skip it.
            lastBranchTitle = nil
            updateBranchButton()
            return item
        case .gitMenu:
            // The repo-actions "···" button. A plain NSButton whose click pops an
            // NSMenu (built in `openGitMenu`), not an NSPopUpButton: a pop-up would
            // draw its own disclosure arrow next to the ellipsis and reserve menu
            // space we don't want. One narrow icon so it can't overflow the strip.
            let button = NSButton(title: "", target: self, action: #selector(openGitMenu))
            button.bezelStyle = .toolbar
            button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Repository actions")
            button.imagePosition = .imageOnly
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Actions"
            item.toolTip = "Fetch, push, and more"
            item.visibilityPriority = .low
            gitMenuItem = item
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
            let panes = InspectorPane.allCases
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
            // The panel's only opener — it overflows last, after the branch chip
            // and "···" (both `.low`), which act on an open panel and lose
            // nothing by dropping into the `»` menu first.
            item.visibilityPriority = .high
            paneControl = segmented
            paneItem = item
            syncToolbar()
            return item
        default:
            return nil
        }
    }
}
