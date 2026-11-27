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
    /// Leaves of the layout that take no room here: they have no frame, and
    /// what is beside them shares theirs (`SplitLayout.frames`).
    private(set) var hiddenLeaves: Set<SplitLayout.Leaf> = []
    private var leafViews: [SplitLayout.Leaf: NSView] = [:]
    private var dividerViews: [SplitDividerView] = []

    /// A divider was pressed, before anything moves: the moment to note
    /// the sizes it may change.
    var onDividerPressed: () -> Void = {}
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
        // Laid out again only when the leaves' views changed: every sync
        // hands them over, a divider's drag syncs on every step, and each
        // of those laid the whole tree out a second time.
        let changed = views.count != leafViews.count || views.contains { leafViews[$0.key] !== $0.value }
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
        if changed { needsLayout = true }
    }

    /// A pane that is gone: its view leaves the window.
    func discard(_ view: NSView) {
        guard view.superview === self else { return }
        view.removeFromSuperview()
    }

    /// `slides`: a leaf that comes onto the screen or leaves it with this
    /// change does so over a moment instead of in one cut. Asked for when
    /// the side split or the strip is opened or put away by hand, which have
    /// always slid; a split somebody makes or closes, a zoom and a session
    /// switch cut.
    func apply(layout: SplitLayout, zoomed: SplitLayout.Leaf?, hidden: Set<SplitLayout.Leaf> = [],
               slides: Bool = false) {
        guard layout != splitLayout || zoomed != self.zoomed || hidden != hiddenLeaves else { return }
        // One at a time: a change during a slide lands it first.
        finishSlide()
        let before = slides && window != nil ? shownFrames : nil
        splitLayout = layout
        self.zoomed = zoomed
        hiddenLeaves = hidden
        // A drag whose divider this change took away, or put between other
        // splits, or behind a zoom, is over (`Held`).
        if held != nil, !heldIsStillThere { cancelDrag() }
        if let before {
            let after = wantedFrames
            if Set(before.keys) != Set(after.keys), !after.isEmpty, !before.isEmpty {
                slide(from: before, to: after)
                return
            }
        }
        needsLayout = true
    }

    // MARK: Sliding a leaf in or out

    /// A slide under way: where each leaf started and where it ends.
    private struct Slide {
        var timer: Timer
        var starts: [SplitLayout.Leaf: NSRect]
        var ends: [SplitLayout.Leaf: NSRect]
        var leaving: Set<SplitLayout.Leaf>
        var bounds: NSRect
    }
    private var sliding: Slide?

    /// The leaves on screen now, where their views are.
    private var shownFrames: [SplitLayout.Leaf: NSRect] {
        leafViews.filter { !$0.value.isHidden }.mapValues(\.frame)
    }

    /// Where the layout puts each leaf that has a view.
    private var wantedFrames: [SplitLayout.Leaf: NSRect] {
        if let zoomed = effectiveZoom { return [zoomed: bounds] }
        return splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).leaves
            .filter { leafViews[$0.key] != nil }
    }

    /// Step every leaf from where it is to where it goes, the way AppKit's
    /// own split view steps a pane open: real frames, a step a frame, with
    /// every terminal's resizing held until it lands (`Motion.pane`), so a
    /// terminal beside the one sliding is resized once and not thirty times.
    private func slide(from before: [SplitLayout.Leaf: NSRect], to after: [SplitLayout.Leaf: NSRect]) {
        var starts = before, ends = after
        var leaving = Set<SplitLayout.Leaf>()
        for (leaf, frame) in after where before[leaf] == nil {
            starts[leaf] = Self.collapsed(frame, without: before, with: after)
        }
        for (leaf, frame) in before where after[leaf] == nil {
            ends[leaf] = Self.collapsed(frame, without: after, with: before)
            leaving.insert(leaf)
        }
        let opening = leaving.isEmpty
        let duration = opening ? Motion.opening : Motion.closing
        dividerViews.forEach { $0.isHidden = true }
        for (leaf, start) in starts {
            guard let view = leafViews[leaf] else { continue }
            view.frame = start
            view.isHidden = false
        }
        // The rows dress for where they will be, before anything moves.
        onPlaced()
        SurfaceView.holdResizes()
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard self != nil else {
                // The tree went away mid-slide (its window closed within the
                // slide). Returning alone left this timer waking the main
                // thread 120 times a second until quit, and the hold on
                // every terminal in every window to the watchdog's two
                // seconds. `finishSlide` can't run, so its two parts are
                // done here.
                timer.invalidate()
                MainActor.assumeIsolated { SurfaceView.releaseResizes() }
                return
            }
            MainActor.assumeIsolated {
                guard let self, let slide = self.sliding else { return }
                let progress = min(1, (CACurrentMediaTime() - began) / duration)
                guard progress < 1 else { return self.finishSlide() }
                let eased = Self.ease(CGFloat(progress))
                for (leaf, start) in slide.starts {
                    guard let end = slide.ends[leaf], let view = self.leafViews[leaf] else { continue }
                    view.frame = NSRect(x: (start.minX + (end.minX - start.minX) * eased).rounded(),
                                        y: (start.minY + (end.minY - start.minY) * eased).rounded(),
                                        width: (start.width + (end.width - start.width) * eased).rounded(),
                                        height: (start.height + (end.height - start.height) * eased).rounded())
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sliding = Slide(timer: timer, starts: starts, ends: ends, leaving: leaving, bounds: bounds)
    }

    /// Land a slide: every leaf at its frame, the dividers back, and the
    /// terminals let go of a turn later, when the frames are final.
    private func finishSlide() {
        guard let slide = sliding else { return }
        sliding = nil
        slide.timer.invalidate()
        place()
        DispatchQueue.main.async { SurfaceView.releaseResizes() }
    }

    /// A leaf that is coming or going, squeezed to nothing against the edge
    /// it shares with the neighbour that makes room for it: where it starts
    /// from, or ends. `without` are the frames while it isn't there and
    /// `with` while it is.
    private static func collapsed(_ frame: NSRect, without: [SplitLayout.Leaf: NSRect],
                                  with: [SplitLayout.Leaf: NSRect]) -> NSRect {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        guard let neighbour = without.first(where: { $0.value.contains(centre) }),
              let beside = with[neighbour.key] else {
            return NSRect(x: frame.maxX, y: frame.minY, width: 0, height: frame.height)
        }
        let room = neighbour.value
        if frame.minX >= beside.maxX - 2 { return NSRect(x: room.maxX, y: frame.minY, width: 0, height: frame.height) }
        if frame.maxX <= beside.minX + 2 { return NSRect(x: room.minX, y: frame.minY, width: 0, height: frame.height) }
        if frame.minY >= beside.maxY - 2 { return NSRect(x: frame.minX, y: room.maxY, width: frame.width, height: 0) }
        return NSRect(x: frame.minX, y: room.minY, width: frame.width, height: 0)
    }

    /// `Motion.curve`, cubic-bezier(0.23, 1, 0.32, 1), evaluated: how far
    /// along a slide is at `time` of its length.
    private static func ease(_ time: CGFloat) -> CGFloat {
        func bezier(_ s: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
            let inverse = 1 - s
            return 3 * inverse * inverse * s * p1 + 3 * inverse * s * s * p2 + s * s * s
        }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if bezier(middle, 0.23, 0.32) < time { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, 1, 1)
    }

    /// Where a leaf is, in this view's coordinates. nil when it isn't shown.
    func frame(of leaf: SplitLayout.Leaf) -> NSRect? {
        if let zoomed = effectiveZoom { return leaf == zoomed ? bounds : nil }
        return splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).leaves[leaf]
    }

    /// The leaves on screen with their frames, in reading order.
    var visibleLeaves: [(leaf: SplitLayout.Leaf, frame: NSRect)] {
        if let zoomed = effectiveZoom { return [(zoomed, bounds)] }
        let frames = splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).leaves
        return splitLayout.leaves.compactMap { leaf in frames[leaf].map { (leaf, $0) } }
    }

    /// Whether a point in window coordinates is on a divider, its reach
    /// included.
    func isOnDivider(_ point: NSPoint) -> Bool {
        let local = convert(point, from: nil)
        return dividerViews.contains { !$0.isHidden && $0.frame.contains(local) }
    }

    /// The zoom, when it names a leaf that is here to be shown.
    private var effectiveZoom: SplitLayout.Leaf? {
        guard let zoomed, splitLayout.contains(zoomed), !hiddenLeaves.contains(zoomed),
              leafViews[zoomed] != nil else { return nil }
        return zoomed
    }

    /// Leaving the window lands a slide under way: one left running held
    /// every terminal's resizing until the watchdog let go, and its timer
    /// kept firing.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishSlide() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        if let slide = sliding {
            // The frames are the slide's until it lands. Unless the area
            // itself changed size under it: then it lands now.
            guard slide.bounds.size != bounds.size else { return }
            finishSlide()
            return
        }
        place()
    }

    /// The leaves were given their frames: which are along the top, and so
    /// have their rows in the titlebar, may have changed.
    var onPlaced: () -> Void = {}

    /// Give every leaf its frame now, without waiting for the layout pass:
    /// a session switch wants the terminal at its size before it is shown.
    func placeNow() {
        finishSlide()
        place()
    }

    private func place() {
        placeLeaves()
        onPlaced()
    }

    private func placeLeaves() {
        if let zoomed = effectiveZoom {
            for (leaf, view) in leafViews {
                view.isHidden = leaf != zoomed
                if leaf == zoomed, view.frame != bounds { view.frame = bounds }
            }
            dividerViews.forEach { $0.isHidden = true }
            return
        }
        let frames = splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves)
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
            divider.onPress = { [weak self, weak divider] pressed in
                guard let self, let divider else { return }
                self.hold(pressed, by: divider)
            }
            divider.onDrag = { [weak self, weak divider] pressed, position in
                guard let self, let divider else { return false }
                return self.dragHeld(pressed, by: divider, to: position)
            }
            divider.onRelease = { [weak self, weak divider] moved in
                guard let self, let divider else { return }
                self.letGo(by: divider, moved: moved)
            }
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
    var dividerRects: [NSRect] {
        splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).dividers.map(\.rect)
    }

    /// One divider to a position along its axis, as one step of a drag.
    func moveDivider(_ index: Int, to position: CGFloat) {
        let dividers = splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).dividers
        guard dividers.indices.contains(index) else { return }
        drag(dividers[index], to: position)
        layoutSubtreeIfNeeded()
    }

    /// A press on divider `index`, as the pointer makes one, and a first
    /// step of `delta`. Then `stepHeld` and `releaseHeld` go on with that
    /// same press, whatever happens to the tree meanwhile.
    func pressDivider(_ index: Int, by delta: CGFloat) -> Bool {
        let dividers = splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).dividers
        guard dividers.indices.contains(index), dividerViews.indices.contains(index) else { return false }
        let divider = dividers[index]
        hold(divider, by: dividerViews[index])
        probeStart = divider.axis == .row ? divider.rect.minX : divider.rect.minY
        return stepHeld(by: delta)
    }
    private var probeStart: CGFloat = 0

    /// Whether the held drag took the step (false: it was let go of).
    func stepHeld(by delta: CGFloat) -> Bool {
        guard let held, let view = held.view else { return false }
        let moved = dragHeld(held.divider, by: view, to: probeStart + delta)
        layoutSubtreeIfNeeded()
        return moved
    }

    func releaseHeld() {
        guard let view = held?.view else { return }
        letGo(by: view, moved: true)
    }

    func dragDivider(_ index: Int, by delta: CGFloat) {
        let dividers = splitLayout.frames(in: bounds, metrics: metrics, hidden: hiddenLeaves).dividers
        guard dividers.indices.contains(index) else { return }
        let divider = dividers[index]
        drag(divider, to: (divider.axis == .row ? divider.rect.minX : divider.rect.minY) + delta)
        onDividerReleased()
    }
    #endif

    private func drag(_ divider: SplitLayout.Divider, to position: CGFloat) {
        guard splitLayout.moveDivider(at: divider.path, index: divider.index, to: position,
                                      in: bounds, metrics: metrics, hidden: hiddenLeaves) else { return }
        place()
        onLayoutChanged(splitLayout)
    }

    // MARK: A divider held by the pointer

    /// The divider being dragged, as it was when it was pressed: its place
    /// in the tree and what it stands between. Divider views are reused by
    /// their place in the list, so when the tree changes during a drag (a
    /// split made by `wortel split`, one closed because its shell exited)
    /// the view under the pointer is handed another divider. The drag went
    /// on with that one, and the size it ended at was saved and remembered
    /// as the column's width: a side split of 400pt went to 801.
    private struct Held {
        weak var view: SplitDividerView?
        var divider: SplitLayout.Divider
        var sides: SplitLayout.DividerSides?
    }
    private var held: Held?

    /// The drag was let go of because the split it was moving changed: no
    /// release follows, so nothing is saved or remembered for it.
    var onDividerDragCancelled: () -> Void = {}

    private func hold(_ divider: SplitLayout.Divider, by view: SplitDividerView) {
        held = Held(view: view, divider: divider, sides: splitLayout.sides(of: divider, hidden: hiddenLeaves))
        onDividerPressed()
    }

    /// Whether the divider pressed is still there, between the same leaves,
    /// and on screen.
    private var heldIsStillThere: Bool {
        guard let held, let sides = held.sides else { return false }
        return effectiveZoom == nil && splitLayout.sides(of: held.divider, hidden: hiddenLeaves) == sides
    }

    /// One step of the drag, of the divider as it was pressed. False when
    /// the drag is over: let go of here, or before.
    private func dragHeld(_ divider: SplitLayout.Divider, by view: SplitDividerView,
                          to position: CGFloat) -> Bool {
        guard let held, held.view === view else { return false }
        guard heldIsStillThere else {
            cancelDrag()
            return false
        }
        drag(held.divider, to: position)
        return true
    }

    private func letGo(by view: SplitDividerView, moved: Bool) {
        guard held?.view === view else { return }
        held = nil
        if moved { onDividerReleased() }
    }

    /// Let go of the divider being dragged, if there is one: the split it
    /// was moving has changed, or the tree is another session's. Its view
    /// takes no more steps from this drag, and the release does nothing.
    func cancelDrag() {
        guard let held else { return }
        self.held = nil
        held.view?.dragWasCancelled()
        onDividerDragCancelled()
    }
}

