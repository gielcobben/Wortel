import CoreGraphics
import XCTest
#if canImport(MarkSnap)
@testable import MarkSnap
#endif

final class MarkSnapTests: XCTestCase {
    // MARK: - Shapes that snap

    func testARoughBoxIsABox() {
        assertRecognised(.box, Draw.box)
    }

    func testARoughLoopIsAnOval() {
        assertRecognised(.oval, Draw.oval)
    }

    func testANearlyStraightStrokeIsALine() {
        assertRecognised(.line, Draw.line)
    }

    func testARoughArrowIsAnArrow() {
        assertRecognised(.arrow, Draw.arrow)
    }

    func testATiltedLongLoopIsAnOval() {
        assertRecognised(.oval, Draw.tiltedLongOval)
    }

    func testATiltedOvalKeepsItsTilt() {
        for seed in 0..<Self.seeds {
            var hand = Hand(seed: UInt64(seed), noise: .low)
            let tilt = hand.sign() * hand.degrees(10...40)
            let width = hand.size(120...800), height = width / hand.value(2...4)
            let outline = Ideal.ellipse(width: width, height: height)
            let path = Ideal.trace(outline, from: hand.value(0...1), span: 1.05, backwards: hand.coin())
            let stroke = hand.draw(Ideal.place(path, turnedBy: tilt, at: CGPoint(x: 600, y: 500)),
                                   scale: (width * height).squareRoot())
            guard case let .oval(rect, fitted)? = MarkSnap.recognise(stroke) else {
                XCTFail("seed \(seed) is not an oval")
                continue
            }
            XCTAssertEqual(fitted, tilt, accuracy: 4 * .pi / 180, "seed \(seed)")
            XCTAssertEqual(rect.width, width, accuracy: 0.08 * width, "seed \(seed)")
            XCTAssertEqual(rect.height, height, accuracy: 0.15 * height, "seed \(seed)")
        }
    }

    func testAnUprightOvalOrANearCircleHasNoTilt() {
        for seed in 0..<Self.seeds {
            var hand = Hand(seed: UInt64(seed), noise: .low)
            let width = hand.size(60...800), round = hand.coin()
            let height = round ? width * hand.value(0.95...1) : width / hand.value(1.5...4)
            let tilt = round ? hand.degrees(0...90) : hand.sign() * hand.degrees(0...3)
            let outline = Ideal.ellipse(width: width, height: height)
            let path = Ideal.trace(outline, from: hand.value(0...1), span: 1.05, backwards: hand.coin())
            let stroke = hand.draw(Ideal.place(path, turnedBy: tilt, at: CGPoint(x: 600, y: 500)),
                                   scale: (width * height).squareRoot())
            guard case let .oval(_, fitted)? = MarkSnap.recognise(stroke) else { continue }
            XCTAssertEqual(fitted, 0, "seed \(seed)")
        }
    }

    // MARK: - Marks that are left alone

    func testATickIsLeftAlone() { assertLeftAlone(Draw.tick) }
    func testAZigzagIsLeftAlone() { assertLeftAlone(Draw.zigzag) }
    func testASawtoothUnderlineIsLeftAlone() { assertLeftAlone(Draw.sawtooth) }
    func testAnLElbowIsLeftAlone() { assertLeftAlone(Draw.elbow) }
    func testAVIsLeftAlone() { assertLeftAlone(Draw.vee) }
    func testACWithAThirdMissingIsLeftAlone() { assertLeftAlone(Draw.openC) }
    func testASpiralIsLeftAlone() { assertLeftAlone(Draw.spiral) }
    func testADoubleLoopIsLeftAlone() { assertLeftAlone(Draw.doubleLoop) }
    func testAFigureEightIsLeftAlone() { assertLeftAlone(Draw.figureEight) }
    func testHandwritingIsLeftAlone() { assertLeftAlone(Draw.scribble) }
    func testAQuestionMarkIsLeftAlone() { assertLeftAlone(Draw.questionMark) }
    func testATriangleIsLeftAlone() { assertLeftAlone(Draw.triangle) }
    func testARectangleTiltedByAQuarterIsLeftAlone() { assertLeftAlone(Draw.tiltedRectangle) }
    func testAStronglyBowedLineIsLeftAlone() { assertLeftAlone(Draw.bowedLine) }
    func testATinyCircleIsLeftAlone() { assertLeftAlone(Draw.tinyCircle) }
    func testAnArrowWithOneBarbIsLeftAlone() { assertLeftAlone(Draw.oneBarbArrow) }
    func testScribblingSomethingOutIsLeftAlone() { assertLeftAlone(Draw.backAndForth) }
    func testALineEndingInACurlIsLeftAlone() { assertLeftAlone(Draw.curl) }
    func testATrapezoidIsLeftAlone() { assertLeftAlone(Draw.trapezoid) }
    func testALineEndingInACrossbarIsLeftAlone() { assertLeftAlone(Draw.crossbar) }
    func testABoxWithOneSideOpenIsLeftAlone() { assertLeftAlone(Draw.openBox) }

    func testStrokesWithNothingToReadAreLeftAlone() {
        let still = Array(repeating: CGPoint(x: 40, y: 40), count: 50)
        var broken = (0..<40).map { CGPoint(x: CGFloat($0) * 5, y: 10) }
        broken[7] = CGPoint(x: CGFloat.nan, y: 3)
        var endless = broken
        endless[7] = CGPoint(x: CGFloat.infinity, y: 3)
        XCTAssertNil(MarkSnap.recognise([]))
        XCTAssertNil(MarkSnap.recognise([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]))
        XCTAssertNil(MarkSnap.recognise(still))
        XCTAssertNil(MarkSnap.recognise(broken))
        XCTAssertNil(MarkSnap.recognise(endless))
    }

    // MARK: - What does not change the answer

    func testScalingAStrokeKeepsItsShape() {
        var changed: [String] = []
        // The tiny circle is left alone for its size alone, so it is the one drawing that may change.
        for (name, draw) in Draw.all where name != "tiny circle" {
            for seed in 0..<100 {
                var hand = Hand(seed: UInt64(seed), noise: .middle)
                let stroke = draw(&hand)
                let kind = Kind(MarkSnap.recognise(stroke))
                for factor: CGFloat in [0.3, 5] {
                    let scaled = stroke.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
                    guard size(of: scaled) >= 40 else { continue }
                    let after = Kind(MarkSnap.recognise(scaled))
                    if after != kind { changed.append("\(name) #\(seed) ×\(factor): \(kind) → \(after)") }
                }
            }
        }
        XCTAssertEqual(changed, [])
    }

    func testDoubleThePointsKeepsTheShape() {
        var changed: [String] = []
        for (name, draw) in Draw.all {
            for seed in 0..<Self.seeds {
                var hand = Hand(seed: UInt64(seed), noise: .middle)
                let stroke = draw(&hand)
                let before = Kind(MarkSnap.recognise(stroke)), after = Kind(MarkSnap.recognise(doubled(stroke)))
                if after != before { changed.append("\(name) #\(seed): \(before) → \(after)") }
            }
        }
        XCTAssertEqual(changed, [])
    }

    /// The pen thins to about 2pt, so a mark worth reading arrives with 20 points or more. Below that,
    /// halving takes away corners and teeth that were really drawn, so only strokes that keep 20 count.
    func testHalfThePointsKeepsTheShapeAtThePensDensity() {
        var changed: [String] = [], wrong: [String] = [], counted = 0
        for (name, draw) in Draw.all {
            let truth = Draw.truth(of: name)
            for seed in 0..<Self.seeds {
                var hand = Hand(seed: UInt64(seed), noise: .middle)
                let stroke = draw(&hand), thinned = halved(stroke)
                guard thinned.count >= 20 else { continue }
                counted += 1
                let before = Kind(MarkSnap.recognise(stroke)), after = Kind(MarkSnap.recognise(thinned))
                if after != before { changed.append("\(name) #\(seed): \(before) → \(after)") }
                if after != .none, after != truth { wrong.append("\(name) #\(seed): \(after)") }
            }
        }
        print("Half the points: \(changed.count) of \(counted) strokes changed: \(changed)")
        XCTAssertEqual(wrong, [])
        XCTAssertLessThanOrEqual(changed.count, counted / 200)
    }

    func testAClosedShapeDrawnTheOtherWayIsTheSameShape() {
        for draw in [Draw.box, Draw.oval] {
            for seed in 0..<200 {
                var hand = Hand(seed: UInt64(seed), noise: .middle)
                let stroke = draw(&hand)
                let forwards = MarkSnap.recognise(stroke)
                let backwards = MarkSnap.recognise(stroke.reversed())
                XCTAssertEqual(Kind(forwards), Kind(backwards), "seed \(seed)")
                if let one = rect(of: forwards), let other = rect(of: backwards) {
                    XCTAssertLessThan(difference(one, other), 0.05 * size(of: stroke), "seed \(seed)")
                }
            }
        }
    }

    // MARK: - The geometry given back

    func testALineRunsFromTheFirstPointToTheLast() {
        var hand = Hand(seed: 7, noise: .low)
        let stroke = Draw.line(&hand)
        XCTAssertEqual(MarkSnap.recognise(stroke), .line(stroke[0], stroke[stroke.count - 1]))
    }

    func testAnArrowRunsFromTheFirstPointToTheFarthest() {
        for seed in 0..<50 {
            var hand = Hand(seed: UInt64(seed), noise: .low)
            let stroke = Draw.arrow(&hand)
            guard case let .arrow(tail, tip)? = MarkSnap.recognise(stroke) else { continue }
            let farthest = stroke.max { hypot($0.x - tail.x, $0.y - tail.y) < hypot($1.x - tail.x, $1.y - tail.y) }
            XCTAssertEqual(tail, stroke[0])
            XCTAssertEqual(tip, farthest)
        }
    }

