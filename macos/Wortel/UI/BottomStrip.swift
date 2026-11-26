import AppKit
import Observation
import SwiftUI

// MARK: - The strip

/// The strip: a host for its terminals that works exactly like the side
/// split's, and in front of that the pane or file when one of those is the
/// tab in front. Its row is `bar`; `leaf` is the two together, a split of
/// the window's tree like any other. What is the strip's own is that ⌘J
/// tucks it away with its tabs kept, and that it opens under the main row
/// at the height below.
@MainActor
final class BottomPaneController: NSViewController {
    /// How tall the strip opens: the height it was last dragged to, in any
    /// session, as a strip of logs wants the same room whichever session it
    /// is in. Once it is there its size is a share of the area, like every
    /// split's.
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

    let bar = PaneBar(region: .bottom)
    private(set) lazy var leaf = SplitLeafView(bar: bar, body: view)
    private let host = SideTerminalHostController()
    private let paneHost: NSHostingController<BottomAreaPane>
    private let runtime: GhosttyRuntime
    private let manager: SessionManager
    private let home: SessionWindow
    private let git: GitPanelModel

    init(runtime: GhosttyRuntime, manager: SessionManager, home: SessionWindow, git: GitPanelModel,
         files: FileTreeModel, previewTabs: PreviewTabs) {
        self.runtime = runtime
        self.manager = manager
        self.home = home
        self.git = git
        paneHost = NSHostingController(rootView: BottomAreaPane(git: git, files: files,
                                                                previewTabs: previewTabs))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(host)
        addChild(paneHost)
        for body in [host.view, paneHost.view] {
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

        bar.wire(to: git, home: home, region: .bottom)
        observe()
    }


    /// The strip as the selected session has it, applied now rather than a
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
        bar.strip.update(items: git.bottomTabs.map { TitleBarController.stripItem(for: $0, in: session) },
                         active: git.activeBottomTab)
        let active = git.isShowing(.bottom) ? git.activeBottomTab : nil
        // Only for the session the panel is pointed at: see `SideColumnController.sync`.
        let surface = git.session === session
            ? active?.terminalID.flatMap { session?.ensureSideSurface($0, runtime: runtime) } : nil
        host.show(surface, focusRequest: git.bottomFocusRequest, handBack: { [weak git] in git?.focusFront(of: .main) })
        paneHost.view.isHidden = active == nil || active?.terminalID != nil
    }
}

/// A pane or a file in the strip.
struct BottomAreaPane: View {
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel
    let previewTabs: PreviewTabs

    var body: some View {
        TabContent(tab: git.isShowing(.bottom) ? git.activeBottomTab : nil, region: .bottom,
                   git: git, files: files, previewTabs: previewTabs)
    }
}

// MARK: - Dragging tabs

/// Resolves a tab drag against every place it could land: the tab rows (to
/// reorder, or to move to another split's row at an exact spot) and the
/// splits themselves, an edge to make a new split there and the middle to
/// move into the one that is there. The side split and the strip are splits
/// like the rest. A tab only lights up the places it's allowed to go
/// (`SideTab.fits`): the session's own tab none but its own row, and the
/// side split, which it trades sides with.
///
/// While it runs, a ghost of the tab follows the pointer and the landing spot
/// is drawn: a marker between tabs, or an overlay the size of the pane the
/// drop would make, labelled with what will happen. All of it in one overlay
/// view over the window that takes no clicks.
///
/// A file tab can also leave the window: past its edge, the ghost turns into
/// a small window that follows the pointer (`TabTearOffGhost`), and letting go
/// there opens the file in a preview window at that spot, as "Open in New
/// Window" does. Only files: a terminal or a browser has no window of its own
/// to go to. And back: a preview window dragged by its row over one of these
/// rows hands over to `handleDock`, which shows the tab it would become and
/// where, and makes it on letting go.
@MainActor
final class TabDragController {
    struct StripTarget {
        weak var strip: SideTabStrip?
        let region: TabRegion
        /// Where to drop while the strip is hidden, in window coordinates: the
        /// main area's row shows the session's title rather than a row of one
        /// tab, and is still where a tab dragged up there should go (after
        /// the session). nil, a hidden strip takes no drops.
        var whenHidden: () -> (area: NSRect, markerX: CGFloat)? = { nil }
    }

