import CoreGraphics

/// The clean shape a hand-drawn mark-up stroke was meant as.
///
/// One closed loop means "this area" however rough it is, so a loop is read generously: nearly any
/// single loop becomes an oval, and a squarish one a box. An open stroke is read strictly, since a wrong
/// line or arrow says something the person did not mean: a tick, a wave or handwriting stays as drawn,
/// and so does a scribble, a second loop or a figure eight.
enum MarkSnap: Equatable {
    /// A straight line from where the stroke began to where it ended.
    case line(CGPoint, CGPoint)
    /// An arrow from its tail (where the stroke began) to its tip.
    case arrow(tail: CGPoint, tip: CGPoint)
    /// An upright rectangle.
    case box(CGRect)
    /// An ellipse: its box before it is turned by `tilt` radians about its centre, clockwise in a view
    /// counted from the top. The tilt is 0 for an upright oval and for a near-circle.
    case oval(CGRect, tilt: CGFloat)

    /// The clean shape a stroke was meant as, or nil when it is not clearly one.
    static func recognise(_ points: [CGPoint]) -> MarkSnap? {
        guard let stroke = Stroke(points) else { return nil }
        let guess: MarkSnap?
        if let loop = stroke.loop() {
            guess = closedShape(loop)
        } else if let line = straightLine(stroke) {
            guess = line
        } else {
            guess = arrow(stroke)
        }
        guard let guess, stroke.lies(on: guess) else { return nil }
        return guess
    }
}

// MARK: - Thresholds

