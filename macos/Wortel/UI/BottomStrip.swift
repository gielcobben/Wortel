import AppKit
import Observation
import SwiftUI

// MARK: - The strip under the terminal

/// The terminal pane's content: the session's terminal on top and, when it's
/// showing, a strip of terminals under it (a dev server's output under the agent
/// that started it).
///
/// Under the session's terminal only, not under the side column as well, which
/// is where the ChatGPT app puts its bottom pane. The column is where diffs and
/// trees are read and they want its full height; a strip of logs belongs with
/// the terminal it came from. It is also the cheaper arrangement to take back
/// out if the strip doesn't earn its place: nothing outside this pane knows it
/// exists.
@MainActor
final class TerminalWorkspaceController: NSSplitViewController {
    private let top: NSViewController
    private let bottom: BottomPaneController
    private let git: GitPanelModel
    private var bottomItem: NSSplitViewItem!
    /// Held while we're the ones moving the divider, so it isn't saved as a drag.
    private var suspendCapture = false
    private var syncing = false
    private var lastHeight: CGFloat = 0
    private var captureWork: DispatchWorkItem?

    /// The strip's height is app-wide, like the ChatGPT app's: a strip of logs
    /// wants the same room whichever session it's in.
    enum Height {
        static let minimum: CGFloat = 100
        private static let fallback: CGFloat = 240
        private static let key = "bottomStrip.height"
        static var chosen: CGFloat {
            let stored = UserDefaults.standard.double(forKey: key)
            return stored > 0 ? CGFloat(stored) : fallback
        }
        static func remember(_ height: CGFloat) {
            UserDefaults.standard.set(Double(height), forKey: key)
        }
    }

    init(top: NSViewController, bottom: BottomPaneController, git: GitPanelModel) {
        self.top = top
        self.bottom = bottom
        self.git = git
        super.init(nibName: nil, bundle: nil)
        let split = ChromeSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        splitView = split
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let topItem = NSSplitViewItem(viewController: top)
        topItem.minimumThickness = 80
        topItem.holdingPriority = NSLayoutConstraint.Priority(250)
        addSplitViewItem(topItem)

        let item = NSSplitViewItem(viewController: bottom)
        item.minimumThickness = Height.minimum
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.holdingPriority = NSLayoutConstraint.Priority(260)
        item.isCollapsed = !git.bottomVisible
        addSplitViewItem(item)
        bottomItem = item
        observe()
    }

    private var didApplyInitialHeight = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialHeight, splitView.bounds.height > 0 else { return }
        didApplyInitialHeight = true
        lastHeight = splitView.bounds.height
        DispatchQueue.main.async { [weak self] in self?.applyHeight() }
    }

    private func observe() {
        withObservationTracking {
            _ = git.bottomVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyVisibility()
                self.observe()
            }
        }
    }

    /// Open when the user opened it, animated; snap when a session switch did,
    /// for the same reason the side column does.
    private func applyVisibility() {
        let show = git.bottomVisible
        guard let bottomItem, bottomItem.isCollapsed == show else { return }
        syncing = true
        suspendCapture = true
        if git.animatesBottomChange {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                bottomItem.animator().isCollapsed = !show
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.suspendCapture = false
                    if show { self?.applyHeight() }
                }
            }
        } else {
            bottomItem.isCollapsed = !show
            suspendCapture = false
            if show { applyHeight() }
        }
        syncing = false
    }

    private func applyHeight() {
        guard let bottomItem, !bottomItem.isCollapsed else { return }
        let total = splitView.bounds.height
        guard total > 0 else { return }
        let target = min(max(Height.chosen, Height.minimum), total * 0.6)
        guard abs(target - bottomItem.viewController.view.frame.height) > 0.5 else { return }
        suspendCapture = true
        splitView.setPosition(total - target - splitView.dividerThickness, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in self?.suspendCapture = false }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let total = splitView.bounds.height
        let windowResized = total != lastHeight
        lastHeight = total
        guard let bottomItem else { return }
        // Dragged shut: the strip hides, and the session remembers that.
        if !syncing, bottomItem.isCollapsed, git.bottomVisible {
            git.bottomCollapsedByDrag()
            return
        }
        guard !windowResized, !suspendCapture, !bottomItem.isCollapsed else { return }
        captureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let item = self.bottomItem, !item.isCollapsed else { return }
            let height = item.viewController.view.frame.height
            if height > 1 { Height.remember(height) }
        }
        captureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                        forDrawnRect: drawnRect, ofDividerAt: dividerIndex).insetBy(dx: 0, dy: -4)
    }

    /// Where the terminal's own content sits, for the drag controller's zones.
    var terminalView: NSView { top.view }
}

