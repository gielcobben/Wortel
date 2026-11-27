import AppKit

/// The Move tool: a press on a drawing selects it, a drag carries it or,
/// from a handle, resizes it, and letting go ties it again to what is
/// under it there. A picked element is not moved: it is where its element
/// is. What a handle does to a drawing's points is `MarkStroke`'s to say;
/// this hands the mouse to it.
extension MarkupOverlayView {
    /// The drawing in hand: which, where the press began, how far it has
    /// been carried, and its ink in the view when it began to be, which is
    /// where it is let go from: what it is on may move meanwhile.
    struct Carry {
        let mark: Mark
        let from: CGPoint
        var offset = CGSize.zero
        var points: [CGPoint]?
        var carried: Bool { points != nil }
    }

    /// A handle in hand: whose, which, the drawing's points in the view
    /// when it was taken, where the press began, and how far from the
    /// handle's middle, so the handle does not jump to the pointer.
    struct Resize {
        let mark: Mark
        let handle: MarkStroke.Handle
        let points: [CGPoint]
        let from: CGPoint
        let grab: CGSize
        var carried = false
    }

    // MARK: - The press

    /// A press with the Move tool in hand: on a handle of the selected
    /// drawing, on a drawing, or on neither.
    func moveBegan(at point: CGPoint) {
        if let (mark, handle, points) = handleHit(at: point) {
            let at = MarkStroke.position(of: handle, pen: mark.pen, points: points)
            resizing = Resize(mark: mark, handle: handle, points: points, from: point,
                              grab: CGSize(width: point.x - at.x, height: point.y - at.y))
            cursor(at: point).set()
        } else if let mark = movable(at: point) {
            // Selected at the press; the selected one is left as it is
            // until the press has travelled, so a click never moves it.
            select(mark.number)
            moving = Carry(mark: mark, from: point)
            NSCursor.closedHand.set()
        } else {
            select(nil)
        }
    }