private extension MarkSnap {
    /// A mark smaller than this is a dot or a letter, too small to read a shape from.
    static let smallestSide: CGFloat = 24
    /// Fewer points than this cannot show a shape.
    static let fewestPoints = 8
    /// The stroke is read at this many evenly spaced points, so the speed of the hand does not count.
    static let sampleCount = 64
    /// Ends closer than this share of the length between them make a loop.
    static let loopGap: CGFloat = 0.15
    /// The share of the stroke searched at each end for where a loop closes, so an overshoot is cut off.
    static let loopTail: CGFloat = 0.2
    /// A gap wider than this share of a box's smaller side leaves a side open, as in a U.
    static let loopGapOfSide: CGFloat = 0.5
    /// A straight line strays no further than this share of its length from its chord.
    static let lineBend: CGFloat = 0.05
    /// A straight line is no longer than this many chords; more is a wave or a sawtooth.
    static let lineDetour: CGFloat = 1.08
    /// A flick this many samples long at either end of a line, as the pen lands or lifts, is left off it;
    /// a tick's short leg or an arrow's head is longer.
    static let hookSamples = 4
    /// A line's direction may stray this far from its chord's before the stray counts as a swing.
    static let waveLean: CGFloat = 16 * .pi / 180
    /// A stroke whose direction swings from one side to the other this often is a wave, however shallow:
    /// a hand's straight line drifts one way, or twice at most.
    static let waveSwings = 4
    /// A head that comes back to the tip lands near it, not on it, so the shaft ends where the
    /// stroke first comes within this share of its farthest reach.
    static let tipSlack: CGFloat = 0.06
    /// A head shorter than this share of the shaft is a hook at the end of a line.
    static let headShortest: CGFloat = 0.1
    /// A head longer than this share of the shaft is more than two barbs.
    static let headLongest: CGFloat = 1
    /// A head reaching further than this share of the shaft from the tip is a second stroke, as in a V.
    static let headReach: CGFloat = 0.3
    /// A head may come this share of the shaft past the tip; further, it is not behind it.
    static let headAhead: CGFloat = 0.08
    /// Each barb reaches at least this share of the shaft to its side, or the head is one barb.
    static let barbSpread: CGFloat = 0.025
    /// The shorter barb reaches at least this share of the longer, or the head is one barb.
    static let barbBalance: CGFloat = 0.35
    /// Barbs sweep back from the tip by at least this share of their reach; a bar level with the tip is a T.
    static let barbSweep: CGFloat = 0.25
    /// A head turns back on itself at the end of a barb; a curl at the end of a line bends no
    /// more than about 90 degrees anywhere.
    static let headBend: CGFloat = 110 * .pi / 180
    /// Detail finer than this share of the stroke's size is the wobble of a hand, not a corner.
    static let cornerDetail: CGFloat = 0.04
    /// Two barbs need one to three corners after the tip; a scribble needs more.
    static let headCorners = 1...3
    /// A step this close to level or upright can be part of a box's side.
    static let sideLean: CGFloat = 20 * .pi / 180
    /// A level or upright stretch shorter than this share of the loop is a wobble, not a side.
    static let shortestSide: CGFloat = 0.03
    /// A side further than this from level or upright belongs to a tilted shape, not a box. A hand's
    /// square leans its sides by up to about 15 degrees.
    static let boxSkew: CGFloat = 20 * .pi / 180
    /// Facing sides of a box lean alike; legs that lean apart by more than this make a trapezoid.
    static let boxParallel: CGFloat = 18 * .pi / 180
    /// A loop drawn straight along at least this share of every side, at some tilt, is square: a box
    /// when upright, and never an oval. People's circles stay near a third; their squares stay above a
    /// half nineteen times in twenty.
    static let squareCover: CGFloat = 0.48
    /// A box's points miss its outline by no more than this share of its smaller side, on average.
    static let boxMeanMiss: CGFloat = 0.08
    /// No point of a box misses its outline by more than this share of its smaller side.
    static let boxWorstMiss: CGFloat = 0.25
    /// An oval's points miss its outline by no more than this share of its radius, on average. A hand's
    /// oval is an egg or a lemon, and a loop around something means the same however rough it is.
    static let ovalMeanMiss: CGFloat = 0.1
    /// No point of an oval misses its outline by more than this share of its radius.
    static let ovalWorstMiss: CGFloat = 0.3
    /// A tilt smaller than this is a hand that meant upright.
    static let leastTilt: CGFloat = 5 * .pi / 180
    /// A loop whose narrow spread is more than this share of its wide one is round, and shows no tilt.
    static let roundSpread: CGFloat = 0.9
    /// An oval turns at least this far in all; less is a C or a figure eight.
    static let ovalLeastTurn: CGFloat = 1.7 * .pi
    /// An oval turns at most this far in all; more is a spiral or a second loop.
    static let ovalMostTurn: CGFloat = 2.4 * .pi
    /// The last check: no point of the stroke lies further than this from the clean shape.
    static let outlineMissFloor: CGFloat = 6
    /// The same check grows with the stroke, as this share of its size.
    static let outlineMiss: CGFloat = 0.08
    /// A box's or an oval's points may wander this share of its size: a loop around something means
    /// the area inside it, so a rough loop made clean says nothing new.
    static let loopOutlineMiss: CGFloat = 0.2
}

// MARK: - The stroke

private extension MarkSnap {
    struct Stroke {
        /// The points as drawn.
        let points: [CGPoint]
        /// The same path at evenly spaced points.
        let samples: [CGPoint]
        /// The diagonal of the bounding box.
        let size: CGFloat

        init?(_ points: [CGPoint]) {
            guard points.count >= MarkSnap.fewestPoints,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let bounds = MarkSnap.bounds(of: points)
            guard max(bounds.width, bounds.height) >= MarkSnap.smallestSide else { return nil }
            self.points = points
            self.samples = MarkSnap.resample(points, count: MarkSnap.sampleCount)
            self.size = CGPoint(x: bounds.width, y: bounds.height).length
        }

        /// The closed part of the stroke, cut where its ends come closest, or nil when it is open.
        func loop() -> Loop? {
            let count = samples.count, reach = Int(MarkSnap.loopTail * CGFloat(count))
            var best = (first: 0, last: count - 1, gap: CGFloat.infinity)
            for first in 0..<reach {
                for last in (count - reach)..<count where samples[first].distance(to: samples[last]) < best.gap {
                    best = (first, last, samples[first].distance(to: samples[last]))
                }
            }
            let points = Array(samples[best.first...best.last])
            guard best.gap <= MarkSnap.loopGap * MarkSnap.length(of: points) else { return nil }
            return Loop(points: points, gap: best.gap)
        }