    private enum Target: Equatable {
        case strip(TabRegion, index: Int, marker: NSRect)
        case zone(TabRegion, area: NSRect)
        /// An edge of a pane of the main area: a new pane there, holding the
        /// tab. `area` is the half the new pane would take.
        case split(TabRegion, SplitLayout.Edge, area: NSRect)
        /// The terminal's edge away from the column: the column moves there.
        case swap(leading: Bool, area: NSRect)
        /// Outside the window: a window of its own.
        case tearOff
        /// A row in another main window: it moves to that window's session
        /// (`elsewhere`).
        case otherWindow
    }

    enum DockPhase { case moved, ended, cancelled }

    /// What is under the pointer outside this window, for a tab drag.
    enum Elsewhere {
        /// Nothing of ours: this window, the desktop, another app.
        case nothing
        /// Another main window, not over a row that takes this tab.
        case window
        /// A row in another main window that takes it, now showing where.
        case row
    }

    var strips: [StripTarget] = []
    /// The rows of the main area's panes, asked at each step: they come and
    /// go with the panes, and with the session on screen.
    var paneStrips: () -> [StripTarget] = { [] }
    /// The pane of the main area under a point in window coordinates, and
    /// what a drop there asks for (`MainAreaController.paneDrop`).
    var paneDrop: (NSPoint, SideTab?) -> (region: TabRegion, frame: NSRect, edge: SplitLayout.Edge?, half: NSRect?)? = { _, _ in nil }
    /// Whether a pane has the room on screen to be split in two on an edge
    /// (`MainAreaController.hasRoom`).
    var hasRoom: (TabRegion, SplitLayout.Edge) -> Bool = { _, _ in true }
    /// How many tabs a row holds: a pane can't be split from its only tab.
    var tabCount: (TabRegion) -> Int = { _ in 0 }
    var onSplit: (SideTab, TabRegion, SplitLayout.Edge) -> Void = { _, _, _ in }
    var onFileSplit: ([URL], TabRegion, SplitLayout.Edge) -> Void = { _, _, _ in }
    var onDrop: (SideTab, TabRegion, Int) -> Void = { _, _, _ in }
    /// Files dragged out of a list and dropped on a row or an area: open them
    /// there, from `index` in that row's order.
    var onFileDrop: ([URL], TabRegion, Int) -> Void = { _, _, _ in }
    /// Which side the column is on now.
    var columnLeading: () -> Bool = { false }
    var onSwap: (SideTab, Bool) -> Void = { _, _ in }
    /// Which row a tab is in now: dropped back on its own area, it stays put.
    var regionOf: (SideTab) -> TabRegion? = { _ in nil }
    /// A file tab let go outside the window: open it in a window whose
    /// top-left is at this point, in screen coordinates.
    var onTearOff: (SideTab, NSPoint) -> Void = { _, _ in }
    /// The other main windows, asked where a tab dragged out of this one
    /// is, at a point in screen coordinates. `dragged` is the tab's ghost
    /// window, to look past; the picture is what another row shows standing
    /// in for the tab. On `.ended` over a row, that window takes the tab;
    /// `.cancelled` takes down whatever another window showed.
    var elsewhere: (DockPhase, SideTab, _ dragged: NSWindow?, NSPoint, NSImage?) -> Elsewhere = { _, _, _, _, _ in .nothing }

    private var overlay: TabDragOverlay?
    /// The tab's picture, kept so the overlay can stop drawing it while the
    /// tear-off ghost stands in for it, and draw it again on the way back.
    private var tabPicture: NSImage?
    private var tearOff: TabTearOffGhost?
    /// Whether the tab being dragged may leave the window. The ghost itself
    /// is made only once it does: most drags are a reorder in a row.
    private var canTearOff = false
    private weak var dragWindow: NSWindow?
    private var target: Target?
    private weak var source: NSView?
    /// The tab being dragged, for `finish` to tell the other windows the
    /// drag is over.
    private var draggedTab: SideTab?
    /// Another window was asked about this drag, so it is told when it ends.
    private var askedElsewhere = false

