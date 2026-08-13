import AppKit
import SwiftUI

/// Every branch the picker can offer, and the one place that knows the remote
/// half arrives late.
///
/// The split is not tidiness. Local branches cost ~0.05ms each to list and are
/// as many as you have personally checked out; remote-tracking branches are as
/// many as the repository has ever had, and listing 4000 of them costs 140ms.
/// So the sheet opens on the local half and this fills in the rest behind it.
/// Everything reading the catalogue therefore has to be correct while the
/// remote half is still empty, which is why `remotes(carrying:)` answering
/// "none yet" is a transient and not a verdict: the creation path re-asks git
/// (see SessionManager.openSession) rather than trusting this.
@Observable
@MainActor
final class BranchCatalog {
    private(set) var local: [GitBranch]
    private(set) var remote: [GitBranch] = []
    private(set) var isLoadingRemote = false
    /// Branches that already have a worktree. Choosing one *goes* to it rather
    /// than making a second, which is worth saying before the click.
    let withWorktree: Set<String>

    /// Case folded once, for the same reason matches are stored: a
    /// locale-aware scan per branch per keystroke came to 9.5ms over 5000.
    private var foldedLocal: [String]
    private var foldedRemote: [String] = []
    /// Folded local names, for an O(1) `hasLocal`.
    private var localFolded: Set<String>
    /// Short branch name -> the remotes carrying it, built once when the remote
    /// half lands, because the alternative is walking every remote ref per ask.
    private var remotesByShort: [String: [String]] = [:]

    /// `origin/release/2026` -> `release/2026`. Split at the *first* slash: a
    /// remote's name cannot contain one, and a branch's very much can.
    static func shortName(_ full: String) -> String {
        guard let slash = full.firstIndex(of: "/") else { return full }
        return String(full[full.index(after: slash)...])
    }

    init(local: [GitBranch], withWorktree: Set<String>) {
        self.local = local
        self.withWorktree = withWorktree
        foldedLocal = local.map { $0.name.lowercased() }
        localFolded = Set(local.map { $0.name.lowercased() })
    }

    func beginLoadingRemote() { isLoadingRemote = true }

    func finishLoadingRemote(_ branches: [GitBranch]) {
        remote = branches
        foldedRemote = branches.map { $0.name.lowercased() }
        remotesByShort = branches.reduce(into: [:]) { table, branch in
            let short = Self.shortName(branch.name).lowercased()
            let remote = String(branch.name.prefix(while: { $0 != "/" }))
            table[short, default: []].append(remote)
        }
        isLoadingRemote = false
    }

    var hasAnyBranch: Bool { !local.isEmpty || !remote.isEmpty }

    func hasLocal(_ name: String) -> Bool { localFolded.contains(name.lowercased()) }

    /// Which remotes carry a branch of this short name.
    func remotes(carrying name: String) -> [String] {
        remotesByShort[name.lowercased()] ?? []
    }

    /// One pass per keystroke over each half, against the folded copies.
    func filtered(_ needle: String) -> (local: [GitBranch], remote: [GitBranch]) {
        guard !needle.isEmpty else { return (local, remote) }
        return (zip(local, foldedLocal).filter { $0.1.contains(needle) }.map(\.0),
                zip(remote, foldedRemote).filter { $0.1.contains(needle) }.map(\.0))
    }
}

/// What the filter list is showing: the query, what it matched, and which row
/// is selected.
///
/// Matches are stored rather than computed, which is the same code costing
/// three times less: one SwiftUI body evaluation reads them three times (the
/// `isEmpty` test, its negation, and the `ForEach`), and each read used to be a
/// fresh scan of every branch.
@Observable
@MainActor
final class BranchPickerModel {
    let catalog: BranchCatalog
    var query = "" { didSet { refilter() } }

    private(set) var localMatches: [GitBranch] = []
    private(set) var remoteMatches: [GitBranch] = []
    var selection = 0

    init(catalog: BranchCatalog) {
        self.catalog = catalog
        refilter()
    }

    var rowCount: Int { localMatches.count + remoteMatches.count }

    var selectedBranch: GitBranch? {
        let rows = localMatches + remoteMatches
        guard rows.indices.contains(selection) else { return rows.first }
        return rows[selection]
    }

    func move(by delta: Int) {
        guard rowCount > 0 else { return }
        selection = (selection + delta + rowCount) % rowCount
    }

    /// Also the hook for the remote half landing: the catalogue changed under
    /// the filter, so the filter runs again.
    func refilter() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let (local, remote) = catalog.filtered(needle)
        localMatches = local
        remoteMatches = remote
        selection = min(selection, max(0, rowCount - 1))
    }
}