    func testAnOvershootDoesNotGrowTheBox() {
        let truth = CGRect(x: 300, y: 200, width: 240, height: 140)
        for seed in 0..<50 {
            var hand = Hand(seed: UInt64(seed), noise: .low)
            let outline = Ideal.roundedRectangle(width: truth.width, height: truth.height, radius: 10)
            let path = Ideal.trace(outline, from: hand.value(0...1), span: 1.15, backwards: hand.coin())
            let stroke = hand.draw(Ideal.place(path, turnedBy: 0, at: CGPoint(x: truth.midX, y: truth.midY)),
                                   scale: 180)
            guard case let .box(rect)? = MarkSnap.recognise(stroke) else { return XCTFail("seed \(seed)") }
            XCTAssertLessThan(difference(rect, truth), 0.03 * truth.width, "seed \(seed): \(rect)")
        }
    }

    func testAnOvershootDoesNotGrowTheOval() {
        let truth = CGRect(x: 300, y: 200, width: 260, height: 120)
        for seed in 0..<50 {
            var hand = Hand(seed: UInt64(seed), noise: .low)
            let outline = Ideal.ellipse(width: truth.width, height: truth.height)
            let path = Ideal.trace(outline, from: hand.value(0...1), span: 1.15, backwards: hand.coin())
            let stroke = hand.draw(Ideal.place(path, turnedBy: 0, at: CGPoint(x: truth.midX, y: truth.midY)),
                                   scale: 180)
            guard case let .oval(rect, _)? = MarkSnap.recognise(stroke) else { return XCTFail("seed \(seed)") }
            XCTAssertLessThan(difference(rect, truth), 0.03 * truth.width, "seed \(seed): \(rect)")
        }
    }

    // MARK: - Cost

    /// Every kind of drawing at 300 points, the most a pen gives; ovals and boxes cost the most, since
    /// a loop is tried as both, and an oval is also searched for a hidden tilted box.
    func testThreeHundredPointsTakeWellUnderAMillisecond() {
        let clock = ContinuousClock()
        var slowest: (name: String, each: Duration) = ("", .zero)
        for (name, draw) in Draw.all {
            let strokes = (0..<10).map { seed in
                var hand = Hand(seed: UInt64(seed), noise: .middle)
                return Self.stretched(draw(&hand), to: 300)
            }
            let elapsed = clock.measure {
                for run in 0..<100 { _ = MarkSnap.recognise(strokes[run % strokes.count]) }
            }
            if elapsed / 100 > slowest.each { slowest = (name, elapsed / 100) }
        }
        print("Slowest drawing at 300 points: \(slowest.name), \(slowest.each) each")
        XCTAssertLessThan(slowest.each, .milliseconds(1))
    }

    // MARK: - The whole picture

    func testNothingLeftAloneIsSnappedAtAnyNoise() {
        for noise in Noise.allCases {
            var table = "\nNoise \(noise) (wobble \(noise.rawValue) of size)\n"
            table += "drawn".padding(toLength: 18, withPad: " ", startingAt: 0)
            table += Kind.allCases.map { Self.leftPadded($0.rawValue, 7) }.joined() + "\n"
            for (name, draw) in Draw.all + Draw.edges {
                let counts = tally(draw, noise: noise)
                table += name.padding(toLength: 18, withPad: " ", startingAt: 0)
                table += Kind.allCases.map { Self.leftPadded(String(counts[$0, default: 0]), 7) }.joined() + "\n"
                if Draw.leftAlone.contains(where: { $0.0 == name }) {
                    XCTAssertEqual(counts[.none, default: 0], Self.seeds, "\(name) at \(noise)")
                }
            }
            print(table)
        }
    }

    // MARK: - Real strokes

    /// Real people drawing, from Google's Quick, Draw! dataset (CC BY 4.0): single strokes by mouse,
    /// trackpad and touch, thinned to 2 units as the app does. Each must become what it was meant as,
    /// which for a scribble, a wave or a C is nothing.
    func testRealStrokesBecomeWhatTheyWereMeantAs() {
        var wrong: [String] = []
        let entries = Self.realStrokes.split(separator: "\n")
        for (number, entry) in entries.enumerated() {
            let fields = entry.split(separator: " ")
            guard fields.count == 3, let expected = Kind(rawValue: String(fields[1])) else {
                XCTFail("entry \(number) does not read")
                continue
            }
            let found = Kind(MarkSnap.recognise(Self.decoded(fields[2])))
            if found != expected { wrong.append("#\(number) \(fields[0]): \(found), meant \(expected)") }
        }
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(wrong, [])
    }

    /// A stroke written as where it starts, then one step for each pair of letters: each letter moves
    /// -32 to 31 units, first along x then along y, counted along the base 64 alphabet.
    private static func decoded(_ text: Substring) -> [CGPoint] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let parts = text.split(separator: ":")
        let start = parts.first?.split(separator: ",").compactMap { Double($0) } ?? []
        guard start.count == 2 else { return [] }
        var point = CGPoint(x: start[0], y: start[1]), points = [point]
        let steps = parts.count > 1 ? Array(parts[1]) : []
        for index in stride(from: 0, to: steps.count - 1, by: 2) {
            guard let across = alphabet.firstIndex(of: steps[index]),
                  let down = alphabet.firstIndex(of: steps[index + 1]) else { continue }
            point = CGPoint(x: point.x + CGFloat(across - 32), y: point.y + CGFloat(down - 32))
            points.append(point)
        }
        return points
    }

    // MARK: - Helpers

    private static let seeds = 80

    private func tally(_ draw: Drawing, noise: Noise) -> [Kind: Int] {
        var counts: [Kind: Int] = [:]
        for seed in 0..<Self.seeds {
            var hand = Hand(seed: UInt64(seed), noise: noise)
            counts[Kind(MarkSnap.recognise(draw(&hand))), default: 0] += 1
        }
        return counts
    }

    /// The true shape in at least nine strokes in ten at middling wobble, and never another shape at any.
    private func assertRecognised(_ kind: Kind, _ draw: Drawing, file: StaticString = #filePath, line: UInt = #line) {
        for noise in Noise.allCases {
            let counts = tally(draw, noise: noise)
            if noise == .middle {
                XCTAssertGreaterThanOrEqual(counts[kind, default: 0], Self.seeds * 9 / 10, "\(counts)",
                                            file: file, line: line)
            }
            let wrong = counts.filter { $0.key != kind && $0.key != .none }
            XCTAssertEqual(wrong, [:], "at \(noise)", file: file, line: line)
        }
    }

    private func assertLeftAlone(_ draw: Drawing, file: StaticString = #filePath, line: UInt = #line) {
        for noise in Noise.allCases {
            let counts = tally(draw, noise: noise)
            XCTAssertEqual(counts[.none, default: 0], Self.seeds, "\(counts) at \(noise)", file: file, line: line)
        }
    }

    private func size(of points: [CGPoint]) -> CGFloat {
        let xs = points.map(\.x), ys = points.map(\.y)
        return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The same path at exactly so many points, spaced evenly along it.
    private static func stretched(_ points: [CGPoint], to count: Int) -> [CGPoint] {
        let path = Polyline(points)
        return (0..<count).map { path.point(at: path.length * CGFloat($0) / CGFloat(count - 1)) }
    }

    private func halved(_ points: [CGPoint]) -> [CGPoint] {
        var result = stride(from: 0, to: points.count, by: 2).map { points[$0] }
        if points.count % 2 == 0, let last = points.last { result.append(last) }
        return result
    }

    private func doubled(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for (point, next) in zip(points, points.dropFirst()) {
            result.append(point)
            result.append(CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2))
        }
        if let last = points.last { result.append(last) }
        return result
    }

    private func rect(of snap: MarkSnap?) -> CGRect? {
        switch snap {
        case let .box(rect)?, let .oval(rect, _)?: return rect
        default: return nil
        }
    }

    private func difference(_ one: CGRect, _ other: CGRect) -> CGFloat {
        max(abs(one.minX - other.minX), abs(one.minY - other.minY),
            abs(one.maxX - other.maxX), abs(one.maxY - other.maxY))
    }
}

// MARK: - A seeded hand

/// Everything that draws, nested here so its names cannot meet a host project's own.
extension MarkSnapTests {

    /// SplitMix64: a small seeded source, so every stroke is the same on every run.
    fileprivate struct SplitMix64: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    fileprivate enum Kind: String, CaseIterable {
        case line, arrow, box, oval, none = "nil"

        init(_ snap: MarkSnap?) {
            switch snap {
            case .line?: self = .line
            case .arrow?: self = .arrow
            case .box?: self = .box
            case .oval?: self = .oval
            case nil: self = .none
            }
        }
    }

    /// How far a hand wanders off the path it means, as a share of the size of what it draws.
    fileprivate enum Noise: CGFloat, CaseIterable {
        case low = 0.01
        case middle = 0.025
        case high = 0.04
    }

    fileprivate typealias Drawing = (inout Hand) -> [CGPoint]

    fileprivate struct Hand {
        private var random: SplitMix64
        let noise: CGFloat

        init(seed: UInt64, noise: Noise) {
            random = SplitMix64(state: seed &* 0x2545_F491_4F6C_DD1D &+ 1)
            self.noise = noise.rawValue
        }

        mutating func value(_ range: ClosedRange<CGFloat>) -> CGFloat {
            CGFloat.random(in: range, using: &random)
        }

        mutating func coin() -> Bool {
            Bool.random(using: &random)
        }

        mutating func sign() -> CGFloat {
            coin() ? 1 : -1
        }

        /// A size spread evenly across scales, so 30pt is as likely as 300pt.
        mutating func size(_ range: ClosedRange<CGFloat>) -> CGFloat {
            exp(value(log(range.lowerBound)...log(range.upperBound)))
        }

        mutating func degrees(_ range: ClosedRange<CGFloat>) -> CGFloat {
            value(range) * .pi / 180
        }

        mutating func somewhere() -> CGPoint {
            CGPoint(x: value(0...1500), y: value(0...1500))
        }

        /// Draws an ideal path as a hand does: a slow wobble, a little jitter, and uneven spacing.
        mutating func draw(_ ideal: [CGPoint], scale: CGFloat, count: Int? = nil) -> [CGPoint] {
            let path = Polyline(ideal)
            let spacing = max(path.length / 300, value(2...6))
            let total = count ?? max(Int(path.length / spacing), 12)
            var positions: [CGFloat] = [0]
            for _ in 1..<total { positions.append(positions[positions.count - 1] + value(0.4...1.6)) }
            let end = positions[total - 1]
            var waves: [(cycles: CGFloat, phase: CGFloat, weight: CGFloat)] = []
            for _ in 0..<6 { waves.append((value(0.5...3.5), value(0...(2 * .pi)), value(0.3...1))) }
            let amplitude = noise * scale
            var points: [CGPoint] = []
            for position in positions {
                let t = position / end
                let base = path.point(at: t * path.length)
                let dx = amplitude * Self.blend(waves[0..<3], at: t) + value(-0.3...0.3)
                let dy = amplitude * Self.blend(waves[3..<6], at: t) + value(-0.3...0.3)
                points.append(CGPoint(x: base.x + dx, y: base.y + dy))
            }
            return points
        }

        private static func blend(_ waves: ArraySlice<(cycles: CGFloat, phase: CGFloat, weight: CGFloat)>,
                                  at t: CGFloat) -> CGFloat {
            let total = waves.reduce(0) { $0 + $1.weight }
            let sum = waves.reduce(0) { $0 + $1.weight * sin(2 * .pi * $1.cycles * t + $1.phase) }
            return sum / total
        }
    }

