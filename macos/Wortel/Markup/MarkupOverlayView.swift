import AppKit
import SwiftUI

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
@MainActor
final class MarkupOverlayView: NSView {
    let session: MarkupSession
    private let surface: any MarkupSurface
    private let noteBar: MarkupNoteBar

    private let marksLayer = CALayer()
    private let hoverLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var markLayers: [Int: MarkLayer] = [:]

    /// The press in progress: where the pointer has been since mouse-down.
    private var press: [CGPoint]?
    /// A stroke whose mark is being made: drawn until its mark takes over.
    private var pending = 0
    private var tracking: NSTrackingArea?
    private weak var followed: NSView?
    private var isShowing = false
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
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = MarkStroke.width
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        noteBar.onHeightChange = { [weak self] in self?.needsLayout = true }
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
    /// behind its back: a docked Web Inspector shrinks the web view.
    func follow(_ view: NSView) {
        followed = view
        frame = view.frame
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(followedMoved),
                                               name: NSView.frameDidChangeNotification, object: view)
    }

    @objc private func followedMoved() {
        guard let followed, followed.superview === superview else { return }
        frame = followed.frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { show() } else { hide() }
    }

    private func show() {
        guard !isShowing else { return }
        isShowing = true
        session.overlay = self
        surface.attach(to: self)
        surface.activate(moved: { [weak self] in self?.moved() })
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
        NotificationCenter.default.removeObserver(self)
        noteBar.detach()
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

    override func layout() {
        super.layout()
        marksLayer.frame = bounds
        // Closer to the edges where there is little width to give away.
        let margin = bounds.width < 420 ? 12 : MarkupNoteBar.margin
        let width = max(min(bounds.width - margin * 2, MarkupNoteBar.widest), 120)
        let height = noteBar.height(forWidth: width)
        noteBar.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - margin - height,
                               width: width, height: height)
        window?.invalidateCursorRects(for: self)
        place()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for layer in markLayers.values { layer.removeFromSuperlayer() }
        markLayers = [:]
        marksChanged()
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
        place()
    }

    /// Put every mark where its content is now.
    private func place() {
        CATransaction.begin()
        // No animation: a mark that eases to its place is a mark that is
        // somewhere else for a quarter of a second.
        CATransaction.setDisableActions(true)
        for mark in session.marks {
            guard let layer = markLayers[mark.number] else { continue }
            if let placement = surface.placement(of: mark.number) {
                layer.isHidden = false
                layer.place(mark, at: placement)
            } else {
                // What it was on is gone. Its chip and its picture stay.
                layer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private func moved() {
        awaiting = false
        behind?.cancel()
        behind = nil
        if marksLayer.opacity != 1 { setFaint(false) }
        place()
    }

    private func setFaint(_ faint: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marksLayer.opacity = faint ? 0.35 : 1
        CATransaction.commit()
    }

    func insertChip(for mark: Mark) {
        noteBar.insert(mark)
    }

    // MARK: - The mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// The pointer over the preview: a crosshair with a pen in hand, since
    /// the preview is then for pointing at. With the Move tool it is the
    /// arrow, and a hand over a drawing that can be moved. The bar keeps
    /// its own cursors.
    private func cursor(at point: CGPoint) -> NSCursor {
        guard session.tool == .move else { return .crosshair }
        if moving != nil { return .closedHand }
        return movable(at: point) == nil ? .arrow : .openHand
    }

    override func resetCursorRects() {
        guard session.tool != .move else { return }
        let above = NSRect(x: 0, y: 0, width: bounds.width, height: max(noteBar.frame.minY, 0))
        addCursorRect(above, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !noteBar.frame.contains(point) { cursor(at: point).set() }
    }

    /// Another tool was taken up in the bar.
    func toolChanged() {
        showHover(nil)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !noteBar.frame.contains(point) else { return showHover(nil) }
        if session.tool == .move {
            cursor(at: point).set()
            return showHover(nil)
        }
        guard press == nil, surface.picksThings else { return }
        surface.probe(at: point) { [weak self] rect in
            // An answer to where the pointer was before a press began, or
            // before the tool changed.
            guard let self, self.press == nil, self.session.tool != .move else { return }
            self.showHover(rect)
        }
    }

    override func mouseExited(with event: NSEvent) {
        showHover(nil)
    }

    private func showHover(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect, rect.width >= 1, rect.height >= 1 {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                hoverLayer.strokeColor = NSColor.controlAccentColor.cgColor
                hoverLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            }
            hoverLayer.path = CGPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5),
                                     cornerWidth: min(3, rect.width / 2), cornerHeight: min(3, rect.height / 2),
                                     transform: nil)
            hoverLayer.isHidden = false
        } else {
            hoverLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        // The keyboard back to the note, if it wandered to the header.
        if window?.firstResponder !== noteBar.textView { noteBar.focus() }
        showHover(nil)
        let point = convert(event.locationInWindow, from: nil)
        if session.tool == .move {
            if let mark = movable(at: point) {
                moving = (mark, point, .zero)
                NSCursor.closedHand.set()
            }
            return
        }
        press = [point]
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (mark, from, _) = moving {
            // The drawing follows the pointer; it is tied again where it
            // is let go.
            let offset = CGSize(width: point.x - from.x, height: point.y - from.y)
            moving = (mark, from, offset)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            markLayers[mark.number]?.setAffineTransform(CGAffineTransform(translationX: offset.width, y: offset.height))
            CATransaction.commit()
            return
        }
        guard press != nil, let pen = session.tool.pen else { return }
        press?.append(CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height)))
        guard let press, !MarkStroke.isClick(press) else { return }
        showStroke(MarkStroke.points(for: pen, drawn: press, straight: event.modifierFlags.contains(.shift)),
                   pen: pen, colour: .of(session.upcomingNumber))
    }

    override func mouseUp(with event: NSEvent) {
        if let (mark, _, offset) = moving {
            moving = nil
            cursor(at: convert(event.locationInWindow, from: nil)).set()
            return move(mark, by: offset)
        }
        guard let points = press else { return }
        press = nil
        guard let pen = session.tool.pen else { return }
        if MarkStroke.isClick(points) {
            hideStroke()
            if surface.picksThings, let point = points.first { pick(at: point) }
        } else {
            let straight = event.modifierFlags.contains(.shift)
            let kept = pen == .pen || pen == .highlighter ? MarkStroke.thinned(points) : points
            draw(MarkStroke.points(for: pen, drawn: kept, straight: straight), pen: pen)
        }
    }

    /// Esc with a stroke or a drawing in hand: it is let go, mark-up stays.
    func cancelStroke() -> Bool {
        if let (mark, _, _) = moving {
            moving = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            markLayers[mark.number]?.setAffineTransform(.identity)
            CATransaction.commit()
            return true
        }
        guard press != nil else { return false }
        press = nil
        hideStroke()
        return true
    }

    // Clicks of every other kind stop here too: nothing under the layer
    // is pressed, and no menu of the page's opens over the marks.
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func showStroke(_ points: [CGPoint], pen: MarkPen, colour: MarkColour) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.strokeColor = MarkDrawing.resolved(colour, in: effectiveAppearance)
        strokeLayer.lineWidth = pen.width
        strokeLayer.opacity = Float(pen.opacity)
        strokeLayer.lineCap = pen == .highlighter ? .butt : .round
        strokeLayer.path = MarkStroke.path(for: pen, through: points)
        strokeLayer.isHidden = false
        CATransaction.commit()
    }

    private func hideStroke() {
        guard pending == 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.isHidden = true
        strokeLayer.path = nil
        CATransaction.commit()
    }

    // MARK: - Making a mark

    private func pick(at point: CGPoint) {
        let number = session.takeNumber()
        surface.pick(number, at: point) { [weak self] tie in
            guard let self, self.session.isOn, let tie else {
                self?.session.giveBack(number)
                return
            }
            var details = tie.details
            details.kind = "element"
            let mark = Mark(number: number, shape: .thing, name: tie.name ?? "element",
                            picture: nil, details: details)
            self.session.add(mark)
            // The element with some room, and nothing drawn on it.
            let box = tie.placement.box(of: .thing).intersection(tie.placement.clip)
            self.surface.capture(box.insetBy(dx: -MarkStroke.room, dy: -MarkStroke.room)) { [weak self] capture in
                if let capture { self?.session.keep(capture.image, for: number) }
            }
        }
    }

    private func draw(_ points: [CGPoint], pen: MarkPen) {
        guard let area = MarkStroke.area(of: points, pen: pen, within: bounds) else { return hideStroke() }
        let number = session.takeNumber()
        showStroke(points, pen: pen, colour: .of(number))
        pending += 1
        tie(number, pen: pen, points: points, area: area) { [weak self] mark in
            guard let self else { return }
            self.pending -= 1
            self.hideStroke()
            if let mark { self.session.add(mark) } else { self.session.giveBack(number) }
        }
    }

    /// Tie a drawn mark to what is under it, and take its picture. Its
    /// area and its points are kept in the units of what they are tied to,
    /// from its origin: that is what lets them move and zoom with it.
    private func tie(_ number: Int, pen: MarkPen, points: [CGPoint], area: CGRect,
                     done: @escaping (Mark?) -> Void) {
        surface.tie(number, to: area) { [weak self] tie in
            guard let self, self.session.isOn, let tie, tie.placement.scale > 0 else { return done(nil) }
            let origin = tie.placement.origin, scale = tie.placement.scale
            func own(_ point: CGPoint) -> CGPoint {
                CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
            }
            let box = CGRect(origin: own(area.origin),
                             size: CGSize(width: area.width / scale, height: area.height / scale))
            var details = tie.details
            details.kind = "area"
            details.shape = pen.rawValue
            var mark = Mark(number: number, shape: .area(box: box, ink: points.map(own)), name: pen.word,
                            picture: nil, details: details)
            mark.pen = pen
            done(mark)
            let colour = MarkDrawing.resolved(mark.colour, in: self.effectiveAppearance)
            // The area with its ink (a circle around a word and a line
            // through it are different things to say), and what is around
            // it, so the picture can be placed without another.
            self.surface.capture(MarkStroke.pictured(area, within: self.bounds)) { [weak self] capture in
                guard let capture else { return }
                let inked = MarkupPicture.inked(capture.image, showing: capture.showing,
                                                mark: mark, at: tie.placement, colour: colour)
                self?.session.keep(inked, for: number)
            }
        }
    }

    // MARK: - Moving a drawing

    /// The drawing in hand with the Move tool: which, where the press
    /// began, and how far it has been carried.
    private var moving: (mark: Mark, from: CGPoint, offset: CGSize)?

    /// The drawn mark under a point, the newest first. A picked element
    /// is not one: it is where its element is.
    private func movable(at point: CGPoint) -> Mark? {
        session.marks.reversed().first { mark in
            guard case .area = mark.shape, let placement = surface.placement(of: mark.number) else { return false }
            return placement.box(of: mark.shape).insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    /// Let go of a drawing somewhere else: it is tied to what is under it
    /// there, and pictured again. Where it cannot be (off the edge of an
    /// image), it goes back.
    private func move(_ mark: Mark, by offset: CGSize) {
        func settle() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            markLayers[mark.number]?.setAffineTransform(.identity)
            CATransaction.commit()
            place()
        }
        guard case .area(_, let ink) = mark.shape, abs(offset.width) + abs(offset.height) >= 1,
              let placement = surface.placement(of: mark.number) else { return settle() }
        let points = ink.map { point -> CGPoint in
            let placed = placement.point(point)
            return CGPoint(x: placed.x + offset.width, y: placed.y + offset.height)
        }
        guard let area = MarkStroke.area(of: points, pen: mark.pen, within: bounds) else { return settle() }
        tie(mark.number, pen: mark.pen, points: points, area: area) { [weak self] moved in
            if let moved { self?.session.replace(moved) }
            settle()
        }
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

/// One mark on screen: its ink or its outline and its badge, cut off where
/// its content is cut off.
private final class MarkLayer: CALayer {
    private let shape = CAShapeLayer()
    private let badge = CALayer()

    init(mark: Mark, colour: CGColor, scale: CGFloat) {
        super.init()
        anchorPoint = .zero
        masksToBounds = true
        shape.anchorPoint = .zero
        shape.fillColor = nil
        shape.strokeColor = colour
        shape.lineCap = .round
        shape.lineJoin = .round
        if case .area = mark.shape {
            shape.lineWidth = mark.pen.width
            shape.opacity = Float(mark.pen.opacity)
            // A marker's ends are cut square.
            if mark.pen == .highlighter { shape.lineCap = .butt }
        } else {
            shape.lineWidth = MarkDrawing.outline
        }
        addSublayer(shape)
        badge.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        badge.bounds = CGRect(x: 0, y: 0, width: MarkDrawing.badge, height: MarkDrawing.badge)
        badge.contentsScale = scale
        badge.contents = Self.badgeImage(mark.number, colour: colour, scale: scale)
        addSublayer(badge)
    }

    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func place(_ mark: Mark, at placement: MarkPlacement) {
        // The layer is the part of the view the mark may show in; what it
        // draws is placed in the view's own coordinates, moved back by that.
        let clip = placement.clip
        frame = clip
        let offset = CGAffineTransform(translationX: -clip.minX, y: -clip.minY)
        let box = placement.box(of: mark.shape)
        switch mark.shape {
        case .thing:
            let rect = box.insetBy(dx: -MarkDrawing.outline / 2, dy: -MarkDrawing.outline / 2)
            var transform = offset
            shape.path = CGPath(roundedRect: rect,
                                cornerWidth: min(MarkDrawing.outlineRadius, rect.width / 2),
                                cornerHeight: min(MarkDrawing.outlineRadius, rect.height / 2),
                                transform: &transform)
        case .area(_, let ink):
            var transform = offset
            shape.path = MarkStroke.path(for: mark.pen, through: ink.map(placement.point)).copy(using: &transform)
        }
        // On the corner, and never off the edge of what it may show in.
        let half = MarkDrawing.badge / 2, at = placement.badge(of: mark.shape)
        badge.position = CGPoint(x: min(max(at.x, clip.minX + half), max(clip.maxX - half, clip.minX + half)) - clip.minX,
                                 y: min(max(at.y, clip.minY + half), max(clip.maxY - half, clip.minY + half)) - clip.minY)
    }

    private static func badgeImage(_ number: Int, colour: CGColor, scale: CGFloat) -> CGImage? {
        let side = Int((MarkDrawing.badge * scale).rounded())
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        MarkDrawing.badge(number, centre: CGPoint(x: MarkDrawing.badge / 2, y: MarkDrawing.badge / 2),
                          diameter: MarkDrawing.badge, colour: colour, in: context)
        return context.makeImage()
    }
}

/// The button that turns mark-up on, in the bar each preview already has.
/// The system's own Markup glyph, drawn as the header's other buttons are,
/// and lit while mark-up is on.
struct MarkupButton: View {
    let session: MarkupSession
    var size: CGFloat = 24
    /// Get the session ready for what is shown now, and say whether there
    /// is anything to mark. A page is always ready.
    var prepare: () -> Bool = { true }

    var body: some View {
        Button {
            if session.isOn || prepare() { session.toggle() }
        } label: {
            Image(systemName: session.justCopied ? "checkmark" : "pencil.tip.crop.circle")
                .font(.system(size: 13))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: session.isOn ? Chrome.selectedFill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
        .foregroundStyle(.secondary)
        .help(session.justCopied ? "Copied" : "Mark Up (\u{21E7}\u{2318}M)")
        .accessibilityLabel("Mark Up")
    }
}

/// The mark-up layer over a file's preview, placed by SwiftUI over views
/// SwiftUI also places. (Over a page it is AppKit's, see `WebViewContainer`.)
struct MarkupOverlayHost: NSViewRepresentable {
    let session: MarkupSession

    func makeNSView(context: Context) -> NSView {
        guard let surface = session.surface else { return NSView() }
        return MarkupOverlayView(session: session, surface: surface)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
