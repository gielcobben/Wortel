import AppKit

/// One mark on screen: its ink or its outline, cut off where its content is
/// cut off, and its badge, which is not.
final class MarkLayer: CALayer {
    private let shape = CAShapeLayer()
    /// What cuts the ink off. Only the ink: a badge held whole where the
    /// clip is too small for it (`MarkBadge.spot`) lies partly outside it.
    private let cut = CALayer()
    private let badge = CALayer()
    /// The point of a badge that is a pin (`MarkBadge`), under the badge.
    private let point = CAShapeLayer()
    /// Where the pin is in the view, while the badge is one.
    private(set) var pin: CGRect?

    init(mark: Mark, colour: CGColor, scale: CGFloat) {
        super.init()
        anchorPoint = .zero
        cut.anchorPoint = .zero
        cut.masksToBounds = true
        addSublayer(cut)
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
        cut.addSublayer(shape)
        point.anchorPoint = .zero
        point.fillColor = colour
        point.strokeColor = nil
        addSublayer(point)
        badge.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        badge.bounds = CGRect(x: 0, y: 0, width: MarkDrawing.badge, height: MarkDrawing.badge)
        badge.contentsScale = scale
        badge.contents = Self.badgeImage(mark.number, colour: colour, scale: scale)
        addSublayer(badge)
    }

    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Draw `mark` where `placement` says it is. `view` is the view's
    /// bounds and `floor` where the note bar begins: a pin is kept in the
    /// one and above the other (`MarkBadge.spot`).
    func place(_ mark: Mark, at placement: MarkPlacement, in view: CGRect, above floor: CGFloat) {
        // The layer is the part of the view the mark may show in; what it
        // draws is placed in the view's own coordinates, moved back by that.
        let clip = placement.clip
        // Not `frame`: on a layer with a transform (the Move tool's, while
        // a drawing is carried) the frame is the moved box, and setting it
        // takes the move back off the position.
        bounds = CGRect(origin: .zero, size: clip.size)
        position = clip.origin
        cut.frame = bounds
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
        // On the corner, never off the edge of what it may show in (or of
        // the view, where that has no room for it), and a pin pointing at
        // the mark once the mark has left.
        let spot = MarkBadge.spot(for: placement.badge(of: mark.shape), of: box, in: clip, seen: view, above: floor)
        badge.position = CGPoint(x: spot.centre.x - clip.minX, y: spot.centre.y - clip.minY)
        point.path = spot.toward.map { MarkBadge.point(at: badge.position, toward: $0) }
        let half = MarkDrawing.badge / 2
        pin = spot.toward == nil ? nil : CGRect(x: spot.centre.x - half, y: spot.centre.y - half,
                                                width: MarkDrawing.badge, height: MarkDrawing.badge)
    }

    /// Move the pin along its edge, out from under another.
    func slidePin(by dx: CGFloat) {
        guard let was = pin else { return }
        pin = was.offsetBy(dx: dx, dy: 0)
        badge.position.x += dx
        var move = CGAffineTransform(translationX: dx, y: 0)
        point.path = point.path?.copy(using: &move)
    }

    private static func badgeImage(_ number: Int, colour: CGColor, scale: CGFloat) -> CGImage? {
        let side = Int((MarkDrawing.badge * scale).rounded())
        guard let context = CGContext.picture(width: side, height: side) else { return nil }
        context.scaleBy(x: scale, y: scale)
        MarkDrawing.badge(number, centre: CGPoint(x: MarkDrawing.badge / 2, y: MarkDrawing.badge / 2),
                          diameter: MarkDrawing.badge, colour: colour, in: context)
        return context.makeImage()
    }
}