/// The strip's own row: its tabs, and at the trailing end a new terminal and
/// the button that tucks the strip away. On a faint band, so the tab in front
/// can be raised off it the way the column's tabs are off the titlebar.
@MainActor
final class BottomBar: FilledView {
    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Terminal")
    let hide = HoverFillButton.glyph("chevron.down", "Hide Bottom Strip")

    init() {
        super.init(color: Chrome.stripBand)
        strip.region = .bottom
        strip.translatesAutoresizingMaskIntoConstraints = false
        let trailing = NSStackView(views: [add, hide])
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
}

/// The strip: its row, and a host for its terminals that works exactly like the
/// side column's.
@MainActor
final class BottomPaneController: NSViewController {
    let bar = BottomBar()
    private let host = SideTerminalHostController()
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let git: GitPanelModel

    init(runtime: GhosttyRuntime, manager: SessionManager, git: GitPanelModel) {
        self.runtime = runtime
        self.manager = manager
        self.git = git
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(host)
        let body = host.view
        bar.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        bar.add.target = self
        bar.add.action = #selector(addTerminal)
        bar.hide.target = self
        bar.hide.action = #selector(hideStrip)
        let strip = bar.strip
        strip.onSelect = { [weak self] tab in
            if let id = tab.terminalID { self?.git.selectBottom(id) }
        }
        strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
        strip.onCloseOthers = { [weak self] keep in
            guard let self else { return }
            for id in self.git.bottomTabs where id != keep.terminalID {
                self.git.requestClose(.terminal(id))
            }
        }
        strip.onMove = { [weak self] tab, region in self?.git.move(tab, to: region, at: .max) }
        observe()
    }

    @objc private func addTerminal() { git.openBottomTerminal() }
    @objc private func hideStrip() { git.toggleBottom() }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        let session = manager.selected
        let titles = session?.sideTerminalTitles ?? [:]
        let items = git.bottomTabs.map { id in
            SideTabStrip.Item(tab: .terminal(id), title: TitleBarController.terminalTitle(titles[id]),
                              symbol: "apple.terminal")
        }
        bar.strip.update(items: items, active: git.activeBottomTab.map { .terminal($0) })
        let surface = git.bottomVisible
            ? git.activeBottomTab.flatMap { session?.ensureSideSurface($0, runtime: runtime) }
            : nil
        host.show(surface, focusRequest: git.bottomFocusRequest, mainTerminal: session?.surfaceView)
    }
}

// MARK: - Dragging tabs

/// Resolves a tab drag against every place it could land: the tab rows (to
/// reorder, or to move between the column and the strip at an exact spot) and
/// two drop zones for when the destination has no row on screen, the lower
/// quarter of the terminal (the strip) and the column. A tab only lights up the
/// places it's allowed to go (`SideTab.fits`), so a pane dragged over the
/// terminal's lower edge shows nothing.
///
/// While it runs, a ghost of the tab follows the pointer and the landing spot
/// is drawn: a marker between tabs, or an overlay the size of the pane the
/// drop would make, labelled with what will happen. All of it in one overlay
/// view over the window that takes no clicks.
@MainActor
final class TabDragController {
    struct StripTarget {
        weak var strip: SideTabStrip?
        let region: TabRegion
    }

    private enum Target: Equatable {
        case strip(TabRegion, index: Int, marker: NSRect)
        case zone(TabRegion, area: NSRect)
        /// The terminal's edge away from the column: the column moves there.
        case swap(leading: Bool, area: NSRect)
    }

