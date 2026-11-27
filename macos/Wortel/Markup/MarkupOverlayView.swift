import AppKit

/// The mark-up layer: one view over whatever is previewed.
///
/// It draws the marks, takes the mouse (a click picks, a drag draws) and
/// holds the note bar. Clicks do not reach what is under it; scrolling is
/// handed on, and the marks follow where the preview says they are
/// (`MarkupSurface`). It is native, a sibling of the preview and not a
/// part of it, so a page can neither break the marks nor be changed by
/// them, and no picture of the preview has a mark in it unless one is drawn
/// there on purpose.
///
/// It exists only while mark-up is on and its tab is showing. Everything it
/// started is let go when it leaves its window.
///
/// This file is the view coming and going, its layout, and the marks kept
/// on their content. The mouse is in `MarkupOverlayView+Mouse.swift`, making
/// a mark in `+Marking` and the Move tool in `+Move`.
@MainActor
final class MarkupOverlayView: NSView {
    let session: MarkupSession
    let surface: any MarkupSurface
    let noteBar: MarkupNoteBar

    private let marksLayer = CALayer()
    var markLayers: [Int: MarkLayer] = [:]
    /// The outline of what a click would pick.
    let hoverLayer = CAShapeLayer()
    /// The stroke being drawn, until its mark takes over.
    let strokeLayer = CAShapeLayer()
    /// The selected drawing's outline and handles. Over the marks, and in
    /// their layer, so it goes faint with them.
    let selectionLayer = MarkSelectionLayer()

    // What the other three files keep. An extension cannot store anything,
    // so it is declared here.

    var tracking: NSTrackingArea?
    /// The press in progress with a pen in hand: where the pointer has been
    /// since mouse-down.
    var press: [CGPoint]?
    /// A stroke whose mark is being made: drawn until its mark takes over.
    var pending = 0
    /// The drawing selected with the Move tool, by its number. One at most.
    var selected: Int?
    /// The drawing being carried with the Move tool.
    var moving: Carry?
    /// The handle in hand with the Move tool.
    var resizing: Resize?
    /// The drawing being resized as the hand has it now, drawn in place of
    /// the session's until it is tied again or let go.
    var live: Mark?

    /// The drawing drawn where the hand has it rather than where its
    /// content is: carried with the Move tool, or let go and not yet tied
    /// again. `place` leaves it alone.
    var held: Int?
    /// Mark-up went off and the layer is fading out (`leave`). It is still
    /// in its window for that long, and takes no part in anything.
    private(set) var isLeaving = false

    private weak var followed: NSView?
    private var isShowing = false
    /// The mark whose chip the pointer is on, shown by the others standing
    /// back. With eight marks on a page, "which one is 5" is otherwise a
    /// search by colour and number; this answers it where the question is
    /// asked, in the sentence.
    private var pointedOut: Int?
    /// Scrolling was handed on and the preview has not said where its
    /// marks went: after a moment of that, they are drawn faint.
    private var awaiting = false
    private var behind: DispatchWorkItem?

    /// How long the preview has to answer a scroll before its marks go
    /// faint: three frames at 60 Hz. An idle page answers in under 1 ms.
    private static let patience: TimeInterval = 0.05