        /// Whether every point as drawn lies near the clean shape, so a snap never hides part of a mark.
        func lies(on shape: MarkSnap) -> Bool {
            let share: CGFloat
            switch shape {
            case .box, .oval: share = MarkSnap.loopOutlineMiss
            case .line, .arrow: share = MarkSnap.outlineMiss
            }
            let tolerance = max(MarkSnap.outlineMissFloor, share * size)
            return points.allSatisfy { MarkSnap.miss($0, shape) <= tolerance }
        }
    }

    struct Loop {
        let points: [CGPoint]
        /// How far apart the ends are left.
        let gap: CGFloat
    }

    /// A stretch of a loop drawn level or upright: where it starts, and how many steps it runs.
    struct Side {
        let isLevel: Bool
        let start: Int
        let steps: Int
        /// How far it runs level or upright, leaving out the wobbles inside it.
        let length: CGFloat
    }
}

// MARK: - Open shapes

private extension MarkSnap {
    /// The stroke as a line, from where it began to where it ended, or without a hook at either end.
    static func straightLine(_ stroke: Stroke) -> MarkSnap? {
        let samples = stroke.samples
        if isStraight(samples), let first = stroke.points.first, let last = stroke.points.last {
            return .line(first, last)
        }
        for (front, back) in [(0, hookSamples), (hookSamples, 0), (hookSamples, hookSamples)] {
            let middle = Array(samples[front..<(samples.count - back)])
            if isStraight(middle), runsStraightToItsEnds(middle), let first = middle.first, let last = middle.last {
                return .line(first, last)
            }
        }
        return nil
    }

    /// Whether a line with a hook left off still runs along its chord right to where the hook was cut;
    /// what is left of a barb turns away there.
    static func runsStraightToItsEnds(_ path: [CGPoint]) -> Bool {
        guard path.count > 2 * hookSamples, let start = path.first, let end = path.last else { return false }
        let chord = end.minus(start), reach = hookSamples - 1
        let ends = [path[reach].minus(start), end.minus(path[path.count - 1 - reach])]
        return ends.allSatisfy { abs(atan2(chord.cross($0), chord.dot($0))) <= waveLean }
    }

    static func isStraight(_ path: [CGPoint]) -> Bool {
        guard let start = path.first, let end = path.last else { return false }
        let chord = start.distance(to: end)
        guard chord > 0, length(of: path) <= lineDetour * chord, swings(path) < waveSwings else { return false }
        return path.allSatisfy { $0.distance(toSegment: start, end) <= lineBend * chord }
    }

    /// How often a path's direction swings past its chord's, from one side to the other.
    static func swings(_ path: [CGPoint]) -> Int {
        guard let start = path.first, let end = path.last else { return 0 }
        let chord = end.minus(start)
        var side = 0, count = 0
        for (point, next) in zip(path, path.dropFirst()) {
            let step = next.minus(point), lean = atan2(chord.cross(step), chord.dot(step))
            let now = lean > waveLean ? 1 : lean < -waveLean ? -1 : side
            if now != side, side != 0 { count += 1 }
            side = now
        }
        return count
    }

    static func arrow(_ stroke: Stroke) -> MarkSnap? {
        let samples = stroke.samples
        guard let start = samples.first, let tail = stroke.points.first,
              let tip = farthest(from: tail, in: stroke.points).map({ stroke.points[$0] }),
              let farthest = farthest(from: start, in: samples) else { return nil }
        let reach = start.distance(to: samples[farthest]) * (1 - tipSlack)
        guard let tipIndex = samples.firstIndex(where: { $0.distance(to: start) >= reach }) else { return nil }
        let head = Array(samples[tipIndex...])
        let shaftLength = start.distance(to: samples[tipIndex]), headLength = length(of: head)
        guard head.count >= 3, isStraight(Array(samples[...tipIndex])),
              headLength >= headShortest * shaftLength, headLength <= headLongest * shaftLength,
              isHead(head, shaftFrom: start, size: stroke.size) else { return nil }
        return .arrow(tail: tail, tip: tip)
    }

