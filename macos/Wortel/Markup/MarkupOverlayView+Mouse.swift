import AppKit

/// The mouse over the mark-up layer: the pointer, the outline of what a
/// click would pick, and the press, which belongs to the tool in hand. A
/// pen's press is a click that picks or a drag that draws (`+Marking`);
/// the Move tool's takes a drawing or a handle (`+Move`).
extension MarkupOverlayView {
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

    // MARK: - The pointer

    /// The pointer over the preview: a crosshair with a pen in hand, since
    /// the preview is then for pointing at. With the Move tool it is the
    /// arrow, a hand over a drawing that can be moved, and the resize
    /// pointer over a handle of the selected one. The bar keeps its own
    /// cursors.
    func cursor(at point: CGPoint) -> NSCursor {
        guard session.tool == .move else { return .crosshair }
        // The marks are on another layer on the note: nothing here to take.
        guard hasMarks else { return .arrow }
        if let resizing { return resizeCursor(resizing.handle, points: resizing.points) }
        if moving != nil { return .closedHand }
        if let (_, handle, points) = handleHit(at: point) { return resizeCursor(handle, points: points) }
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
        select(nil)
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

    func showHover(_ rect: CGRect?) {
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

    // MARK: - The press

    // Fading out, the layer is not there: what is under it takes the
    // pointer, as it will once the layer has gone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isLeaving ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLeaving else { return }
        // The note on screen in another window or split had the marks:
        // what is made here is tied through this preview.
        claim()
        // The keyboard back to the note, if it wandered to the header.
        if window?.firstResponder !== noteBar.textView { noteBar.focus() }
        showHover(nil)
        let point = convert(event.locationInWindow, from: nil)
        // A pin points at a mark that is out of view, and a press on it is
        // a wish to see that mark, with any tool in hand.
        if let number = pinned(at: point) { return reveal(number) }
        if session.tool == .move { return moveBegan(at: point) }
        press = [point]
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if moveDragged(to: point, flags: event.modifierFlags) { return }
        guard press != nil, let pen = session.tool.pen else { return }
        press?.append(point.held(in: bounds))
        guard let press, !MarkStroke.isClick(press) else { return }
        showStroke(MarkStroke.points(for: pen, drawn: press, straight: event.modifierFlags.contains(.shift)),
                   pen: pen, colour: .of(session.upcomingNumber))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if moveEnded(at: point, flags: event.modifierFlags) { return }
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

    /// Esc, one step at a time: a stroke, a drawing or a handle in hand is
    /// let go (a drawing as it was before the drag), then a selection is
    /// dropped. Only with none of those does Esc leave mark-up.
    func stepBack() -> Bool {
        if moveCancelled() { return true }
        if press != nil {
            press = nil
            hideStroke()
            return true
        }
        if selected != nil {
            select(nil)
            return true
        }
        return false
    }

    // Clicks of every other kind stop here too: nothing under the layer
    // is pressed, and no menu of the page's opens over the marks.
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