    fileprivate struct Polyline {
        let points: [CGPoint]
        let distances: [CGFloat]

        init(_ points: [CGPoint]) {
            self.points = points
            var distances: [CGFloat] = [0]
            for (point, next) in zip(points, points.dropFirst()) {
                distances.append(distances[distances.count - 1] + hypot(next.x - point.x, next.y - point.y))
            }
            self.distances = distances
        }

        var length: CGFloat { distances[distances.count - 1] }

        func point(at distance: CGFloat) -> CGPoint {
            var low = 0, high = distances.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if distances[middle] <= distance { low = middle } else { high = middle }
            }
            let span = distances[high] - distances[low]
            let t = span > 0 ? min(max((distance - distances[low]) / span, 0), 1) : 0
            let start = points[low], end = points[high]
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    // MARK: - Ideal paths

    fileprivate enum Ideal {
        /// A rounded rectangle's outline about the origin, clockwise on screen.
        static func roundedRectangle(width: CGFloat, height: CGFloat, radius: CGFloat) -> [CGPoint] {
            let x = width / 2 - radius, y = height / 2 - radius
            let centres = [CGPoint(x: x, y: -y), CGPoint(x: x, y: y), CGPoint(x: -x, y: y), CGPoint(x: -x, y: -y)]
            var outline: [CGPoint] = []
            for (corner, centre) in centres.enumerated() {
                for step in 0...8 {
                    let angle = (CGFloat(corner) - 1 + CGFloat(step) / 8) * .pi / 2
                    outline.append(CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle)))
                }
            }
            return outline
        }

        static func ellipse(width: CGFloat, height: CGFloat) -> [CGPoint] {
            (0..<240).map { step in
                let angle = CGFloat(step) / 240 * 2 * .pi
                return CGPoint(x: width / 2 * cos(angle), y: height / 2 * sin(angle))
            }
        }

        /// A closed outline traced from a share of the way round, for a span of turns, either way.
        static func trace(_ outline: [CGPoint], from start: CGFloat, span: CGFloat, backwards: Bool) -> [CGPoint] {
            let ordered = backwards ? outline.reversed() : outline
            let path = Polyline(ordered + [ordered[0]])
            return (0...720).map { step in
                let along = (start + span * CGFloat(step) / 720) * path.length
                return path.point(at: along.truncatingRemainder(dividingBy: path.length))
            }
        }

        static func place(_ points: [CGPoint], turnedBy angle: CGFloat, at centre: CGPoint) -> [CGPoint] {
            points.map { point in
                CGPoint(x: centre.x + point.x * cos(angle) - point.y * sin(angle),
                        y: centre.y + point.x * sin(angle) + point.y * cos(angle))
            }
        }