/// The "From" control: the ref a new branch forks from, and a click that opens
/// the filter list right under it.
///
/// **One click, one surface.** It was an `NSPopUpButton` whose menu listed the
/// local branches and carried a `Filter…` item that opened a popover on top of
/// the sheet: a menu to get to a filter to get to the branches. A control whose
/// job is "choose from a list you may have to search" should show that list,
/// once, where you clicked.
///
/// A plain button rather than a pop-up button, because it does not open a menu
/// and the shape of a control is a promise: a pop-up that opens something else
/// has no arrow keys, no type-select, and describes itself wrongly to
/// VoiceOver.
@MainActor
final class BranchChooser: NSButton, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model: BranchPickerModel
    private var keys: Any?

    /// The ref to fork from.
    private(set) var branch: String? {
        didSet { updateTitle() }
    }

    /// Called when the selection changes, so the sheet can restate what the
    /// Create button is about to do.
    var onChange: (() -> Void)?

    /// A floor, not the width: the popover matches the button it hangs off when
    /// that is wider. At 300 against a 362pt button, `copy-and-docs` rendered as
    /// `c…cs` and `attention-rollup` as `atte…rollup`, which is a list you
    /// cannot read holding the space of one you can. The other half of that fix
    /// was giving the name priority over the upstream note, so this no longer
    /// has to be generous to be readable.
    private static let minPopoverWidth: CGFloat = 360

    init(catalog: BranchCatalog, initial: String?) {
        model = BranchPickerModel(catalog: catalog)
        super.init(frame: .zero)
        branch = initial

        bezelStyle = .rounded
        controlSize = .large
        // Left, to sit under the branch field's text rather than floating in
        // the middle of the row. The chevron stays pinned to the trailing edge:
        // the alignment moves the title within the space the image leaves, it
        // does not drag the image along with it.
        alignment = .left
        imagePosition = .imageTrailing
        image = NSImage(systemSymbolName: "chevron.up.chevron.down",
                        accessibilityDescription: nil)
        target = self
        action = #selector(showList)
        updateTitle()

        // Transient: clicking anywhere else closes it. A picker that can leave
        // you with nothing to click is the bug this whole control came from.
        popover.behavior = .transient
        // Every close comes through here, which is the only way to be sure the
        // key monitor goes with it: a transient click-away and a second click on
        // the button both close the popover without passing through `take` or
        // the Escape case, and each would otherwise leave an application-wide
        // keyDown monitor installed for the rest of this control's life. It
        // passes events through while the popover is down, so the damage was
        // latent rather than visible — but "an arrow-key interceptor nobody
        // asked for, kept honest by one guard" is not a thing to leave running.
        popover.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func updateTitle() {
        title = branch ?? "Choose a branch\u{2026}"
    }

    @objc private func showList() {
        guard !popover.isShown else { return popover.performClose(nil) }
        // A fresh filter each time. Reopening onto whatever you typed a week
        // ago hides most of the list and looks like a list with things missing.
        model.query = ""
        model.selection = 0
        // Built here rather than in init because the width is the button's, and
        // the button has no width until it has been laid out. A SwiftUI view
        // with no definite width leaves the hosting controller nothing to
        // report, so this is also what gives the popover a size at all.
        let width = max(bounds.width, Self.minPopoverWidth)
        let host = NSHostingController(rootView: BranchChooserList(model: model, width: width) {
            [weak self] branch in self?.take(branch)
        })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Anchored to this button, which is the whole point: the thing you
        // clicked is where the list comes from.
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        watchKeys()
    }

    private func take(_ chosen: GitBranch) {
        branch = chosen.name
        popover.performClose(nil)
        stopWatchingKeys()
        onChange?()
    }

    /// The remote half landing changes what the list can offer.
    func catalogChanged() { model.refilter() }

    /// Arrows and Return, taken before the filter field sees them, because a
    /// focused `TextField` is exactly what swallows those. Guarded on the
    /// popover being shown, and torn down when it closes: an application-wide
    /// monitor that outlives its reason swallows arrow keys everywhere.
    private func watchKeys() {
        stopWatchingKeys()
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            switch event.keyCode {
            case 126: self.model.move(by: -1); return nil          // up
            case 125: self.model.move(by: 1); return nil           // down
            case 36, 76:                                           // return, enter
                if let branch = self.model.selectedBranch { self.take(branch) }
                return nil
            case 53:                                               // escape
                self.popover.performClose(nil)
                self.stopWatchingKeys()
                return nil
            default: return event
            }
        }
    }

    private func stopWatchingKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { stopWatchingKeys() }
    }

    deinit { if let keys { NSEvent.removeMonitor(keys) } }
}

/// What the chooser's popover hosts: the shared list, no create row. You fork
/// from a ref that exists and from nothing else.
private struct BranchChooserList: View {
    @Bindable var model: BranchPickerModel
    let width: CGFloat
    let choose: (GitBranch) -> Void

    var body: some View {
        BranchOptionList(
            query: $model.query,
            local: model.localMatches,
            remote: model.remoteMatches,
            selection: $model.selection,
            isLoadingRemote: model.catalog.isLoadingRemote,
            hasAnyBranch: model.catalog.hasAnyBranch,
            activate: choose)
            .frame(width: width)
    }
}