    func handle(_ phase: SideTabStrip.DragPhase, tab: SideTab, view: NSView, point: NSPoint) {
        switch phase {
        case .began:
            guard let window = view.window, let content = window.contentView else { return }
            let overlay = TabDragOverlay(frame: content.bounds)
            overlay.autoresizingMask = [.width, .height]
            let picture = view.snapshot()
            overlay.ghost = picture
            tabPicture = picture
            let grab = view.convert(point, from: nil)
            overlay.grabOffset = NSPoint(x: grab.x, y: view.bounds.height - grab.y)
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.overlay = overlay
            dragWindow = window
            canTearOff = { if case .file = tab { return true } else { return false } }()
            draggedTab = tab
            source = view
            view.alphaValue = 0.35
            update(tab: tab, point: point)
        case .moved:
            update(tab: tab, point: point)
        case .ended:
            let landing = target
            let screen = view.window?.convertPoint(toScreen: point)
            let topLeft = screen.flatMap { tearOff?.windowTopLeft(for: $0) }
            if case .otherWindow? = landing, let screen {
                // Before `finish`: the ghost is still there to look past.
                _ = elsewhere(.ended, tab, tearOff?.window, screen, tabPicture)
                askedElsewhere = false
            }
            finish()
            switch landing {
            case .strip(let region, let index, _): onDrop(tab, region, index)
            case .zone(let region, _): onDrop(tab, region, .max)
            case .split(let region, let edge, _): onSplit(tab, region, edge)
            case .swap(let leading, _): onSwap(tab, leading)
            case .tearOff: if let topLeft { onTearOff(tab, topLeft) }
            case .otherWindow, nil: break
            }
        case .cancelled:
            finish()
        }
    }

    /// Whether the tab being dragged is the session's own, which reads the
    /// same drop zones differently (see `resolve`).
    private var draggingSession = false

    /// A file is being dragged out of a list rather than a tab across rows:
    /// it opens where it lands ("Open in…"), and never moves the column.
    private var draggingFile = false
    private weak var fileDragWindow: NSWindow?

    /// A file dragged out of a list (Changes, History, the file tree): the
    /// same landing spots as a tab, to open it there as a tab. Not over a
    /// terminal: a file dropped on one types its path, which is how you hand
    /// an agent a file, and that stays the terminal's.
    func handleFileDrag(_ phase: RowClickCatcher.FileDragPhase, urls: [URL],
                        window: NSWindow, point: NSPoint) {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        guard let first = files.first else { return }
        let tab = SideTab.file(first.resolvingSymlinksInPath().standardizedFileURL.path)
        switch phase {
        case .began:
            guard let content = window.contentView else { return }
            let overlay = TabDragOverlay(frame: content.bounds)
            overlay.autoresizingMask = [.width, .height]
            // No ghost: the system drag already shows the file's icon.
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.overlay = overlay
            draggingFile = true
            fileDragWindow = window
            update(tab: tab, point: point)
        case .moved:
            guard draggingFile else { return }
            update(tab: tab, point: point)
        case .ended(let accepted):
            guard draggingFile else { return }
            let landing = accepted ? nil : target
            finish()
            switch landing {
            case .strip(let region, let index, _): onFileDrop(files, region, index)
            case .zone(let region, _): onFileDrop(files, region, .max)
            case .split(let region, let edge, _): onFileSplit(files, region, edge)
            case .swap, .tearOff, .otherWindow, nil: break
            }
        }
    }