    var strips: [StripTarget] = []
    /// The session terminal's area, in window coordinates.
    var terminalArea: () -> NSRect? = { nil }
    /// The bottom strip, bar and all, while it's showing, in window coordinates.
    var bottomArea: () -> NSRect? = { nil }
    /// The side column's content area when it's showing, in window coordinates.
    var columnArea: () -> NSRect? = { nil }
    var onDrop: (SideTab, TabRegion, Int) -> Void = { _, _, _ in }
    /// Which side the column is on now.
    var columnLeading: () -> Bool = { false }
    var onSwap: (SideTab, Bool) -> Void = { _, _ in }

    private var overlay: TabDragOverlay?
    private var target: Target?
    private weak var source: NSView?

    func handle(_ phase: SideTabStrip.DragPhase, tab: SideTab, view: NSView, point: NSPoint) {
        switch phase {
        case .began:
            guard let window = view.window, let content = window.contentView else { return }
            let overlay = TabDragOverlay(frame: content.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.ghost = Self.snapshot(of: view)
            let grab = view.convert(point, from: nil)
            overlay.grabOffset = NSPoint(x: grab.x, y: view.bounds.height - grab.y)
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.overlay = overlay
            source = view
            view.alphaValue = 0.35
            update(tab: tab, point: point)
        case .moved:
            update(tab: tab, point: point)
        case .ended:
            let landing = target
            finish()
            switch landing {
            case .strip(let region, let index, _): onDrop(tab, region, index)
            case .zone(let region, _): onDrop(tab, region, .max)
            case .swap(let leading, _): onSwap(tab, leading)
            case nil: break
            }
        case .cancelled:
            finish()
        }
    }

    /// Whether the tab being dragged is the session's own, which reads the
    /// same drop zones differently (see `resolve`).
    private var draggingSession = false

    private func update(tab: SideTab, point: NSPoint) {
        draggingSession = tab == .session
        target = resolve(tab: tab, point: point)
        guard let overlay else { return }
        overlay.pointer = overlay.convert(point, from: nil)
        switch target {
        case .strip(_, _, let marker):
            overlay.marker = overlay.convert(marker, from: nil)
            overlay.zone = nil
        case .zone(let region, let area):
            overlay.marker = nil
            overlay.zone = overlay.convert(area, from: nil)
            switch region {
            case .bottom:
                overlay.zoneLabel = "Move to Bottom"
                overlay.zoneEdge = .maxY
            case .side:
                overlay.zoneLabel = "Move to Side Column"
                overlay.zoneEdge = columnLeading() ? .maxX : .minX
            case .main:
                overlay.zoneLabel = "Move Here"
                overlay.zoneEdge = .minY
            }
        case .swap(let leading, let area):
            overlay.marker = nil
            overlay.zone = overlay.convert(area, from: nil)
            if draggingSession {
                // The session's terminal trades places with the column.
                overlay.zoneLabel = leading ? "Move Terminal to the Right" : "Move Terminal to the Left"
                overlay.zoneEdge = leading ? .minX : .maxX
            } else {
                overlay.zoneLabel = leading ? "Move Column to the Left" : "Move Column to the Right"
                overlay.zoneEdge = leading ? .maxX : .minX
            }
        case nil:
            overlay.marker = nil
            overlay.zone = nil
        }
        overlay.needsDisplay = true
    }

    private func resolve(tab: SideTab, point: NSPoint) -> Target? {
        for entry in strips {
            guard let strip = entry.strip, strip.window != nil, !strip.isHiddenOrHasHiddenAncestor,
                  tab.fits(entry.region) else { continue }
            // Wider than the tabs: aiming for the first or last place, the
            // pointer runs past the row's end, and that still means "here".
            let rect = strip.convert(strip.bounds, to: nil).insetBy(dx: -16, dy: -8)
            guard rect.contains(point) else { continue }
            let (index, x) = strip.insertion(atWindowX: point.x)
            let marker = NSRect(x: x - 1, y: rect.midY - 11, width: 2, height: 22)
            return .strip(entry.region, index: index, marker: marker)
        }
        // The session's own tab never goes *into* the column's row: it is the
        // main area's anchor, as the chat is in the ChatGPT app. Dropped on the
        // column (its row or its page), it trades places with it instead: the
        // terminal goes where the column was, the column to the other side.
        if tab == .session {
            guard let column = columnArea() else { return nil }
            let row = strips.first { $0.region == .side }?.strip
            let rowRect = row.flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: nil) }
            guard column.contains(point) || rowRect?.insetBy(dx: -16, dy: -8).contains(point) == true
            else { return nil }
            return .swap(leading: !columnLeading(), area: column)
        }
        if tab.fits(.bottom), let bottom = bottomArea(), bottom.contains(point) {
            return .zone(.bottom, area: bottom)
        }
        if tab.fits(.bottom), bottomArea() == nil, let area = terminalArea() {
            let zone = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 4)
            if zone.contains(point) {
                let height = min(TerminalWorkspaceController.Height.chosen, area.height * 0.6)
                return .zone(.bottom, area: NSRect(x: area.minX, y: area.minY,
                                                   width: area.width, height: height))
            }
        }
        guard tab.fits(.side) else { return nil }
        let column = columnArea()
        if let column, column.contains(point) {
            return .zone(.side, area: column)
        }
        guard let area = terminalArea() else { return nil }
        // The main area's two edges, a quarter of it each: the one on the
        // column's side opens the column (when it's hidden), the far one moves
        // the column over to it. What's left in the middle is the main area
        // itself, and the overlay covers only it.
        let leading = columnLeading()
        let edge = area.width / 4
        let width = min(MainSplitViewController.ColumnWidth.lastChosen, area.width / 2)
        let leftEdge = NSRect(x: area.minX, y: area.minY, width: edge, height: area.height)
        let rightEdge = NSRect(x: area.maxX - edge, y: area.minY, width: edge, height: area.height)
        let leftPane = NSRect(x: area.minX, y: area.minY, width: width, height: area.height)
        let rightPane = NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        if leftEdge.contains(point) {
            return leading ? (column == nil ? .zone(.side, area: leftPane) : nil)
                           : .swap(leading: true, area: leftPane)
        }
        if rightEdge.contains(point) {
            return leading ? .swap(leading: false, area: rightPane)
                           : (column == nil ? .zone(.side, area: rightPane) : nil)
        }
        if area.contains(point), tab.fits(.main) {
            return .zone(.main, area: area)
        }
        return nil
    }

    private func finish() {
        overlay?.removeFromSuperview()
        overlay = nil
        source?.alphaValue = 1
        source = nil
        target = nil
    }

    private static func snapshot(of view: NSView) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// What a drag draws: the ghost, and where it would land.