        /// A line about the origin, bowed by a share of its length at the middle.
        static func bowed(length: CGFloat, bow: CGFloat) -> [CGPoint] {
            (0...24).map { step in
                let t = CGFloat(step) / 24
                return CGPoint(x: (t - 0.5) * length, y: bow * length * 4 * t * (1 - t))
            }
        }
    }

    // MARK: - Drawings

    fileprivate enum Draw {
        static var shapes: [(String, Drawing)] {
            [
                ("box", box), ("oval", oval), ("line", line), ("arrow", arrow), ("tilted long oval", tiltedLongOval),
            ]
        }

        /// What a drawing should come back as.
        static func truth(of name: String) -> Kind {
            switch name {
            case "box": return .box
            case "oval", "tilted long oval": return .oval
            case "line": return .line
            case "arrow": return .arrow
            default: return .none
            }
        }

        static var leftAlone: [(String, Drawing)] {
            [
                ("tick", tick), ("zigzag", zigzag), ("sawtooth", sawtooth), ("L elbow", elbow), ("V", vee),
                ("C, 30% gap", openC), ("spiral", spiral), ("double loop", doubleLoop), ("figure eight", figureEight),
                ("handwriting", scribble), ("question mark", questionMark), ("triangle", triangle),
                ("box tilted 25°", tiltedRectangle), ("bowed line", bowedLine),
                ("tiny circle", tinyCircle), ("one-barb arrow", oneBarbArrow), ("scribble-out", backAndForth),
                ("line with a curl", curl), ("trapezoid", trapezoid), ("T", crossbar),
                ("U, a side open", openBox),
            ]
        }

        /// Drawings with no right answer fixed in advance, counted in the table to show where the edges are.
        static var edges: [(String, Drawing)] {
            [
                ("very rounded box", roundBox), ("box 6:1 to 10:1", thinBox), ("oval 4:1 to 8:1", thinOval),
            ]
        }

        static var all: [(String, Drawing)] { shapes + leftAlone }

        // MARK: Shapes that snap

        static func box(_ hand: inout Hand) -> [CGPoint] {
            let (width, height) = sides(&hand)
            let radius = hand.value(0...0.15) * min(width, height)
            let outline = Ideal.roundedRectangle(width: width, height: height, radius: radius)
            let tilt = hand.sign() * hand.degrees(2...6)
            return closed(outline, tilt: tilt, scale: (width * height).squareRoot(), &hand)
        }

        static func oval(_ hand: inout Hand) -> [CGPoint] {
            let (width, height) = sides(&hand)
            let tilt = hand.sign() * hand.degrees(0...6)
            return closed(Ideal.ellipse(width: width, height: height), tilt: tilt,
                          scale: (width * height).squareRoot(), &hand)
        }

        static func line(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(40...1000)
            let ideal = Ideal.bowed(length: length, bow: hand.value(-0.015...0.015))
            return anyWay(ideal, scale: length / 2, &hand)
        }

        static func arrow(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(60...900)
            let barb = length * hand.value(0.12...0.25)
            var ideal = Ideal.bowed(length: length, bow: hand.value(-0.01...0.01))
            ideal += head(at: ideal[ideal.count - 1], barb: barb, spread: hand.degrees(20...45), &hand)
            return anyWay(ideal, scale: length / 2, &hand)
        }

        // MARK: Marks left alone

        static func tick(_ hand: inout Hand) -> [CGPoint] {
            let long = hand.size(30...300)
            let short = long * hand.value(0.3...0.5)
            let down = hand.degrees(40...60), up = -hand.degrees(50...70)
            let corner = CGPoint(x: short * cos(down), y: short * sin(down))
            let end = CGPoint(x: corner.x + long * cos(up), y: corner.y + long * sin(up))
            return open([.zero, corner, end], tilt: hand.degrees(-10...10), scale: long / 2, &hand)
        }

        static func zigzag(_ hand: inout Hand) -> [CGPoint] {
            let segments = Int(hand.value(3...6.99))
            let width = hand.size(15...150), height = width * hand.value(0.5...1.5)
            let ideal = (0...segments).map { CGPoint(x: CGFloat($0) * width, y: $0 % 2 == 0 ? 0 : height) }
            return open(ideal, tilt: hand.degrees(-20...20), scale: width * CGFloat(segments) / 2, &hand)
        }

        static func sawtooth(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(100...1000)
            let teeth = Int(hand.value(6...14.99))
            let depth = length * hand.value(0.06...0.12)
            let ideal = (0...(2 * teeth)).map {
                CGPoint(x: CGFloat($0) * length / CGFloat(2 * teeth), y: $0 % 2 == 0 ? 0 : depth)
            }
            return open(ideal, tilt: hand.degrees(-5...5), scale: length / 2, &hand)
        }

        static func elbow(_ hand: inout Hand) -> [CGPoint] {
            let first = hand.size(40...600)
            let second = first * hand.value(0.3...1)
            let turn = hand.sign() * hand.degrees(80...100)
            let corner = CGPoint(x: first, y: 0)
            let end = CGPoint(x: first + second * cos(turn), y: second * sin(turn))
            return open([.zero, corner, end], tilt: hand.degrees(0...360), scale: first / 2, &hand)
        }

        static func vee(_ hand: inout Hand) -> [CGPoint] {
            let arm = hand.size(40...600)
            let other = arm * hand.value(0.7...1.3)
            let half = hand.degrees(25...80) / 2
            let ideal = [CGPoint(x: -arm * sin(half), y: -arm * cos(half)), .zero,
                         CGPoint(x: other * sin(half), y: -other * cos(half))]
            return open(ideal, tilt: hand.degrees(0...360), scale: arm / 2, &hand)
        }

        static func openC(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(40...800), height = width * hand.value(0.7...1.3)
            let path = Ideal.trace(Ideal.ellipse(width: width, height: height), from: hand.value(0...1), span: 0.7,
                                   backwards: hand.coin())
            return open(path, tilt: 0, scale: (width * height).squareRoot(), &hand)
        }

        static func spiral(_ hand: inout Hand) -> [CGPoint] {
            let radius = hand.size(40...600)
            let turns = hand.value(2...3), way = hand.sign()
            let ideal = (0...400).map { step in
                let t = CGFloat(step) / 400
                let angle = way * t * turns * 2 * .pi
                let reach = radius * (0.15 + 0.85 * t)
                return CGPoint(x: reach * cos(angle), y: reach * sin(angle))
            }
            return open(ideal, tilt: hand.degrees(0...360), scale: radius, &hand)
        }

        static func doubleLoop(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(40...800), height = width * hand.value(0.7...1.3)
            let turns = hand.value(1.9...2.1), drift = hand.sign() * hand.value(0.05...0.2), way = hand.sign()
            let ideal = (0...500).map { step in
                let t = CGFloat(step) / 500
                let angle = way * t * turns * 2 * .pi
                let grow = 1 + drift * t
                return CGPoint(x: width / 2 * grow * cos(angle), y: height / 2 * grow * sin(angle))
            }
            return open(ideal, tilt: hand.degrees(0...360), scale: (width * height).squareRoot(), &hand)
        }

        static func figureEight(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(40...600), height = width * hand.value(0.6...1.2)
            let start = hand.value(0...(2 * .pi)), span = 2 * .pi * hand.value(1...1.08)
            let ideal = (0...400).map { step in
                let t = start + span * CGFloat(step) / 400
                return CGPoint(x: width / 2 * sin(t), y: height * sin(t) * cos(t))
            }
            return open(ideal, tilt: hand.degrees(0...360), scale: (width * height).squareRoot(), &hand)
        }

        /// Joined-up loops, like a hand writing "llll".
        static func scribble(_ hand: inout Hand) -> [CGPoint] {
            let height = hand.size(20...150)
            let pace = height * hand.value(0.15...0.3), loop = height * hand.value(0.4...0.6)
            let loops = hand.value(3...5)
            let ideal = (0...400).map { step in
                let t = CGFloat(step) / 400 * loops * 2 * .pi
                return CGPoint(x: pace * t - loop * sin(t), y: -height / 2 * cos(t))
            }
            return open(ideal, tilt: hand.degrees(-10...10), scale: height, &hand)
        }

        static func questionMark(_ hand: inout Hand) -> [CGPoint] {
            let radius = hand.size(15...200)
            var ideal = (0...60).map { step in
                let angle = (200 + 230 * CGFloat(step) / 60) * .pi / 180
                return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
            }
            ideal.append(CGPoint(x: 0, y: radius * hand.value(1.6...2.2)))
            return open(ideal, tilt: hand.degrees(-10...10), scale: radius, &hand)
        }

        static func triangle(_ hand: inout Hand) -> [CGPoint] {
            let base = hand.size(40...800), height = base * hand.value(0.6...1.2)
            let corners = [CGPoint(x: -base / 2, y: height / 2), CGPoint(x: base / 2, y: height / 2),
                           CGPoint(x: 0, y: -height / 2)]
            let outline = Polyline(corners + [corners[0]])
            let dense = (0..<240).map { outline.point(at: CGFloat($0) / 240 * outline.length) }
            return closed(dense, tilt: hand.degrees(0...360), scale: (base * height).squareRoot(), &hand)
        }

        static func tiltedRectangle(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(40...800), height = width / hand.size(1...3)
            let outline = Ideal.roundedRectangle(width: width, height: height,
                                                 radius: hand.value(0...0.15) * min(width, height))
            let tilt = hand.sign() * hand.degrees(22...28)
            return closed(outline, tilt: tilt, scale: (width * height).squareRoot(), &hand)
        }

        static func bowedLine(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(40...1000)
            let ideal = Ideal.bowed(length: length, bow: hand.sign() * hand.value(0.15...0.25))
            return open(ideal, tilt: hand.degrees(0...360), scale: length / 2, &hand)
        }

        static func tiltedLongOval(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(60...900), height = width / hand.value(2.5...4)
            return closed(Ideal.ellipse(width: width, height: height), tilt: hand.sign() * hand.degrees(30...60),
                          scale: (width * height).squareRoot(), &hand)
        }

        static func tinyCircle(_ hand: inout Hand) -> [CGPoint] {
            closed(Ideal.ellipse(width: 18, height: 18), tilt: 0, scale: 18, &hand)
        }

        static func oneBarbArrow(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(60...900)
            let barb = length * hand.value(0.12...0.25), spread = hand.degrees(20...45)
            var ideal = Ideal.bowed(length: length, bow: hand.value(-0.01...0.01))
            let tip = ideal[ideal.count - 1]
            ideal.append(CGPoint(x: tip.x - barb * cos(spread), y: tip.y + hand.sign() * barb * sin(spread)))
            return open(ideal, tilt: hand.degrees(0...360), scale: length / 2, &hand)
        }

        /// The hand going back and forth over a word to cross it out.
        static func backAndForth(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(40...600)
            let passes = Int(hand.value(3...6.99)), step = length * hand.value(0.02...0.06)
            let ideal = (0...passes).map { CGPoint(x: $0 % 2 == 0 ? 0 : length, y: CGFloat($0) * step) }
            return open(ideal, tilt: hand.degrees(-10...10), scale: length / 2, &hand)
        }

        /// A line that ends by looping round on itself, as a hand does when it doodles.
        static func curl(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(60...900), radius = length * hand.value(0.05...0.12), way = hand.sign()
            var ideal = Ideal.bowed(length: length, bow: hand.value(-0.01...0.01))
            let tip = ideal[ideal.count - 1]
            let turns = hand.value(0.9...1.3)
            ideal += (1...60).map { step in
                let angle = CGFloat(step) / 60 * turns * 2 * .pi
                return CGPoint(x: tip.x + radius * sin(angle) - radius * 0, y: tip.y + way * radius * (1 - cos(angle)))
            }
            return anyWay(ideal, scale: length / 2, &hand)
        }

        /// A line ending in a bar across it, drawn out to one side and back through to the other: a T.
        static func crossbar(_ hand: inout Hand) -> [CGPoint] {
            let length = hand.size(60...900), bar = length * hand.value(0.1...0.25), side = hand.sign()
            var ideal = Ideal.bowed(length: length, bow: hand.value(-0.01...0.01))
            let tip = ideal[ideal.count - 1]
            ideal += [CGPoint(x: tip.x, y: tip.y + side * bar), CGPoint(x: tip.x, y: tip.y - side * bar)]
            return anyWay(ideal, scale: length / 2, &hand)
        }

        /// Three sides of a box, with either a short or a long side left open.
        static func openBox(_ hand: inout Hand) -> [CGPoint] {
            let (width, height) = sides(&hand)
            let radius = hand.value(0...0.15) * min(width, height)
            let outline = Ideal.roundedRectangle(width: width, height: height, radius: radius)
            let perimeter = 2 * (width + height), open = hand.coin() ? width : height
            let path = Ideal.trace(outline, from: hand.value(0...1), span: 1 - open / perimeter, backwards: hand.coin())
            return hand.draw(Ideal.place(path, turnedBy: hand.sign() * hand.degrees(0...6), at: hand.somewhere()),
                             scale: (width * height).squareRoot())
        }

        static func trapezoid(_ hand: inout Hand) -> [CGPoint] {
            let base = hand.size(40...800), height = base * hand.value(0.4...1)
            let top = base * hand.value(0.3...0.55)
            let outline = Polyline([CGPoint(x: -base / 2, y: height / 2), CGPoint(x: base / 2, y: height / 2),
                                    CGPoint(x: top / 2, y: -height / 2), CGPoint(x: -top / 2, y: -height / 2),
                                    CGPoint(x: -base / 2, y: height / 2)])
            let dense = (0..<240).map { outline.point(at: CGFloat($0) / 240 * outline.length) }
            return closed(dense, tilt: hand.sign() * hand.degrees(0...6), scale: (base * height).squareRoot(), &hand)
        }

        static func roundBox(_ hand: inout Hand) -> [CGPoint] {
            let (width, height) = sides(&hand)
            let outline = Ideal.roundedRectangle(width: width, height: height,
                                                 radius: hand.value(0.25...0.45) * min(width, height))
            return closed(outline, tilt: hand.sign() * hand.degrees(0...6), scale: (width * height).squareRoot(), &hand)
        }

        static func thinBox(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(150...1200), height = max(width / hand.value(6...10), 24)
            let outline = Ideal.roundedRectangle(width: width, height: height, radius: hand.value(0...0.15) * height)
            return closed(outline, tilt: hand.sign() * hand.degrees(0...3), scale: (width * height).squareRoot(), &hand)
        }

        static func thinOval(_ hand: inout Hand) -> [CGPoint] {
            let width = hand.size(100...1200), height = max(width / hand.value(4...8), 24)
            return closed(Ideal.ellipse(width: width, height: height), tilt: hand.sign() * hand.degrees(0...3),
                          scale: (width * height).squareRoot(), &hand)
        }

        // MARK: Parts

        /// The sides of a box or an oval: from 30pt to 1,200pt, up to four times as long as high, either way.
        private static func sides(_ hand: inout Hand) -> (CGFloat, CGFloat) {
            let long = hand.size(30...1200)
            let short = max(long / hand.size(1...4), 24)
            return hand.coin() ? (long, short) : (short, long)
        }

        /// The head of an arrow drawn on in one stroke: out to a barb and back, then the other; or round a triangle.
        private static func head(at tip: CGPoint, barb: CGFloat, spread: CGFloat, _ hand: inout Hand) -> [CGPoint] {
            let side = hand.sign()
            let first = CGPoint(x: tip.x - barb * cos(spread), y: tip.y + side * barb * sin(spread))
            let second = CGPoint(x: tip.x - barb * cos(spread), y: tip.y - side * barb * sin(spread))
            return hand.coin() ? [first, tip, second] : [first, second, tip]
        }

        /// A closed outline drawn from anywhere on it, either way, overshooting the start or stopping short.
        private static func closed(_ outline: [CGPoint], tilt: CGFloat, scale: CGFloat,
                                   _ hand: inout Hand) -> [CGPoint] {
            let span = hand.value(0...1) < 0.7 ? 1 + hand.value(0...0.15) : 1 - hand.value(0...0.05)
            let path = Ideal.trace(outline, from: hand.value(0...1), span: span, backwards: hand.coin())
            return hand.draw(Ideal.place(path, turnedBy: tilt, at: hand.somewhere()), scale: scale)
        }

        /// A path drawn in the direction it was given, at any angle, anywhere.
        private static func anyWay(_ ideal: [CGPoint], scale: CGFloat, _ hand: inout Hand) -> [CGPoint] {
            hand.draw(Ideal.place(ideal, turnedBy: hand.degrees(0...360), at: hand.somewhere()), scale: scale)
        }

        private static func open(_ ideal: [CGPoint], tilt: CGFloat, scale: CGFloat, _ hand: inout Hand) -> [CGPoint] {
            let ordered = hand.coin() ? ideal : ideal.reversed()
            return hand.draw(Ideal.place(ordered, turnedBy: tilt, at: hand.somewhere()), scale: scale)
        }
    }

    /// Text pushed right to fill a column.
    static func leftPadded(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(width - text.count, 0)) + text
    }
}