    /// A preview window being dragged by its row, the pointer at `point` in
    /// this window's coordinates. Only the tab rows take it, never the drop
    /// zones: a window is moved over the main window all the time, and a
    /// pane lighting up under it every time would be in the way. Returns
    /// the row and place the pointer is over, if any, so the window can step
    /// aside while the tab stands in for it; on `.ended`, where the tab goes.
    /// Making it is the caller's: it has the window's diff and view to keep.
    @discardableResult
    func handleDock(_ phase: DockPhase, tab: SideTab, window: NSWindow, point: NSPoint,
                    picture: () -> NSImage?) -> (region: TabRegion, index: Int)? {
        switch phase {
        case .moved:
            guard let landing = stripLanding(tab: tab, point: point),
                  case .strip(let region, let index, let marker) = landing else {
                if docking { finish() }
                return nil
            }
            if overlay == nil {
                guard let content = window.contentView else { return nil }
                let overlay = TabDragOverlay(frame: content.bounds)
                overlay.autoresizingMask = [.width, .height]
                let ghost = picture()
                overlay.ghost = ghost
                // Held a little way into the tab, by its glyph, as a tab
                // picked up from a row usually is.
                overlay.grabOffset = NSPoint(x: 24, y: (ghost?.size.height ?? Chrome.controlSize) / 2)
                content.addSubview(overlay, positioned: .above, relativeTo: nil)
                self.overlay = overlay
            }
            docking = true
            target = landing
            overlay?.pointer = overlay?.convert(point, from: nil) ?? point
            overlay?.marker = overlay?.convert(marker, from: nil)
            overlay?.zone = nil
            overlay?.redraw()
            return (region, index)
        case .ended:
            let landing = docking ? target : nil
            if docking { finish() }
            guard case .strip(let region, let index, _)? = landing else { return nil }
            return (region, index)
        case .cancelled:
            if docking { finish() }
            return nil
        }
    }

    /// A preview window is over a row, standing in as a tab.
    private var docking = false

    /// Whether `point` is over a terminal, which takes a dropped file itself.
    private static func isOverTerminal(_ point: NSPoint, in window: NSWindow?) -> Bool {
        guard let frameView = window?.contentView?.superview else { return false }
        var view = frameView.hitTest(point)
        while let current = view {
            if current is SurfaceView { return true }
            view = current.superview
        }
        return false
    }

    private func update(tab: SideTab, point: NSPoint) {
        draggingSession = tab == .session
        // A tab's drag (not a list's file, which `AppDelegate` takes to the
        // window it's over): another window in front of the pointer has it,
        // even inside this window's frame, as it is once that window sprang
        // forward over this one.
        var away = Elsewhere.nothing
        if !draggingFile, let window = dragWindow {
            let screen = window.convertPoint(toScreen: point)
            SpringLoading.hover(at: screen, dragging: tearOff?.window)
            away = elsewhere(.moved, tab, tearOff?.window, screen, tabPicture)
            askedElsewhere = true
        }
        if away == .row {
            target = .otherWindow
            // That window's row draws the tab now.
            tearOff?.hide()
            overlay?.ghost = nil
            overlay?.marker = nil
            overlay?.zone = nil
            overlay?.redraw()
            return
        }
        target = away == .window ? nil : resolve(tab: tab, point: point)
        updateTearOff(point: point, covered: away == .window)
        if draggingFile {
            // Never "move the column" for a file, and nothing over a terminal:
            // that drop is the terminal's (it types the path).
            if case .swap? = target { target = nil }
            if case .zone? = target, Self.isOverTerminal(point, in: fileDragWindow) { target = nil }
            if case .split? = target, Self.isOverTerminal(point, in: fileDragWindow) { target = nil }
        }
        if case .tearOff? = target {
            overlay?.marker = nil
            overlay?.zone = nil
            overlay?.redraw()
            return
        }
        guard let overlay else { return }
        overlay.pointer = overlay.convert(point, from: nil)
        switch target {
        case .strip(_, _, let marker):
            overlay.marker = overlay.convert(marker, from: nil)
            overlay.zone = nil
        case .zone(_, let area):
            // No words on any of these: where it lights up is where the tab
            // goes, and "Move Here" or "Split Right" over it only said so
            // twice.
            overlay.marker = nil
            overlay.zone = overlay.convert(area, from: nil)
            overlay.zoneEdge = nil
        case .split(_, let edge, let area):
            overlay.marker = nil
            overlay.zone = overlay.convert(area, from: nil)
            // The line is on the side of the new pane that meets the old one.
            // The overlay's coordinates are AppKit's: up is a larger y.
            switch edge {
            case .right: overlay.zoneEdge = .minX
            case .left: overlay.zoneEdge = .maxX
            case .down: overlay.zoneEdge = .maxY
            case .up: overlay.zoneEdge = .minY
            }
        case .swap(let leading, let area):
            overlay.marker = nil
            overlay.zone = overlay.convert(area, from: nil)
            // Only the session's own tab lands here: its terminal trades
            // sides with the side split.
            overlay.zoneEdge = leading ? .minX : .maxX
        case .tearOff, .otherWindow, nil:
            overlay.marker = nil
            overlay.zone = nil
        }
        overlay.redraw()
    }