@MainActor
private final class TabDragOverlay: NSView {
    var ghost: NSImage?
    var grabOffset = NSPoint.zero
    var pointer = NSPoint.zero
    var marker: NSRect?
    var zone: NSRect?
    var zoneLabel = ""
    var zoneEdge: NSRectEdge = .maxY

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        if let zone {
            accent.withAlphaComponent(0.10).setFill()
            zone.fill()
            // A border on the edge that faces the terminal only, where the new
            // pane would meet it.
            accent.withAlphaComponent(0.55).setFill()
            switch zoneEdge {
            case .maxY: NSRect(x: zone.minX, y: zone.maxY - 1, width: zone.width, height: 1).fill()
            case .maxX: NSRect(x: zone.maxX - 1, y: zone.minY, width: 1, height: zone.height).fill()
            case .minX: NSRect(x: zone.minX, y: zone.minY, width: 1, height: zone.height).fill()
            default: break
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let text = zoneLabel as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: zone.midX - size.width / 2, y: zone.midY - size.height / 2),
                      withAttributes: attributes)
        }
        if let marker {
            accent.setFill()
            NSBezierPath(roundedRect: marker, xRadius: 1, yRadius: 1).fill()
        }
        if let ghost {
            let origin = NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
            ghost.draw(in: NSRect(origin: origin, size: ghost.size), from: .zero,
                       operation: .sourceOver, fraction: 0.9)
        }
    }
}