    /// A drag with a drawing or a handle in hand. False with neither.
    func moveDragged(to point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        if var carry = moving {
            // The drawing follows the pointer; it is tied again where it
            // is let go. Until the press has travelled it is a click.
            let offset = CGSize(width: point.x - carry.from.x, height: point.y - carry.from.y)
            guard carry.carried || hypot(offset.width, offset.height) >= MarkStroke.clickTravel else { return true }
            if carry.points == nil {
                guard case .area(_, let ink) = carry.mark.shape,
                      let placement = surface.placement(of: carry.mark.number) else { return true }
                carry.points = ink.map(placement.point)
                held = carry.mark.number
            }
            carry.offset = offset
            moving = carry
            let shift = CGAffineTransform(translationX: offset.width, y: offset.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            markLayers[carry.mark.number]?.setAffineTransform(shift)
            if selected == carry.mark.number { selectionLayer.setAffineTransform(shift) }
            CATransaction.commit()
            return true
        }
        if var resize = resizing {
            guard resize.carried || hypot(point.x - resize.from.x, point.y - resize.from.y) >= MarkStroke.clickTravel
            else { return true }
            resize.carried = true
            resizing = resize
            if let points = resized(resize, to: point, flags: flags) {
                live = reshaped(resize.mark, to: points)
                place()
            }
            return true
        }
        return false
    }

    /// The drawing or the handle in hand is let go. False with neither.
    func moveEnded(at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        if let carry = moving {
            moving = nil
            cursor(at: point).set()
            if carry.carried { move(carry) }
            return true
        }
        if let resize = resizing {
            resizing = nil
            cursor(at: point).set()
            if resize.carried, let points = resized(resize, to: point, flags: flags) {
                retie(resize.mark, to: points)
            } else {
                settle(resize.mark.number)
            }
            return true
        }
        return false
    }

    /// Esc with a drawing or a handle in hand: it is put back as it was
    /// before the drag. False with neither.
    func moveCancelled() -> Bool {
        if let carry = moving {
            moving = nil
            settle(carry.mark.number)
            return true
        }
        if let resize = resizing {
            resizing = nil
            settle(resize.mark.number)
            return true
        }
        return false
    }

    // MARK: - Moving a drawing

    /// The drawn mark under a point: the selected one if it is there, then
    /// the newest. A picked element is not one: it is where its element is.
    func movable(at point: CGPoint) -> Mark? {
        func under(_ mark: Mark) -> Bool {
            guard case .area = mark.shape, let placement = surface.placement(of: mark.number) else { return false }
            return placement.box(of: mark.shape).insetBy(dx: -4, dy: -4).contains(point)
        }
        if let mark = selectedMark, under(mark) { return mark }
        return session.marks.reversed().first(where: under)
    }

    /// Let go of a drawing somewhere else: where it was drawn under the
    /// pointer, whatever its content did meanwhile.
    private func move(_ carry: Carry) {
        let offset = carry.offset
        guard let points = carry.points, abs(offset.width) + abs(offset.height) >= 1 else {
            return settle(carry.mark.number)
        }
        retie(carry.mark, to: points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) })
    }

    /// A drawing moved or resized to `points` in the view: it is tied to
    /// what is under it there and pictured again, the same mark with the
    /// same chip. Where it cannot be (off the edge of an image), it goes
    /// back.
    private func retie(_ mark: Mark, to points: [CGPoint]) {
        guard let area = MarkStroke.area(of: points, pen: mark.pen, within: bounds) else { return settle(mark.number) }
        tie(mark.number, pen: mark.pen, points: points, area: area) { [weak self] moved in
            if let moved { self?.session.replace(moved) }
            self?.settle(mark.number)
        }
    }

    /// Draw a drawing as the session has it again: while carried or
    /// resized it was drawn where the hand had it.
    private func settle(_ number: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayers[number]?.setAffineTransform(.identity)
        selectionLayer.setAffineTransform(.identity)
        CATransaction.commit()
        if held == number { held = nil }
        if live?.number == number { live = nil }
        place()
    }

    // MARK: - Selecting and resizing a drawing

    func select(_ number: Int?) {
        guard selected != number else { return }
        selected = number
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSelection()
        CATransaction.commit()
    }

    /// The selected drawing, as the session has it.
    private var selectedMark: Mark? {
        selected.flatMap { number in session.marks.first { $0.number == number } }
    }

    /// The selected drawing's handle under a point, with the drawing and
    /// its points in the view.
    func handleHit(at point: CGPoint) -> (Mark, MarkStroke.Handle, [CGPoint])? {
        guard let mark = selectedMark, case .area(_, let ink) = mark.shape,
              let placement = surface.placement(of: mark.number) else { return nil }
        let points = ink.map(placement.point)
        guard let handle = MarkStroke.handle(at: point, pen: mark.pen, points: points) else { return nil }
        return (mark, handle, points)
    }

    /// The drawing's points with the handle in hand where the pointer is.
    /// From where the drawing is now, not where it was at the press: the
    /// content may have scrolled under it. Shift keeps the proportions,
    /// Option resizes from the middle.
    private func resized(_ resize: Resize, to point: CGPoint, flags: NSEvent.ModifierFlags) -> [CGPoint]? {
        guard case .area(_, let ink) = resize.mark.shape,
              let placement = surface.placement(of: resize.mark.number) else { return nil }
        let target = CGPoint(x: point.x - resize.grab.width, y: point.y - resize.grab.height)
        return MarkStroke.resized(ink.map(placement.point), pen: resize.mark.pen, moving: resize.handle, to: target,
                                  proportional: flags.contains(.shift), fromCentre: flags.contains(.option))
    }

    /// `mark` with its ink at `points` in the view, kept in the units of
    /// what it is tied to, as `tie` keeps it.
    private func reshaped(_ mark: Mark, to points: [CGPoint]) -> Mark? {
        guard let placement = surface.placement(of: mark.number), placement.scale > 0 else { return nil }
        let area = MarkStroke.area(of: points, pen: mark.pen, within: bounds) ?? placement.box(of: mark.shape)
        return Mark(number: mark.number, shape: placement.shape(of: area, ink: points), name: mark.name,
                    picture: mark.picture, details: mark.details, pen: mark.pen)
    }

    /// The selection where its drawing is now.
    func placeSelection() {
        // In hand, it goes with its drawing, by the same transform.
        if held != nil, held == selected { return }
        guard let selected, let mark = live?.number == selected ? live : selectedMark,
              case .area(_, let ink) = mark.shape, let placement = surface.placement(of: selected) else {
            selectionLayer.isHidden = true
            return
        }
        var accent = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.cgColor }
        selectionLayer.place(around: ink.map(placement.point), pen: mark.pen, clip: placement.clip, accent: accent)
        selectionLayer.isHidden = false
    }

    /// The system's pointer for resizing a frame from that corner, and for
    /// an arrow's end the corner or edge it points to. Before macOS 15 there
    /// is no public pointer for a corner, and the crosshair says "exactly
    /// here" well enough.
    func resizeCursor(_ handle: MarkStroke.Handle, points: [CGPoint]) -> NSCursor {
        guard #available(macOS 15, *) else { return .crosshair }
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomRight: position = .bottomRight
        case .bottomLeft: position = .bottomLeft
        case .tail, .tip:
            guard let first = points.first, let last = points.last else { return .crosshair }
            let (from, to) = handle == .tip ? (first, last) : (last, first)
            // The view counts down, so a quarter turn on from the right is down.
            let step = (Int((atan2(to.y - from.y, to.x - from.x) / (.pi / 4)).rounded()) + 8) % 8
            position = [.right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft, .top, .topRight][step]
        }
        return .frameResize(position: position, directions: .all)
    }
}
