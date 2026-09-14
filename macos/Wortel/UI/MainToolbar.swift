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
    /// Servers and builds the sessions are still running. Lives at the trailing
    /// edge of the *content* section, on the terminal's side of the inspector's
    /// tracking separator, because what a session is running is a fact about the
    /// session and not about the repository the panel beside it is showing.
    /// Inserted and removed with the list itself (see `syncProcessItem`), so an
    /// ordinary terminal that has started nothing carries no extra chrome.
    static let runningJobs = NSToolbarItem.Identifier("wortel.runningJobs")
}

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate, NSPopoverDelegate {
    private weak var splitView: NSSplitView?
    private let git: GitPanelModel
    /// What the sessions are still running. Drives whether the item exists at
    /// all, and fills the popover it opens.
    private let processes: ProcessMonitor
    /// Names for the popover's section headings. Set by AppDelegate.
    var sessionName: (UUID) -> String? = { _ in nil }
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
    ///
    /// Held strongly, unlike the views around it: measuring the natural width
    /// means deactivating this, and a deactivated constraint is owned by nobody
    /// — a weak reference to one can be nil again by the time we go to switch it
    /// back on, leaving a chip whose width nothing controls.
    private var branchWidthConstraint: NSLayoutConstraint?
    /// The open branch popover, kept only so a second click while it's up doesn't
    /// stack a second one.
    private var branchPopover: NSPopover?
    /// Everything `updateBranchButton` remembers about the chip it last drew,
    /// kept together because it belongs to **the button**, not to this delegate.
    ///
    /// `syncRepoItems` rebuilds that button every time the panel opens, closes
    /// or changes pane, and a fresh one that inherits the previous one's memory
    /// is a chip that never gets sized: every change-guard answers "no change",
    /// and the width constraint keeps the zero it was born with. That is a chip
    /// collapsed to an ellipsis, and it was one forgotten line away — so the
    /// reset is one assignment, not four.
    private struct BranchChipState {
        /// The branch the chip was last sized for. Re-fitting on every
        /// observation tick made the chip (and the controls beside it) jitter.
        var title: String?
        /// Whether it's currently the glyph alone, so the title is only rebuilt
        /// when the mode actually flips.
        var isIconOnly = false
        /// Its width with the name at full length. `fittingSize` needs the width
        /// constraint off to answer, so this is only remeasured when the name or
        /// the mode changes.
        var naturalWidth: CGFloat = 0
        /// The full title's own width, measured alongside `naturalWidth`. The
        /// difference between the two is the chrome the bezel adds — chevron,
        /// insets — which is what lets a chosen chip width be turned back into
        /// the text width `branchTitle` has to fit into.
        var fullTextWidth: CGFloat = 0
        /// The width last written to the constraint, so a resize that doesn't
        /// move the chip doesn't touch layout at all. Negative until written,
        /// which is what makes a fresh button always get sized.
        var width: CGFloat = -1
    }
    private var chip = BranchChipState()
    /// The toolbar items with custom views, held so their overflow-menu forms
    /// can track live state. Without a `menuFormRepresentation`, a view item
    /// that lands in the toolbar's `»` menu is a dead, disabled label.
    private weak var paneItem: NSToolbarItem?
    private weak var gitControlsItem: NSToolbarItem?
    private weak var gitMenuItem: NSToolbarItem?
    private weak var runningJobsItem: NSToolbarItem?
    private weak var runningJobsButton: NSButton?
    /// The open jobs popover, kept so a second click doesn't stack another.
    private var runningJobsPopover: NSPopover?
    /// The chip stops growing here and truncates the branch name instead — the
    /// inspector section is 260pt at its narrowest, and an unbounded chip was
    /// what shoved the whole section into the `»` menu. High enough that ordinary
    /// three-word branch names (`rename-to-terminaal` measures 190) show whole:
    /// the cap is there for the pathological name, not the long one.
    private static let maxBranchChipWidth: CGFloat = 200
    /// Below this *the section* stops getting a name at all and the chip becomes
    /// the branch glyph alone. A name squeezed under this is two characters and an
    /// ellipsis — it identifies nothing, and it's still wide enough to push the
    /// section into the `»` menu, which is the worse outcome of the two: an icon
    /// that opens the switcher is a control, and a `»` menu is a control you have
    /// to go looking for.
    ///
    /// This is a threshold on the room available, **not** a floor on the chip:
    /// making it both is what padded `main` out to a chip half of which was empty.
    private static let minBranchChipWidth: CGFloat = 96
    /// The floor on the chip's own width, which only a very short name reaches.
    /// Low enough that `main` is still fit-content, high enough that the capsule
    /// doesn't read as stubby beside the round `···` button.
    private static let branchChipFloor: CGFloat = 72
    /// The glyph-only chip: one symbol in a toolbar bezel.
    private static let iconOnlyChipWidth: CGFloat = 34
    /// Air added past the fitted size so the bezel centres the name with a little
    /// room on each side. It's part of the chip's natural width, but the *name*
    /// never pays for it: a chip that's already being squeezed should spend its
    /// last points on letters, not on symmetry. Small because the toolbar bezel
    /// brings ~32pt of its own inset and chevron — 28 on top of that was what made
    /// a short branch look padded rather than fitted.
    private static let chipPadding: CGFloat = 12
    /// The widest inspector section the chip has actually been seen to overflow
    /// at. Everything at or below it shows the glyph alone — see `verifyChipFits`,
    /// which is what turns the width estimate below from a promise into a guess
    /// that gets corrected.
    private var overflowedAtSection: CGFloat = 0
    /// The one pending "did that fit?" check (see `verifyChipFits`).
    private var fitCheckWork: DispatchWorkItem?
    /// Measured width of the section's fixed items; see `fixedSectionWidth`.
    private var cachedFixedSectionWidth: CGFloat?
    private static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "toolbar")

    /// Observer for the split view's resizes, which is what changes how much room
    /// the branch chip has. Kept so it can be removed with the delegate.
    private var resizeObserver: NSObjectProtocol?

    init(splitView: NSSplitView, git: GitPanelModel, processes: ProcessMonitor) {
        self.splitView = splitView
        self.git = git
        self.processes = processes
        super.init()
        observePanel()
        observeProcesses()
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
                paneControl.setSelected(git.isVisible && pane == git.pane, forSegment: index)
            }
        }
        syncRepoItems()
        syncProcessItem()
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
                entry.state = (git.isVisible && pane == git.pane) ? .on : .off
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
        if let runningJobsItem {
            // A submenu rather than a popover anchor: an overflowed item has no
            // on-screen view to hang a popover from, and the list is short
            // enough to be a menu. Quitting stays available from here, which is
            // the part that would otherwise be lost.
            let form = NSMenuItem(title: "Running", action: nil, keyEquivalent: "")
            form.submenu = runningJobsMenu()
            runningJobsItem.menuFormRepresentation = form
        }
    }

    /// The jobs list as a menu, for the toolbar's `»` overflow.
    private func runningJobsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let snapshot = processes.snapshot
        for job in snapshot.work + snapshot.orphans {
            let port = job.primaryPort.map { " (:\($0))" } ?? ""
            let size = RunningJobsList.size(job.footprint)
            let title = job.isKillable
                ? "Quit \(job.label)\(port), \(size)"
                : "\(job.label)\(port), \(size)"
            let entry = ClosureMenuItem(title: title) { [weak self] in
                guard job.isKillable else { return }
                self?.processes.quit(job)
            }
            entry.isEnabled = job.isKillable
            menu.addItem(entry)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "Nothing running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    /// Pop the repo-actions menu — fetch, pull, push — below the "···" button. Built
    /// fresh on each click so it reads live state (an in-flight op, whether
    /// there's a remote, the ahead count) without any observation wiring; a
    /// disabled item just can't be chosen. `autoenablesItems = false` so our
    /// explicit `isEnabled` wins over AppKit's target/action validation.
    @objc private func openGitMenu(_ sender: NSButton) {
        guard let menu = repoActionsMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The fetch/pull/push menu, shared by the "···" click and the overflow (`»`)
    /// form. nil when no repo is open.
    private func repoActionsMenu() -> NSMenu? {
        guard let repo = git.repo else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let busy = repo.isFetching || repo.isPulling || repo.isPushing

        let fetch = ClosureMenuItem(title: repo.isFetching ? "Fetching…" : "Fetch") {
            Task { await repo.fetch() }
        }
        fetch.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        fetch.isEnabled = !busy && repo.canFetch
        menu.addItem(fetch)

        // Between fetch and push, in the order the work happens. Named with the
        // count when the last fetch already found commits waiting; plain "Pull"
        // otherwise, because pull fetches first and may well find some.
        let pullTitle: String
        if repo.isPulling {
            pullTitle = "Pulling…"
        } else {
            let behind = repo.status.behind
            pullTitle = behind > 0 ? "Pull \(behind) Commit\(behind == 1 ? "" : "s")" : "Pull"
        }
        let pull = ClosureMenuItem(title: pullTitle) { Task { await repo.pull() } }
        pull.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        pull.isEnabled = !busy && repo.canPull
        menu.addItem(pull)

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
        if branch != chip.title || iconOnly != chip.isIconOnly {
            chip.title = branch
            chip.isIconOnly = iconOnly
            if iconOnly {
                // No room for a name worth reading: the chip becomes the branch
                // glyph, and the name moves to the tooltip. The chevron goes too
                // — it's an affordance, and an affordance that costs half the
                // control's width at this size isn't one.
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.branchGlyphImage()
                button.imagePosition = .imageOnly
            } else {
                let title = Self.branchTitle(branch)
                chip.fullTextWidth = title.size().width
                button.attributedTitle = title
                button.image = Self.chevronImage()
                button.imagePosition = .imageTrailing
            }
            // Widen past the fitted size so the bezel centres the content with a
            // little air on each side. Deactivate the width first so
            // `fittingSize` reports the content width, not the last padded one —
            // and, since the button is unconstrained in that moment, a content
            // width measured on one line.
            branchWidthConstraint?.isActive = false
            chip.naturalWidth = button.fittingSize.width + Self.chipPadding
            branchWidthConstraint?.isActive = true
            // The name changed, so the fitted title below has to be rebuilt even
            // if the width it's fitted to lands on the same number.
            chip.width = -1
        }
        // The branch, always — not "Switch branch". The chip is the one place the
        // full name can be *missing*: truncated to fit, or gone entirely when it's
        // the glyph alone. A tooltip naming the control it's already attached to
        // answers a question nobody had, where the name answers the one the
        // truncation created. What it does is the chevron's job, and the glyph's
        // accessibility description still says it for VoiceOver.
        button.toolTip = branch

        // Fit-content, bounded twice: never below the floor, never past the cap,
        // and never past the room the inspector section actually has. Truncation
        // takes it from there, so the name shortens as the column narrows rather
        // than the whole section dropping into `»`.
        let width = iconOnly
            ? Self.iconOnlyChipWidth
            : min(max(chip.naturalWidth, Self.branchChipFloor),
                  Self.maxBranchChipWidth, available)
        guard abs(width - chip.width) > 0.5 else { return }
        chip.width = width
        branchWidthConstraint?.constant = width
        if !iconOnly {
            // Re-fit the name to the width just chosen. What the bezel itself
            // costs — its insets and the chevron — is everything in the natural
            // width that isn't the text or the padding, and it doesn't change
            // with the chip's size; the rest of the width is the name's to use.
            // Doing this *here* rather than in the re-title block above is the
            // point: the title depends on the width, and the width isn't known
            // until the clamping is done.
            let bezel = chip.naturalWidth - Self.chipPadding - chip.fullTextWidth
            button.attributedTitle = Self.branchTitle(branch, textWidth: max(0, width - bezel))
        }
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
        return section - fixedSectionWidth() - Self.sectionChrome
    }

    /// What the section holds besides the chip: three fixed segments and one
    /// glyph button. Measured once and kept, because neither ever changes size
    /// and `fittingSize` is a layout query — not a thing to ask twice a frame
    /// while a divider is being dragged. Cleared when either item is rebuilt.
    ///
    /// The running-jobs button is deliberately **not** counted: it lives in the
    /// content section, on the other side of the inspector's tracking separator,
    /// so it takes none of the chip's room.
    private func fixedSectionWidth() -> CGFloat {
        if let cachedFixedSectionWidth { return cachedFixedSectionWidth }
        let panes = paneControl.map { max($0.frame.width, $0.fittingSize.width) } ?? 0
        let actions = gitMenuItem?.view.map { max($0.frame.width, $0.fittingSize.width) } ?? 0
        // Nothing laid out yet — answer from the defaults and don't cache a
        // measurement of views that don't have a size to give.
        guard panes > 1, actions > 1 else { return 110 + 34 }
        cachedFixedSectionWidth = panes + actions
        return panes + actions
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
        guard !chip.isIconOnly, section > 1 else { return }
        // One pending check, not one per frame: a divider drag changes the width
        // sixty times a second, and each would otherwise leave a closure sitting
        // in the queue to re-ask a question only the final width can answer.
        fitCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
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
        fitCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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

    /// The chip's title, shortened with an ellipsis when it doesn't fit in
    /// `textWidth`. Passing nil asks for it at full length, which is how the
    /// natural width is measured.
    ///
    /// **The truncation is ours, and it has to be.** A `.toolbar` bezel on
    /// macOS 26+ lays its own title out, and that layout honours none of the four
    /// ways AppKit documents for asking a button to stay on one line — the
    /// paragraph style's `.byTruncatingTail`, or the cell's `wraps`,
    /// `usesSingleLineMode`, `lineBreakMode`. All four were measured in a real
    /// toolbar and all four still broke `update-website` at the hyphen onto a
    /// second line, growing the chip to 36pt while the buttons beside it stayed
    /// 23. The toolbar gives the item more vertical room than its content needs,
    /// so there is always a second line there to take; a string that already fits
    /// is the one thing the bezel can't undo. (Outside a toolbar the same button
    /// truncates correctly, which is why this only shows up in the app.)
    private static func branchTitle(_ branch: String, textWidth: CGFloat? = nil) -> NSAttributedString {
        let full = branchLabel(branch)
        guard let textWidth, full.size().width > textWidth else { return full }
        // Shortest-first would need a second measurement to know where to start;
        // names are short enough that walking in from the tail is cheaper than
        // being clever, and this only runs when the chip's width actually moves.
        var name = branch
        while !name.isEmpty {
            name.removeLast()
            let candidate = branchLabel(name + "\u{2026}")
            if candidate.size().width <= textWidth { return candidate }
        }
        return branchLabel("\u{2026}")
    }

    private static func branchLabel(_ name: String) -> NSAttributedString {
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
        result.append(NSAttributedString(string: name, attributes: [
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
        Task { @MainActor in
            branchPopover = nil
            runningJobsPopover = nil
            // The list may have emptied while it was open, in which case the
            // item was left standing rather than yanked out from under it.
            syncProcessItem()
        }
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
        git.isVisible && git.repo != nil && git.pane.isSourceControl
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

    /// Whether there is anything to show. The item is absent, not disabled, when
    /// a session has started nothing: an empty popover is chrome that teaches
    /// you to ignore it, and this is meant to be noticed on the days it appears.
    /// Agents alone are not "running something" — that is just having sessions
    /// open, and it would put this item in the toolbar permanently.
    private var showsRunningJobsItem: Bool { processes.snapshot.hasWork }

    private func syncProcessItem() {
        guard let toolbar else { return }
        let present = toolbar.items.contains { $0.itemIdentifier == .runningJobs }
        if showsRunningJobsItem, !present {
            let index = runningJobsInsertionIndex(in: toolbar.items.map(\.itemIdentifier))
                ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .runningJobs, at: index)
        } else if !showsRunningJobsItem, present {
            // Not while its own popover is open: pulling the anchor out from
            // under a popover the user is reading closes it mid-sentence, and
            // the last row vanishing is exactly when they are reading it.
            guard runningJobsPopover == nil else { return }
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .runningJobs }) {
                toolbar.removeItem(at: index)
            }
        }
        updateRunningJobsButton()
        // The `»` overflow form lists the jobs and their Quit actions, so it is
        // as stale as the last scan. Rebuilt here rather than only in
        // `syncToolbar`, which the *git panel* drives: without this the item
        // could sit in the overflow menu for minutes showing jobs that had
        // stopped, and on first insert it would have had no form at all, which
        // AppKit renders as a dead disabled label.
        updateMenuForms()
    }

    /// One glyph, always the same one.
    ///
    /// It used to swap between a bolt and broadcast rings depending on whether
    /// anything held a port, which was the wrong axis twice over. Changing the
    /// silhouette makes the item harder to find, and nobody was going to learn
    /// that a bolt means "running but not serving" — a distinction the list
    /// already draws properly, with a green dot and a port badge per row.
    ///
    /// The glyph carries no state because it does not have to: the item only
    /// exists when something is running, so its presence is the signal and one
    /// click is the detail. A dot field rather than an object, because this is
    /// ambient load rather than a thing, and because nothing else in this
    /// toolbar looks remotely like it.
    private static let runningJobsSymbol = "aqi.medium"

    private func updateRunningJobsButton() {
        guard let button = runningJobsButton else { return }
        let snapshot = processes.snapshot
        button.image = NSImage(systemSymbolName: Self.runningJobsSymbol,
                               accessibilityDescription: "Running")
        let count = snapshot.work.count + snapshot.orphans.count
        let noun = count == 1 ? "job" : "jobs"
        var tip = "\(count) \(noun) running in your sessions"
        if !snapshot.orphans.isEmpty {
            tip += ", \(snapshot.orphans.count) with no session left"
        }
        button.toolTip = tip
        runningJobsItem?.toolTip = button.toolTip
    }

    /// Re-arming observation of the scan, so the item appears and disappears with
    /// the list rather than at the next unrelated toolbar change.
    private func observeProcesses() {
        withObservationTracking {
            _ = processes.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncProcessItem()
                self.processes.updateActivityAssertion()
                self.observeProcesses()
            }
        }
    }

    @objc private func openRunningJobs(_ sender: NSButton) {
        guard runningJobsPopover == nil else { return }
        // Scan before showing, not after: NSPopover sizes itself to the content
        // it is handed at presentation, so a list that fills in a moment later
        // gets a popover sized for the list that was there before.
        processes.refresh()
        Telemetry.capture(.processesShown(
            jobs: CountBucket(processes.snapshot.work.count),
            orphans: CountBucket(processes.snapshot.orphans.count)))
        let popover = NSPopover()
        popover.behavior = .transient
        let list = RunningJobsList(
            monitor: processes,
            sessionName: { [weak self] in self?.sessionName($0) },
            dismiss: { [weak self] in self?.runningJobsPopover?.performClose(nil) })
        let host = NSHostingController(rootView: list)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.delegate = self
        runningJobsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
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
        // Likewise for restored sessions whose servers survived the last quit:
        // the keeper keeps them running, so they are there before any scan.
        if showsRunningJobsItem, let index = runningJobsInsertionIndex(in: ids) {
            ids.insert(.runningJobs, at: index)
        }
        return ids
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids = identifiers
        if let paneIndex = ids.firstIndex(of: .gitPane) {
            ids.insert(contentsOf: [.gitMenu, .gitControls], at: paneIndex)
        }
        if let index = runningJobsInsertionIndex(in: ids) {
            ids.insert(.runningJobs, at: index)
        }
        return ids
    }

    /// Where the running-jobs item goes: the trailing edge of the **content**
    /// section, just before the separator that starts the repo cluster.
    ///
    /// Not among the repo controls, which is where it first landed. That cluster
    /// is bound to the git panel's divider and is entirely about the repository:
    /// a branch, its remote actions, and which pane the inspector shows. What a
    /// session is still running is a fact about the session, so it belongs on the
    /// terminal's side of the divider, and the tracking separator draws the line
    /// that says so.
    ///
    /// Stated once and used by both the declared lists and the live insert,
    /// because the two used to disagree. Both inserted "before `.gitPane`", so
    /// the order came out of whichever arrived first: a session that started a
    /// server before its repo resolved got the item on one side of the repo
    /// controls, and one that resolved first got it on the other. A toolbar that
    /// rearranges itself according to history is the kind of thing nobody
    /// reports and everybody notices.
    private func runningJobsInsertionIndex(
        in ids: [NSToolbarItem.Identifier]) -> Int? {
        for anchor in [NSToolbarItem.Identifier.trackingInspector, .gitPane] {
            if let index = ids.firstIndex(of: anchor) { return index }
        }
        return nil
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
            // A fresh button starts at width 0 and remembers nothing, so
            // neither may we — every guard in `updateBranchButton` has to read
            // as "changed" or the chip is never sized. This one line is the
            // whole reason that state is a struct.
            chip = BranchChipState()
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
            item.toolTip = "Fetch, pull, push, and more"
            item.visibilityPriority = .low
            gitMenuItem = item
            cachedFixedSectionWidth = nil // this item is one of the two it measures
            return item
        case .runningJobs:
            // Same shape as the "···" button: one narrow icon whose click opens a
            // popover. Narrow so it never widens the section enough to push
            // anything into the toolbar's `»` menu.
            let button = NSButton(title: "", target: self, action: #selector(openRunningJobs))
            button.bezelStyle = .toolbar
            button.imagePosition = .imageOnly
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Running"
            item.visibilityPriority = .low
            runningJobsButton = button
            runningJobsItem = item
            updateRunningJobsButton()
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
            cachedFixedSectionWidth = nil // this item is one of the two it measures
            syncToolbar()
            return item
        default:
            return nil
        }
    }
}
