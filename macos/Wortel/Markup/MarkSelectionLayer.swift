import AppKit

/// The selected drawing's outline and handles, as the Move tool shows them.
///
/// A box, a pen's line and a highlight have a 1pt accent outline round their
/// ink and a handle on each corner. An arrow has a handle on each end and no
/// outline: a box around a line says nothing the line does not. Which
/// handles and where is `MarkStroke`'s to say; this draws them.
final class MarkSelectionLayer: CALayer {
    private let outline = CAShapeLayer()
    private var handles: [CAShapeLayer] = []

    override init() {
        super.init()
        anchorPoint = .zero
        masksToBounds = true
        zPosition = 1
        isHidden = true
        outline.anchorPoint = .zero
        outline.fillColor = nil
        outline.lineWidth = 1
        addSublayer(outline)
        let side = MarkStroke.handle
        for _ in 0..<4 {
            let handle = CAShapeLayer()
            handle.path = CGPath(ellipseIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), transform: nil)
            handle.fillColor = NSColor.white.cgColor
            handle.lineWidth = 1
            addSublayer(handle)
            handles.append(handle)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Around a drawing whose ink is at `points` in the view, in the part
    /// of the view the drawing may show in.
    func place(around points: [CGPoint], pen: MarkPen, clip: CGRect, accent: CGColor) {
        // Cut off where the drawing is, with room for a handle on its edge.
        let room = clip.insetBy(dx: -MarkStroke.handle, dy: -MarkStroke.handle)
        bounds = CGRect(origin: .zero, size: room.size)
        position = room.origin
        var offset = CGAffineTransform(translationX: -room.minX, y: -room.minY)
        outline.strokeColor = accent
        outline.path = pen == .arrow ? nil : CGPath(rect: MarkStroke.outline(of: points, pen: pen), transform: &offset)
        let shown = MarkStroke.handles(for: pen, points: points)
        for (index, layer) in handles.enumerated() {
            layer.isHidden = index >= shown.count
            guard index < shown.count else { continue }
            layer.strokeColor = accent
            layer.position = MarkStroke.position(of: shown[index], pen: pen, points: points).applying(offset)
        }
    }
}