    init(session: MarkupSession, surface: any MarkupSurface) {
        self.session = session
        self.surface = surface
        noteBar = MarkupNoteBar(
            session: session,
            placeholders: surface.picksThings
                ? ["Click something or drag over it, then say what you want",
                   "Click or drag, then say what you want", "Say what you want"]
                : ["Drag over something, then say what you want",
                   "Drag, then say what you want", "Say what you want"])
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        marksLayer.anchorPoint = .zero
        layer?.addSublayer(marksLayer)
        for shape in [hoverLayer, strokeLayer] {
            shape.anchorPoint = .zero
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        hoverLayer.lineWidth = 1
        marksLayer.addSublayer(selectionLayer)
        // Its width, its ends and how much shows through are the pen's, set
        // for each stroke (`showStroke`).
        strokeLayer.fillColor = nil
        strokeLayer.lineJoin = .round
        noteBar.onHeightChange = { [weak self] in self?.needsLayout = true }
        noteBar.onHoverMark = { [weak self] in self?.pointOut($0) }
        noteBar.onPickMark = { [weak self] in self?.reveal($0) }
        addSubview(noteBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mark Up")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Coming and going

    /// Keep this view exactly over `view`, which its owner may resize
    /// behind its back: a docked Web Inspector shrinks the web view. Heard
    /// while the layer is in a window (`show`).
    func follow(_ view: NSView) {
        followed = view
        frame = view.frame
        view.postsFrameChangedNotifications = true
        if isShowing { startFollowing() }
    }

    private func startFollowing() {
        guard let followed else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(followedMoved),
                                               name: NSView.frameDidChangeNotification, object: followed)
        // It may have moved while this layer was out of the window.
        followedMoved()
    }

    @objc private func followedMoved() {
        guard let followed, followed.superview === superview else { return }
        frame = followed.frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { show() } else { hide() }
    }

    // The same layer can leave its window and come back (its container
    // moved), so what `hide` lets go of, `show` takes up again. The first
    // version let go of the note's text and the frame it follows and took
    // neither back: a layer put back showed an empty note that took no
    // typing and no chips, and stayed the size it was.
    private func show() {
        guard !isShowing, !isLeaving else { return }
        isShowing = true
        session.overlay = self
        noteBar.attach()
        startFollowing()
        surface.attach(to: self)
        surface.activate(moved: { [weak self] in self?.moved() })
        // Once more when everything around has its place: SwiftUI puts this
        // view in its window before it has finished placing its neighbours,
        // and the bar is laid out against them.
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
        marksChanged()
        // The keyboard to the note: mark-up is pointing and then typing.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.noteBar.focus()
        }
        arrive()
    }

    private func hide() {
        guard isShowing else { return }
        isShowing = false
        behind?.cancel()
        // Left set, the check that draws the marks faint was never asked
        // again after a scroll.
        behind = nil
        awaiting = false
        setFaint(false)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        noteBar.detach()
        // A press that will never hear its mouse-up, and its stroke. One
        // whose mark is being made (`pending`) is hidden by its own reply.
        press = nil
        hideStroke()
        showHover(nil)
        selected = nil
        moving = nil
        resizing = nil
        live = nil
        // Drawn where the hand had it, by a transform nothing else would
        // take off: back where the session has it if the layer returns.
        if let held {
            markLayers[held]?.setAffineTransform(.identity)
            selectionLayer.setAffineTransform(.identity)
        }
        held = nil
        // Only the layer the session knows as its own lets go: a tab moving
        // rows has a new one before the old one is taken down.
        guard session.overlay === self else { return }
        session.overlay = nil
        surface.deactivate(forgetting: !session.isOn && !session.hasNote)
    }

    /// The bar comes up from just under where it rests. Not with Reduce
    /// Motion, and never the marks: they are where the content is.
    private func arrive() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let bar = noteBar.layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 8
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [rise, fade]
        group.duration = Motion.opening
        group.timingFunction = Motion.curve
        bar.add(group, forKey: "arrive")
    }

    /// Mark-up went off: fade out, then go.
    func leave() {
        // Faded is not gone: a click on the page in those moments came
        // here, was swallowed, and over a page picked an element for a
        // mark the session would never add.
        isLeaving = true
        hide()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, superview != nil else {
            return removeFromSuperview()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.closing
            context.timingFunction = Motion.curve
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for layer in markLayers.values { layer.removeFromSuperlayer() }
        markLayers = [:]
        marksChanged()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        marksLayer.frame = bounds
        let span = barSpan()
        let height = noteBar.height(forWidth: span.width)
        noteBar.frame = NSRect(x: span.x, y: bounds.height - span.margin - height, width: span.width, height: height)
        window?.invalidateCursorRects(for: self)
        place()
    }

    /// Where the bar starts and how wide it is.
    ///
    /// Centred, 640pt at most. Where the preview is read in a column of
    /// its own (rendered Markdown), the bar is that column and its own
    /// padding more either side, so the note's words start under the
    /// document's and the bar stands a little proud of the text.
    private func barSpan() -> (x: CGFloat, width: CGFloat, margin: CGFloat) {
        // Closer to the edges where there is little width to give away.
        let margin: CGFloat = bounds.width < 420 ? 12 : MarkupNoteBar.margin
        let room = bounds.width - margin * 2
        var width = max(min(room, MarkupNoteBar.widest), 120)
        if let column = surface.readingColumn, column.width >= 200 {
            let wanted = column.insetBy(dx: -MarkupNoteBar.inset, dy: 0)
            if wanted.minX >= margin, wanted.maxX <= bounds.width - margin {
                return (wanted.minX.rounded(), wanted.width.rounded(), margin)
            }
            // A window too narrow for that: as much of the width as there is.
            width = max(min(room, wanted.width), 120)
        }
        return (((bounds.width - width) / 2).rounded(), width, margin)
    }

    // MARK: - The marks

    /// The session's marks changed: a layer for each that has none, and
    /// none for a mark that is gone.
    func marksChanged() {
        noteBar.update()
        guard isShowing else { return }
        let numbers = Set(session.marks.map(\.number))
        for (number, layer) in markLayers where !numbers.contains(number) {
            layer.removeFromSuperlayer()
            markLayers[number] = nil
        }
        let scale = window?.backingScaleFactor ?? 2
        for mark in session.marks where markLayers[mark.number] == nil {
            let layer = MarkLayer(mark: mark, colour: MarkDrawing.resolved(mark.colour, in: effectiveAppearance),
                                  scale: scale)
            marksLayer.addSublayer(layer)
            markLayers[mark.number] = layer
        }
        if let selected, !numbers.contains(selected) { self.selected = nil }
        // The chip the pointer was on is gone with its mark: nothing is
        // pointed out, or every other mark would stay faint.
        if let pointedOut, !numbers.contains(pointedOut) { pointOut(nil) }
        place()
    }

    func insertChip(for mark: Mark) {
        noteBar.insert(mark)
    }

    /// Put every mark where its content is now.
    func place() {
        CATransaction.begin()
        // No animation: a mark that eases to its place is a mark that is
        // somewhere else for a quarter of a second.
        CATransaction.setDisableActions(true)
        for mark in session.marks {
            // Content that moves under a drawing in hand moves under it:
            // the drawing stays with the pointer.
            guard let layer = markLayers[mark.number], mark.number != held else { continue }
            if let placement = surface.placement(of: mark.number) {
                layer.isHidden = false
                layer.place(live?.number == mark.number ? live ?? mark : mark, at: placement, in: bounds,
                            above: noteBar.frame.minY)
            } else {
                // What it was on is gone. Its chip and its picture stay.
                layer.isHidden = true
            }
        }
        spreadPins()
        placeSelection()
        CATransaction.commit()
    }

    /// The preview says its marks may have moved.
    private func moved() {
        // The column is known once the document has said where its blocks
        // are, which may be a moment after the layer appears, and it moves
        // with ⌘+. Asked each time and compared with where the bar is: the
        // first version compared the column with the one it was laid out
        // to, which was the stale one, and the bar jumped to its place at
        // the first scroll.
        let span = barSpan()
        if span.x != noteBar.frame.minX || span.width != noteBar.frame.width { needsLayout = true }
        awaiting = false
        behind?.cancel()
        behind = nil
        if marksLayer.opacity != 1 { setFaint(false) }
        place()
    }

    private func pointOut(_ number: Int?) {
        guard number != pointedOut else { return }
        pointedOut = number
        // Eased, both ways: it is the pointer passing over a word, and a
        // cut would flicker along a row of chips.
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12)
        for (mark, layer) in markLayers {
            layer.opacity = number == nil || mark == number ? 1 : 0.25
        }
        CATransaction.commit()
    }

