import XCTest

/// `SplitLayout` is the tree the main area is divided by. Nothing in it throws
/// when it is wrong: a pane lands in a row inside a row and its divider moves
/// two edges, a closed pane's room goes to the wrong sibling, a terminal is
/// drawn half a point off its pixels, ⌥⌘→ goes to the pane you didn't mean.
/// So each rule gets a test of its own.
final class SplitLayoutTests: XCTestCase {
    private typealias Leaf = SplitLayout.Leaf
    private typealias Node = SplitLayout.Node
    private typealias Part = SplitLayout.Part

    private let a = Leaf.pane(UUID())
    private let b = Leaf.pane(UUID())
    private let c = Leaf.pane(UUID())

    private let bounds = CGRect(x: 0, y: 0, width: 801, height: 601)

    /// `leaves` as a row of equal parts.
    private func row(_ leaves: Leaf...) -> SplitLayout {
        SplitLayout(root: .split(.row, leaves.map { Part(node: .leaf($0), weight: 1 / Double(leaves.count)) }))
    }

    /// Main and `a` over `b` and `c`: two columns of two.
    private func grid() -> SplitLayout {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: .main, on: .down)
        layout.insert(c, beside: a, on: .down)
        return layout
    }

    /// The parts of the split at the root, or none when the root is a leaf.
    private func parts(of layout: SplitLayout) -> [Part] {
        if case .split(_, let parts) = layout.root { return parts }
        return []
    }

    /// Every split in the tree, for rules that hold for all of them.
    private func splits(in node: Node) -> [(axis: SplitLayout.Axis, parts: [Part])] {
        guard case .split(let axis, let parts) = node else { return [] }
        return [(axis, parts)] + parts.flatMap { splits(in: $0.node) }
    }

    private func assertWellFormed(_ layout: SplitLayout, file: StaticString = #filePath, line: UInt = #line) {
        for split in splits(in: layout.root) {
            XCTAssertGreaterThan(split.parts.count, 1, "a split of one is the one", file: file, line: line)
            XCTAssertEqual(split.parts.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9,
                           "a split's weights are shares of it", file: file, line: line)
            for part in split.parts {
                XCTAssertGreaterThan(part.weight, 0, file: file, line: line)
                if case .split(let inner, _) = part.node {
                    XCTAssertNotEqual(inner, split.axis, "a row in a row is one row", file: file, line: line)
                }
            }
        }
        XCTAssertEqual(Set(layout.leaves).count, layout.leaves.count, "each leaf once", file: file, line: line)
        XCTAssertTrue(layout.contains(.main), file: file, line: line)
    }

    /// On whole points, origin and size.
    private func isWhole(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0 == $0.rounded() }
    }

    // MARK: - Reading

    func testAnUnsplitMainAreaIsTheMainRow() {
        let layout = SplitLayout()
        XCTAssertEqual(layout.leaves, [.main])
        XCTAssertFalse(layout.isSplit)
        XCTAssertTrue(layout.contains(.main))
        XCTAssertFalse(layout.contains(a))
    }

    // MARK: - Inserting

    func testASplitHalvesTheLeaf() {
        var layout = SplitLayout()
        XCTAssertTrue(layout.insert(a, beside: .main, on: .right))
        XCTAssertTrue(layout.isSplit)
        XCTAssertEqual(layout.leaves, [.main, a])
        XCTAssertEqual(layout.root, .split(.row, [Part(node: .leaf(.main), weight: 0.5),
                                                  Part(node: .leaf(a), weight: 0.5)]))
    }

    /// Left and up put the new pane before the one it was split from.
    func testTheEdgeDecidesWhichComesFirst() {
        for (edge, axis, first) in [(SplitLayout.Edge.left, SplitLayout.Axis.row, true), (.right, .row, false),
                                    (.up, .column, true), (.down, .column, false)] {
            var layout = SplitLayout()
            layout.insert(a, beside: .main, on: edge)
            XCTAssertEqual(layout.leaves, first ? [a, .main] : [.main, a], "\(edge)")
            guard case .split(let made, _) = layout.root else { return XCTFail("\(edge): not split") }
            XCTAssertEqual(made, axis, "\(edge)")
        }
    }

    /// Along the axis its parent already runs, the new pane is a sibling:
    /// three side by side are one row of three. Equals stay equal, so the
    /// third split gives thirds, not a half and two quarters.
    func testASplitAlongTheParentsAxisIsASibling() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: .main, on: .right)
        XCTAssertEqual(layout.leaves, [.main, b, a])
        let parts = parts(of: layout)
        XCTAssertEqual(parts.count, 3, "one row of three, not a row in a row")
        for part in parts { XCTAssertEqual(part.weight, 1.0 / 3, accuracy: 1e-9) }
        XCTAssertTrue(layout.isEqualized)
        assertWellFormed(layout)
    }

    /// Spreading: the new leaf is one more part of the row its target is
    /// in, with an equal share of all of it, and every other part gives in
    /// proportion. For a target too small to be two.
    func testSpreadingTakesAnEqualShareFromTheWholeRow() {
        var layout = SplitLayout(root: .split(.row, [
            .init(node: .leaf(.main), weight: 0.75), .init(node: .leaf(.side), weight: 0.25),
        ]))
        XCTAssertTrue(layout.insertSpreading(b, beside: .side, on: .right))
        XCTAssertEqual(layout.leaves, [.main, .side, b])
        let weights = parts(of: layout).map(\.weight)
        XCTAssertEqual(weights[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(weights[1], 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(weights[2], 1.0 / 3, accuracy: 1e-9)
        assertWellFormed(layout)

        XCTAssertTrue(layout.insertSpreading(c, beside: .side, on: .left))
        XCTAssertEqual(layout.leaves, [.main, c, .side, b])
        assertWellFormed(layout)
    }

    /// Only where there is a row to take from: a leaf whose split runs the
    /// other way, or the only leaf, is not spread, and nothing changes.
    func testSpreadingNeedsARowAlongTheEdge() {
        var layout = SplitLayout()
        XCTAssertFalse(layout.insertSpreading(a, beside: .main, on: .right))
        XCTAssertEqual(layout, SplitLayout())

        layout.insert(a, beside: .main, on: .right)
        let before = layout
        XCTAssertFalse(layout.insertSpreading(b, beside: a, on: .down), "a row has no column to take from")
        XCTAssertFalse(layout.insertSpreading(a, beside: .main, on: .right), "already there")
        XCTAssertFalse(layout.insertSpreading(b, beside: c, on: .right), "no such leaf")
        XCTAssertEqual(layout, before)
    }

    /// Once the sizes are somebody's choice (a divider was dragged), a new
    /// sibling only halves the pane it was split from.
    func testASiblingAmongUnequalPanesHalvesOnlyItsSource() {
        var layout = SplitLayout(root: .split(.row, [
            .init(node: .leaf(.main), weight: 0.7), .init(node: .leaf(a), weight: 0.3),
        ]))
        layout.insert(b, beside: a, on: .right)
        XCTAssertEqual(layout.leaves, [.main, a, b])
        let weights = parts(of: layout).map(\.weight)
        XCTAssertEqual(weights[0], 0.7, accuracy: 1e-9)
        XCTAssertEqual(weights[1], 0.15, accuracy: 1e-9)
        XCTAssertEqual(weights[2], 0.15, accuracy: 1e-9)
        assertWellFormed(layout)
    }

    func testAFourthSiblingAmongEqualsMakesQuarters() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: .main, on: .right)
        layout.insert(c, beside: a, on: .left)
        XCTAssertEqual(layout.leaves, [.main, b, c, a])
        XCTAssertEqual(self.parts(of: layout).map(\.weight), [0.25, 0.25, 0.25, 0.25])
        assertWellFormed(layout)
    }

    /// Across it, the leaf becomes a split of the two, in the room it had.
    func testASplitAcrossTheParentsAxisNests() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: a, on: .down)
        XCTAssertEqual(layout.leaves, [.main, a, b])
        XCTAssertEqual(layout.root, .split(.row, [
            Part(node: .leaf(.main), weight: 0.5),
            Part(node: .split(.column, [Part(node: .leaf(a), weight: 0.5), Part(node: .leaf(b), weight: 0.5)]),
                 weight: 0.5),
        ]))
        assertWellFormed(layout)
    }

    /// A split deep in the tree finds its sibling there, not at the root.
    func testASiblingIsFoundInANestedSplit() {
        var layout = grid()
        let d = Leaf.pane(UUID())
        XCTAssertTrue(layout.insert(d, beside: c, on: .up))
        XCTAssertEqual(layout.leaves, [.main, b, a, d, c])
        XCTAssertEqual(parts(of: layout).count, 2, "still two columns")
        assertWellFormed(layout)
    }

    func testInsertingBesideNothingOrTwiceChangesNothing() {
        var layout = SplitLayout()
        XCTAssertFalse(layout.insert(a, beside: b, on: .right), "b isn't there to split")
        XCTAssertEqual(layout, SplitLayout())
        layout.insert(a, beside: .main, on: .right)
        let before = layout
        XCTAssertFalse(layout.insert(a, beside: .main, on: .down), "a is there already")
        XCTAssertFalse(layout.insert(.main, beside: a, on: .down))
        XCTAssertEqual(layout, before)
    }

    // MARK: - Removing

    func testRemovingTheOnlyPaneLeavesTheMainRow() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        XCTAssertTrue(layout.remove(a))
        XCTAssertEqual(layout, SplitLayout())
    }

    /// The room goes to the siblings in proportion to what they had.
    func testARemovedPanesRoomGoesToItsSiblingsInProportion() {
        var layout = SplitLayout(root: .split(.row, [Part(node: .leaf(.main), weight: 0.5),
                                                     Part(node: .leaf(a), weight: 0.25),
                                                     Part(node: .leaf(b), weight: 0.25)]))
        XCTAssertTrue(layout.remove(a))
        XCTAssertEqual(layout.leaves, [.main, b])
        let weights = parts(of: layout).map(\.weight)
        XCTAssertEqual(weights[0], 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(weights[1], 1.0 / 3, accuracy: 1e-9)
        assertWellFormed(layout)
    }

    /// A split left with one part is that part.
    func testASplitOfOneIsReplacedByItsPart() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: a, on: .down)
        layout.remove(b)
        XCTAssertEqual(layout.root, .split(.row, [Part(node: .leaf(.main), weight: 0.5),
                                                  Part(node: .leaf(a), weight: 0.5)]))
    }

    /// And when that part is a split along its new parent's axis, the two
    /// are one: main | (a over (b | c)) without a is main | b | c.
    func testASplitLeftInsideItsOwnAxisIsFolded() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: a, on: .down)
        layout.insert(c, beside: b, on: .right)
        XCTAssertEqual(layout.leaves, [.main, a, b, c])
        layout.remove(a)
        XCTAssertEqual(layout.leaves, [.main, b, c])
        let parts = parts(of: layout)
        XCTAssertEqual(parts.count, 3, "one row of three")
        XCTAssertEqual(parts.map(\.weight), [0.5, 0.25, 0.25], "b and c keep the half they shared")
        assertWellFormed(layout)
    }

    func testTheMainRowIsNeverRemoved() {
        var layout = grid()
        let before = layout
        XCTAssertFalse(layout.remove(.main))
        XCTAssertEqual(layout, before)
    }

    func testRemovingWhatIsntThereChangesNothing() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        let before = layout
        XCTAssertFalse(layout.remove(b))
        XCTAssertEqual(layout, before)
    }

    /// Whatever is inserted and removed, every split's weights still sum to
    /// 1 and no split is nested in its own axis.
    func testWeightsSumToOneThroughInsertsAndRemoves() {
        var layout = SplitLayout()
        var panes: [Leaf] = []
        let edges = SplitLayout.Edge.allCases
        for step in 0..<24 {
            let new = Leaf.pane(UUID())
            let target = step % 3 == 0 ? Leaf.main : panes[(step * 7) % max(panes.count, 1)]
            XCTAssertTrue(layout.insert(new, beside: target, on: edges[(step * 5 + step / 4) % 4]), "step \(step)")
            panes.append(new)
            assertWellFormed(layout)
            if step % 4 == 3 {
                let gone = panes.remove(at: (step * 3) % panes.count)
                XCTAssertTrue(layout.remove(gone))
                assertWellFormed(layout)
            }
        }
        XCTAssertEqual(Set(layout.leaves), Set(panes + [.main]))
        for pane in panes { layout.remove(pane) }
        XCTAssertEqual(layout, SplitLayout())
    }

    // MARK: - Equal sizes

    func testEqualizeGivesEverySiblingTheSameShare() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: .main, on: .right)
        layout.insert(c, beside: a, on: .down)
        XCTAssertTrue(layout.isEqualized, "splits among equals leave them equal")
        layout.moveDivider(at: [], index: 0, to: 300, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertFalse(layout.isEqualized)
        layout.equalize()
        XCTAssertTrue(layout.isEqualized)
        for split in splits(in: layout.root) {
            for part in split.parts {
                XCTAssertEqual(part.weight, 1 / Double(split.parts.count), accuracy: 1e-9)
            }
        }
        XCTAssertEqual(layout.leaves, [.main, b, a, c], "sizes only, not places")
    }

    func testIsEqualized() {
        XCTAssertTrue(SplitLayout().isEqualized, "nothing to make equal")
        XCTAssertTrue(row(.main, a, b).isEqualized)
        XCTAssertTrue(grid().isEqualized)
        var layout = row(.main, a)
        layout.moveDivider(at: [], index: 0, to: 300, in: bounds)
        XCTAssertFalse(layout.isEqualized)
        // Uneven only deep in the tree still counts.
        var nested = grid()
        nested.moveDivider(at: [1], index: 0, to: 200, in: bounds)
        XCTAssertFalse(nested.isEqualized)
    }

    // MARK: - A damaged tree

    func testNormalizedLeavesAGoodTreeAlone() {
        for layout in [SplitLayout(), row(.main, a), grid()] {
            XCTAssertEqual(layout.normalized(), layout)
        }
    }

    /// A split with nothing in it is the main row, once.
    func testAnEmptySplitIsTheMainRow() {
        XCTAssertEqual(SplitLayout(root: .split(.row, [])).normalized(), SplitLayout())
        let nested = SplitLayout(root: .split(.row, [Part(node: .split(.column, []), weight: 1)]))
        XCTAssertEqual(nested.normalized(), SplitLayout())
    }

    /// A tree that lost the main row gets it back, beside what it has.
    func testAMissingMainRowIsPutBack() {
        let layout = SplitLayout(root: .leaf(a)).normalized()
        XCTAssertEqual(layout.leaves, [.main, a])
        assertWellFormed(layout)

        let two = SplitLayout(root: .split(.column, [Part(node: .leaf(a), weight: 0.5),
                                                     Part(node: .leaf(b), weight: 0.5)])).normalized()
        XCTAssertEqual(Set(two.leaves), [.main, a, b])
        assertWellFormed(two)
    }

    /// A leaf listed twice is kept where it is first read.
    func testALeafListedTwiceIsKeptOnce() {
        let damaged = SplitLayout(root: .split(.row, [
            Part(node: .leaf(.main), weight: 0.25),
            Part(node: .leaf(a), weight: 0.25),
            Part(node: .split(.column, [Part(node: .leaf(a), weight: 0.5), Part(node: .leaf(.main), weight: 0.5)]),
                 weight: 0.5),
        ]))
        let layout = damaged.normalized()
        XCTAssertEqual(layout.leaves, [.main, a])
        assertWellFormed(layout)
    }

    /// Weights that are nothing, negative or not numbers become shares.
    func testBadWeightsBecomeShares() {
        for weights in [[0.0, 0.0, 0.0], [-1, 2, .nan], [.infinity, 1, 1], [3, 3, 6]] {
            let damaged = SplitLayout(root: .split(.row, zip([Leaf.main, a, b], weights).map {
                Part(node: .leaf($0), weight: $1)
            }))
            let layout = damaged.normalized()
            XCTAssertEqual(layout.leaves, [.main, a, b], "\(weights)")
            assertWellFormed(layout)
        }
        let scaled = SplitLayout(root: .split(.row, [Part(node: .leaf(.main), weight: 3),
                                                     Part(node: .leaf(a), weight: 1)])).normalized()
        XCTAssertEqual(parts(of: scaled).map(\.weight), [0.75, 0.25], "the proportions it had")
    }

    /// A split of one and a row inside a row are folded.
    func testNestingAFileGotWrongIsFolded() {
        let damaged = SplitLayout(root: .split(.column, [Part(node: .split(.row, [
            Part(node: .leaf(.main), weight: 0.5),
            Part(node: .split(.row, [Part(node: .leaf(a), weight: 0.5), Part(node: .leaf(b), weight: 0.5)]),
                 weight: 0.5),
        ]), weight: 1)]))
        let layout = damaged.normalized()
        XCTAssertEqual(layout.leaves, [.main, a, b])
        XCTAssertEqual(parts(of: layout).map(\.weight), [0.5, 0.25, 0.25])
        guard case .split(.row, _) = layout.root else { return XCTFail("the column of one is its row") }
        assertWellFormed(layout)
    }

    // MARK: - Frames

    func testTheMainRowAloneFillsTheArea() {
        let frames = SplitLayout().frames(in: bounds)
        XCTAssertEqual(frames.leaves, [.main: bounds])
        XCTAssertTrue(frames.dividers.isEmpty)
    }

    func testTwoPanesShareTheWidthAroundTheDivider() {
        let frames = row(.main, a).frames(in: bounds)
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 0, y: 0, width: 400, height: 601))
        XCTAssertEqual(frames.leaves[a], CGRect(x: 401, y: 0, width: 400, height: 601))
        XCTAssertEqual(frames.dividers, [SplitLayout.Divider(path: [], index: 0, axis: .row,
                                                             rect: CGRect(x: 400, y: 0, width: 1, height: 601))])
    }

    /// The area's own origin is where the frames start.
    func testFramesAreInTheBoundsTheyAreGiven() {
        let offset = CGRect(x: 220, y: 40, width: 801, height: 601)
        let frames = row(.main, a).frames(in: offset)
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 220, y: 40, width: 400, height: 601))
        XCTAssertEqual(frames.leaves[a], CGRect(x: 621, y: 40, width: 400, height: 601))
    }

    func testAColumnStacksTopDown() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .down)
        let frames = layout.frames(in: bounds)
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 0, y: 0, width: 801, height: 300))
        XCTAssertEqual(frames.leaves[a], CGRect(x: 0, y: 301, width: 801, height: 300))
        XCTAssertEqual(frames.dividers.first?.axis, .column)
        XCTAssertEqual(frames.dividers.first?.rect, CGRect(x: 0, y: 300, width: 801, height: 1))
    }

    /// A nested split's dividers say the way down to it.
    func testDividersCarryThePathToTheirSplit() {
        let frames = grid().frames(in: bounds)
        XCTAssertEqual(frames.leaves.count, 4)
        XCTAssertEqual(frames.dividers.count, 3)
        XCTAssertEqual(Set(frames.dividers.map(\.path)), [[], [0], [1]])
        let right = frames.dividers.first { $0.path == [1] }
        XCTAssertEqual(right?.axis, .column)
        XCTAssertEqual(right?.rect, CGRect(x: 401, y: 300, width: 400, height: 1))
        XCTAssertEqual(frames.leaves[c], CGRect(x: 401, y: 301, width: 400, height: 300))
    }

    /// Every frame on whole points, whatever the weights and the width, and
    /// the leaves and dividers together exactly the area: no gap, no overlap.
    func testFramesAreWholePointsAndFillTheArea() {
        var layout = grid()
        layout.insert(Leaf.pane(UUID()), beside: b, on: .right)
        layout.moveDivider(at: [], index: 0, to: 333, in: bounds)
        for width in stride(from: 700, through: 1500, by: 37) {
            for height in [500, 601, 777] {
                let area = CGRect(x: 0, y: 0, width: width, height: height)
                let frames = layout.frames(in: area)
                var covered: CGFloat = 0
                for rect in Array(frames.leaves.values) + frames.dividers.map(\.rect) {
                    XCTAssertTrue(isWhole(rect), "\(width)×\(height): \(rect)")
                    XCTAssertTrue(area.contains(rect), "\(width)×\(height): \(rect)")
                    covered += rect.width * rect.height
                }
                // Where a row's divider crosses a column's there is nothing
                // to double count: each divider is inside its own split.
                XCTAssertEqual(covered, area.width * area.height, "\(width)×\(height)")
                let rects = Array(frames.leaves.values)
                for (index, rect) in rects.enumerated() {
                    for other in rects[(index + 1)...] {
                        XCTAssertFalse(rect.intersects(other), "\(width)×\(height): \(rect) over \(other)")
                    }
                }
            }
        }
    }

    /// An odd point goes to one pane whole, not half to each.
    func testAnOddPointIsNotShared() {
        let frames = row(.main, a).frames(in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(frames.leaves[.main]?.width, 400)
        XCTAssertEqual(frames.leaves[a]?.width, 399)
        XCTAssertEqual(frames.leaves[a]?.minX, 401)
    }

    /// A pane whose share is under its minimum is given the minimum, taken
    /// from the others.
    func testASmallShareIsRaisedToTheMinimum() {
        let layout = SplitLayout(root: .split(.row, [Part(node: .leaf(.main), weight: 0.9),
                                                     Part(node: .leaf(a), weight: 0.1)]))
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1001, height: 600))
        XCTAssertEqual(frames.leaves[a]?.width, 160)
        XCTAssertEqual(frames.leaves[.main]?.width, 840)

        var stacked = SplitLayout(root: .split(.column, [Part(node: .leaf(.main), weight: 0.95),
                                                         Part(node: .leaf(a), weight: 0.05)]))
        XCTAssertEqual(stacked.frames(in: bounds).leaves[a]?.height, 100)
        stacked.equalize()
        XCTAssertEqual(stacked.frames(in: bounds).leaves[a]?.height, 300, "and not when it has room")
    }

    /// Raising one pane can leave the others just over theirs, at half a
    /// point: rounding must not take the last one under.
    func testRoundingNeverTakesAPaneUnderItsMinimum() {
        let layout = SplitLayout(root: .split(.row, [Part(node: .leaf(.main), weight: 0.4),
                                                     Part(node: .leaf(a), weight: 0.4),
                                                     Part(node: .leaf(b), weight: 0.2)]))
        for width in 482...520 {
            let frames = layout.frames(in: CGRect(x: 0, y: 0, width: width, height: 400))
            for leaf in [Leaf.main, a, b] {
                XCTAssertGreaterThanOrEqual(frames.leaves[leaf]?.width ?? 0, 160, "\(width)pt wide")
            }
            XCTAssertEqual(frames.leaves[b]?.maxX, CGFloat(width), "\(width)pt wide")
        }
    }

    /// A nested split needs room for all of its leaves, and gets it.
    func testANestedSplitsMinimumIsItsLeavesTogether() {
        let metrics = SplitLayout.Metrics()
        let nested = Node.split(.row, [Part(node: .leaf(a), weight: 0.5), Part(node: .leaf(b), weight: 0.5)])
        XCTAssertEqual(SplitLayout.minimumSize(of: nested, metrics: metrics), CGSize(width: 321, height: 100))
        XCTAssertEqual(SplitLayout.minimumSize(of: .split(.column, [Part(node: nested, weight: 0.5),
                                                                    Part(node: .leaf(c), weight: 0.5)]),
                                               metrics: metrics),
                       CGSize(width: 321, height: 201))

        // Main over (a | b), the bottom given a sliver: it is still 100 high.
        let layout = SplitLayout(root: .split(.column, [Part(node: .leaf(.main), weight: 0.99),
                                                        Part(node: nested, weight: 0.01)]))
        let frames = layout.frames(in: bounds)
        XCTAssertEqual(frames.leaves[a]?.height, 100)
        XCTAssertEqual(frames.leaves[b]?.height, 100)
        XCTAssertEqual(frames.leaves[.main]?.height, 500)
    }

    /// With no room for the minimums the panes share what there is: nothing
    /// negative, nothing outside the area, still whole points.
    func testTooLittleRoomIsSharedNotOverdrawn() {
        let layout = row(.main, a, b)
        for width in [0, 1, 2, 3, 50, 200, 479] {
            let area = CGRect(x: 0, y: 0, width: width, height: 30)
            let frames = layout.frames(in: area)
            XCTAssertEqual(frames.leaves.count, 3)
            var total: CGFloat = 0
            for rect in frames.leaves.values {
                XCTAssertGreaterThanOrEqual(rect.width, 0, "\(width)pt")
                XCTAssertTrue(isWhole(rect), "\(width)pt: \(rect)")
                total += rect.width
            }
            XCTAssertEqual(total, CGFloat(max(width - 2, 0)), "\(width)pt: the room less the dividers")
        }
        // Equal shares of what there is, as near as whole points allow.
        let widths = [Leaf.main, a, b].map { layout.frames(in: CGRect(x: 0, y: 0, width: 202, height: 30)).leaves[$0]!.width }
        XCTAssertEqual(widths.reduce(0, +), 200)
        XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1)
    }

    func testMetricsSetTheGapAndTheMinimum() {
        let metrics = SplitLayout.Metrics(gap: 8, minimum: CGSize(width: 300, height: 50))
        let layout = SplitLayout(root: .split(.row, [Part(node: .leaf(.main), weight: 0.9),
                                                     Part(node: .leaf(a), weight: 0.1)]))
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1008, height: 400), metrics: metrics)
        XCTAssertEqual(frames.leaves[a]?.width, 300)
        XCTAssertEqual(frames.dividers.first?.rect, CGRect(x: 700, y: 0, width: 8, height: 400))
        XCTAssertEqual(frames.leaves[a]?.minX, 708)
    }

    // MARK: - Dragging a divider

    private let wide = CGRect(x: 0, y: 0, width: 1202, height: 600)

    func testMovingADividerMovesOnlyItsNeighbours() {
        var layout = row(.main, a, b)
        let before = layout.frames(in: wide)
        XCTAssertEqual(before.leaves[.main]?.width, 400)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 300, in: wide))
        let frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 0, y: 0, width: 300, height: 600))
        XCTAssertEqual(frames.leaves[a], CGRect(x: 301, y: 0, width: 500, height: 600))
        XCTAssertEqual(frames.leaves[b], before.leaves[b], "the third pane didn't move")
        XCTAssertEqual(frames.dividers.first { $0.index == 0 }?.rect.minX, 300, "it starts where it was put")
        assertWellFormed(layout)

        // The second divider: only a and b.
        XCTAssertTrue(layout.moveDivider(at: [], index: 1, to: 901, in: wide))
        let after = layout.frames(in: wide)
        XCTAssertEqual(after.leaves[.main], frames.leaves[.main])
        XCTAssertEqual(after.leaves[a]?.width, 600)
        XCTAssertEqual(after.leaves[b], CGRect(x: 902, y: 0, width: 300, height: 600))
    }

    /// No further than either neighbour's minimum.
    func testADividerStopsAtItsNeighboursMinimums() {
        var layout = row(.main, a, b)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: -500, in: wide))
        var frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.main]?.width, 160)
        XCTAssertEqual(frames.leaves[a]?.width, 640)
        XCTAssertEqual(frames.leaves[b]?.width, 400)

        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 5000, in: wide))
        frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.main]?.width, 640)
        XCTAssertEqual(frames.leaves[a]?.width, 160)
        XCTAssertEqual(frames.leaves[b]?.width, 400)
    }

    /// A neighbour that is a split stops at the room all its leaves need.
    func testADividerStopsAtANestedSplitsMinimum() {
        // Main beside a over (b | c): the right side needs room for b and c
        // side by side, though a alone would need less.
        var sideways = SplitLayout(root: .split(.row, [
            Part(node: .leaf(.main), weight: 0.5),
            Part(node: .split(.column, [Part(node: .leaf(a), weight: 0.5), Part(node: .split(.row, [
                Part(node: .leaf(b), weight: 0.5), Part(node: .leaf(c), weight: 0.5),
            ]), weight: 0.5)]), weight: 0.5),
        ]))
        sideways.moveDivider(at: [], index: 0, to: 5000, in: wide)
        let frames = sideways.frames(in: wide)
        XCTAssertEqual(frames.leaves[a]?.width, 321, "b and c, 160 each, and their divider")
        XCTAssertEqual(frames.leaves[.main]?.width, 880)
    }

    func testADividerInANestedSplitIsFoundByItsPath() {
        var layout = grid()
        // The right column's divider: between a and c.
        XCTAssertTrue(layout.moveDivider(at: [1], index: 0, to: 200, in: bounds))
        let frames = layout.frames(in: bounds)
        XCTAssertEqual(frames.leaves[a], CGRect(x: 401, y: 0, width: 400, height: 200))
        XCTAssertEqual(frames.leaves[c], CGRect(x: 401, y: 201, width: 400, height: 400))
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 0, y: 0, width: 400, height: 300), "the other column is as it was")
        XCTAssertEqual(frames.leaves[b], CGRect(x: 0, y: 301, width: 400, height: 300))
        assertWellFormed(layout)
    }

    /// The position is in the space the bounds are in, not from the split's
    /// own edge.
    func testADividerPositionIsInTheBoundsSpace() {
        let offset = CGRect(x: 220, y: 40, width: 801, height: 601)
        var layout = grid()
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 520, in: offset))
        XCTAssertEqual(layout.frames(in: offset).leaves[.main]?.width, 300)
        XCTAssertTrue(layout.moveDivider(at: [1], index: 0, to: 240, in: offset))
        XCTAssertEqual(layout.frames(in: offset).leaves[a]?.height, 200)
    }

    func testADividerThatDidntMoveSaysSo() {
        var layout = row(.main, a, b)
        let before = layout
        XCTAssertFalse(layout.moveDivider(at: [], index: 0, to: 400, in: wide), "where it is already")
        XCTAssertFalse(layout.moveDivider(at: [], index: 2, to: 100, in: wide), "no such divider")
        XCTAssertFalse(layout.moveDivider(at: [], index: -1, to: 100, in: wide))
        XCTAssertFalse(layout.moveDivider(at: [5], index: 0, to: 100, in: wide), "no such split")
        XCTAssertFalse(layout.moveDivider(at: [0], index: 0, to: 100, in: wide), "a leaf has no divider")
        XCTAssertEqual(layout, before)
        var unsplit = SplitLayout()
        XCTAssertFalse(unsplit.moveDivider(at: [], index: 0, to: 100, in: wide))
    }

    /// A pane held at its minimum keeps the size it is drawn at when another
    /// divider of its row is dragged.
    func testAPaneHeldAtItsMinimumStaysWhenAnotherDividerMoves() {
        var layout = SplitLayout(root: .split(.row, [Part(node: .leaf(.main), weight: 0.45),
                                                     Part(node: .leaf(a), weight: 0.45),
                                                     Part(node: .leaf(b), weight: 0.1)]))
        XCTAssertEqual(layout.frames(in: wide).leaves[b]?.width, 160)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 300, in: wide))
        let frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[b]?.width, 160)
        XCTAssertEqual(frames.leaves[.main]?.width, 300)
        XCTAssertEqual(frames.leaves[a]?.width, 740)
    }

    /// With no room for both minimums the divider still moves, each side
    /// keeping a sliver.
    func testADividerIsNeverStuckInTooLittleRoom() {
        var layout = row(.main, a)
        let narrow = CGRect(x: 0, y: 0, width: 201, height: 300)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 40, in: narrow))
        XCTAssertEqual(layout.frames(in: narrow).leaves[.main]?.width, 40)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: -90, in: narrow))
        XCTAssertEqual(layout.frames(in: narrow).leaves[.main]?.width, 1)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 900, in: narrow))
        XCTAssertEqual(layout.frames(in: narrow).leaves[a]?.width, 1)
        assertWellFormed(layout)
    }

    /// With a point between them there is no sliver for each side, and
    /// nothing moves: a weight of zero would read back as an equal share.
    /// Laid out in one point, 0.3 and 0.7 come to 0 and 1.
    func testADividerWithNoRoomForTwoSaysNoZero() {
        var layout = row([(.main, 0.3), (a, 0.7)])
        let none = CGRect(x: 0, y: 0, width: 2, height: 300)
        XCTAssertEqual(layout.frames(in: none).leaves[.main]?.width, 0)
        let before = layout
        XCTAssertFalse(layout.moveDivider(at: [], index: 0, to: 2, in: none))
        XCTAssertFalse(layout.resize(.main, to: 1, in: none))
        XCTAssertEqual(layout, before)
        assertWellFormed(layout)
    }

    /// A part with no room that a drag does not move does not hold the
    /// others still. Three panes in too little room for their minimums, the
    /// first left a sliver by an earlier drag, rounds to nothing once the
    /// window narrows: 0.3, 149.85 and 149.85 points come to 0, 150 and 150.
    /// The divider between the other two still moves, and so does a resize,
    /// and the first keeps the weight it had rather than a zero.
    func testASliverRoundedToNothingDoesNotStickTheOtherDividers() {
        var layout = row([(.main, 0.001), (a, 0.4995), (b, 0.4995)])
        let narrow = CGRect(x: 0, y: 0, width: 302, height: 300)
        var frames = layout.frames(in: narrow)
        XCTAssertEqual(frames.leaves[.main]?.width, 0)
        XCTAssertEqual(frames.leaves[a]?.width, 150)
        XCTAssertEqual(frames.leaves[b]?.width, 150)

        XCTAssertTrue(layout.moveDivider(at: [], index: 1, to: 101, in: narrow))
        frames = layout.frames(in: narrow)
        XCTAssertEqual(frames.leaves[a]?.width, 100)
        XCTAssertEqual(frames.leaves[b]?.width, 200)
        XCTAssertEqual(parts(of: layout).first?.weight ?? 0, 0.001, accuracy: 1e-9)
        assertWellFormed(layout)

        XCTAssertTrue(layout.resize(a, to: 120, in: narrow))
        frames = layout.frames(in: narrow)
        XCTAssertEqual(frames.leaves[a]?.width, 120)
        XCTAssertEqual(frames.leaves[b]?.width, 180)
        XCTAssertEqual(parts(of: layout).first?.weight ?? 0, 0.001, accuracy: 1e-9)
        assertWellFormed(layout)
    }

    // MARK: Which divider a drag holds

    /// A divider is known by what it stands between, not by its sizes: a
    /// drag that moves it is still holding the same one.
    func testADividerIsKnownByWhatItStandsBetween() throws {
        var layout = grid()
        let dividers = layout.frames(in: bounds).dividers
        let across = try XCTUnwrap(dividers.first { $0.path.isEmpty })
        let under = try XCTUnwrap(dividers.first { $0.path == [0] })
        XCTAssertEqual(layout.sides(of: across),
                       SplitLayout.DividerSides(axis: .row, before: [.main, b], after: [a, c]))
        XCTAssertEqual(layout.sides(of: under),
                       SplitLayout.DividerSides(axis: .column, before: [.main], after: [b]))

        let before = layout.sides(of: across)
        XCTAssertTrue(layout.moveDivider(at: across.path, index: across.index, to: 300, in: bounds))
        XCTAssertEqual(layout.sides(of: across), before, "moved, and the same divider")
    }

    /// The tree changing during a drag: a split closed beside the divider
    /// held puts the same place in the tree between other splits. This is
    /// the drag that went on with the wrong divider: holding main|a, a's
    /// shell exited, and the next step moved main|side, which took the
    /// column from 400pt to 801 and was remembered.
    func testASplitClosedUnderADragChangesWhatItsDividerStandsBetween() {
        var layout = row(.main, a, .side)
        let held = layout.frames(in: bounds).dividers[0]
        let sides = layout.sides(of: held)
        XCTAssertEqual(sides?.after, [a])
        layout.remove(a)
        XCTAssertEqual(layout.frames(in: bounds).dividers.count, 1)
        XCTAssertEqual(layout.sides(of: held)?.after, [.side], "the same place, another divider")
        XCTAssertNotEqual(layout.sides(of: held), sides)

        // The last divider of the three, with nothing after it now.
        var three = row(.main, a, .side)
        let last = three.frames(in: bounds).dividers[1]
        three.remove(a)
        XCTAssertNil(three.sides(of: last))
    }

    /// A split made elsewhere in the tree leaves a divider it doesn't touch
    /// as it was; one made beside it changes what it stands between.
    func testASplitMadeDuringADrag() throws {
        var layout = grid()
        let dividers = layout.frames(in: bounds).dividers
        let across = try XCTUnwrap(dividers.first { $0.path.isEmpty })
        let under = try XCTUnwrap(dividers.first { $0.path == [0] })
        let acrossSides = layout.sides(of: across), underSides = layout.sides(of: under)
        let d = Leaf.pane(UUID())
        XCTAssertTrue(layout.insert(d, beside: c, on: .right))
        XCTAssertEqual(layout.sides(of: under), underSides, "main over b, untouched")
        XCTAssertNotEqual(layout.sides(of: across), acrossSides, "d joined the right of it")
    }

    /// A place that is no divider of this tree has no sides: a path past a
    /// leaf, a part out of range, or the wrong axis.
    func testAPlaceThatIsNoDividerHasNoSides() {
        let layout = row(.main, a)
        let rect = CGRect.zero
        XCTAssertNil(layout.sides(of: .init(path: [0], index: 0, axis: .row, rect: rect)))
        XCTAssertNil(layout.sides(of: .init(path: [], index: 1, axis: .row, rect: rect)))
        XCTAssertNil(layout.sides(of: .init(path: [], index: 0, axis: .column, rect: rect)))
        XCTAssertNil(SplitLayout().sides(of: .init(path: [], index: 0, axis: .row, rect: rect)))
    }

    // MARK: - Neighbours

    /// Main | a over b | c: every direction from every pane.
    func testNeighboursInATwoByTwo() {
        let layout = grid()
        let expected: [(Leaf, SplitLayout.Edge, Leaf?)] = [
            (.main, .right, a), (.main, .down, b), (.main, .left, nil), (.main, .up, nil),
            (a, .left, .main), (a, .down, c), (a, .right, nil), (a, .up, nil),
            (b, .up, .main), (b, .right, c), (b, .left, nil), (b, .down, nil),
            (c, .up, a), (c, .left, b), (c, .right, nil), (c, .down, nil),
        ]
        for (leaf, edge, neighbour) in expected {
            XCTAssertEqual(layout.neighbour(of: leaf, toward: edge, in: bounds), neighbour, "\(edge)")
        }
    }

    /// Main the whole height on the left, a over b on the right.
    func testNeighboursInAnLShape() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .right)
        layout.insert(b, beside: a, on: .down)
        XCTAssertEqual(layout.neighbour(of: .main, toward: .right, in: bounds), a, "a tie goes to the upper one")
        XCTAssertEqual(layout.neighbour(of: a, toward: .left, in: bounds), .main)
        XCTAssertEqual(layout.neighbour(of: b, toward: .left, in: bounds), .main)
        XCTAssertEqual(layout.neighbour(of: a, toward: .down, in: bounds), b)
        XCTAssertEqual(layout.neighbour(of: b, toward: .up, in: bounds), a)
        XCTAssertNil(layout.neighbour(of: .main, toward: .left, in: bounds))
        XCTAssertNil(layout.neighbour(of: .main, toward: .down, in: bounds))
        XCTAssertNil(layout.neighbour(of: a, toward: .right, in: bounds))
        XCTAssertNil(layout.neighbour(of: b, toward: .down, in: bounds))

        // The one that lines up best: with b the taller, main's right is b.
        layout.moveDivider(at: [1], index: 0, to: 150, in: bounds)
        XCTAssertEqual(layout.neighbour(of: .main, toward: .right, in: bounds), b)
    }

    /// Main across the top, a beside b under it: a tie goes to the left one.
    func testATieSidewaysGoesToTheLeftOne() {
        var layout = SplitLayout()
        layout.insert(a, beside: .main, on: .down)
        layout.insert(b, beside: a, on: .right)
        XCTAssertEqual(layout.neighbour(of: .main, toward: .down, in: bounds), a)
        XCTAssertEqual(layout.neighbour(of: b, toward: .up, in: bounds), .main)
        XCTAssertEqual(layout.neighbour(of: b, toward: .left, in: bounds), a)
    }

    func testNoNeighbourOfWhatIsntThere() {
        XCTAssertNil(grid().neighbour(of: .pane(UUID()), toward: .left, in: bounds))
        XCTAssertNil(SplitLayout().neighbour(of: .main, toward: .right, in: bounds))
    }

    // MARK: - Dropping a tab on a pane

    private let pane = CGRect(x: 100, y: 50, width: 400, height: 400)

    /// A quarter of the pane along each edge is that edge's band.
    func testADropNearAnEdgeSplitsOnThatEdge() {
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 110, y: 250), in: pane), .left)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 490, y: 250), in: pane), .right)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 300, y: 60), in: pane), .up)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 300, y: 440), in: pane), .down)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 199, y: 250), in: pane), .left, "just inside the band")
    }

    func testADropInTheMiddleIsIntoThePane() {
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 300, y: 250), in: pane))
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 200, y: 250), in: pane), "the band's inner edge is the middle")
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 201, y: 151), in: pane))
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 399, y: 349), in: pane))
    }

    /// In a corner two bands overlap: the one the point is deeper into.
    func testInACornerTheDeeperEdgeWins() {
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 110, y: 80), in: pane), .left)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 130, y: 60), in: pane), .up)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 490, y: 420), in: pane), .right)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 470, y: 440), in: pane), .down)
    }

    func testADropOutsideThePaneIsNothing() {
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 99, y: 250), in: pane))
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 300, y: 451), in: pane))
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 10, y: 10), in: .zero))
    }

    /// A small pane still has a middle, and a large one's band stops at 160.
    func testTheBandIsBounded() {
        let small = CGRect(x: 0, y: 0, width: 90, height: 90)
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 45, y: 45), in: small))
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 29, y: 45), in: small), .left, "a third of it at most")
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 31, y: 45), in: small))

        // A quarter of 200 is 50; of 100 it would be 25, and the band is 32.
        let narrow = CGRect(x: 0, y: 0, width: 100, height: 800)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 30, y: 400), in: narrow), .left)
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 34, y: 400), in: narrow))

        let large = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 150, y: 700), in: large), .left)
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 170, y: 700), in: large))
        XCTAssertEqual(SplitLayout.dropEdge(at: CGPoint(x: 1000, y: 1250), in: large), .down)
        XCTAssertNil(SplitLayout.dropEdge(at: CGPoint(x: 1000, y: 1230), in: large))
    }

    /// What lights up before the drop: half the pane, on whole points, the
    /// two halves of one axis meeting or overlapping by the odd point.
    func testHalf() {
        let frame = CGRect(x: 10, y: 20, width: 301, height: 201)
        XCTAssertEqual(SplitLayout.half(of: frame, on: .left), CGRect(x: 10, y: 20, width: 151, height: 201))
        XCTAssertEqual(SplitLayout.half(of: frame, on: .right), CGRect(x: 160, y: 20, width: 151, height: 201))
        XCTAssertEqual(SplitLayout.half(of: frame, on: .up), CGRect(x: 10, y: 20, width: 301, height: 101))
        XCTAssertEqual(SplitLayout.half(of: frame, on: .down), CGRect(x: 10, y: 120, width: 301, height: 101))
        for edge in SplitLayout.Edge.allCases {
            XCTAssertTrue(frame.contains(SplitLayout.half(of: frame, on: edge)), "\(edge)")
        }
    }

    func testEdges() {
        XCTAssertEqual(SplitLayout.Edge.left.axis, .row)
        XCTAssertEqual(SplitLayout.Edge.right.axis, .row)
        XCTAssertEqual(SplitLayout.Edge.up.axis, .column)
        XCTAssertEqual(SplitLayout.Edge.down.axis, .column)
        XCTAssertEqual(SplitLayout.Edge.allCases.filter(\.isLeading), [.left, .up])
        XCTAssertEqual(SplitLayout.Axis.row.crossed, .column)
        XCTAssertEqual(SplitLayout.Axis.column.crossed, .row)
    }

    // MARK: - Saving

    func testALayoutRoundTrips() throws {
        var uneven = grid()
        uneven.moveDivider(at: [], index: 0, to: 333, in: bounds)
        uneven.moveDivider(at: [1], index: 0, to: 123, in: bounds)
        for layout in [SplitLayout(), row(.main, a), row(a, .main, b), grid(), uneven] {
            let data = try JSONEncoder().encode(layout)
            XCTAssertEqual(try JSONDecoder().decode(SplitLayout.self, from: data), layout)
        }
    }

    /// The form in the file: a leaf by name, a split by its axis and parts.
    func testTheSavedForm() throws {
        let id = UUID()
        let json = """
        {"axis":"row","parts":[{"node":{"leaf":"main"},"weight":0.75},
                               {"node":{"leaf":"\(id.uuidString)"},"weight":0.25}]}
        """
        let layout = try JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.leaves, [.main, .pane(id)])
        XCTAssertEqual(parts(of: layout).map(\.weight), [0.75, 0.25])
        XCTAssertEqual(try JSONDecoder().decode(SplitLayout.self, from: Data(#"{"leaf":"main"}"#.utf8)),
                       SplitLayout())
    }

    /// What isn't a layout doesn't decode as one: whoever reads the file
    /// decides what a session without one gets.
    func testADamagedLayoutDoesNotDecode() {
        for json in [#"{"leaf":"somewhere"}"#, #"{"axis":"diagonal","parts":[]}"#, #"{"axis":"row"}"#,
                     #"{"axis":"row","parts":[{"node":{"leaf":"nope"},"weight":1}]}"#, #"[]"#, #""main""#] {
            XCTAssertThrowsError(try JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8)), json)
        }
    }

    func testLeafRawValues() {
        let id = UUID()
        XCTAssertEqual(Leaf.main.rawValue, "main")
        XCTAssertEqual(Leaf(rawValue: "main"), .main)
        XCTAssertEqual(Leaf.pane(id).rawValue, id.uuidString)
        XCTAssertEqual(Leaf(rawValue: id.uuidString), .pane(id))
        XCTAssertEqual(Leaf.side.rawValue, "side")
        XCTAssertEqual(Leaf(rawValue: "side"), .side)
        XCTAssertEqual(Leaf.bottom.rawValue, "bottom")
        XCTAssertEqual(Leaf(rawValue: "bottom"), .bottom)
        XCTAssertNil(Leaf(rawValue: "top"))
        XCTAssertNil(Leaf(rawValue: ""))
    }

    /// The column and the strip are saved in the tree by name, like the main
    /// row.
    func testATreeWithTheColumnAndTheStripRoundTrips() throws {
        var layout = SplitLayout()
        layout.insert(.side, atRootEdge: .right, share: 1.0 / 3)
        layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
        layout.insert(a, beside: .main, on: .right)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(SplitLayout.self, from: data), layout)

        let json = """
        {"axis":"row","parts":[{"node":{"leaf":"side"},"weight":0.25},
                               {"node":{"axis":"column","parts":[{"node":{"leaf":"main"},"weight":0.7},
                                                                 {"node":{"leaf":"bottom"},"weight":0.3}]},
                                "weight":0.75}]}
        """
        let read = try JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8))
        XCTAssertEqual(read.leaves, [.side, .main, .bottom])
        XCTAssertEqual(read, read.normalized(), "a tree with them in it is a good tree")
    }

    // MARK: - The column and the strip

    /// A row of `leaves` with these weights.
    private func row(_ parts: [(Leaf, Double)]) -> SplitLayout {
        SplitLayout(root: .split(.row, parts.map { Part(node: .leaf($0.0), weight: $0.1) }))
    }

    private func assertWeights(_ layout: SplitLayout, _ expected: [Double],
                               file: StaticString = #filePath, line: UInt = #line) {
        let weights = parts(of: layout).map(\.weight)
        XCTAssertEqual(weights.count, expected.count, "\(weights)", file: file, line: line)
        for (weight, wanted) in zip(weights, expected) {
            XCTAssertEqual(weight, wanted, accuracy: 1e-9, "\(weights)", file: file, line: line)
        }
    }

    func testWhatIsInTheTree() {
        var layout = SplitLayout()
        XCTAssertFalse(layout.hasPanes)
        layout.insert(.side, atRootEdge: .right, share: 0.25)
        layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
        XCTAssertTrue(layout.isSplit, "more than the main row")
        XCTAssertFalse(layout.hasPanes, "the column and the strip are nobody's split")
        XCTAssertTrue(layout.contains(.side) && layout.contains(.bottom))
        XCTAssertFalse(layout.contains(a))
        layout.insert(a, beside: .bottom, on: .right)
        XCTAssertTrue(layout.hasPanes)
        XCTAssertTrue(layout.contains(a))
        XCTAssertEqual(layout.leaves, [.main, .bottom, a, .side])
        assertWellFormed(layout)
    }

    /// A leaf's share of the whole along an axis: its part of every split on
    /// the way down that runs that way.
    func testShareOfTheWhole() {
        var layout = SplitLayout()
        XCTAssertEqual(layout.share(of: .main, along: .row), 1)
        XCTAssertNil(layout.share(of: .side, along: .row))
        layout.insert(.side, atRootEdge: .right, share: 0.25)
        layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
        layout.insert(a, beside: .bottom, on: .right)
        XCTAssertEqual(layout.share(of: .side, along: .row) ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(layout.share(of: .side, along: .column) ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(layout.share(of: .main, along: .row) ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(layout.share(of: .bottom, along: .column) ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(layout.share(of: a, along: .row) ?? 0, 0.375, accuracy: 1e-9, "half of the strip's row")
        XCTAssertEqual(layout.share(of: a, along: .column) ?? 0, 0.3, accuracy: 1e-9)
    }

    // MARK: At the outer edge

    func testALeafAtTheOuterEdgeOfTheMainRowAlone() {
        var right = SplitLayout()
        XCTAssertTrue(right.insert(.side, atRootEdge: .right, share: 1.0 / 3))
        XCTAssertEqual(right.leaves, [.main, .side])
        assertWeights(right, [2.0 / 3, 1.0 / 3])
        guard case .split(.row, _) = right.root else { return XCTFail("\(right.root)") }

        var left = SplitLayout()
        XCTAssertTrue(left.insert(.side, atRootEdge: .left, share: 1.0 / 3))
        XCTAssertEqual(left.leaves, [.side, .main])
        assertWeights(left, [1.0 / 3, 2.0 / 3])

        var under = SplitLayout()
        XCTAssertTrue(under.insert(.bottom, atRootEdge: .down, share: 0.3))
        XCTAssertEqual(under.root, .split(.column, [Part(node: .leaf(.main), weight: 0.7),
                                                    Part(node: .leaf(.bottom), weight: 0.3)]))
    }

    /// A root that already runs that way gets one more part, and everybody
    /// in it is scaled to what is left.
    func testALeafAtTheOuterEdgeOfARow() {
        var right = row(.main, a)
        XCTAssertTrue(right.insert(.side, atRootEdge: .right, share: 0.25))
        XCTAssertEqual(right.leaves, [.main, a, .side])
        assertWeights(right, [0.375, 0.375, 0.25])
        assertWellFormed(right)

        var left = row([(.main, 0.8), (a, 0.2)])
        XCTAssertTrue(left.insert(.side, atRootEdge: .left, share: 0.5))
        XCTAssertEqual(left.leaves, [.side, .main, a])
        assertWeights(left, [0.5, 0.4, 0.1])
    }

    /// A root that runs the other way becomes one part of a new split: the
    /// new leaf runs the whole length of everything else.
    func testALeafAtTheOuterEdgeOfAColumn() {
        var layout = SplitLayout()
        layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
        let column = layout.root
        XCTAssertTrue(layout.insert(.side, atRootEdge: .right, share: 1.0 / 3))
        XCTAssertEqual(layout.leaves, [.main, .bottom, .side])
        assertWeights(layout, [2.0 / 3, 1.0 / 3])
        XCTAssertEqual(parts(of: layout).first?.node, column, "what was there is as it was")
        let frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.side]?.height, 600, "beside the main row and the strip both")
        assertWellFormed(layout)

        // And along a column root, one more part of it.
        var stacked = SplitLayout()
        stacked.insert(.bottom, beside: .main, on: .down, share: 0.3)
        XCTAssertTrue(stacked.insert(a, atRootEdge: .down, share: 0.5))
        XCTAssertEqual(stacked.leaves, [.main, .bottom, a])
        assertWeights(stacked, [0.35, 0.15, 0.5])
        XCTAssertTrue(stacked.insert(b, atRootEdge: .up, share: 0.2))
        XCTAssertEqual(stacked.leaves, [b, .main, .bottom, a])
        assertWeights(stacked, [0.2, 0.28, 0.12, 0.4])
    }

    func testAShareAtTheOuterEdgeLeavesBothSidesSomething() {
        for (asked, given) in [(0.0, 0.05), (-3, 0.05), (7, 0.95), (1, 0.95), (Double.nan, 0.5), (0.4, 0.4)] {
            var layout = SplitLayout()
            XCTAssertTrue(layout.insert(.side, atRootEdge: .right, share: asked))
            assertWeights(layout, [1 - given, given])
        }
        var layout = row(.main, a)
        XCTAssertTrue(layout.insert(.side, atRootEdge: .right, share: 0.25))
        let before = layout
        XCTAssertFalse(layout.insert(.side, atRootEdge: .left, share: 0.5), "already in the tree")
        XCTAssertFalse(layout.insert(a, atRootEdge: .down, share: 0.5))
        XCTAssertEqual(layout, before)
    }

    // MARK: Beside a leaf, at a share

    func testALeafBesideAnotherAtAShare() {
        var strip = SplitLayout()
        XCTAssertTrue(strip.insert(.bottom, beside: .main, on: .down, share: 0.3))
        XCTAssertEqual(strip.root, .split(.column, [Part(node: .leaf(.main), weight: 0.7),
                                                    Part(node: .leaf(.bottom), weight: 0.3)]))

        // Among equal siblings it still takes only its share of the one it
        // is beside: nobody else moves.
        var after = row(.main, a, b)
        XCTAssertTrue(after.insert(c, beside: a, on: .right, share: 0.25))
        XCTAssertEqual(after.leaves, [.main, a, c, b])
        assertWeights(after, [1.0 / 3, 0.25, 1.0 / 12, 1.0 / 3])
        assertWellFormed(after)

        var before = row(.main, a, b)
        XCTAssertTrue(before.insert(c, beside: a, on: .left, share: 0.25))
        XCTAssertEqual(before.leaves, [.main, c, a, b])
        assertWeights(before, [1.0 / 3, 1.0 / 12, 0.25, 1.0 / 3])

        // Across the parent's axis the leaf becomes a split of the two.
        var nested = row(.main, a)
        XCTAssertTrue(nested.insert(.bottom, beside: .main, on: .down, share: 0.3))
        XCTAssertEqual(nested.leaves, [.main, .bottom, a])
        XCTAssertEqual(parts(of: nested).first?.node,
                       .split(.column, [Part(node: .leaf(.main), weight: 0.7),
                                        Part(node: .leaf(.bottom), weight: 0.3)]))

        let unchanged = nested
        XCTAssertFalse(nested.insert(c, beside: b, on: .right, share: 0.5), "beside nothing")
        XCTAssertFalse(nested.insert(a, beside: .main, on: .right, share: 0.5), "already there")
        XCTAssertEqual(nested, unchanged)
    }

    // MARK: Equal among the others

    /// One more split among equals makes them all equal, and the column
    /// keeps the share it has: it is not one of the equals.
    func testASplitAmongEqualsLeavesTheColumnItsShare() {
        var layout = row([(.main, 0.3), (a, 0.3), (.side, 0.4)])
        XCTAssertTrue(layout.insert(b, beside: a, on: .right))
        XCTAssertEqual(layout.leaves, [.main, a, b, .side])
        assertWeights(layout, [0.2, 0.2, 0.2, 0.4])

        // The first split beside the column: the main row was alone, which
        // is as equal as it gets.
        var first = row([(.main, 0.75), (.side, 0.25)])
        first.insert(a, beside: .main, on: .right)
        assertWeights(first, [0.375, 0.375, 0.25])

        // The same in a column, beside the strip.
        var stacked = SplitLayout(root: .split(.column, [Part(node: .leaf(.main), weight: 0.35),
                                                          Part(node: .leaf(a), weight: 0.35),
                                                          Part(node: .leaf(.bottom), weight: 0.3)]))
        stacked.insert(b, beside: .main, on: .up)
        XCTAssertEqual(stacked.leaves, [b, .main, a, .bottom])
        assertWeights(stacked, [0.7 / 3, 0.7 / 3, 0.7 / 3, 0.3])
    }

    /// Among unequal ones the new leaf halves the one it came from, as
    /// without a column.
    func testASplitAmongUnequalPanesBesideTheColumn() {
        var layout = row([(.main, 0.4), (a, 0.2), (.side, 0.4)])
        layout.insert(b, beside: a, on: .right)
        assertWeights(layout, [0.4, 0.1, 0.1, 0.4])
    }

    /// Split beside the column itself, the two halve what the column had.
    func testASplitBesideTheColumnHalvesTheColumn() {
        var layout = row([(.main, 0.3), (a, 0.3), (.side, 0.4)])
        XCTAssertTrue(layout.insert(b, beside: .side, on: .left))
        XCTAssertEqual(layout.leaves, [.main, a, b, .side])
        assertWeights(layout, [0.3, 0.3, 0.2, 0.2])
    }

    func testEqualizeLeavesTheColumnAndTheStripTheirShare() {
        var layout = row([(.main, 0.5), (a, 0.1), (.side, 0.4)])
        XCTAssertFalse(layout.isEqualized)
        layout.equalize()
        assertWeights(layout, [0.3, 0.3, 0.4])
        XCTAssertTrue(layout.isEqualized)
        XCTAssertTrue(row([(.main, 0.8), (.side, 0.2)]).isEqualized, "nobody to be unequal to")

        // In a split under the root too.
        var nested = SplitLayout(root: .split(.row, [
            Part(node: .split(.column, [Part(node: .leaf(.main), weight: 0.6), Part(node: .leaf(a), weight: 0.1),
                                        Part(node: .leaf(.bottom), weight: 0.3)]), weight: 0.75),
            Part(node: .leaf(.side), weight: 0.25),
        ]))
        XCTAssertFalse(nested.isEqualized)
        nested.equalize()
        XCTAssertTrue(nested.isEqualized)
        assertWeights(nested, [0.75, 0.25])
        guard case .split(.column, let inner)? = parts(of: nested).first?.node else { return XCTFail() }
        XCTAssertEqual(inner.map(\.weight)[0], 0.35, accuracy: 1e-9)
        XCTAssertEqual(inner.map(\.weight)[1], 0.35, accuracy: 1e-9)
        XCTAssertEqual(inner.map(\.weight)[2], 0.3, accuracy: 1e-9)
    }

    /// A pane closed beside the column gives its room back to the panes it
    /// took it from. The column itself gives its room to everybody.
    func testARemovedLeafsRoomBesideTheColumn() {
        var layout = row([(.main, 0.2), (a, 0.2), (b, 0.2), (.side, 0.4)])
        layout.remove(b)
        assertWeights(layout, [0.3, 0.3, 0.4])
        layout.remove(a)
        assertWeights(layout, [0.6, 0.4])

        var column = row([(.main, 0.4), (a, 0.2), (.side, 0.4)])
        XCTAssertTrue(column.remove(.side))
        XCTAssertEqual(column.leaves, [.main, a])
        assertWeights(column, [2.0 / 3, 1.0 / 3])

        // With only the column left beside it, the column takes it.
        var last = SplitLayout(root: .split(.column, [
            Part(node: .leaf(.main), weight: 0.5),
            Part(node: .split(.row, [Part(node: .leaf(a), weight: 0.5), Part(node: .leaf(.side), weight: 0.5)]),
                 weight: 0.5),
        ]))
        last.remove(a)
        XCTAssertEqual(last.root, .split(.column, [Part(node: .leaf(.main), weight: 0.5),
                                                   Part(node: .leaf(.side), weight: 0.5)]))
    }

    // MARK: - Hidden leaves

    /// A hidden leaf takes no room and has no divider. What is beside it
    /// shares its room, and nothing about the tree changes.
    func testAHiddenLeafTakesNoRoom() {
        let layout = row(.main, a, .side)
        let all = layout.frames(in: wide)
        XCTAssertEqual(all.leaves[.side], CGRect(x: 802, y: 0, width: 400, height: 600))
        XCTAssertEqual(all.dividers.count, 2)

        let frames = layout.frames(in: wide, hidden: [.side])
        XCTAssertNil(frames.leaves[.side])
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 0, y: 0, width: 601, height: 600))
        XCTAssertEqual(frames.leaves[a], CGRect(x: 602, y: 0, width: 600, height: 600))
        XCTAssertEqual(frames.dividers, [SplitLayout.Divider(path: [], index: 0, axis: .row,
                                                             rect: CGRect(x: 601, y: 0, width: 1, height: 600))])
        XCTAssertEqual(layout, row(.main, a, .side), "measuring changes nothing")
        XCTAssertEqual(layout.frames(in: wide), all, "shown again, it is where it was")
    }

    /// Unequal siblings share a hidden one's room in proportion.
    func testAHiddenLeafsRoomIsSharedInProportion() {
        let layout = row([(.main, 0.6), (a, 0.2), (.side, 0.2)])
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1201, height: 600), hidden: [.side])
        XCTAssertEqual(frames.leaves[.main]?.width, 900)
        XCTAssertEqual(frames.leaves[a]?.width, 300)
    }

    /// A divider is named for the part before it. The part after it is the
    /// next one on screen.
    func testADividerSkipsAHiddenPart() {
        let layout = row(.main, .side, a)
        let frames = layout.frames(in: wide, hidden: [.side])
        XCTAssertEqual(frames.dividers, [SplitLayout.Divider(path: [], index: 0, axis: .row,
                                                             rect: CGRect(x: 601, y: 0, width: 1, height: 600))])
        XCTAssertEqual(frames.leaves[a]?.minX, 602)

        // Hidden at the start: the one divider is after the second part.
        let leading = row(.side, .main, a).frames(in: wide, hidden: [.side])
        XCTAssertEqual(leading.dividers.map(\.index), [1])
        XCTAssertEqual(leading.leaves[.main]?.minX, 0)
    }

    func testOneLeafOnScreenFillsTheArea() {
        let layout = row(.main, .side)
        let frames = layout.frames(in: wide, hidden: [.side])
        XCTAssertEqual(frames.leaves, [.main: wide])
        XCTAssertTrue(frames.dividers.isEmpty)

        let nothing = layout.frames(in: wide, hidden: [.main, .side])
        XCTAssertTrue(nothing.leaves.isEmpty, "nothing on screen, no frames")
        XCTAssertTrue(nothing.dividers.isEmpty)
    }

    /// A part with nothing in it on screen is a hidden part, however deep.
    func testAHiddenSubtreeTakesNoRoom() {
        let layout = SplitLayout(root: .split(.row, [
            Part(node: .leaf(.main), weight: 0.5),
            Part(node: .split(.column, [Part(node: .leaf(.side), weight: 0.5),
                                        Part(node: .leaf(.bottom), weight: 0.5)]), weight: 0.5),
        ]))
        let both = layout.frames(in: wide, hidden: [.side, .bottom])
        XCTAssertEqual(both.leaves, [.main: wide])
        XCTAssertTrue(both.dividers.isEmpty)

        // One of the two: the other has the whole of their part.
        let one = layout.frames(in: wide, hidden: [.bottom])
        XCTAssertEqual(one.leaves[.main], CGRect(x: 0, y: 0, width: 601, height: 600))
        XCTAssertEqual(one.leaves[.side], CGRect(x: 602, y: 0, width: 600, height: 600))
        XCTAssertEqual(one.dividers.count, 1)
        XCTAssertEqual(one.dividers.first?.axis, .row)

        // Two rows, the lower one hidden whole: the upper one has the height.
        let rows = SplitLayout(root: .split(.column, [
            Part(node: .split(.row, [Part(node: .leaf(.main), weight: 0.5), Part(node: .leaf(a), weight: 0.5)]),
                 weight: 0.5),
            Part(node: .split(.row, [Part(node: .leaf(.side), weight: 0.5), Part(node: .leaf(.bottom), weight: 0.5)]),
                 weight: 0.5),
        ]))
        let upper = rows.frames(in: wide, hidden: [.side, .bottom])
        XCTAssertEqual(upper.leaves[.main], CGRect(x: 0, y: 0, width: 601, height: 600))
        XCTAssertEqual(upper.leaves[a], CGRect(x: 602, y: 0, width: 600, height: 600))
        XCTAssertEqual(upper.dividers.map(\.path), [[0]])
    }

    func testAHiddenLeafNeedsNoMinimum() {
        let layout = row(.main, a, .side)
        XCTAssertEqual(SplitLayout.minimumSize(of: layout.root, metrics: SplitLayout.Metrics()),
                       CGSize(width: 482, height: 100))
        XCTAssertEqual(SplitLayout.minimumSize(of: layout.root, metrics: SplitLayout.Metrics(), hidden: [.side]),
                       CGSize(width: 321, height: 100))
        XCTAssertEqual(SplitLayout.minimumSize(of: layout.root, metrics: SplitLayout.Metrics(),
                                               hidden: [.main, a, .side]), .zero)
        // 400 points is room for two minimums and not for three.
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frames = layout.frames(in: narrow, hidden: [.side])
        XCTAssertEqual(frames.leaves[.main]?.width, 200)
        XCTAssertEqual(frames.leaves[a]?.width, 199)
    }

    /// Hide a leaf, drag a divider, show it again: it has the share it had,
    /// and the others moved only by the drag.
    func testAHiddenLeafKeepsItsShareThroughADrag() {
        var layout = row(.main, a, .side)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 401, in: wide, hidden: [.side]))
        let dragged = layout.frames(in: wide, hidden: [.side])
        XCTAssertEqual(dragged.leaves[.main], CGRect(x: 0, y: 0, width: 401, height: 600))
        XCTAssertEqual(dragged.leaves[a], CGRect(x: 402, y: 0, width: 800, height: 600))
        XCTAssertEqual(parts(of: layout).last?.weight ?? 0, 1.0 / 3, accuracy: 1e-12, "the hidden one's weight")
        assertWellFormed(layout)

        let shown = layout.frames(in: wide)
        XCTAssertEqual(shown.leaves[.side], CGRect(x: 802, y: 0, width: 400, height: 600), "its share is back")
        // The other two have the rest, 401 to 800 as the drag left them.
        XCTAssertEqual(shown.leaves[.main]?.width, 267)
        XCTAssertEqual(shown.leaves[a]?.width, 533)
    }

    /// The divider between two parts with a hidden one between them moves
    /// those two, and a hidden part has no divider to move.
    func testADragAcrossAHiddenPart() {
        var layout = row(.main, .side, a)
        XCTAssertTrue(layout.moveDivider(at: [], index: 0, to: 300, in: wide, hidden: [.side]))
        let frames = layout.frames(in: wide, hidden: [.side])
        XCTAssertEqual(frames.leaves[.main]?.width, 300)
        XCTAssertEqual(frames.leaves[a], CGRect(x: 301, y: 0, width: 901, height: 600))
        XCTAssertEqual(parts(of: layout)[1].weight, 1.0 / 3, accuracy: 1e-12)

        let before = layout
        XCTAssertFalse(layout.moveDivider(at: [], index: 1, to: 500, in: wide, hidden: [.side]),
                       "the hidden part has no divider after it")
        XCTAssertFalse(layout.moveDivider(at: [], index: 2, to: 500, in: wide, hidden: [.side]),
                       "and the last one on screen has none")
        XCTAssertEqual(layout, before)
    }

    /// A divider further down is found in the room its split has while
    /// something beside it is hidden.
    func testADragInASplitBesideAHiddenLeaf() {
        var layout = SplitLayout(root: .split(.row, [
            Part(node: .leaf(.side), weight: 0.25),
            Part(node: .split(.column, [
                Part(node: .split(.row, [Part(node: .leaf(.main), weight: 0.5), Part(node: .leaf(a), weight: 0.5)]),
                     weight: 0.5),
                Part(node: .leaf(b), weight: 0.5),
            ]), weight: 0.75),
        ]))
        XCTAssertTrue(layout.moveDivider(at: [1, 0], index: 0, to: 300, in: wide, hidden: [.side]))
        let frames = layout.frames(in: wide, hidden: [.side])
        XCTAssertEqual(frames.leaves[.main], CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(frames.leaves[a], CGRect(x: 301, y: 0, width: 901, height: 300))
        XCTAssertEqual(parts(of: layout).first?.weight ?? 0, 0.25, accuracy: 1e-12)
        XCTAssertFalse(layout.moveDivider(at: [0], index: 0, to: 300, in: wide, hidden: [.side]),
                       "nothing to move inside a part that isn't on screen")
        assertWellFormed(layout)
    }

    func testAHiddenLeafIsNobodysNeighbour() {
        let layout = row(.main, .side, a)
        XCTAssertEqual(layout.neighbour(of: .main, toward: .right, in: wide), .side)
        XCTAssertEqual(layout.neighbour(of: .main, toward: .right, in: wide, hidden: [.side]), a)
        XCTAssertEqual(layout.neighbour(of: a, toward: .left, in: wide, hidden: [.side]), .main)
        XCTAssertNil(layout.neighbour(of: .side, toward: .left, in: wide, hidden: [.side]))
    }

    // MARK: - A size in points

    /// A leaf given a length in points: the others share the rest as they
    /// shared it before.
    func testResizingALeafToPoints() {
        var layout = row(.main, a, .side)
        XCTAssertTrue(layout.resize(.side, to: 440, in: wide))
        var frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.side], CGRect(x: 762, y: 0, width: 440, height: 600))
        XCTAssertEqual(frames.leaves[.main]?.width, 380)
        XCTAssertEqual(frames.leaves[a]?.width, 380)
        assertWellFormed(layout)
        XCTAssertFalse(layout.resize(.side, to: 440, in: wide), "already that long")

        var uneven = row([(.main, 0.5), (a, 0.25), (.side, 0.25)])
        XCTAssertTrue(uneven.resize(.side, to: 450, in: wide))
        frames = uneven.frames(in: wide)
        XCTAssertEqual(frames.leaves[.main]?.width, 500)
        XCTAssertEqual(frames.leaves[a]?.width, 250)
        XCTAssertEqual(frames.leaves[.side]?.width, 450)
    }

    /// Held so that it and its siblings keep their minimums.
    func testResizingStopsAtTheMinimums() {
        var layout = row(.main, a, .side)
        XCTAssertTrue(layout.resize(.side, to: 5000, in: wide))
        var frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.side]?.width, 880)
        XCTAssertEqual(frames.leaves[.main]?.width, 160)
        XCTAssertEqual(frames.leaves[a]?.width, 160)

        XCTAssertTrue(layout.resize(.side, to: 10, in: wide))
        frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.side]?.width, 160)
        XCTAssertEqual(frames.leaves[.main]?.width, 520)
        XCTAssertEqual(frames.leaves[a]?.width, 520)

        // A sibling that its share would take under its minimum is held
        // there, and the other one gives the rest.
        var tight = row([(.main, 0.7), (a, 0.15), (.side, 0.15)])
        XCTAssertTrue(tight.resize(.side, to: 500, in: wide))
        frames = tight.frames(in: wide)
        XCTAssertEqual(frames.leaves[.side]?.width, 500)
        XCTAssertEqual(frames.leaves[a]?.width, 160)
        XCTAssertEqual(frames.leaves[.main]?.width, 540)
        assertWellFormed(tight)
    }

    /// Along the axis of the split it is a part of: the strip's height.
    func testResizingTheStripUnderTheMainRow() {
        var layout = SplitLayout()
        layout.insert(.side, atRootEdge: .right, share: 1.0 / 3)
        layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
        let before = layout.frames(in: wide)
        XCTAssertTrue(layout.resize(.bottom, to: 240, in: wide))
        let frames = layout.frames(in: wide)
        XCTAssertEqual(frames.leaves[.bottom]?.height, 240)
        XCTAssertEqual(frames.leaves[.main]?.height, 359)
        XCTAssertEqual(frames.leaves[.bottom]?.width, frames.leaves[.main]?.width)
        XCTAssertEqual(frames.leaves[.side], before.leaves[.side], "the column is as it was")
        assertWellFormed(layout)
    }

    /// A hidden sibling keeps its weight, and so the share it comes back to.
    func testResizingBesideAHiddenLeaf() {
        var layout = row(.main, a, .side)
        XCTAssertTrue(layout.resize(.side, to: 440, in: wide, hidden: [a]))
        let frames = layout.frames(in: wide, hidden: [a])
        XCTAssertEqual(frames.leaves[.side]?.width, 440)
        XCTAssertEqual(frames.leaves[.main]?.width, 761)
        XCTAssertEqual(parts(of: layout)[1].weight, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(layout.frames(in: wide).leaves[a]?.width, 400)
        assertWellFormed(layout)
    }

    func testWhatCannotBeResized() {
        var alone = SplitLayout()
        XCTAssertFalse(alone.resize(.main, to: 100, in: wide), "no split to be a part of")
        XCTAssertEqual(alone, SplitLayout())

        var layout = row(.main, a, .side)
        let before = layout
        XCTAssertFalse(layout.resize(b, to: 300, in: wide), "not in the tree")
        XCTAssertFalse(layout.resize(.side, to: 300, in: wide, hidden: [.side]), "not on screen")
        XCTAssertFalse(layout.resize(.side, to: 300, in: wide, hidden: [.main, a]), "nobody on screen beside it")
        XCTAssertFalse(layout.resize(.side, to: 400, in: wide), "already that long")
        XCTAssertFalse(layout.resize(.side, to: 400.3, in: wide), "less than half a point is nothing")
        XCTAssertEqual(layout, before)
    }
}
