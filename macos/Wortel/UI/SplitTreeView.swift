import AppKit

/// The main area's panes, laid out from a `SplitLayout`: each leaf's view in
/// its frame, a hairline between neighbours that can be dragged.
///
/// One flat view, not split views inside split views. Every pane is a direct
/// subview whose frame is set here, so a pane that is added, closed or moved
/// to another edge never takes any other pane out of the window on its way:
/// a terminal that left the hierarchy would have to be shown again, which is
/// what every terminal host in the app avoids. It also means the tree can be
/// replaced whole (a session switch) with nothing rebuilt.
///
/// The view owns no model. It is handed a layout and the views of its leaves,
/// moves a divider in its own copy while one is dragged (so the pane follows
/// the pointer in the same event), and says so; whoever owns the session
/// writes it down.
@MainActor
final class SplitTreeView: NSView {
    var metrics = SplitLayout.Metrics()

    private(set) var splitLayout = SplitLayout()
    /// A leaf shown alone, filling the view. The others are hidden, not
    /// removed.
    private(set) var zoomed: SplitLayout.Leaf?
    private var leafViews: [SplitLayout.Leaf: NSView] = [:]
    private var dividerViews: [SplitDividerView] = []

    /// A divider was dragged: the layout as it now is.
    var onLayoutChanged: (SplitLayout) -> Void = { _ in }
    /// The drag is over: the moment to save.
    var onDividerReleased: () -> Void = {}
    /// A divider was double-clicked.
    var onDividerDoubleClicked: () -> Void = {}

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The views of the leaves on screen. A view handed over before and not
    /// in `views` now stays a subview, hidden: it is another session's pane,
    /// and its terminals stay in the window. `discard` takes one out for good.
    func setLeaves(_ views: [SplitLayout.Leaf: NSView]) {
        for (_, view) in views where view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            // Under the dividers, which take presses a few points either
            // side of their line.
            addSubview(view, positioned: .below, relativeTo: dividerViews.first)
        }
        let shown = Set(views.values.map(ObjectIdentifier.init))
        for view in leafViews.values where !shown.contains(ObjectIdentifier(view)) {
            view.isHidden = true
        }
        leafViews = views
        needsLayout = true
    }

    /// A pane that is gone: its view leaves the window.
    func discard(_ view: NSView) {
        guard view.superview === self else { return }
        view.removeFromSuperview()
    }

    func apply(layout: SplitLayout, zoomed: SplitLayout.Leaf?) {
        guard layout != splitLayout || zoomed != self.zoomed else { return }
        splitLayout = layout
        self.zoomed = zoomed
        needsLayout = true
    }

    /// Where a leaf is, in this view's coordinates. nil when it isn't shown.
    func frame(of leaf: SplitLayout.Leaf) -> NSRect? {
        if let zoomed = effectiveZoom { return leaf == zoomed ? bounds : nil }
        return splitLayout.frames(in: bounds, metrics: metrics).leaves[leaf]
    }

    /// The leaves on screen with their frames, in reading order.
    var visibleLeaves: [(leaf: SplitLayout.Leaf, frame: NSRect)] {
        if let zoomed = effectiveZoom { return [(zoomed, bounds)] }
        let frames = splitLayout.frames(in: bounds, metrics: metrics).leaves
        return splitLayout.leaves.compactMap { leaf in frames[leaf].map { (leaf, $0) } }
    }

    /// The zoom, when it names a leaf that is here to be shown.
    private var effectiveZoom: SplitLayout.Leaf? {
        guard let zoomed, splitLayout.contains(zoomed), leafViews[zoomed] != nil else { return nil }
        return zoomed
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        if let zoomed = effectiveZoom {
            for (leaf, view) in leafViews {
                view.isHidden = leaf != zoomed
                if leaf == zoomed, view.frame != bounds { view.frame = bounds }
            }
            dividerViews.forEach { $0.isHidden = true }
            return
        }
        let frames = splitLayout.frames(in: bounds, metrics: metrics)
        for (leaf, view) in leafViews {
            guard let frame = frames.leaves[leaf] else {
                view.isHidden = true
                continue
            }
            if view.frame != frame { view.frame = frame }
            view.isHidden = false
        }
        while dividerViews.count < frames.dividers.count {
            let divider = SplitDividerView()
            divider.onDrag = { [weak self] divider, position in self?.drag(divider, to: position) }
            divider.onRelease = { [weak self] in self?.onDividerReleased() }
            divider.onDoubleClick = { [weak self] in self?.onDividerDoubleClicked() }
            addSubview(divider, positioned: .above, relativeTo: nil)
            dividerViews.append(divider)
        }
        for (index, view) in dividerViews.enumerated() {
            guard index < frames.dividers.count else {
                view.isHidden = true
                continue
            }
            view.show(frames.dividers[index])
        }
    }

    #if DEBUG
    /// For `SplitProbe`: the dividers as laid out, and one of them dragged.
    var dividerRects: [NSRect] { splitLayout.frames(in: bounds, metrics: metrics).dividers.map(\.rect) }

    func dragDivider(_ index: Int, by delta: CGFloat) {
        let dividers = splitLayout.frames(in: bounds, metrics: metrics).dividers
        guard dividers.indices.contains(index) else { return }
        let divider = dividers[index]
        drag(divider, to: (divider.axis == .row ? divider.rect.minX : divider.rect.minY) + delta)
        onDividerReleased()
    }
    #endif

    private func drag(_ divider: SplitLayout.Divider, to position: CGFloat) {
        guard splitLayout.moveDivider(at: divider.path, index: divider.index, to: position,
                                 in: bounds, metrics: metrics) else { return }
        place()
        onLayoutChanged(splitLayout)
    }
}

/// One divider: a hairline, and a few points either side of it that take the
/// press, as the window's own dividers do.
@MainActor
private final class SplitDividerView: NSView {
    static let reach: CGFloat = 4

    var onDrag: (SplitLayout.Divider, CGFloat) -> Void = { _, _ in }
    var onRelease: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    private let line = FilledView(color: Chrome.hairline)
    private var divider: SplitLayout.Divider?
    /// How far the press was from the line's start, so the line doesn't jump
    /// to the pointer when the drag begins.
    private var grab: CGFloat = 0
    private var dragged = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        addSubview(line)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ divider: SplitLayout.Divider) {
        self.divider = divider
        isHidden = false
        let frame = divider.axis == .row
            ? divider.rect.insetBy(dx: -Self.reach, dy: 0)
            : divider.rect.insetBy(dx: 0, dy: -Self.reach)
        if self.frame != frame {
            self.frame = frame
            window?.invalidateCursorRects(for: self)
        }
        line.frame = divider.axis == .row
            ? NSRect(x: Self.reach, y: 0, width: divider.rect.width, height: frame.height)
            : NSRect(x: 0, y: Self.reach, width: frame.width, height: divider.rect.height)
    }

    private var cursor: NSCursor {
        divider?.axis == .column ? .resizeUpDown : .resizeLeftRight
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // A terminal under the divider's reach sets its own pointer as the mouse
    // moves over it; this says whose it is while the pointer is here.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { cursor.set() }

    override func mouseDown(with event: NSEvent) {
        guard let divider, let tree = superview else { return }
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        let point = tree.convert(event.locationInWindow, from: nil)
        grab = divider.axis == .row ? point.x - divider.rect.minX : point.y - divider.rect.minY
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider, let tree = superview else { return }
        let point = tree.convert(event.locationInWindow, from: nil)
        dragged = true
        onDrag(divider, (divider.axis == .row ? point.x : point.y) - grab)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onRelease() }
        dragged = false
    }
}