    /// Whether what follows the tip is two straight barbs behind it, one to each side.
    static func isHead(_ head: [CGPoint], shaftFrom start: CGPoint, size: CGFloat) -> Bool {
        let tip = head[0], shaftLength = start.distance(to: tip)
        let direction = tip.minus(start).scaled(1 / shaftLength)
        var left: CGFloat = 0, right: CGFloat = 0, back: CGFloat = 0, reach: CGFloat = 0
        for point in head {
            let offset = point.minus(tip)
            guard offset.length <= headReach * shaftLength,
                  offset.dot(direction) <= headAhead * shaftLength else { return false }
            left = max(left, direction.cross(offset))
            right = max(right, -direction.cross(offset))
            back = max(back, -offset.dot(direction))
            reach = max(reach, offset.length)
        }
        let shorter = min(left, right)
        guard shorter >= barbSpread * shaftLength, shorter >= barbBalance * max(left, right),
              back >= barbSweep * reach, sharpestBend(head) >= headBend else { return false }
        return headCorners.contains(keptIndices(head, tolerance: cornerDetail * size).count - 2)
    }

    /// The sharpest turn along a path, over one step and over two, so a cusp shows wherever the
    /// evenly spaced points happen to fall.
    static func sharpestBend(_ path: [CGPoint]) -> CGFloat {
        var sharpest: CGFloat = 0
        for span in 1...2 where path.count > 2 * span {
            for index in span..<(path.count - span) {
                let before = path[index].minus(path[index - span]), after = path[index + span].minus(path[index])
                sharpest = max(sharpest, abs(atan2(before.cross(after), before.dot(after))))
            }
        }
        return sharpest
    }
}

// MARK: - Closed shapes

private extension MarkSnap {
    /// A box or an oval, when the loop is clearly one and not the other, and closed enough to read as one.
    static func closedShape(_ loop: Loop) -> MarkSnap? {
        let box = boxFit(loop), oval = ovalFit(loop)
        switch (box, oval) {
        case let (box?, nil):
            // Only a box needs this: a U is no ellipse, and a wide oval's gap is wide along with it.
            return loop.gap <= loopGapOfSide * min(box.width, box.height) ? .box(box) : nil
        case let (nil, oval?):
            return .oval(oval.rect, tilt: oval.tilt)
        default:
            return nil
        }
    }

    static func boxFit(_ loop: Loop) -> CGRect? {
        let sides = straightSides(loop.points)
        guard let rect = boxRect(sides, of: loop.points), cover(of: sides, on: rect) >= squareCover else { return nil }
        let misses = loop.points.map { rectMiss($0, rect) / min(rect.width, rect.height) }
        guard mean(misses) <= boxMeanMiss, (misses.max() ?? 0) <= boxWorstMiss else { return nil }
        return rect
    }

