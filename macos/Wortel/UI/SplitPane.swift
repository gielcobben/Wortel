import AppKit
import Observation
import SwiftUI

// MARK: - A pane's row

/// The row of a pane in a split main area: its tabs with "+" right after the
/// last one, on the strip's faint band. The same row the bottom strip has,
/// because it is the same thing in another place: a row of tabs that is not
/// in the titlebar.
///
/// Nothing at the trailing end until the pane is zoomed: then one button
/// says so, and puts the others back. A double-click on the row's empty part
/// zooms the pane and unzooms it, as a double-click on the titlebar zooms the
/// window.
@MainActor
final class PaneBar: FilledView {
    static let height: CGFloat = 36

    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Tab")
    let unzoom = HoverFillButton.glyph("arrow.down.right.and.arrow.up.left", "Show All Splits (⇧⌘↩)")
    var onDoubleClick: () -> Void = {}

    init(region: TabRegion) {
        super.init(color: Chrome.stripBand)
        strip.region = region
        strip.isOnPage = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.trailingAccessory = add
        unzoom.isSelected = true
        unzoom.isHidden = true
        let trailing = NSStackView(views: [unzoom])
        trailing.spacing = 4
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick() }
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
        onDoubleClick = { [weak git] in git?.toggleZoom(region) }
        add.target = self
        add.action = #selector(addTab(_:))
        unzoom.target = self
        unzoom.action = #selector(unzoomPressed)
        self.git = git
        self.region = region
    }

    private weak var git: GitPanelModel?
    private var region: TabRegion = .main

    @objc private func addTab(_ sender: NSView) {
        guard let git else { return }
        NewTabMenu.popUp(from: sender, git: git, region: region)
    }

    @objc private func unzoomPressed() { git?.toggleZoom(region) }
}

// MARK: - A pane

/// A pane split off the main area: its row, a host for its terminals that
/// works exactly like the side column's and the strip's, and in front of that
/// the page when the tab in front is not a terminal.
///
/// One per pane, for as long as the pane exists in any session of the window,
/// so nothing is rebuilt when another pane closes or the session is switched
/// away from and back: the view is hidden, its terminals stay where they are.
/// While its session isn't the one on screen the panel has no tabs for it, so
/// it shows nothing and its terminal is told it can't be seen.
@MainActor
final class SplitPaneController: NSViewController {
    let id: UUID
    let bar: PaneBar
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
        // The page has no say in how big the pane is (`SideColumnController`).
        pageHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(host)
        addChild(pageHost)
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        for body in [host.view, pageHost.view] {
            body.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: bar.bottomAnchor),
                body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: PaneBar.height),
        ])
        view = root
        bar.wire(to: git, home: home, region: region)
        observe()
    }

    /// The pane as the selected session has it, applied now rather than a
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
        bar.unzoom.isHidden = git.zoomedRegion != region
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

/// A pane, a file or a web page in a split pane: `TabContent`, as in every
/// other row.
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
