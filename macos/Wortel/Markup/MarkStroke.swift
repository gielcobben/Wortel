import CoreGraphics
import Foundation

/// The geometry of a drawn mark: when a press is a click and when a stroke,
/// which points of a stroke are kept, the area it stands for, and the line
/// drawn through it.
enum MarkStroke {
    /// A press that travels less than this is a click, not a drawing.
    static let clickTravel: CGFloat = 4
    /// The room around the ink that belongs to its area, and around a picked
    /// element in its picture.
    static let room: CGFloat = 8
    /// The ink's width.
    static let width: CGFloat = 3

    /// Whether the press ended close enough to where it began to be a click.
    static func isClick(_ points: [CGPoint]) -> Bool {
        guard let first = points.first else { return true }
        return !points.contains { hypot($0.x - first.x, $0.y - first.y) >= clickTravel }
    }

    /// The points worth keeping: a mouse reports several a point apart, and
    /// a line through all of them is no smoother than one through fewer.
    static func thinned(_ points: [CGPoint], apart: CGFloat = 2) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var kept = [last]
        for point in points.dropFirst() where hypot(point.x - last.x, point.y - last.y) >= apart {
            kept.append(point)
            last = point
        }
        // The end of the stroke is where the hand stopped, kept even when it
        // is close to the point before it.
        if let end = points.last, end != kept.last { kept.append(end) }
        return kept
    }

    /// The area a stroke stands for: its outline's box, with some room, and
    /// no further than the view it was drawn in.
    static func area(of points: [CGPoint], within bounds: CGRect) -> CGRect? {
        guard let first = points.first else { return nil }
        var box = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            box = box.union(CGRect(origin: point, size: .zero))
        }
        let roomy = box.insetBy(dx: -(room + width / 2), dy: -(room + width / 2)).intersection(bounds)
        return roomy.isNull || roomy.width < 1 || roomy.height < 1 ? nil : roomy.integral
    }

    /// The line through a stroke's points: straight to the first midpoint,
    /// then a curve through each point to the next midpoint, so a hand's
    /// corners come out round and the line still passes where it was drawn.
    static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            // A dot: one point still has to draw (a round cap does the rest).
            if points.count == 1 { path.addLine(to: first) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let point = points[index], next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
