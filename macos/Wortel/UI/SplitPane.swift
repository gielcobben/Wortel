import AppKit
import Observation
import SwiftUI

// MARK: - A split's row

/// A split's row: its tabs with "+" right after the last one, and nothing
/// else. Every split has this one, the main row's, the side column's and the
/// strip's included: what a row once had of its own (the session's "…", what
/// it runs, the column's toggle, the strip's chevron) was the session's or
/// the window's and is at the end of the titlebar (`WindowControls`), or on
/// the keyboard. Along the top of the window it is a titlebar row; lower
/// down, a row on a page (`SplitLeafView`).
///
/// Nothing at the trailing end until the split is zoomed: then one button
/// says so, and puts the others back.
@MainActor
final class PaneBar: ChromeBarView, LeafBar {
    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Tab (⌥⌘T)")
    // The two ways to split this split, at the end of its own row: a
    // control sits on the thing it acts on. They were two buttons in the
    // window's corner that split "the split you're in", which the owner
    // found odd ("it's weird that they are all the way to the right, even
    // though if you have focus on a left pane and click the split it splits
    // on there"): to know what a click would do you had to know where the
    // keyboard was. The split they make holds an empty tab that asks what
    // goes there; the keys, ⌘D and ⇧⌘D, put a terminal there without asking.
    let splitRight = HoverFillButton.glyph("rectangle.split.2x1", "Split Right")
    let splitDown = HoverFillButton.glyph("rectangle.split.1x2", "Split Down")
    let unzoom = ZoomedButton()
    /// The split buttons and the zoom button, in that order. A hidden one
    /// takes no room (a stack view lets go of it).
    private let trailing = NSStackView()
    private var stripLeading: NSLayoutConstraint!
    private var stripTrailing: NSLayoutConstraint!
    private var trailingEnd: NSLayoutConstraint!
    /// Room for the sidebar's controls when this row is the leftmost in the
    /// titlebar with the sidebar collapsed.
    var leadingClearance: CGFloat = 0 {
        didSet {
            let constant = max(8, leadingClearance)
            if abs(stripLeading.constant - constant) > 0.01 { stripLeading.constant = constant }
            fitSplitButtons()
        }
    }
    /// And for the session's controls at the other end, when this row is the
    /// rightmost in the titlebar (`WindowControls`).
    var trailingClearance: CGFloat = 0 {
        didSet {
            let constant = -max(8, trailingClearance)
            if abs(trailingEnd.constant - constant) > 0.01 { trailingEnd.constant = constant }
            fitSplitButtons()
        }
    }

    /// What a row needs to show its split buttons: a named tab, the "+",
    /// and the two of them. In a narrower split they go, and the tabs have
    /// the row; ⌘D, a tab's menu and a drag to an edge split it still.
    private static let roomForSplitButtons: CGFloat = 240

    init(region: TabRegion) {
        super.init()
        strip.region = region
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.trailingAccessory = add
        addSubview(strip)
        for button in [splitRight, splitDown, unzoom] { trailing.addArrangedSubview(button) }
        trailing.spacing = 4
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailing)
        stripLeading = strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        trailingEnd = trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        stripTrailing = strip.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8)
        unzoom.onVisibility = { [unowned self] in fitSplitButtons() }
        NSLayoutConstraint.activate([
            stripLeading,
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            stripTrailing,
            trailingEnd,
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitSplitButtons()
    }

    /// Show the split buttons while the row has room for them beside a tab,
    /// and keep the gap before them only while something is there.
    private func fitSplitButtons() {
        let room = bounds.width - max(8, leadingClearance) - max(8, trailingClearance)
        let hides = room < Self.roomForSplitButtons
        if splitRight.isHidden != hides {
            splitRight.isHidden = hides
            splitDown.isHidden = hides
        }
        let gap: CGFloat = hides && unzoom.isHidden ? 0 : -8
        if stripTrailing.constant != gap { stripTrailing.constant = gap }
    }

    /// Wire the row to the panel the way every row is wired: picking, closing,
    /// keeping and moving are the panel's, by region.
    func wire(to git: GitPanelModel, home: SessionWindow, region: TabRegion) {
        strip.onSelect = { [weak git] tab in git?.bringForward(tab, in: region) }
        strip.onClose = { [weak git] tab in git?.requestClose(tab) }
        strip.onCloseOthers = { [weak git] keep in git?.closeOthers(keeping: keep) }
        strip.onKeep = { [weak git] tab in git?.keep(tab) }
        strip.onMove = { [weak git] tab, destination in git?.move(tab, to: destination, at: .max) }
        strip.onSplit = { [weak git] tab, edge in git?.split(region, on: edge, with: tab) }
        strip.preview = { [weak home] tab in TitleBarController.preview(for: tab, in: home?.selected) }
        add.target = self
        add.action = #selector(addTab(_:))
        splitRight.target = self
        splitRight.action = #selector(splitToTheRight(_:))
        splitDown.target = self
        splitDown.action = #selector(splitDownward(_:))
        self.git = git
        self.region = region
    }

    private weak var git: GitPanelModel?
    private var region: TabRegion = .main

    /// An empty tab in this split, whose page offers what it can become
    /// (`NewTabPage`): the first click gives the place, the second says
    /// what goes in it. It was a menu until 2026-11-26, two clicks with
    /// nothing on screen in between.
    @objc private func addTab(_ sender: NSView) {
        git?.openBlank(in: region)
    }

    /// This split, split: a new one beside it or under it, holding an empty
    /// tab. With no room for two, nothing is made and the sound says so
    /// (`GitPanelModel.roomToSplit`), as for the keys.
    @objc private func splitToTheRight(_ sender: Any?) {
        git?.split(region, on: .right, with: .blank(UUID()))
    }

    @objc private func splitDownward(_ sender: Any?) {
        git?.split(region, on: .down, with: .blank(UUID()))
    }
}