// MARK: - Real strokes, as drawn

extension MarkSnapTests {
    /// What was asked for, what it should become, and the stroke.
    fileprivate static let realStrokes = """
        circle oval 707,80:VdVfSgPjQiRkQlRmTnUnTpUpWpZpaqbrdufsitjwlvlwqysytwuvvvzuzs3s2p2o4m3g4e1e2b0ayZyXvVtVrUpTm\
        UkSiTgReRaPYPXPUOSQRRQRPTNULVKYMaLbJdMgKfQhSjRi
        circle oval 473,529:VfHaHbPaNXNXOQPPUEVFcCdDjLkLjLrLrLrL4C5C2R1S2R1X2X1X+c/d8j7j0u0uv4v4p7p7k5j5g6g5X6X5O2P2\
        I0HzEwFwCqDrCnBnIgJhMcNbRX
        circle oval 484,192:YZUcXdVcUeTgQfOgKjMlOmQoQpOsLwLwOwQuR0TzU3U+V6Z6b3g1g4kzr3s1uxvvwpzn7l6h3g6gwcwd/Zxcxbwb\
        wb9V8Q2O0LvLrKpJqGpHlLhNhOgOaQZUbXdZcYcXbXaXYYYYZaabZdadXbTZUcYeXeZg
        circle oval 940,300:bebgbgbgafbgagagYgZgWhYhZhaiZhbhbiZhaibkYjbiZkalblbkblclcmbncncncpeneleognglgmglgoglioil\
        imimkljnlnjllkklllmmpmomlimjnkojnininioinhniphnhlgmglglgpglgmgogneoeleleleldmeqbpcocmbnakbkbjaiajZjYiYiYhZgY\
        gYgbdYdYebebeadbdadZdadbcbcabbbabbcbabbcbcbcbcbdbebdbebfbgbgeg
        circle oval 262,162:lblglendre9e0g4k8p5r7v8w7x2y000yw1s0t1o0p3n4l4k6h5h5g2c1a0YzXwUtSrRoQoRoPmTlPmTjRkTjTjVi\
        WhVgUgUbRYRWSVRVTVQTTTQTTTTUUUYWWUWSZWaUbWcWcWcWdXeWdVfVeVfWgXgXgXgYgXgVgWgVgYgWgXhXhWhXiWiZiZkXiakalViblXoY\
        oanbmboaleleleodndlflflgoflegW
        circle oval 444,347:XcbdcbaZdbbYbWbXeVcWeYcZeZfWeYgafagagZgagXgZiajZjZkXlYtJoTlYkbnamepbpcpbrcuascscpepeofpg\
        lgmgmhohqipiqimhnkmjlknolmlnnnnomolplolqjqiqhpgogphqgqgqgrgtgtewZsapaoanamXnYnYlZlXlSnToVlVkYjXiZjYiZhZgZgZg\
        YgYgagbebeabcabbabacYbYbacbbbd
        circle oval 1002,194:bYcbacadWdXfUhTiUiTmPoWlUpUrUrXsWrYtZrbsZubtbzesevfugvh0i2htj2jylzlwq4oupvrustssvuurtpw\
        pvpvk5nrjzizixdzd2dtdzbscwawYvWsXsVqWqVpTqOkYlTjUiTiTgOfSdOeTcMdTXJcVaQZSYSWQVSUQWXUUUVSURXTYRZQZQbQdJaUgLfd\
        g
        circle oval 696,304:agbgbhbiajbibibkbjbkblcldlcmelemflfmgmglgngohohohlimjljljmlnlnklkllllmlklklkmkmisjlhmglg\
        lgmglfleldlbjbkalbkbjbibhbibhbiahbhbhbgahbgbgbgbgbgbgbfbdbebebdbebcabbcbbcbcbcbdbdbebebfbebgagbgbgcg
        circle oval 625,341:eWgVgTiSkTqTsR0U4T5Y4c6gwiwi5m6r7u5w2wzzvyqumvmxjsgpbrYrQtOqGqCmQiQiOgNfOeNdQcPbFULWQWWX\
        VYYXZXcYeagYia
        circle oval 509,318:ZdYebeYdVbcebebdbebcYcXYbcabcaYXcacXdbbYeaeagbgbgWgagZmWjYicibmZlYoZmaobncpbmeodsfsemglg\
        lgngpiogninilipmnkmlnnknmmkmikiljojnhmjngniognglglgogrglcmememdmdmambjbkZiajbiaiaiahbhagbgbdbfagbgZgZkbhch
        circle oval 387,243:jRlTwO4N5P8V7Z5d5g4j3u2w0002v7s7m8i6d+U6P4I0FzBtQlQlBlEiQgPgEbGVKUMQSRVLZMcIgIgHiKmLoPsP\
        uS2R0W5Z6c
        circle oval 466,143:NoQmWlclaocmcwfngpgpglgnivjzjoillllnlklpomlioimjlglglgndpckZlgrNiYgagbgTfbfadWgacbdbYSga\
        dadbeaeYebdbaaWfbgbgce
        circle oval 219,157:caYdafagbgZhYjYkXkXlWnYmXpapbqdpeqgthqkqlroqqqroumvkuiugsgsdqZoWoTlVkSkRgSgScQbWWSUVSYOZ\
        Gf
        circle oval 205,96:WbWgUgTjVjWkWkYlXmYpZqbscveyf0hyizkvkuktmqnopnulujsgtgrdqfscscuZrZpZnXkXjVhVgUgTgVgVfXgWe\
        XfZeYdYcZbZbbZaYcXcYcYfZfYecg
        circle oval 202,53:agYgafbfagbfagagbhahZhahZjZiYkJvYnambocneofohqjrlsmtntotnqoponnmmlmjmimhngmgnfogneofodqco\
        cpbobobnbmblZjYjXhVhWfWfWfWfXeYfZeZebdadbccacZbZdDa
        circle oval 688,147:SgYgagWiYkaiaiakYmakcoYocococqaoeqeoememgmgmgqgsiuiqioioioimkmmkooomqmmkmimgqgqeqeqeoeoe\
        ococmemcoememcmakamckYkaiamagaiYgagYgYgacagacYeaeacaeagacaeacacaaacaaaacaeacaeagag
        circle oval 216,109:ZfbgZgYgYgbgbgbgZiUmblekbncmcodndmflfofrfpflgofngpgnhmjmlmmnljlkljlkmimilhmhmglhmgmglgmg\
        mgkflencmbkakaibiajWkUjWhShTfUfZgZeceaccZaceaebebfabZdcgbgcgeg
        circle oval 565,281:TePgJmHwK0P2W3e1i3vy2u9oxgxhxfxf9V0TsToQkNgLWIPOLRLUOTUZYcbfdh
        circle oval 683,251:ahUjKnOjXjbhbjahajTlWoamdlcldlcleldncwb6dxgqhqhpiljlmos0kolmljojqinilglgrgxfqfqflglg9dwe\
        ofmepalclemaoZjbpCpBiVibhbgZfZfbebeTfVfbaZbdadbbcadbbaaZUSbcbdahaibibjbibkajbi
        circle oval 349,60:UiUoRuUyV4bwbxdwdxgzgzh2h3k4j4nynx17528w+swixiwgxg+YwYwZ/HuQtQsQrPqQpPmOlPmBgQgPbCUEPKLPI\
        SFTFUFYDcDgIjLmRlTk
        circle oval 114,87:ZpZoaqasbvdzh0lypwvv0q2n4j4d0WvSoQiOdMbNVJVLXQUVUbRfNkPnQt
        circle oval 140,52:ajUtbnZselepfogljonlmiohngoblapUlZoShagWgbfVbeXcZebebgTr
        circle oval 945,228:bYZbDZCZDaCZDZIlImIlLtLtZqWpZuR+R9cuepe6e6m7n7m7t3t3004t3tymvi1g2g+gwfxf8bxcxc4X5Y4XrYqV\
        sNrNjVkXnMjUlPhWgZfTaTMDLDbZMKaZcbbbVaccbbebXceg
        circle oval 493,95:biYjYjbjbkZmZmamaododmenenfmflgmglhnhmjljmlknlplmkliqjnhnhmhlglgnfpfnflfmfmbldlblclZkXibh\
        ZgbfbgZeZgbfbfbgbfbcbbcbcbccbbbbbbdbdbebfbebfcg
        circle oval 556,176:WeYeWeVfSgTfSgSgSgShTjUlUkSmTpUqUrWrWsXuZtZubvcwewfvg0hxkvmvntpsppqqonpmqlpkqjrjrishsish\
        siqg4gsgtdsaqbrYrVqUpTmVlVjSjUiTiRgSgRgSgSgTgTbJeWcVXNcYbZbabcUabeWdWecg
        circle oval 927,255:bbbbbZcbbabbZcbeaebeafbfYeagWeYgYfZgZfXgUfXgWgYgVgSgQkVjVkXlVlWoWoZqZqcpbncoeneqfsfqgogl\
        glglgmgqgmgmglhmhmhoklmmjmjlmonlqlminjlipnlkmkommkmjlkliljljnhnhlgmgngnhlgnglgpgodndobsbldmcnbmboYnbmclblclZ\
        ibkalZhblXjZjamYjakbjahbiZhbhYhagbgagZgbgZgZgZgafbfbeZdbcaaZcadbdbgacbaebcfe
        circle oval 538,315:gbgahaibjblbleocnfmgpgpgogogqgogpgngogmgogqgogogqhohnhmhlhplnmppmmmmklnqimknioilhmhmhnio\
        gmgoglgpglgmfogmcmdoclanXnajYjZjXjYlXkXlZlYkZjbkZjZkZibhbgbgWgYgYdXdWbXcWbXabcadYZbaZWcbdZdZdYfZeZfWgafagagZ\
        gbgYgbgbgZiaiZiaibhbkbibhc
        circle oval 205,103:ccZcYgYiUmToToVnXoYmancncmcmdnemglgkhlhlhmjnknt2ptllkllklllkmklililhlgmglglglflflflfmfle\
        memdlclbkbnUjZiZhYiQhZhXgagZgZgZfagZfafbfbfaebbZXbUdZfYfZfZgZgVgchbh
        circle oval 562,241:bgWiZgbjajXoYlZlZmYlXoZlZmblbogofogqgmgojmtltgmg/g2doboanamZlbjblWkamSgbgbgbcaaaOY
        circle oval 566,164:YYSYQbGcOgPgOkPkQpQpE4I8YwXwaybzgyfzizhzoyoy79ysxtzqzr0mzmzizhygygwcxc7S5IqQqPmMmMkKjKhI\
        hIeIdJYLYLVNVNSPTPQVQVPaPZ
        circle oval 458,149:WuZsbyducye0g2k6k0k1q2oxtyruuuvrztwnym0lwi4fvb5YuY4TvV0QwSvMsQtNnRmNlSjReRdRdWaSUUSUXYMT\
        QaNXLYNcKaOaKbLdNfKgNfNhNhQkLqaj
        circle oval 720,419:lgnhlhtkmiqjmjoiljljnlimilimhmhlgnhmiqgogqglglglbqcnclZkbkbgYhbgQgWgXgWgYgVgYeWdCXWdaeYb\
        dbgagbgZgagahbjYhbjbkYibjamYmZnbldmcnclcmclclelgmgmg
        circle oval 751,183:ZgVgUjLnTlXkYlbhZiaibkdlcnW3YzXzU9ayerfngmhmhmhmjlklnmmlnlqmslqkpjrjsjuixjuhrgpgmgnflemd\
        qYmcnbmcoZlakajaiajaibibhagbgaeYfTgXfZfafafbeZfYdZcbbebcbbbbacbcZaZYYZbbbcabcabbbdbfbgfg
        circle oval 752,209:aibiZjXmYlVnWoWnWoXqXpYqWsYrZqZrbrbtdveteufufugtguhuktltnsosoropqnonpjojqhqgsgvgwg1d3d8d\
        7a7Y3Z8U0WxVuUvUqWoTmWkWiVhXhYgWgYgYfYfZeaeZeacZcZcacZbYaZXXXYWYTWTZQWQXQZPXOYPZOaQbSbVdWeZfbfaebgbkbmdlcmcm\
        ei
        circle nil 849,247:gZjYgZfbdbbZVaaeYeYgWgVhRjTkSkOpPpTqSrUtVsapWtdmdndqeogojqkrmtrtsrmjpluntlvntksktiuhwgvev\
        exbwawXuWrVpWnVqMkXjXiVhThUftgGdScQWQVTUZWcVdVe
        circle nil 887,319:ZdadZfbeXgbgbgagXgXhXjbhQlKlLmKlNnRlQlGrZkWnbkblbobsbsgmeofngpgngpgqjyinjpkpv8mpuwlmmlpn0\
        m0mqh6jugzgzgxgtgtfrdqeobwZncmboanamajalShTiVhagbhYhZiYgagTgYgIgYgXgXgZgXfafZeUdVfZdUgZcWbbbdYgafXgagXgYgelr\
        nnhmh
        circle nil 147,28:hokvimhmhmglYiZdbggZhZmcmflkiqglbiagbgdnfmdqc0b1bwbqcnbnhYsHnRmUlTkWlamYmeokqtqwmtmujpjnin\
        hj
        circle nil 1178,110:bdadSbOdMgMfMiNhIjJjMmLnDsDsJrIqJrKyJxGwFvGwWyWzK2K2M4M4Q2P2U4V3U4V5d4d4e0d0e0f1i0j0k0j0\
        kylzqzpzpwpwuytyy79+8zwqwr8t9u/s+l0k1kxkxjyixhwixiyi2iyizh4gsg2e3fwexd
        circle nil 270,126:ZWZcZcUcVdTdSeReQgQhRmRoRpTrUqVsVtXuXuZwbvcqesgrgtgtnvlrnsqupssruqtqxnzmykyiyiwgxfwZvVwOq\
        QpPmTlO
        circle nil 568,129:RZOcOfJgBoByQuQuSxTxV0V1a2b2i0h1ryryywyx0u1u
        wide-circle oval 145,74:XkbjZjZiWlZlYmZmYnYqbnaqbubtYvb0evgsgqksjplonpkmmoponlnjrjqjoi0hpeneoeoe7UmdpboarXna\
        mbrakcqYmboaqXoVjZkZjYjXhYkYiZhZhYgYhXfZgYfXeafacadZcadcbcdcbcadbdXcVdWfVeXhUiWhTjYjQlSnbiWkdh
        wide-circle oval 697,183:bacZdZYZWYWYOZPZKaJcEdQfPfKgLgOhOhLkLjKlJlIoInKpLpJsJsMtNtMuNvMxMxQvQvL8R6b4i0l3t12\
        w+xwnxnzmzl2k2k2j2j4g4h5e5f6c6d6a5b5a5a2a2Zwaxb+T1YyXuWwUwTtSqVqTrQnRmQkTjRfTfSgTdUdUeXaVaWWWVVYWWYYaTZKa
        wide-circle oval 553,264:RlUnUmXmWoXmWnXmZlemZnhmgmhmgmhmgljlllhmjmhmolglglrlqlrkqlrksitjvgthxhthtfvfvgvfsex\
        evbvdubvbsbxYuZvbsZsavbuZvbpZqapalanZmZlakalakbianagbgafbgbfaYbdaWbVbWbObTdWcQcUgTdOdTfRfTeUgRgRhOiUhRhUiTiP\
        iUkRkUkUkRkUjTjSlTjXnWmelSmdi
        wide-circle oval -3,173:eYeYbZeZeZeYhYhYhYlVnZtZwawbwdvdye2f1hyh1hyh1j7k9kzlzlzmzm6owmwn0pwponmnhpfniqerfoZn\
        WoWmUjWkNlKlHjRgRgFfFeIeFdIeJcLdIdRdSbbaaaYaPaRdSb
        wide-circle oval 359,76:bkfmfkdqenlqxwuvuxuv32rt1wvq3q+rwmxl0m1l+o+p2m2l8m7n2k3j8k8j+e2e/YtZuUtNjRlPcSYYXYUY\
        NXMXCVGWCVQaPbQbPbBXObNbFZCXIaMcLcLdHdLeLeOgOfHdEfOeHfOeShik
        wide-circle oval 838,200:fZXXXWUUUUUUOOMQJPMTBMFOOXOXOWPXQYQYOXOXOXOXKWLWGUHVBVBVBUBVBVHXGYHXJZJYJZIYIYIYLYK\
        ZLYJZIYJZDYDXFYFYLbLaLbKcLdKcCaBbFcEdFcGeHfGeDfDgDfDfEgDfDgCgDgGjFkGjJkIjJkKuLtM5K9aybxjyjyw4v4575758574z3z4\
        z/3/2/36x6x5w6x6x/z/z/y/z/z9w8v9w9v9w8v9w9w8w9v8w9w9v8w9w+u/t+u/t+u/t+u/t+u9t9s9t9t8s9t9t9s9t+s+r9s+r+s9s+r+\
        s8r8s8r9r8r8s8r9s9s9s+s9s9s9s/t/s+t/t/s/t+r+r+s+r5p5p5o5p5p4m3n3n4m4l4k4l5j5jxgxh9byW2V8TxYxXwZwZyayayV/V8Sv\
        TmSmSjRYKXNSNWQNPOONQJONRIPNSIQNQMSMSLTJRBMFOBMBOFOBOEPPWPVOWPWEQOWPXQWQXOWPXEQQYQXEQMULULUISKUPVLVOXPVLULVE\
        ROWPWOWPWPVDPDODPLVPWPVOWTX
        square box 371,133:ogmgwh1h1h5i5h6i+g9h6g2g2gygxhsiqhlgjtiwi3g2gwgxe6c/fzfze/f5f2gyhygwgqdlZkbffbbdbgZeUfTeP\
        eQeNdOdRePgPgQhOkQmQkTjUiVgWgXgYfaeaeYcbdfbdVfUeSfRgTfReTeRdOeReRfRfQgTgTgUhViShTiUhUiVhWiYiYiZiZiZhbgi
        square box 370,107:lfsgwg6f8g/gxgxgyixhxgxgygxhwgwh8h6h1gvgrgmghpgrguhzi1i5g8g8g5f6e5d2d2d0cwbubrboZkYkUjPgN\
        gKgHeHcGeFeHeLfKfNgQgTgWgYgagYdZZaWeVeRfLgLgKgIfIfHeIdJeKdLfMfPfQgSgWgZhbii
        square box 350,230:enfnescseqdvevfyf1f5f5g5g2h1htirimjllgngrgwfzfyf1f0g5g2g4gzgzgvgtgmflehbgVgXgUhQhPhMhOhMg\
        LeMcNdPbRcTcTdXdZcaaZaebgXhZhXhThWgUgUhXgUgXgXgXhYiYhZiZiYhZhZhYgZgagXgZfcd
        square box 91,132:rohoiphsgugxevcxeteqgnglljlgododtdweye0e4fygygsfqgnflgibfbdWgUgSgRhSiUjVhXhYgZgbVZVfRgPgOg\
        MhMhNhOhUgTgWgZh
        square box 786,126:bgbgbgbgYgbhbgbgbgbhagbgbgagbgbgagagbgbgbgagagbgbfbfbfbfbgbgbgfnhmgninhmhngnhnhmhngnhlglg\
        pgmgoglglgngmfmfpfngnfpgnglflfnglglmhnilimhmgsilimgrimgqhlhogmgrhogmhngnhsgmgqhmgmglilijbgaiYhbgagYgXgVgbgbg\
        agagagafbgbfafYfVgbgUfYgYgagafbfbgbfbfafbfbgbgbbcafafYgWfbfbfXf
        square box 100,307:lhpgngogxeydoexcoexcpe8czeqg0eqgqf0f9g+h0hqhphphognhnhnhlhlgmilhdohoglgmhwgygygzgyfzgogpf\
        pgzgpgpgphyg7gpgogogogogohsgpfnfkbgZdafXfbfafZgSfXfYfYgPfXgXfXgWgWfXgNeNfNdYfXfXePdXfQeYfSeUfPfZgYgahagZhagb\
        XgYhagZjQiOhXlEiWlEhXhWhWhXhXgYgPgQgYgQhYgYhSgahYgb
        square box 697,99:ZeXfVfRfOfNgDgDgOgNhQgPgPgPgDhFiIhMiQgVgZgbgfmglgogrguhtgygyg4g5g8g6f5e4d1d1fxewfvgsfofngn\
        ncofvfyg3f3f7f+f/gygxgxgxfxgxgygxgwgwh6i4hzhuhogmgbdfaeZfXcRdScNbOdMdKdJeHeHfJeHfJeKfOeNeRbJfafafe
        square box 560,550:YCfYdEeYfWeWeWfUeWfWfWfUfWfWgYfWgYfagafagafYfagaicmalgpelgneogpepeqgpeqereqergqereqgqeqep\
        gqepgogognengmglgoimgmikogohmgmgmgqhohsgqhshuhuhshuiuiuisisjsisiqioioiohmhohkgmhofmembkZgaeXebeagagZgYgXgXgX\
        gWgWgWgWgWgWgXgWgYgYgXeZgagaebgbgZebgeg
        square box 330,272:gqhngrgvgugtgwgvgzhthzgugvgvgogmfmmhngoiqhtgrhugqhuhtitisjujrisirirhriqgsiqhqhpinhnglgmgg\
        ZfYfXgZgXgTiUgSiRhOiOgShQgRgSgTgTfTfVfXeXfaebfbbgZhVhYhXhUiXhShUiUiSiTiUiVgUgVgThXgVhWgYgXgZgZfagbgbg
        square box 71,124:hkhmhohpirhshthuhshqhohmglhlglqiqgufwfvgwguhththrhqhphohlglgibgcfagYeXeXfYeZeXeWeWfXfZfYfY\
        gYgagZfbfZfbZeagahVhUjTiShTiUhWhWhViVhWhXhYhahbgch
        square box 288,343:fVgUfJfGfHdJdKbJcNbMcTeTdXdbZbafKjJjJmNkJjJiQjThYhbgaiflfnfsfxg0g5j6j2jxixktiskpkplnmmnjr\
        iugxgyd4e5f7e5c5budqene
        square box 806,339:gmgogngpg0gmgqgrgpgwgoglgmgpgmglglhmmjxgtgrgsgygugmgnfpfqemfogufsfogpfsfmgmglgmgldgXgZgag\
        bgOgWgWgXgWgWgXeYgZfbfZfafXfbfbfZgaeZZfXgVgXgagYgWgXjaiZhZiYhahSjXhZhYhVhZjbibhaiZhZkZhZjaibi
        square box 581,243:ilinilhmglgmhmgngmglglhmgmgqgmmkmgpgmgngpgnglglgoglglflglflfgaeXfbeaeadYeagbfbfbgbfbfagaf\
        WgbgbgbWgbhYhbgbgZgZgagZgbgbkbjci
        square box 107,137:mfogqgueuewewfvfvfqfnfjofofqfrfrfufteufufufugsfqgogladXfXeWfTeUfUfVeWeXfYeagafbfbgbgaghbg\
        bgbiaiYjYiaiXhbhZhZhaiZhahZhahbgbhbhbhYhahd
        square box 786,241:OfQgZgYgZgXhCkDlahagahbhYhagbhfmhmgpflemfnenenfmenelflelelfmemfmgnfmfmfmgoflmhpgmhnhpiqhq\
        hrhrgsgrgrgrhsgrhqhphohnhmglgohlgbbdafZgWgZgXiXhWhVhVhUhVgUgVgWfXfYfafafaef
        square box 293,186:clcqasZuaxZ1Y5X6Z8a7Z7c4c0evfrgomjqauewf0e1g3g3g3g6g6g3i5i7j4i4k2k1k0kxkwlsjrjnhnhiagWkRl\
        LlNmMkLlMjLkJlIkJjMjMiMjMjMjQjRiVhWiagbbcYiYiZhYhbgXgbgafXeFbGgGhUjZiXjbgYeUdTdUfWfYgZgZfZfYeXgZfZfZfZgVfWfa\
        fbfagbfbgYfZgYfZgZgagagbjbjZmYoUuWwXyZxcverfnglbj
        square box 387,124:hpgnhmgoiqhqirhthshththrhrgrhrgqhqgohoilknqkrhriwiwhxgzgyhzgygzgygxgwgththvhshwhvgqgpZjYi\
        ZhbgZgadacZdacYcTfWeQfRfVdTdWdXbYbWbXbVbUdUdWdVeYdYdXcbYcbfYgXfUgWgUgUgViVjViXiYiWiYhYiXhYiWiYhXhXiYhYiYhYha\
        hagbhYgbgahflhvhviohk
        square nil 419,205:frfmfqeoeqdqdreqdrgrfqfreognengmeqfmfrfmfnfmglfmgqgmgoglgmgmgngmoioeqfrfsgtgqgtgrgpgngngl\
        glgngogmgmgrjnhnhlilgohnhlhmhphqhnhrhmhnhoh
        square nil 505,230:mgmglglgngpgrgrgqgtgrgsgsgshohpgnhmibkglglglgogrg1g5g+g/g5g3g1hvgshndbaebeZgZfTfUfTgTgPfQ\
        gVgTgXgQgVdVeafZelckc
        square nil 1056,125:fvh0i9j3j7i6i7i9i+i8h6g4f3e5e4g1gzgugqgnglYfWfUgRgNhLhHiGhEgEgQgQgQgQgQgPfOfPfOgPfQfPfCd\
        CeEeHgLgNiRgWhYgcgaggagUgWfUgVgUgTfRePePfOfMdLeLdLeMeMeOeQdRdGfUfYfbgZlanZnckdndjZmdhbfh
        squiggle nil 453,282:lizrojrlnjlgmbnalbmbnblbnclblimjlknjqklilhlgocodmdlemelfmdldldobldogpipisjpimjlinhxglgm\
        gngmglfndpgthqjnipjlhpkrjmhogngoclfmdmfofmfoengmhmilkpkljlilhmgnfleldleqfpdlfle
        squiggle nil 786,419:lcldldlelelelelelgljlililjljlilililglgmglglelcldlelelglflglhlhlilikljlljlhlglglglelflen\
        elflglglglhlhlglhlhlglhlhlhlhlhlglglglglflglflelflelflflglglglilkljlklklhlglflelflelf
        squiggle nil 377,211:tmrgnenZmboVqmnmlmllmhlimgngodlfnglgmlpklglfocqbqnrk1gwg1ilgtmogwg2gmgngmflklkzhngugrgl\
        eogtlqhphmgqgrgmgpfndnonlminiminipgrgogngmjllllmmlkmjmhlgmgjg
        squiggle nil 493,319:TgdTqE3D9J+S9g4su3o2ithlgPZEYMVXVfPlLwN0KzKnKYSIdCkQjPtQtPyQzQ4Q3R6W6W1c1c7hrrg5U/U0T0O\
        3P3N0NzNpNpJgXclEsOtP1M1M6N7N8S8T4Y4YwexeuggtVyVyO5P5K8K7HyHxIoInMeNfJLdCmQlPwOwP3S3R6U5T7Y7Y2e3fwkwjwwh0ZxZ\
        xQyQzK0K1IyHyJsJrCnWgmO6DzQzQ3S3S3V3V2Y2ZwfwfxhlrawawQ0Q0K6K5H6H5HzHzKoLoHhXSkNjNsMsMyOzO2S3S1Y1Xwdwd2jnwcwb\
        xRyRyIyHyIyJpIoJpQkQkLnCqHlSeaNiMjNqMqLvMvL0QzPyZzZ3imqa8J+OvPvKuJuIrJrLmLnChOabDhGhHqDqDvEvEzIzI0N1N2S3R
        squiggle nil 459,151:YsQvMxLyWqbpfntmvhxgwg3g8Z0c1b0azZwYwZ8W4XtZZdWgZiapfsgzs6z6yuzt1p2o1p1l1k1l7i7ixgxgwWn\
        WhRgNXQSOGQCYCYCYKfLeKfJiIiJiCoCoDnCoCoCxCxM0L1a+a+sztz/41n2n1n1k1j1k7g6h7g6h7g2e3fyYzZvUmTiRfQPGPGKKNTPbFdU\
        nWwbzg3h4h5t6z80w7kxgxgygyg1g1g2awZwZxUsVlahbgogpgmgogk
        squiggle nil 119,57:UeTjSqTwY1ezmwus4j5jwVrPlOeVbdSkOuQzW0fxmp0j4YzRtPjUbbLkDwJ2S3g0su7j1ZvTpOhRdaWhQwR+b8kx\
        vo5c3SxNpOjXXsT+V7dxhlrfzUzPvQpTjXbbReSlWse3vr4g0RyCjMjNdDdUbdVjSxX1fqncrJiPjPiDeTbdUrQzY3grlkudxSuIpDfBdSZc\
        TiQsS0aygomhzXpZ
        squiggle nil 125,76:RpQuM6O+X/g6mxuswpzi1e5V8P/M5KwNaSWVPfNmJwI4O9X6gzoppovkxk1f3e4c2guflZkYbTZRWYYeXmXyW3d6\
        i3ptrpqjresZvOzLvMqMhTfYebcc
        squiggle nil 332,174:blXrczczx06g5f5f6g7V8V7W8V7V8Q8R8R8Q4MhYfaERPePfDkElDkGsGtMuLuO2ez02020t1t8m8n8m8n8m5i6\
        i5i4g4g4gUjFmGmFmCoCnHoHoGrgl8g4g4f4f4g9b9b9a+b9b9b9a9b9b+b9a9b9b9Z9Z9Y9Z+Z9Y9Z9Z/Y/Y/Y/Y/Y/Y/YgIgIgIgIgQCQI\
        dJeIdGfGfGgGfGkFkGlFkGkDlEmDlDlElDmElDlDlEmDlCqBrCqBrCqErErFqErJrKrJrUuhm9l9l8a7amcabbg2wxkxl8l9l9l9k9l9l9k9\
        l1rkoWvQvQvGzFzC2C2C3C2C2YrioskphnegVGOGNCWCWCVCWCWGaGaGbGaDcDdCdDcFcFbFcFcFcFbFcEYFYOXPXSPfXZbwhyfzf6c7d6c+\
        X9X+X+X+X9X+W+X9X+X+X+X9X+X/U/U+U/U5S5T6S5T5SiYYYBWEgEfEfEgEgEfEmDnEnEmDmEnEnEmDmEnGqGpGpFqGqGpFrGrFqGrFrY6Y\
        6X6Y6g0g0gyty1q2p1q6j7j/a/Z/Z/a/a/Z/Z/a5W5W5W+h+h+h+h+h+h+h+i+h+h+h+h+h+h+h+h+h+h+h+h+h+h+i+h+h+h+h+h+h+hMWN\
        VQYQYLYLXLaLaGeGdGdGeLgKgLgLhKhLhDmDmEmDmrg7a7a6a7a7a7a4Y4Z4Y2Y3Z2Y6X5X0WzVVdIiJiOmOlGoFpVoMaCbCbCbCbIfIgIfG\
        gHgEgagpe6Z2a2a1a1b0YZdNjMmNlDwDwDwgptp0kzl8h8h
        squiggle nil 91,104:mXoanengnklohpgofmbkrXodnfogmqixgvanXlbhjUpZobodmfmgmgjpgmlimemgogmhkmimhlfoZoaljYlcmelj\
        hpgqbralakogmglglrgqboXlXlbimhhmerXpSoQlPjVhZgbYgWlXmamcmfngiqdmXlWjUjThVhZgbgmWlelfUiUgXcZWeXgZ
        squiggle nil 272,182:mlWeMSLTJSJSPWPXObaij0pxpxqypyo0guYsHrIsPrTuYuarXtOt
        zigzag nil 538,418:ialalZkakbmbkbmcmanZlckbjbldlghljmimjojmjlhlkniljlilhmimilimlhhbjbkbnakalamdlcmblalelblcm\
        bmcimjmjmhmilhliljmjmjljmiljljmjlhljlklnckalZkblamakbkbldlcldlcldldlekmiljmjliljmiljljmjmjmij
        zigzag nil 185,377:kblclbmboYoUpSpNqMqLpOmQlSkWiblmjpiqjrjsjukukvluktkrkrjojmknlgpRmPoMpHnInMnSmXmbljimioiqi\
        qjrkqjplrlqmtlpkojnjmnomhmakSlOmOnOpPoQoRmVmYnclqhphsgsivjviwjxjsjqjmnkpcmUmQnPmMnMpOoRnUmaofiqhvhwhyjwkxkuk\
        rknmirUoUpQnPoMnMlRmUmYmclflhhn
        zigzag nil 47,304:jagZjQjRkPkQiYhbmilnnsqupuoqmnkmmkhbgQgPhOkQkWkYjbkbnup0q6p+r4oumnkYeKeEgFjHoPsTnYlcldjrkr\
        kynxmzmxoumrlokllXhShGhOhVhYhZiaiblhjpkukyjzjxjsipimhlig
        zigzag nil 137,206:lbqZtZsbqcoelflggoYuWtXtandlqisftfsepfnfmemelgasXtXuYrZrcmpfrctbvarbpcneledocnZqZqZpbncnq\
        cqararbqbndlehldlbmapapcodmemfg
        zigzag nil 82,856:2Y3Y4d8c9b+awcwbxbxb/W+W5W1XvaqcmebfYgXgYgWgVgWfSdVdUdVdXdSbETNZQaQZNXEQPXKURXUZSYXaZcaavb\
        1cwcwdwaxbyZzZ1X1X2T2T0UzUwUxU7OzQxWtVsWpZkZbYbgRhTiIjGiGiBhDiFgHgHdMdKeNeOdRcWcZddP9O9P+VyaxazazbyazZyZxZwX\
        wX9Q1QzRrToWjWdSOcNbIfEgQgQhCkHlHlIlHlBmKiJjSgVgbelNuT8S9RyayZ7X8W7X0Y1Z2Y3Z2Y3VtambLaFgIlJmIlOmNnIpIqIpPmPm\
        FqFqTjbh/L9S+V+V/V+V1a1Zyayb2Y1ZmfQmPnFsFtFsItJtFxEwFxD5Mza2zgzg5d5d/b/b/b/b+d+d+e+d
        zigzag nil 97,501:fXgZgUkNlMoGpIsKpSoXmejojwq4q9r+r9o3mrqgmYuOxJ1BsPrPsOtOsOtN0C0MuYpflhhngrg2gwhwgxgxeydzcy\
        dxa6esglmeoYnXqTsLwFrNrNsNtNuOuO7D1Qteohjrhyh3gwfwY9W5ZxbselkZkWtNxKxH0H0GzJyQuWpcmginhuj5k9gwgxgwgwc+Z4bvdp\
        lYnTsLuHzDxDtMoUlZjngxk7m8m7k4jwhqgliahXkSkRkVjXibkllhlfldpZlbmZmYlbldliisjxl0j1hvgpgl
        zigzag nil 306,31:ckdndkcmcmbmbmboaoanbnbmdldkamZnZmajlinismwlxltkpjljknkkZkZiWiVjTiUjRiSlTlVkVlXlXjYiaiahlh\
        nhwizmxmvmvloklikjglblVqStUqWpaldlamahaeTdNcMdBbVdae
        zigzag nil 62,274:hckWkRlKnLmOoQlWmXmbkfppqspxmxmxlwmulokkqYoQnMlLjMjRiYrjoqoyp3m2l0lwocnOnI
        zigzag nil 608,115:wk0k0gwkwkxixiwiwiyiyi6kyisgqgogmgmgcoUmOoOoOoNnNnNoNoImImNlNlPlPlCsCuUmWkcmqm8m1j1j2j2j+\
        p+p1l2k1l+o+o8o8o5o5o+iskqgig
        zigzag nil 544,100:vfugvgugohngmhngsjlhmipinjmipllkljglcoanXoblbkZlZmanYmananclclojohtiwjxltj0mmiljliljklbpU\
        sVoNpPmOkNkUkbibi2hugwh1m1muxmonynzklcmZlVmbjWoUrcncmcmblrkogohsiniliklMlRiOiOhWiTkbibjclcl
        line line 40,204:metc9WyZyZ0Y1Y0W1X7Q3SwXrYldlfdg
        line line 700,255:bhbiZhYiWgYgYhYhWhVhWiTgEkOkOiPjPiOjOiLiNgRiPhPhNgShMhQgLgLgLgLgGgHgHgIgLgNgKgYfZgZeeg
        line line 203,71:pfugyf1i3i5h4g7f5d4d2ezfvgnigg
        line line 212,264:ngogoiuizj2i1j6g7g3g3g3g+h9h+h6g5g5g6g9g9g9g9g5g6g5g6g5g/g/g/g/g+g+g/g+g5g5g5g5g5g7g7g6g7g\
        1g
        line line 590,69:gqgqgsgwgxg2g2g4g5h5g4gyhyg+h+g+g+g2g4g5g0g1hxh8guh0gugmhngl
        line line 73,300:oize+d+cyexdyexdzezdzezd0ezfzezfzfzfygzfygxgygxgygygygxgxgxgygyh0izh0hzh0g1h0i0h0izhzgzhwhw\
        h7i0ithogRg
        line nil 927,66:ZodobqarYsVuUvRvOuLwKvIzJzKvOsUqTpZmamblaoZlbiaj
        line nil 334,115:euf2a+dwdxeyfyfyfzfyfyeyeycwdwazZzYyZyS7Yvaqemmi
        triangle nil 434,612:nisjui8k3l6j3k3jyg8eudwdpfldbXZTYUSEUJaMbMdQdPcHbHeEgMgLgIgIgJgLhHjOjOjRjPiWiWgZelenZsc\
        rYuZsYrP2VwI9VxM8YwQ9XwS1YrWuapYrbnarenbpardncsdperfneognglimhlhlhlilljplqknihi
        triangle nil 596,525:kYkYqUkasMkamWyGoSuNuNmUmWpQpQmWsGkWmOiamWoguomiwqommmysmmyyqooo68ssz1z1suw1w1suosuxuxq\
        ommuwkmomimWmSmYiWiOkOkQkDlDlIkKgHhIiHhGgGgGgGgCgEgFdEcFdCcGdGcGdCcGcCcCcQeNeNeYgEeYgWeme
        triangle nil 637,413:lglfpgtgvgxgygvgvgrgqenflgmeldlelfoflfnenfpgmgoflelgkZfYebebdbdYdXbWbWZVZSWPWOVOUNTOTQV\
        PXSYSZUZVbYcadbeZfbcYeZcaeZdbblfnfnepfqerdtcuduetdudrerfqenfnelflgoglglgnglgmilglglhnhngnglhlgngpglgoglflfle\
        nenfnfoelflelelfl
        triangle nil 515,203:gndmdldmdlbraocobrbtYyZwX0YyZyYybtdseqdpdneoemflfmdngmcnfmememfnningpftgsgtgvgvg3g5g5g5\
        g8g5g5gxgugsgsgqgogmfpelfndldkbgahagadYebdYcYbUaUZRXPQMSRPOPRLOJOJQCNHNEPHRLUSXOXUZWcZdbebehg
        triangle nil 155,106:gngofqfpepeodndndncmdmdlflfmlimilhlhngngogngmflgpemflcibfcdbcabaaZZacYebZWdbdcccdadaecg\
        f
        triangle nil 767,684:lWoWmXkYpWnSmTmYiWmUlUvQpPlQqOpLtPqOpQqPtOoWmStSmTnWoYkXoWkVoYjajZmakYkZlanbjqlrjqjsmsn\
        wpxquo1q1otozmyowo0mvtxoylwmylpnwkqkpmqjmlqilmoiommiljmmllnikZiXgUgUgTgLgOgIgMgGgTgTgSiWjXhWiViVjYjZiYjXhbga\
        gZgVgbgPgTdQgObTfPdTbWeVfXeZebgcfbgge
        """
}