/// One divider: a hairline, and a few points either side of it that take the
/// press, as the window's own dividers do.
@MainActor
private final class SplitDividerView: NSView {
    static let reach: CGFloat = 4

    /// How far one increment or decrement from VoiceOver moves it.
    static let accessibilityStep: CGFloat = 20

    /// Pressed: the divider as it is now, which the whole drag moves.
    var onPress: (SplitLayout.Divider) -> Void = { _ in }
    /// A step of the drag. False: the drag is over, take no more steps.
    var onDrag: (SplitLayout.Divider, CGFloat) -> Bool = { _, _ in false }
    /// Let go, and whether it was dragged at all.
    var onRelease: (Bool) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    private let line = FilledView(color: Chrome.hairline)
    private var divider: SplitLayout.Divider?
    /// How far the press was from the line's start, so the line doesn't jump
    /// to the pointer when the drag begins.
    private var grab: CGFloat = 0
    /// The divider as it was pressed, for the length of the drag: `divider`
    /// is whatever the tree lays out at this view's place, which can be
    /// another one by the next step. nil once the drag is over.
    private var pressed: SplitLayout.Divider?
    private var dragged = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        addSubview(line)
        // A splitter VoiceOver can move, as NSSplitView's dividers were
        // before the tree drew its own: without this the tree's dividers
        // were not there for VoiceOver at all.
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Divider")
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
        // A line between splits side by side stands upright.
        setAccessibilityOrientation(divider.axis == .row ? .vertical : .horizontal)
        setAccessibilityValue(NSNumber(value: Double(position(of: divider))))
    }

    /// Where the line is along its axis, in the tree's coordinates.
    private func position(of divider: SplitLayout.Divider) -> CGFloat {
        divider.axis == .row ? divider.rect.minX : divider.rect.minY
    }

    // VoiceOver's increment and decrement: a drag of one step, through the
    // same path as the pointer's, so it is saved and remembered like one.
    override func accessibilityPerformIncrement() -> Bool { step(by: Self.accessibilityStep) }
    override func accessibilityPerformDecrement() -> Bool { step(by: -Self.accessibilityStep) }

    private func step(by delta: CGFloat) -> Bool {
        guard let divider, !isHidden else { return false }
        onPress(divider)
        let moved = onDrag(divider, position(of: divider) + delta)
        onRelease(moved)
        return true
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
        pressed = divider
        onPress(divider)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let tree = superview else { return }
        let point = tree.convert(event.locationInWindow, from: nil)
        dragged = true
        if !onDrag(pressed, (pressed.axis == .row ? point.x : point.y) - grab) { dragWasCancelled() }
    }

    override func mouseUp(with event: NSEvent) {
        if pressed != nil { onRelease(dragged) }
        pressed = nil
        dragged = false
    }

    /// The tree let go of this drag: the split it was moving changed. The
    /// pointer moves nothing more until the next press, and the release
    /// saves and remembers nothing.
    func dragWasCancelled() {
        pressed = nil
        dragged = false
    }
}