/// The button a zoomed split's row shows, the only sign that there are others
/// behind it: pressing it shows them all again. Hidden otherwise. Every row
/// has one (`LeafBar.unzoom`).
@MainActor
final class ZoomedButton: HoverFillButton {
    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                        accessibilityDescription: "Show All Splits")?.withSymbolConfiguration(Chrome.glyph)
        toolTip = "Show All Splits (⇧⌘↩)"
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: Chrome.controlSize),
        ])
        isSelected = true
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var width: NSLayoutConstraint!
    /// Told when it shows or hides, for the row to give its tabs the room.
    var onVisibility: () -> Void = {}

    /// No room while hidden: a row kept 36 points at its end for a button
    /// only a zoomed split shows, which is what two named tabs lacked under
    /// the window's buttons.
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            width.constant = isHidden ? 0 : Chrome.controlSize
            onVisibility()
        }
    }
}

// MARK: - A split

/// A split somebody made: a host for its terminals that works exactly like
/// the side split's and the strip's, and in front of that the page when the
/// tab in front is not a terminal. Its row is `bar`; `leaf` is the two
/// together, as the window's tree lays them out.
///
/// One per split, for as long as the split exists in any session, so nothing
/// is rebuilt when another split closes or the session is switched away from
/// and back: the view is hidden, its terminals stay where they are. While its
/// session isn't the one on screen the panel has no tabs for it, so it shows
/// nothing and its terminal is told it can't be seen.
@MainActor
final class SplitPaneController: NSViewController {
    let id: UUID
    let bar: PaneBar
    private(set) lazy var leaf = SplitLeafView(bar: bar, body: view)
    private var region: TabRegion { .pane(id) }
    private let host = SideTerminalHostController()
    private let pageHost: NSHostingController<SplitPanePage>
    private let runtime: GhosttyRuntime
    private let home: SessionWindow
    private let git: GitPanelModel

    init(id: UUID, runtime: GhosttyRuntime, home: SessionWindow, git: GitPanelModel,
         files: FileTreeModel, previewTabs: PreviewTabs) {
        self.id = id
        self.runtime = runtime
        self.home = home
        self.git = git
        bar = PaneBar(region: .pane(id))
        pageHost = NSHostingController(rootView: SplitPanePage(region: .pane(id), git: git, files: files,
                                                               previewTabs: previewTabs))
        // The page has no say in how big the split is (`SideColumnController`).
        pageHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(host)
        addChild(pageHost)
        for body in [host.view, pageHost.view] {
            body.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: root.topAnchor),
                body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        bar.wire(to: git, home: home, region: region)
        observe()
    }

    /// The split as the selected session has it, applied now rather than a
    /// turn later by the observer (`MainSplitViewController.show`).
    func applyNow() { sync() }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Out of the session on screen, and already hidden for it.
    private var parked = false

    private func sync() {
        // Another session's split: hidden once, the first time it is found
        // out of the session on screen (which takes its terminal off the
        // screen and the keyboard off it), and left alone after that. Every
        // split ever shown in the window has one of these, and each did all
        // of this again for every tab change of the session on screen.
        // What it reads here is all it watches while parked, and the split
        // coming back into the session on screen changes it.
        let inSession = git.paneTabs[id] != nil
        if !inSession, parked { return }
        parked = !inSession
        let session = home.selected
        let showing = git.isShowing(region)
        if showing {
            bar.strip.update(items: git.tabs(in: region).map { TitleBarController.stripItem(for: $0, in: session) },
                             active: git.activeTab(in: region))
        }
        let active = showing ? git.activeTab(in: region) : nil
        // Only for the session the panel is pointed at: see `SideColumnController.sync`.
        let surface = git.session === session
            ? active?.terminalID.flatMap { session?.ensureSideSurface($0, runtime: runtime) } : nil
        host.show(surface, focusRequest: git.focusRequest(in: region),
                  handBack: { [weak git] in git?.focusFront(of: .main) })
        pageHost.view.isHidden = active == nil || active?.terminalID != nil
    }
}

/// A pane, a file or a web page in a split: `TabContent`, as in every other
/// row.
struct SplitPanePage: View {
    let region: TabRegion
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        // Another session's split shows nothing (its row has no tabs here,
        // so `TabContent` built nothing for it either), and reads no more
        // than this: every hidden page used to be worked out again on each
        // tab change of the session on screen.
        if let id = region.paneID, git.paneTabs[id] == nil {
            Color.clear
        } else {
            TabContent(tab: git.isShowing(region) ? git.activeTab(in: region) : nil, region: region,
                       git: git, files: files, previewTabs: previewTabs)
        }
    }
}