    /// Where a drop at `point` would land. Nowhere, when that's the area the
    /// tab is already in: letting go over your own page is how a drag is
    /// abandoned, and it used to send the tab to the end of its row.
    private func resolve(tab: SideTab, point: NSPoint) -> Target? {
        let target = landing(tab: tab, point: point)
        if case .zone(let region, _)? = target, region == regionOf(tab) { return nil }
        return target
    }

    private func landing(tab: SideTab, point: NSPoint) -> Target? {
        if let strip = stripLanding(tab: tab, point: point) { return strip }
        return zoneLanding(tab: tab, point: point)
    }

    /// The place in a tab row a drop at `point` would take, if it's over one.
    private func stripLanding(tab: SideTab, point: NSPoint) -> Target? {
        for entry in strips + paneStrips() {
            guard let strip = entry.strip, strip.window != nil, tab.fits(entry.region) else { continue }
            if strip.isHiddenOrHasHiddenAncestor {
                guard let slot = entry.whenHidden(),
                      slot.area.insetBy(dx: 0, dy: -8).contains(point) else { continue }
                let marker = NSRect(x: slot.markerX - 1, y: slot.area.midY - 11, width: 2, height: 22)
                return .strip(entry.region, index: .max, marker: marker)
            }
            // Wider than the tabs: aiming for the first or last place, the
            // pointer runs past the row's end, and that still means "here".
            let rect = strip.convert(strip.bounds, to: nil).insetBy(dx: -16, dy: -8)
            guard rect.contains(point) else { continue }
            let (index, x) = strip.insertion(atWindowX: point.x)
            let marker = NSRect(x: x - 1, y: rect.midY - 11, width: 2, height: 22)
            return .strip(entry.region, index: index, marker: marker)
        }
        return nil
    }

    private func zoneLanding(tab: SideTab, point: NSPoint) -> Target? {
        guard let hit = paneDrop(point, tab) else { return nil }
        // The session's own tab never goes into another split's row and is
        // never split off: it is the main row's anchor, as the chat is in
        // the ChatGPT app. Dropped on the side split (its row or its page),
        // it trades sides with it instead.
        if tab == .session {
            return hit.region == .side ? .swap(leading: !columnLeading(), area: hit.frame) : nil
        }
        return paneLanding(hit, tab: tab)
    }

    /// A drop on a pane of the main area: on an edge, a new pane there; in
    /// the middle, into the pane.
    private func paneLanding(_ hit: (region: TabRegion, frame: NSRect, edge: SplitLayout.Edge?, half: NSRect?),
                             tab: SideTab) -> Target? {
        guard tab.fits(hit.region) || (hit.edge != nil && tab != .session) else { return nil }
        // A pane too small to be two has no edges to split on: all of it is
        // its middle.
        // An edge where a split would leave everything where it is has
        // nothing to offer (`MainAreaController.paneDrop`), its middle neither.
        if hit.edge != nil, hit.half == nil { return nil }
        if let edge = hit.edge, let half = hit.half, hasRoom(hit.region, edge) {
            // A pane split from its own only tab would be the same pane.
            if regionOf(tab) == hit.region, tabCount(hit.region) <= 1 { return nil }
            // Nor upward from its own row: that band starts right under the
            // row the tab was picked up from, and letting go there is how a
            // drag is abandoned.
            if regionOf(tab) == hit.region, edge == .up { return nil }
            return .split(hit.region, edge, area: half)
        }
        guard tab.fits(hit.region) else { return nil }
        return .zone(hit.region, area: hit.frame)
    }

