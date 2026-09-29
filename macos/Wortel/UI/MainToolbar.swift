import AppKit
import Observation
import SwiftUI

/// The window toolbar.
///
/// The whole point of this file is the two `NSTrackingSeparatorToolbarItem`s.
/// They bind titlebar sections to the split view's dividers, which is what makes
/// the window title start at the sidebar's trailing edge and the side column's
/// tabs start at the column's leading edge — the alignment is a real constraint
/// on a real divider, not padding that happens to look right.
///
/// Item order defines the sections:
///
///     [ sidebar section ] |divider 0| [ content section ] |divider 1| [ side column ]
///
/// The side column's section holds its tab strip and, at the window's trailing
/// edge, the button that shows and hides the column. That is the ChatGPT app's
/// arrangement: the titlebar over a pane is that pane's tab row, and whatever
/// only makes sense on one tab (a branch, a repo's remote actions) lives inside
/// that tab rather than in the row above it.
///
/// On macOS 26 the standard items pick up Liquid Glass automatically (it keys
/// off the linked SDK, not the deployment target). Nothing here asks for that.
extension NSToolbarItem.Identifier {
    static let trackingSidebar = NSToolbarItem.Identifier("wortel.tracking.sidebar")
    static let trackingInspector = NSToolbarItem.Identifier("wortel.tracking.inspector")
    /// The side column's tabs. Present while the column is up; the column's
    /// section has no room to speak of while it's collapsed.
    static let sideTabs = NSToolbarItem.Identifier("wortel.sideTabs")
    /// Shows and hides the side column, at the window's trailing edge whether
    /// the column is up or not.
    static let toggleSideColumn = NSToolbarItem.Identifier("wortel.toggleSideColumn")
    /// Servers and builds the sessions are still running. Lives at the trailing
    /// edge of the *content* section, on the terminal's side of the column's
    /// tracking separator, because what a session is running is a fact about the
    /// session and not about what the column beside it is showing. Inserted and
    /// removed with the list itself (see `syncProcessItem`), so an ordinary
    /// terminal that has started nothing carries no extra chrome.
    static let runningJobs = NSToolbarItem.Identifier("wortel.runningJobs")
}

@MainActor
final class MainToolbarDelegate: NSObject, NSToolbarDelegate, NSPopoverDelegate {
    private weak var splitView: NSSplitView?
    private let git: GitPanelModel
    /// What the sessions are still running. Drives whether the item exists at
    /// all, and fills the popover it opens.
    private let processes: ProcessMonitor
    /// The session on screen. The pill and its popover are about this session
    /// only: a server is a session's, and a toolbar that showed every session's
    /// servers whichever one you were in said nothing about the one you were in.
    /// Read inside observation tracking, so switching session re-draws the pill.
    /// Set by AppDelegate.
    var selectedSession: () -> UUID? = { nil }
    /// A side terminal's title, read from the selected session inside
    /// observation tracking so a tab's label follows its shell. Set by
    /// AppDelegate.
    var sideTerminalTitle: (UUID) -> String? = { _ in nil }
    /// The window's toolbar, so the tab strip can be inserted and removed as the
    /// column opens and closes. Set by AppDelegate right after it builds it.
    weak var toolbar: NSToolbar?
    /// The tab strip, held so it can be re-synced from anywhere the column
    /// changes: a tab opened from the menu, a session switch, a divider drag.
    private var tabStrip: SideTabStrip?
    private weak var toggleButton: NSButton?
    private weak var runningJobsItem: NSToolbarItem?
    private weak var runningJobsButton: NSButton?
    /// The pill's width, set from its content plus `chipPadding`. Left to the
    /// bezel, the toolbar sized the capsule on its own terms and the title sat
    /// off centre inside it. Held strongly: measuring the natural width means
    /// deactivating it, and a deactivated constraint is owned by nobody.
    private var runningJobsWidthConstraint: NSLayoutConstraint?
    /// What the pill last drew. The title is an attributed string with an image
    /// in it, and attachments compare by identity, so comparing titles said
    /// "changed" on every scan and re-measured the pill every ten seconds.
    private var runningJobsDrawnStatus: RunningStatus?
    /// The open jobs popover, kept so a second click doesn't stack another.
    private var runningJobsPopover: NSPopover?
    /// Air added past the pill's fitted size so the bezel centres its title with
    /// a little room on each side.
    private static let chipPadding: CGFloat = 12
    /// Observer for the split view's resizes, which is what changes how much room
    /// the tab strip has. Kept so it can be removed with the delegate.
    private var resizeObserver: NSObjectProtocol?