    private func setFaint(_ faint: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marksLayer.opacity = faint ? 0.35 : 1
        CATransaction.commit()
    }

    // MARK: - Pins

    /// Pins side by side where they would sit on one another. Marks drawn
    /// down one side of a page all leave by the same place on the same
    /// edge, and a pile of pins shows one number. The lowest number keeps
    /// its place and the rest line up to its right.
    private func spreadPins() {
        let pinned = markLayers.compactMap { number, layer in
            layer.isHidden ? nil : layer.pin.map { (number: number, layer: layer, at: $0.minX) }
        }.sorted { ($0.at.rounded(), $0.number) < ($1.at.rounded(), $1.number) }
        var ends: [Int: CGFloat] = [:]
        for (_, layer, _) in pinned {
            guard let pin = layer.pin else { continue }
            let row = Int(pin.midY.rounded())
            if let end = ends[row], pin.minX < end + 2 { layer.slidePin(by: end + 2 - pin.minX) }
            ends[row] = layer.pin?.maxX ?? pin.maxX
        }
    }

    /// The mark whose pin is under a point: one that is out of view, with
    /// its badge left at the edge pointing at it.
    func pinned(at point: CGPoint) -> Int? {
        markLayers.first { $0.value.pin?.insetBy(dx: -2, dy: -2).contains(point) == true }?.key
    }

    /// Bring a mark into view: its chip was clicked, or its pin.
    func reveal(_ number: Int) {
        guard let mark = session.mark(number) else { return }
        // What the bar covers, from its top down: the strip under it is
        // too thin to show a mark in.
        surface.reveal(mark, coveredBelow: max(bounds.height - noteBar.frame.minY, 0))
    }

    // MARK: - Scrolling goes through

    override func scrollWheel(with event: NSEvent) {
        showHover(nil)
        guard let view = surface.view else { return }
        // To what is under the pointer inside the preview, where it has
        // scrolling parts of its own, and to the preview otherwise.
        var target = view
        if surface.scrollsInside, let parent = view.superview,
           let hit = view.hitTest(parent.convert(event.locationInWindow, from: nil)) {
            target = hit
        }
        target.scrollWheel(with: event)
        guard !session.marks.isEmpty, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0,
              surface.expectsMove(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) else { return }
        awaiting = true
        guard behind == nil else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.behind = nil
            if self.awaiting { self.setFaint(true) }
        }
        behind = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience, execute: check)
    }

    override func magnify(with event: NSEvent) { surface.view?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { surface.view?.smartMagnify(with: event) }
}
