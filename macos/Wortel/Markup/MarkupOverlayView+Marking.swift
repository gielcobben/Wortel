import AppKit

/// Making a mark: the stroke while it is drawn, and a click or a finished
/// stroke tied to what is under it and pictured.
extension MarkupOverlayView {
    // MARK: - The stroke in progress

    func showStroke(_ points: [CGPoint], pen: MarkPen, colour: MarkColour) {
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

    func hideStroke() {
        guard pending == 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.isHidden = true
        strokeLayer.path = nil
        CATransaction.commit()
    }

    // MARK: - Making a mark

    /// A click: the thing under it is picked, where the preview has things.
    func pick(at point: CGPoint) {
        let number = session.takeNumber()
        let picked = session.marks.filter { $0.shape == .thing }.map(\.number)
        surface.pick(number, at: point, unless: picked) { [weak self] answer in
            guard let self, self.session.isOn, let answer else {
                self?.session.giveBack(number)
                return
            }
            let tie: MarkTie
            switch answer {
            case .tied(let made):
                tie = made
            case .already(let mark):
                // Clicked again: its chip, as a click on the chip would,
                // and no reveal, since it was just clicked where it is.
                self.session.giveBack(number)
                return self.noteBar.selectChip(mark)
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

    /// A stroke let go: it stays drawn until its mark is made.
    func draw(_ points: [CGPoint], pen: MarkPen) {
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
    func tie(_ number: Int, pen: MarkPen, points: [CGPoint], area: CGRect, done: @escaping (Mark?) -> Void) {
        surface.tie(number, to: area) { [weak self] tie in
            guard let self, self.session.isOn, let tie, tie.placement.scale > 0 else { return done(nil) }
            var details = tie.details
            details.kind = "area"
            details.shape = pen.rawValue
            let mark = Mark(number: number, shape: tie.placement.shape(of: area, ink: points), name: pen.word,
                            picture: nil, details: details, pen: pen)
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
}