    init(splitView: NSSplitView, git: GitPanelModel, processes: ProcessMonitor) {
        self.splitView = splitView
        self.git = git
        self.processes = processes
        super.init()
        observeProcesses()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTabStrip() }
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    // MARK: - Side column

    /// Start following the column. Called once the closures above are set: the
    /// first tracking pass reads the tab titles through `sideTerminalTitle`, and
    /// run from `init` it would read the placeholder and never learn that a
    /// restored terminal's title can change.
    func startObservingColumn() {
        observeColumn()
        syncColumnItems()
    }

    /// Keep the strip and the toggle honest when the column moves without them.
    /// @Observable's tracking is one-shot, so the observer re-arms itself.
    private func observeColumn() {
        withObservationTracking {
            _ = git.isVisible
            _ = git.tabs
            _ = git.activeTab
            for id in git.tabs.compactMap(\.terminalID) { _ = sideTerminalTitle(id) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncColumnItems()
                self.observeColumn()
            }
        }
    }

    /// The strip exists while the column is up.
    private func syncColumnItems() {
        if let toolbar {
            let present = toolbar.items.contains { $0.itemIdentifier == .sideTabs }
            if git.isVisible, !present,
               let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .trackingInspector }) {
                toolbar.insertItem(withItemIdentifier: .sideTabs, at: index + 1)
            } else if !git.isVisible, present,
                      let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .sideTabs }) {
                toolbar.removeItem(at: index)
            }
        }
        toggleButton?.state = git.isVisible ? .on : .off
        updateTabStrip()
    }

    private func updateTabStrip() {
        guard let tabStrip else { return }
        let items = git.tabs.map { tab -> SideTabStrip.Item in
            switch tab {
            case .pane(let pane):
                return .init(tab: tab, title: pane.title, symbol: pane.symbol)
            case .terminal(let id):
                return .init(tab: tab, title: Self.terminalTitle(sideTerminalTitle(id)),
                             symbol: "apple.terminal")
            }
        }
        tabStrip.update(items: items, active: git.activeTab, availableWidth: stripRoom())
    }

    /// How wide the strip may draw: the column, less the toggle at its end and
    /// the section's own insets.
    private func stripRoom() -> CGFloat {
        guard let splitView, let column = splitView.arrangedSubviews.last else { return 400 }
        return max(120, column.frame.width - 72)
    }

    /// What a shell titled itself, trimmed to what fits on a tab. Shells title a
    /// terminal with `user@host:path`, and the path's last component is the part
    /// that tells two terminals apart.
    private static func terminalTitle(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return "Terminal"
        }
        if let colon = raw.lastIndex(of: ":"), raw[..<colon].contains("@") {
            let path = String(raw[raw.index(after: colon)...])
            let leaf = (path as NSString).lastPathComponent
            return leaf.isEmpty ? path : leaf
        }
        return raw
    }

    /// The "+" menu: a terminal first, because a new one is what "+" usually
    /// means, then the panes, ticked when they're already in the strip.
    private func presentNewTabMenu(from anchor: NSView) {
        let menu = NSMenu()
        let terminal = ClosureMenuItem(title: "New Terminal") { [weak self] in
            self?.git.openTerminal()
        }
        terminal.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
        terminal.keyEquivalent = "`"
        terminal.keyEquivalentModifierMask = [.control]
        menu.addItem(terminal)
        menu.addItem(.separator())
        for pane in InspectorPane.allCases {
            let item = ClosureMenuItem(title: pane.title) { [weak self] in
                self?.git.show(pane)
            }
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            item.state = git.tabs.contains(.pane(pane)) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func toggleSideColumn(_ sender: NSButton) {
        git.toggle()
        sender.state = git.isVisible ? .on : .off
    }

    // MARK: - Running jobs

    /// The jobs list as a menu, for the toolbar's `»` overflow.
    private func runningJobsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let snapshot = runningJobsSnapshot
        for job in snapshot.work + snapshot.orphans {
            let port = job.primaryPort.map { " (:\($0))" } ?? ""
            let size = RunningJobsList.size(job.footprint)
            let title = job.isKillable
                ? "Stop \(job.label)\(port), \(size)"
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

    /// Drop the held reference once it closes, so the next click opens a fresh one.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            runningJobsPopover = nil
            // The list may have emptied while it was open, in which case the
            // item was left standing rather than yanked out from under it.
            syncProcessItem()
        }
    }

    /// Keep the running pill's overflow form as current as its last scan.
    private func updateMenuForms() {
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

    /// Whether there is anything to show. The item is absent, not disabled, when
    /// a session has started nothing: an empty popover is chrome that teaches
    /// you to ignore it, and this is meant to be noticed on the days it appears.
    /// Agents alone are not "running something" — that is just having sessions
    /// open, and it would put this item in the toolbar permanently.
    private var showsRunningJobsItem: Bool { runningJobsSnapshot.hasWork }

    /// What the selected session is running, and anything it started that has
    /// already left. Leftovers nobody owns are not in it: they would put the
    /// pill in every session, which is the thing this scoping exists to stop.
    private var runningJobsSnapshot: RunningJobsSnapshot {
        guard let id = selectedSession() else { return .empty }
        return processes.snapshot.scoped(to: id)
    }

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

    /// A status pill, the way Xcode's activity view and Proxyman's "Listening
    /// on" capsule do it: the state itself, in the toolbar, not an icon that
    /// stands for it.
    ///
    /// This used to be one glyph (`aqi.medium`) that carried no state, on the
    /// reasoning that the item only exists while something runs. True, but it
    /// made the one fact people open this for, which port, cost a click every
    /// time. `bun dev :3000` answers it where you are already looking.
    ///
    /// The dot is the same green as the rows' dot, so "listening" means one
    /// thing in both places.
    private func updateRunningJobsButton() {
        guard let button = runningJobsButton else { return }
        let snapshot = runningJobsSnapshot
        let status = snapshot.status
        if status != runningJobsDrawnStatus {
            runningJobsDrawnStatus = status
            button.attributedTitle = Self.runningJobsTitle(status)
            // Measure unconstrained, then pin: the same move as the branch chip,
            // so the bezel centres the content with equal air either side.
            runningJobsWidthConstraint?.isActive = false
            runningJobsWidthConstraint?.constant = ceil(button.fittingSize.width) + Self.chipPadding
            runningJobsWidthConstraint?.isActive = true
        }
        let spoken = ([status.title] + status.ports).joined(separator: " ")
        button.setAccessibilityLabel("Running: \(spoken)")

        let count = snapshot.work.count + snapshot.orphans.count
        let noun = count == 1 ? "job" : "jobs"
        button.toolTip = "\(count) \(noun) running in this session"
        runningJobsItem?.toolTip = button.toolTip
    }

    /// The longest title the pill carries before it gives way to an ellipsis.
    /// Counted in characters rather than measured: a label is a command line,
    /// and the addresses after it are the part that must never be the one cut.
    private static let maxRunningTitleLength = 22

    private static func runningJobsTitle(_ status: RunningStatus) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let result = NSMutableAttributedString()

        let dotColor: NSColor = status.isServing ? .systemGreen : .tertiaryLabelColor
        if let dot = NSImage(systemSymbolName: status.isServing ? "circle.fill" : "circle",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular)
                .applying(.init(paletteColors: [dotColor]))) {
            let attachment = NSTextAttachment()
            attachment.image = dot
            // Centred on the cap height, same as the branch chip's glyph.
            attachment.bounds = CGRect(
                x: 0, y: (font.capHeight - dot.size.height) / 2,
                width: dot.size.width, height: dot.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }

        var title = status.title
        if title.count > maxRunningTitleLength {
            title = String(title.prefix(maxRunningTitleLength - 1)) + "\u{2026}"
        }
        result.append(NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]))

        if !status.ports.isEmpty {
            // A port is an address: monospaced digits so `:3000` and `:5173`
            // hold their width as the list changes, and secondary so the name
            // stays the headline.
            result.append(NSAttributedString(
                string: "  " + status.ports.joined(separator: " "),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }
        return result
    }

    /// Re-arming observation of the scan, so the item appears and disappears with
    /// the list rather than at the next unrelated toolbar change.
    private func observeProcesses() {
        withObservationTracking {
            _ = processes.snapshot
            _ = selectedSession()
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
        guard let session = selectedSession() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let list = RunningJobsList(
            monitor: processes,
            session: session,
            dismiss: { [weak self] in self?.runningJobsPopover?.performClose(nil) })
        let host = NSHostingController(rootView: list)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.delegate = self
        runningJobsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: - NSToolbarDelegate

    /// The flexible spaces do the aligning, and each one only stretches within its
    /// own section because the tracking separators bound them: the first pushes
    /// the sidebar toggle to the sidebar's trailing edge (clear of the traffic
    /// lights), the second fills the content section, the third pushes the
    /// column toggle to the window's trailing edge. The tab strip, when present,
    /// sits right after the column's separator, at the column's leading edge.
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
            .toggleSideColumn,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids = identifiers
        // Present at launch if the restored session already has the column up,
        // so the strip isn't missing until the first change wakes the observer.
        if git.isVisible, let index = ids.firstIndex(of: .trackingInspector) {
            ids.insert(.sideTabs, at: index + 1)
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
        if let index = ids.firstIndex(of: .trackingInspector) {
            ids.insert(.sideTabs, at: index + 1)
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
        for anchor in [NSToolbarItem.Identifier.trackingInspector] {
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
        case .sideTabs:
            let strip = tabStrip ?? SideTabStrip()
            strip.onSelect = { [weak self] tab in self?.git.select(tab) }
            strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
            strip.onCloseOthers = { [weak self] keep in
                guard let self else { return }
                self.git.select(keep)
                for tab in self.git.tabs where tab != keep { self.git.requestClose(tab) }
            }
            strip.onAdd = { [weak self] anchor in self?.presentNewTabMenu(from: anchor) }
            tabStrip = strip
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = strip
            item.label = "Tabs"
            item.visibilityPriority = .high
            updateTabStrip()
            return item
        case .toggleSideColumn:
            let button = NSButton(title: "", target: self, action: #selector(toggleSideColumn(_:)))
            button.bezelStyle = .toolbar
            button.setButtonType(.pushOnPushOff)
            button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Side Column")
            button.imagePosition = .imageOnly
            button.state = git.isVisible ? .on : .off
            toggleButton = button
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Side Column"
            item.toolTip = "Show or hide the side column"
            item.visibilityPriority = .high
            return item
        case .runningJobs:
            // A capsule carrying its own status (see `updateRunningJobsButton`),
            // built like the branch chip: a real NSButton so the whole pill
            // takes the click. Its title is capped in characters, so it can
            // never widen the content section enough to push the repo controls
            // into `»`.
            let button = NSButton(title: "", target: self, action: #selector(openRunningJobs))
            button.bezelStyle = .toolbar
            button.imagePosition = .noImage
            button.lineBreakMode = .byTruncatingTail
            let width = button.widthAnchor.constraint(equalToConstant: 0)
            runningJobsWidthConstraint = width
            // A fresh button has drawn nothing, whatever the last one showed.
            runningJobsDrawnStatus = nil
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Running"
            item.visibilityPriority = .low
            runningJobsButton = button
            runningJobsItem = item
            updateRunningJobsButton()
            return item
        default:
            return nil
        }
    }
}
