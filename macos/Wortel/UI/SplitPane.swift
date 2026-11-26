import AppKit
import Observation
import SwiftUI

// MARK: - A split's row

/// The row of a split somebody made (⌘D, a tab let go on an edge): its tabs
/// with "+" right after the last one. Along the top of the window it is a
/// titlebar row like the main row's and the side split's; lower down, the
/// strip's kind of row (`SplitLeafView`).
///
/// Nothing at the trailing end until the split is zoomed: then one button
/// says so, and puts the others back.
@MainActor
final class PaneBar: ChromeBarView, LeafBar {
    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Tab")
    let unzoom = ZoomedButton()
    private var stripLeading: NSLayoutConstraint!
    /// As every row's: room for the sidebar's controls when this row is the
    /// leftmost in the titlebar with the sidebar collapsed.
    var leadingClearance: CGFloat = 0 {
        didSet {
            let constant = max(8, leadingClearance)
            if abs(stripLeading.constant - constant) > 0.01 { stripLeading.constant = constant }
        }
    }

    init(region: TabRegion) {
        super.init()
        strip.region = region
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.trailingAccessory = add
        addSubview(strip)
        addSubview(unzoom)
        stripLeading = strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            stripLeading,
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.trailingAnchor.constraint(equalTo: unzoom.leadingAnchor, constant: -8),
            unzoom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            unzoom.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

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
        self.git = git
        self.region = region
    }

    private weak var git: GitPanelModel?
    private var region: TabRegion = .main

    @objc private func addTab(_ sender: NSView) {
        guard let git else { return }
        NewTabMenu.popUp(from: sender, git: git, region: region)
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
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Chrome.controlSize),
            heightAnchor.constraint(equalToConstant: Chrome.controlSize),
        ])
        isSelected = true
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
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

    private func sync() {
        let session = home.selected
        let showing = git.isShowing(region)
        if showing {
            bar.strip.update(items: git.tabs(in: region).map { TitleBarController.stripItem(for: $0, in: session) },
                             active: git.activeTab(in: region))
        }
        bar.strip.isKeyRow = git.keyRegion == region
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
        TabContent(tab: git.isShowing(region) ? git.activeTab(in: region) : nil, region: region,
                   git: git, files: files, previewTabs: previewTabs)
    }
}
