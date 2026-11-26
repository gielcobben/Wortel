import CoreGraphics
import Foundation

/// The geometry of a drawn mark: when a press is a click and when a stroke,
/// which points of a stroke are kept, the area it stands for, the line
/// drawn through it, and a drawing's handles and what dragging one does.
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
        guard !points.isEmpty else { return nil }
        let roomy = box(of: points).insetBy(dx: -(room + width / 2), dy: -(room + width / 2)).intersection(bounds)
        return roomy.isNull || roomy.width < 1 || roomy.height < 1 ? nil : roomy.integral
    }

    // MARK: - The other pens

    /// The points a mark is kept as, for the pen in hand. The pen and the
    /// highlighter keep the hand's own line; a box keeps two corners and an
    /// arrow its two ends.
    ///
    /// `straight` is Shift: a straight line in steps of 45 degrees with the
    /// pen, the highlighter and the arrow. A box takes no notice of it: it
    /// marks an area, and a square says nothing there a rectangle does not
    /// (the owner's call, 2026-11-25). Resizing one is another matter:
    /// Shift keeps its proportions there, as it does everywhere on a Mac.
    static func points(for pen: MarkPen, drawn: [CGPoint], straight: Bool) -> [CGPoint] {
        guard let start = drawn.first, let end = drawn.last, drawn.count > 1 else { return drawn }
        switch pen {
        case .pen, .highlighter:
            return straight ? [start, snapped(end, from: start)] : drawn
        case .arrow:
            return [start, straight ? snapped(end, from: start) : end]
        case .box:
            return [start, end]
        }
    }

    /// `point` moved to the nearest of the eight directions from `start`,
    /// as far from it as it was.
    static func snapped(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// The line a pen makes of its points. `unit` is how large a point of
    /// the arrow's head and the box's corners is drawn: 1 on screen, more
    /// in a picture shrunk to fit.
    static func path(for pen: MarkPen, through points: [CGPoint], unit: CGFloat = 1) -> CGPath {
        switch pen {
        case .pen, .highlighter:
            return path(through: points)
        case .box:
            guard let first = points.first, let last = points.last else { return CGMutablePath() }
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            let radius = min(4 * unit, rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .arrow:
            let path = CGMutablePath()
            guard let tail = points.first, let tip = points.last else { return path }
            path.move(to: tail)
            path.addLine(to: tip)
            // The head: two short lines back from the tip, opened 28 degrees
            // each side, and no longer than half the arrow.
            let length = hypot(tip.x - tail.x, tip.y - tail.y)
            guard length > 0 else { return path }
            let head = min(12 * unit, length / 2)
            let back = atan2(tail.y - tip.y, tail.x - tip.x)
            for side in [-1.0, 1.0] {
                let angle = back + side * 28 * .pi / 180
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x + cos(angle) * head, y: tip.y + sin(angle) * head))
            }
            return path
        }
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

    /// The area a mark drawn with a pen stands for: its line's box with
    /// room, wide enough for a highlighter's own width.
    static func area(of points: [CGPoint], pen: MarkPen, within bounds: CGRect) -> CGRect? {
        guard let area = area(of: points, within: bounds) else { return nil }
        let extra = (pen.width - width) / 2
        return extra > 0 ? area.insetBy(dx: -extra, dy: -extra).intersection(bounds).integral : area
    }

    /// What a drawn area's picture shows: the area and what is around it.
    ///
    /// The area alone is the ink's box, and a loop drawn at the edge of a
    /// paragraph is a picture of half of two words: enough to find the
    /// place in a picture of the whole, and not by itself (the first note
    /// read by an agent, 2026-11-25). So the picture has `around` points
    /// more a side, and is never smaller than `least`: a scribble on one
    /// word still shows the line it is in.
    static let around: CGFloat = 32
    static let least = CGSize(width: 360, height: 160)

    static func pictured(_ area: CGRect, within bounds: CGRect) -> CGRect {
        var rect = area.insetBy(dx: -around, dy: -around)
        if rect.width < least.width { rect = rect.insetBy(dx: -(least.width - rect.width) / 2, dy: 0) }
        if rect.height < least.height { rect = rect.insetBy(dx: 0, dy: -(least.height - rect.height) / 2) }
        // Kept its size where it meets an edge, by moving in, before it is
        // cut to the view.
        if rect.minX < bounds.minX { rect.origin.x = bounds.minX }
        if rect.maxX > bounds.maxX { rect.origin.x = max(bounds.minX, bounds.maxX - rect.width) }
        if rect.minY < bounds.minY { rect.origin.y = bounds.minY }
        if rect.maxY > bounds.maxY { rect.origin.y = max(bounds.minY, bounds.maxY - rect.height) }
        let cut = rect.intersection(bounds)
        return cut.isNull ? area : cut.integral.intersection(bounds)
    }

    // MARK: - A rough shape made clean

    /// What the pen keeps of a stroke it knew for a shape, or nil for one
    /// it did not: the hand's own line stays then.
    static func cleaned(_ drawn: [CGPoint]) -> (pen: MarkPen, points: [CGPoint])? {
        MarkSnap.recognise(drawn).map(drawing)
    }

    /// A recognised shape as a drawing of a kind there already is: a box
    /// as the box's two corners, an arrow as the arrow's two ends, a line
    /// and an oval as the pen's own points.
    ///
    /// There is no oval among the pens, and it needs none. An oval kept as
    /// the points of one is drawn, pictured, moved and resized by what the
    /// pen's line already has, and a handle scales every point, which
    /// keeps an oval an oval. A kind of its own would be a second copy of
    /// each of those for the sake of a rounder name.
    static func drawing(of snap: MarkSnap) -> (pen: MarkPen, points: [CGPoint]) {
        switch snap {
        case .box(let rect):
            return (.box, [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
        case .arrow(let tail, let tip):
            return (.arrow, [tail, tip])
        case .line(let start, let end):
            return (.pen, levelled(start, end))
        case .oval(let rect):
            return (.pen, oval(in: rect))
        }
    }

    /// How far off level or upright a line may be and still be meant so.
    static let nearlyLevel: CGFloat = 4 * .pi / 180

    /// A line from `start` to `end`, made level or upright where it nearly
    /// is: turned about its middle, as long as it was. A line under a row
    /// of text is drawn to be level, and one a degree off looks like a
    /// mistake beside the text. Any other line keeps the hand's angle.
    static func levelled(_ start: CGPoint, _ end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return [start, end] }
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let quarter = CGFloat.pi / 2
        let angle = atan2(dy, dx)
        let square = (angle / quarter).rounded() * quarter
        guard abs(angle - square) <= nearlyLevel else { return [start, end] }
        let half = CGPoint(x: cos(square) * length / 2, y: sin(square) * length / 2)
        return [CGPoint(x: middle.x - half.x, y: middle.y - half.y),
                CGPoint(x: middle.x + half.x, y: middle.y + half.y)]
    }

    /// How many points an oval is kept as, round its whole.
    static let ovalPoints = 96

    /// The oval that fills `rect`, as points for the pen's line.
    ///
    /// The line through them (`path(through:)`) runs inside each corner, so
    /// with too few points it is a smaller oval than asked for: with these
    /// it is 0.4pt inside at 1,200pt across, and less than the eye finds at
    /// any size. It goes round and three points further: that line leaves
    /// its first point and reaches its last along a straight piece, and
    /// lapped over the start those two lie on the curve, where a seam that
    /// only met would show as a flat spot.
    ///
    /// It starts at the upper left, in a view counted from the top: a
    /// mark's badge sits where its ink begins (`MarkPlacement.badge`), and
    /// that is where a box has its own.
    static func oval(in rect: CGRect) -> [CGPoint] {
        let step = 2 * CGFloat.pi / CGFloat(ovalPoints)
        return (0...(ovalPoints + 3)).map { index in
            let angle = CGFloat(index) * step - 3 * .pi / 4
            return CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
        }
    }

    // MARK: - Resizing a drawing

    /// A handle of a selected drawing. In the layer's coordinates, which
    /// count down from the top: a box, a pen's line and a highlighter have
    /// one on each corner of their ink, an arrow one on each end.
    enum Handle: Equatable, CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft, tail, tip

        var isCorner: Bool { self != .tail && self != .tip }
    }

    /// A handle as it is drawn: a circle this wide, white with an accent
    /// edge, as macOS draws the handles of a selected shape.
    static let handle: CGFloat = 9
    /// The square around a handle that takes the press. Wider than the
    /// handle: a 9pt dot is a hard thing to land on, and 20 is the least
    /// the Human Interface Guidelines give a target on the Mac.
    static let handleReach: CGFloat = 20
    /// The least a drawing is resized to on its longer side.
    static let smallest: CGFloat = 8
    /// A selection narrower or shorter than this has one handle, on its
    /// bottom-right corner: four on a small box cover it, and leave no
    /// inside to take it by.
    static let crowded: CGFloat = 16

    /// The handles a drawing has where its points are.
    static func handles(for pen: MarkPen, points: [CGPoint]) -> [Handle] {
        if pen == .arrow { return [.tail, .tip] }
        let rect = outline(of: points, pen: pen)
        if rect.width < crowded || rect.height < crowded { return [.bottomRight] }
        return [.topLeft, .topRight, .bottomRight, .bottomLeft]
    }

    /// The box around the ink as drawn: the box of its points and half the
    /// line's width, so a highlighter's outline is around its stroke and
    /// not through it.
    static func outline(of points: [CGPoint], pen: MarkPen) -> CGRect {
        box(of: points).insetBy(dx: -pen.width / 2, dy: -pen.width / 2)
    }

    /// Where a handle is drawn.
    static func position(of handle: Handle, pen: MarkPen, points: [CGPoint]) -> CGPoint {
        switch handle {
        case .tail: return points.first ?? .zero
        case .tip: return points.last ?? .zero
        default:
            let rect = outline(of: points, pen: pen), (right, down) = direction(of: handle)
            return CGPoint(x: right > 0 ? rect.maxX : rect.minX, y: down > 0 ? rect.maxY : rect.minY)
        }
    }

    /// The handle a press at `point` takes, the nearest where two reach it.
    static func handle(at point: CGPoint, pen: MarkPen, points: [CGPoint]) -> Handle? {
        guard !points.isEmpty else { return nil }
        let reach = handleReach / 2
        return handles(for: pen, points: points)
            .map { ($0, position(of: $0, pen: pen, points: points)) }
            .filter { abs($0.1.x - point.x) <= reach && abs($0.1.y - point.y) <= reach }
            .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }?
            .0
    }

    /// A drawing's points with `handle` taken to `target`, where the handle
    /// is now to be drawn.
    ///
    /// A corner scales every point about the opposite corner, which stays
    /// where it is, or with `fromCentre` (Option) about the middle; past
    /// it, the drawing is mirrored. `proportional` is Shift: the drawing
    /// keeps its proportions. An arrow's end moves alone, and Shift turns
    /// it in steps of 45 degrees about the other end. A drawing is never
    /// made smaller than `smallest` on its longer side (or than it was, if
    /// it was smaller). The line's width is not scaled: it is the pen's.
    static func resized(_ points: [CGPoint], pen: MarkPen, moving handle: Handle, to target: CGPoint,
                        proportional: Bool, fromCentre: Bool = false) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        if !handle.isCorner {
            let still = handle == .tip ? first : last
            var end = proportional ? snapped(target, from: still) : target
            let length = hypot(end.x - still.x, end.y - still.y)
            let least = min(smallest, hypot(last.x - first.x, last.y - first.y))
            if length < least {
                // Too short: as long as it may be, the way it points, or
                // the way it pointed when it points nowhere.
                let was = handle == .tip ? last : first
                let (dx, dy) = length > 0 ? (end.x - still.x, end.y - still.y) : (was.x - still.x, was.y - still.y)
                let along = hypot(dx, dy)
                if along > 0 { end = CGPoint(x: still.x + dx / along * least, y: still.y + dy / along * least) }
            }
            var moved = points
            moved[handle == .tip ? moved.count - 1 : 0] = end
            return moved
        }

        let box = box(of: points), (right, down) = direction(of: handle)
        let anchor = fromCentre
            ? CGPoint(x: box.midX, y: box.midY)
            : CGPoint(x: right > 0 ? box.minX : box.maxX, y: down > 0 ? box.minY : box.maxY)
        // How far the dragged corner was from the anchor, each way, and
        // where it is to be: the handle is drawn half a line further out.
        let half: CGFloat = fromCentre ? 0.5 : 1
        let was = CGSize(width: right * box.width * half, height: down * box.height * half)
        let pad = pen.width / 2
        let to = CGPoint(x: target.x - right * pad, y: target.y - down * pad)
        // A scale of nothing would flatten the drawing for good: one that
        // is exactly zero, or not a number, leaves that side as it was.
        func ratio(_ now: CGFloat, _ was: CGFloat) -> CGFloat {
            let ratio = now / was
            return ratio.isFinite && ratio != 0 ? ratio : 1
        }
        var scale = CGSize(width: ratio(to.x - anchor.x, was.width), height: ratio(to.y - anchor.y, was.height))
        let both = was.width != 0 && was.height != 0
        func sign(_ value: CGFloat) -> CGFloat { value < 0 ? -1 : 1 }
        if proportional, both {
            let most = max(abs(scale.width), abs(scale.height))
            scale = CGSize(width: sign(scale.width) * most, height: sign(scale.height) * most)
        }
        // The floor, on the longer side; with Shift on both, so the
        // proportions hold at the floor too.
        let long = max(box.width, box.height)
        if long > 0 {
            let least = min(smallest, long) / long
            let wide = box.width >= box.height
            if wide || (proportional && both), abs(scale.width) < least { scale.width = sign(scale.width) * least }
            if !wide || (proportional && both), abs(scale.height) < least { scale.height = sign(scale.height) * least }
        }
        var moved = points.map { point in
            CGPoint(x: anchor.x + (point.x - anchor.x) * scale.width, y: anchor.y + (point.y - anchor.y) * scale.height)
        }
        // A box with no width or no height has nothing to scale that way:
        // its corner goes where the handle is.
        if pen == .box, moved.count == 2 {
            if was.width == 0 {
                moved[1].x = to.x
                if fromCentre { moved[0].x = 2 * anchor.x - to.x }
            }
            if was.height == 0 {
                moved[1].y = to.y
                if fromCentre { moved[0].y = 2 * anchor.y - to.y }
            }
        }
        return moved
    }

    /// Which way a corner is from the middle: right and down are +1.
    private static func direction(of handle: Handle) -> (CGFloat, CGFloat) {
        switch handle {
        case .topLeft: return (-1, -1)
        case .topRight: return (1, -1)
        case .bottomRight: return (1, 1)
        case .bottomLeft, .tail, .tip: return (-1, 1)
        }
    }

    /// The box of some points, with no room.
    private static func box(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var box = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { box = box.union(CGRect(origin: point, size: .zero)) }
        return box
    }
}

extension CGPoint {
    /// The nearest point that is inside `rect` and `inset` from its edges.
    /// In a rect too small for that, its near edge wins.
    func held(in rect: CGRect, inset: CGFloat = 0) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX + inset), max(rect.maxX - inset, rect.minX + inset)),
                y: min(max(y, rect.minY + inset), max(rect.maxY - inset, rect.minY + inset)))
    }
}