    /// The upright rectangle through four sides drawn level, upright, level, upright.
    static func boxRect(_ sides: [Side], of loop: [CGPoint]) -> CGRect? {
        let found = sides.compactMap { side in
            edge(points(of: side, in: loop)).flatMap { $0.isLevel == side.isLevel ? $0 : nil }
        }
        // The sides take turns, so the first and third face each other, as do the second and fourth.
        guard sides.count == 4, found.count == 4, abs(found[0].lean - found[2].lean) <= boxParallel,
              abs(found[1].lean - found[3].lean) <= boxParallel else { return nil }
        let edges = found.map(\.at)
        let (levels, uprights) = sides[0].isLevel ? ((edges[0], edges[2]), (edges[1], edges[3]))
                                                  : ((edges[1], edges[3]), (edges[0], edges[2]))
        let rect = CGRect(x: min(uprights.0, uprights.1), y: min(levels.0, levels.1),
                          width: abs(uprights.0 - uprights.1), height: abs(levels.0 - levels.1))
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Whether a run of points is level or upright, where it sits across that direction, and how far it leans.
    static func edge(_ points: [CGPoint]) -> (isLevel: Bool, at: CGFloat, lean: CGFloat)? {
        let centre = points.reduce(CGPoint.zero) { $0.plus($1) }.scaled(1 / CGFloat(max(points.count, 1)))
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for point in points {
            let offset = point.minus(centre)
            xx += offset.x * offset.x
            yy += offset.y * offset.y
            xy += offset.x * offset.y
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        if abs(angle) <= boxSkew { return (true, median(points.map(\.y)), angle) }
        if abs(angle) >= .pi / 2 - boxSkew {
            return (false, median(points.map(\.x)), angle - (angle > 0 ? 1 : -1) * .pi / 2)
        }
        return nil
    }

    /// The level and upright stretches of a loop, in drawing order, with wobbles left out.
    static func straightSides(_ loop: [CGPoint]) -> [Side] {
        var sides: [Side] = []
        var total: CGFloat = 0
        let lean = tan(sideLean)
        for index in loop.indices.dropLast() {
            let step = loop[index + 1].minus(loop[index]), length = step.length
            total += length
            let isLevel = abs(step.y) <= lean * abs(step.x)
            guard length > 0, isLevel || abs(step.x) <= lean * abs(step.y) else { continue }
            sides.append(Side(isLevel: isLevel, start: index, steps: 1, length: length))
        }
        let shortest = shortestSide * total
        return joined(joined(sides, round: loop.count).filter { $0.length >= shortest }, round: loop.count)
    }

    /// Neighbouring stretches that run the same way, joined into one, round a loop of so many points.
    static func joined(_ sides: [Side], round count: Int) -> [Side] {
        var result: [Side] = []
        for side in sides {
            if let last = result.last, last.isLevel == side.isLevel {
                result[result.count - 1] = join(last, side, round: count)
            } else {
                result.append(side)
            }
        }
        if result.count > 1, let first = result.first, let last = result.last, first.isLevel == last.isLevel {
            result[0] = join(last, first, round: count)
            result.removeLast()
        }
        return result
    }

    static func join(_ side: Side, _ next: Side, round count: Int) -> Side {
        let steps = (next.start + next.steps - side.start + count) % count
        return Side(isLevel: side.isLevel, start: side.start, steps: steps, length: side.length + next.length)
    }

    static func points(of side: Side, in loop: [CGPoint]) -> [CGPoint] {
        (0...side.steps).map { loop[(side.start + $0) % loop.count] }
    }

    /// How much of each side of a rectangle is drawn straight, for the side drawn least.
    static func cover(of sides: [Side], on rect: CGRect) -> CGFloat {
        guard sides.count == 4, rect.width > 0, rect.height > 0 else { return 0 }
        return sides.map { $0.length / ($0.isLevel ? rect.width : rect.height) }.min() ?? 0
    }

    /// The side cover of a loop turned upright by the tilt its steps agree on. A box's steps run four
    /// ways a right angle apart, which four times their angle makes one, so their average finds the tilt.
    static func squarestCover(_ loop: [CGPoint]) -> CGFloat {
        var sum = CGPoint.zero
        for (start, end) in zip(loop, loop.dropFirst()) {
            let step = end.minus(start), angle = 4 * atan2(step.y, step.x)
            sum = sum.plus(CGPoint(x: cos(angle), y: sin(angle)).scaled(step.length))
        }
        let tilt = -atan2(sum.y, sum.x) / 4, cosine = cos(tilt), sine = sin(tilt)
        let turned = loop.map { CGPoint(x: $0.x * cosine - $0.y * sine, y: $0.x * sine + $0.y * cosine) }
        return cover(of: straightSides(turned), on: bounds(of: turned))
    }

    static func ovalFit(_ loop: Loop) -> (rect: CGRect, tilt: CGFloat)? {
        let turn = abs(turning(loop.points))
        guard turn >= ovalLeastTurn, turn <= ovalMostTurn,
              let ellipse = ellipse(around: loop.points) else { return nil }
        let misses = loop.points.map { abs(radius(of: $0, on: ellipse.rect, tilt: ellipse.tilt) - 1) }
        guard mean(misses) <= ovalMeanMiss, (misses.max() ?? 0) <= ovalWorstMiss,
              squarestCover(loop.points) < squareCover else { return nil }
        return ellipse
    }

    /// The ellipse a loop draws: turned along its long axis, and as large as what it encloses, since
    /// the overshoot is already cut off and a loop around something means what is inside it.
    static func ellipse(around loop: [CGPoint]) -> (rect: CGRect, tilt: CGFloat)? {
        let centre = loop.reduce(CGPoint.zero) { $0.plus($1) }.scaled(1 / CGFloat(max(loop.count, 1)))
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for point in loop {
            let offset = point.minus(centre)
            xx += offset.x * offset.x
            yy += offset.y * offset.y
            xy += offset.x * offset.y
        }
        let half = (xx + yy) / 2, apart = (((xx - yy) / 2) * ((xx - yy) / 2) + xy * xy).squareRoot()
        guard half + apart > 0 else { return nil }
        // The long axis, folded to within 45 degrees of level, so a tall oval stays tall rather than lying turned.
        var tilt = 0.5 * atan2(2 * xy, xx - yy)
        if tilt > .pi / 4 { tilt -= .pi / 2 } else if tilt <= -.pi / 4 { tilt += .pi / 2 }
        if abs(tilt) < leastTilt || ((half - apart) / (half + apart)).squareRoot() > roundSpread { tilt = 0 }
        let frame = bounds(of: loop.map { $0.turned(by: -tilt, about: centre) })
        guard frame.width > 0, frame.height > 0 else { return nil }
        let middle = CGPoint(x: frame.midX, y: frame.midY).turned(by: tilt, about: centre)
        let rect = CGRect(x: middle.x - frame.width / 2, y: middle.y - frame.height / 2,
                          width: frame.width, height: frame.height)
        return (rect, tilt)
    }

    /// How far a loop turns in all, leaving out the step across its gap, which a hand did not draw.
    static func turning(_ loop: [CGPoint]) -> CGFloat {
        let steps = zip(loop, loop.dropFirst()).map { $1.minus($0) }.filter { $0.length > 0 }
        guard let first = steps.first, let last = steps.last else { return 0 }
        let pairs = zip(steps, steps.dropFirst()).map { ($0, $1) } + [(last, first)]
        return pairs.reduce(0) { $0 + atan2($1.0.cross($1.1), $1.0.dot($1.1)) }
    }
}

// MARK: - Measuring

private extension MarkSnap {
    /// How far a point is from the outline of a clean shape.
    static func miss(_ point: CGPoint, _ shape: MarkSnap) -> CGFloat {
        switch shape {
        case let .line(start, end):
            return point.distance(toSegment: start, end)
        case let .arrow(tail, tip):
            // The head is drawn by the caller, so anything near the tip is on it.
            return point.distance(to: tip) <= headReach * tail.distance(to: tip)
                ? 0 : point.distance(toSegment: tail, tip)
        case let .box(rect):
            return rectMiss(point, rect)
        case let .oval(rect, tilt):
            let ratio = radius(of: point, on: rect, tilt: tilt)
            guard ratio > 0 else { return min(rect.width, rect.height) / 2 }
            return point.distance(to: CGPoint(x: rect.midX, y: rect.midY)) * abs(1 - 1 / ratio)
        }
    }

    static func rectMiss(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let outsideX = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let outsideY = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if outsideX > 0 || outsideY > 0 { return CGPoint(x: outsideX, y: outsideY).length }
        return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }

    /// Where a point sits on an ellipse's own scale: 1 on the outline, 0 at the centre.
    static func radius(of point: CGPoint, on ellipse: CGRect, tilt: CGFloat) -> CGFloat {
        let centre = CGPoint(x: ellipse.midX, y: ellipse.midY), upright = point.turned(by: -tilt, about: centre)
        let u = (upright.x - centre.x) / (ellipse.width / 2), v = (upright.y - centre.y) / (ellipse.height / 2)
        return (u * u + v * v).squareRoot()
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        var low = CGPoint(x: CGFloat.infinity, y: .infinity), high = CGPoint(x: -CGFloat.infinity, y: -.infinity)
        for point in points {
            low = CGPoint(x: min(low.x, point.x), y: min(low.y, point.y))
            high = CGPoint(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        return points.isEmpty ? .zero : CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }

    static func length(of path: [CGPoint]) -> CGFloat {
        zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func farthest(from origin: CGPoint, in points: [CGPoint]) -> Int? {
        points.indices.max { points[$0].distance(to: origin) < points[$1].distance(to: origin) }
    }

    static func mean(_ values: [CGFloat]) -> CGFloat {
        values.reduce(0, +) / CGFloat(max(values.count, 1))
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// The path at evenly spaced points, from its first point to its last.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let step = length(of: points) / CGFloat(count - 1)
        guard step > 0, let first = points.first, let last = points.last else { return points }
        var result = [first], previous = first, travelled: CGFloat = 0, index = 1
        while index < points.count, result.count < count - 1 {
            let next = points[index], gap = previous.distance(to: next)
            if gap > 0, travelled + gap >= step {
                previous = previous.plus(next.minus(previous).scaled((step - travelled) / gap))
                result.append(previous)
                travelled = 0
            } else {
                travelled += gap
                previous = next
                index += 1
            }
        }
        return result + Array(repeating: last, count: count - result.count)
    }

    /// Ramer-Douglas-Peucker: the indices of the points that keep a path's shape within a tolerance.
    static func keptIndices(_ path: [CGPoint], tolerance: CGFloat) -> [Int] {
        var kept = Set([0, path.count - 1]), spans = [(0, path.count - 1)]
        while let (first, last) = spans.popLast() {
            guard last - first > 1 else { continue }
            let distances = ((first + 1)..<last).map { path[$0].distance(toSegment: path[first], path[last]) }
            guard let worst = distances.indices.max(by: { distances[$0] < distances[$1] }),
                  distances[worst] > tolerance else { continue }
            kept.insert(first + 1 + worst)
            spans += [(first, first + 1 + worst), (first + 1 + worst, last)]
        }
        return kept.sorted()
    }
}

private extension CGPoint {
    var length: CGFloat { (x * x + y * y).squareRoot() }
    func plus(_ other: CGPoint) -> CGPoint { CGPoint(x: x + other.x, y: y + other.y) }
    func minus(_ other: CGPoint) -> CGPoint { CGPoint(x: x - other.x, y: y - other.y) }
    func scaled(_ factor: CGFloat) -> CGPoint { CGPoint(x: x * factor, y: y * factor) }
    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    func cross(_ other: CGPoint) -> CGFloat { x * other.y - y * other.x }
    func distance(to other: CGPoint) -> CGFloat { minus(other).length }

    /// The point turned by an angle about a centre, clockwise in a view counted from the top.
    func turned(by angle: CGFloat, about centre: CGPoint) -> CGPoint {
        let offset = minus(centre), cosine = cos(angle), sine = sin(angle)
        return CGPoint(x: centre.x + offset.x * cosine - offset.y * sine,
                       y: centre.y + offset.x * sine + offset.y * cosine)
    }

    func distance(toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let along = end.minus(start), squared = along.dot(along)
        guard squared > 0 else { return distance(to: start) }
        return distance(to: start.plus(along.scaled(min(max(minus(start).dot(along) / squared, 0), 1))))
    }
}
