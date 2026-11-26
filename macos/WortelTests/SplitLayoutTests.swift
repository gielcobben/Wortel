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
        XCTAssertNil(Leaf(rawValue: "side"))
        XCTAssertNil(Leaf(rawValue: ""))
    }
}