    #if DEBUG
    /// For `SplitProbe`: where `tab`, let go at `point` in the window, would
    /// land, in words, and the drop made as the end of a drag makes it.
    func probeDrop(_ tab: SideTab, at point: NSPoint) -> String {
        draggingSession = tab == .session
        defer { draggingSession = false }
        switch resolve(tab: tab, point: point) {
        case .strip(let region, let index, _)?:
            onDrop(tab, region, index)
            return "row \(region.rawValue.prefix(10)) at \(index == .max ? "end" : String(index))"
        case .zone(let region, _)?:
            onDrop(tab, region, .max)
            return "into \(region.rawValue.prefix(10))"
        case .split(let region, let edge, let area)?:
            onSplit(tab, region, edge)
            return "split \(edge.rawValue) of \(region.rawValue.prefix(10)), preview \(Int(area.minX)),\(Int(area.minY)) \(Int(area.width))x\(Int(area.height))"
        case .swap(let leading, _)?:
            onSwap(tab, leading)
            return "column to the \(leading ? "left" : "right")"
        case .tearOff?, .otherWindow?: return "out of the window"
        case nil: return "nowhere"
        }
    }
    #endif

    /// Outside the window, a file tab becomes a window of its own: the
    /// ghost in the overlay gives way to one that can leave the window.
    private func updateTearOff(point: NSPoint, covered: Bool) {
        guard canTearOff, let window = dragWindow else {
            // Nothing to show past the window's edge: the tab's picture
            // stays in the overlay, which is clipped to it.
            if !draggingFile, overlay?.ghost == nil { overlay?.ghost = tabPicture }
            return
        }
        // Past the edge, or over another window in front of this one.
        let outside = covered || !NSRect(origin: .zero, size: window.frame.size).contains(point)
        if outside, tearOff == nil {
            tearOff = TabTearOffGhost(tab: tabPicture, grab: overlay?.grabOffset ?? .zero,
                                      appearance: window.effectiveAppearance)
        }
        guard let tearOff else { return }
        if outside {
            target = .tearOff
            overlay?.ghost = nil
            tearOff.move(to: window.convertPoint(toScreen: point))
            tearOff.show()
        } else {
            // Back in: the overlay draws it again, also after another
            // window's row stood in for it.
            if tearOff.isShown { tearOff.hide() }
            overlay?.ghost = tabPicture
        }
    }

    private func finish() {
        if let tab = draggedTab {
            // This window's own tab drag: a window that only showed where a
            // drag from elsewhere would land leaves both to that one.
            if askedElsewhere { _ = elsewhere(.cancelled, tab, nil, .zero, nil) }
            SpringLoading.end()
        }
        askedElsewhere = false
        draggedTab = nil
        docking = false
        tearOff?.hide()
        tearOff = nil
        canTearOff = false
        tabPicture = nil
        dragWindow = nil
        draggingFile = false
        fileDragWindow = nil
        overlay?.removeFromSuperview()
        overlay = nil
        source?.alphaValue = 1
        source = nil
        target = nil
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
    var zoneEdge: NSRectEdge? = .maxY

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What was drawn last time, so a move repaints what moved (the ghost,
    /// the marker) and the zone only when it changes: this runs at mouse rate
    /// over live terminals, and a whole-window repaint each time was the cost.
    private var drawnGhost: NSRect?
    private var drawnMarker: NSRect?
    private var drawnZone: NSRect?

    func redraw() {
        let ghostRect = ghost.map {
            NSRect(origin: NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y), size: $0.size)
                .insetBy(dx: -2, dy: -2)
        }
        let markerRect = marker?.insetBy(dx: -2, dy: -2)
        for rect in [drawnGhost, ghostRect, drawnMarker, markerRect].compactMap({ $0 }) {
            setNeedsDisplay(rect)
        }
        if zone != drawnZone {
            for rect in [drawnZone, zone].compactMap({ $0 }) { setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
        }
        drawnGhost = ghostRect
        drawnMarker = markerRect
        drawnZone = zone
    }

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
            case .minY: NSRect(x: zone.minX, y: zone.minY, width: zone.width, height: 1).fill()
            default: break
            }
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
