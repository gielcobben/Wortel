import XCTest

/// Mark-up, the parts with no window in them.
final class MarkupTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-markup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func mark(_ number: Int, area: Bool = false, name: String = "button \"Download\"") -> Mark {
        Mark(number: number,
             shape: area ? .area(box: CGRect(x: 10, y: 20, width: 100, height: 50), ink: [CGPoint(x: 12, y: 24)]) : .thing,
             name: area ? "area" : name, picture: nil, details: MarkDetails())
    }

    // MARK: - A mark

    func testColoursGoRoundAfterSeven() {
        XCTAssertEqual(MarkColour.of(1), .red)
        XCTAssertEqual(MarkColour.of(7), .teal)
        XCTAssertEqual(MarkColour.of(8), .red)
        XCTAssertEqual(MarkColour.of(15), .red)
        // A number that should never be asked for still gets a colour.
        XCTAssertEqual(MarkColour.of(0), .teal)
    }

    func testAnAreaIsCalledByItsNumberAndAnElementByItsName() {
        XCTAssertEqual(mark(2, area: true).reference, "area 2")
        XCTAssertEqual(mark(1).reference, "button \"Download\"")
    }

    func testAnAreaMovesAndZoomsWithWhatItIsTiedTo() {
        let placement = MarkPlacement(origin: CGPoint(x: 100, y: 200), size: CGSize(width: 400, height: 300),
                                      scale: 1.5, clip: .infinite)
        XCTAssertEqual(placement.box(of: .thing), CGRect(x: 100, y: 200, width: 400, height: 300))
        XCTAssertEqual(placement.box(of: mark(1, area: true).shape), CGRect(x: 115, y: 230, width: 150, height: 75))
        XCTAssertEqual(placement.point(CGPoint(x: 12, y: 24)), CGPoint(x: 118, y: 236))
    }

    // MARK: - A stroke

    func testAPressThatBarelyMovesIsAClick() {
        XCTAssertTrue(MarkStroke.isClick([]))
        XCTAssertTrue(MarkStroke.isClick([CGPoint(x: 5, y: 5), CGPoint(x: 7, y: 6)]))
        XCTAssertFalse(MarkStroke.isClick([CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 5)]))
        // Out and back again was still a drag.
        XCTAssertFalse(MarkStroke.isClick([CGPoint(x: 5, y: 5), CGPoint(x: 40, y: 5), CGPoint(x: 5, y: 5)]))
    }

    func testThinningKeepsWhereTheHandStopped() {
        let points = (0...20).map { CGPoint(x: CGFloat($0) * 0.5, y: 0) }
        let thinned = MarkStroke.thinned(points)
        XCTAssertLessThan(thinned.count, points.count)
        XCTAssertEqual(thinned.first, points.first)
        XCTAssertEqual(thinned.last, points.last)
    }

    func testAStrokesAreaHasRoomAndStaysInTheView() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let area = MarkStroke.area(of: [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 120)], within: bounds)
        // The ink's box, half its width, and 8 points of room: 9.5 a side,
        // out to whole points.
        XCTAssertEqual(area, CGRect(x: 90, y: 90, width: 60, height: 40))
        // At the corner the room is cut where the view ends.
        let corner = MarkStroke.area(of: [CGPoint(x: 2, y: 3), CGPoint(x: 30, y: 30)], within: bounds)
        XCTAssertEqual(corner?.minX, 0)
        XCTAssertEqual(corner?.minY, 0)
        XCTAssertNil(MarkStroke.area(of: [], within: bounds))
    }

    func testALineIsDrawnThroughOnePointAndThroughMany() {
        XCTAssertFalse(MarkStroke.path(through: [CGPoint(x: 1, y: 1)]).isEmpty)
        let path = MarkStroke.path(through: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)])
        XCTAssertEqual(path.currentPoint, CGPoint(x: 20, y: 0))
        XCTAssertTrue(MarkStroke.path(through: []).isEmpty)
    }

    // MARK: - The other pens

    func testAMarkIsCalledByWhatItWasDrawnWith() {
        var box = mark(3, area: true)
        box.pen = .box
        XCTAssertEqual(box.reference, "box 3")
        var arrow = mark(4, area: true)
        arrow.pen = .arrow
        XCTAssertEqual(arrow.reference, "arrow 4")
        var marker = mark(5, area: true)
        marker.pen = .highlighter
        XCTAssertEqual(marker.reference, "highlight 5")
        // A picked element has its own name, whatever pen was in hand.
        var picked = mark(1)
        picked.pen = .box
        XCTAssertEqual(picked.reference, "button \"Download\"")
    }

    func testEachPenKeepsWhatItNeedsOfADrag() {
        let drag = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 18), CGPoint(x: 60, y: 22), CGPoint(x: 90, y: 40)]
        // The pen keeps the hand's line; a box its corners; an arrow its ends.
        XCTAssertEqual(MarkStroke.points(for: .pen, drawn: drag, straight: false), drag)
        XCTAssertEqual(MarkStroke.points(for: .highlighter, drawn: drag, straight: false), drag)
        XCTAssertEqual(MarkStroke.points(for: .box, drawn: drag, straight: false), [drag[0], drag[3]])
        XCTAssertEqual(MarkStroke.points(for: .arrow, drawn: drag, straight: false), [drag[0], drag[3]])
        // A press that went nowhere is left as it is.
        XCTAssertEqual(MarkStroke.points(for: .box, drawn: [drag[0]], straight: true), [drag[0]])
    }

    func testShiftStraightens() {
        let start = CGPoint(x: 100, y: 100)
        // Nearly level: level, and as long as it was drawn.
        let level = MarkStroke.snapped(CGPoint(x: 200, y: 108), from: start)
        XCTAssertEqual(level.y, 100, accuracy: 0.001)
        XCTAssertEqual(level.x - 100, hypot(100, 8), accuracy: 0.001)
        // Nearly straight down, and nearly on the diagonal.
        XCTAssertEqual(MarkStroke.snapped(CGPoint(x: 96, y: 180), from: start).x, 100, accuracy: 0.001)
        let diagonal = MarkStroke.snapped(CGPoint(x: 160, y: 150), from: start)
        XCTAssertEqual(diagonal.x - 100, diagonal.y - 100, accuracy: 0.001)

        let drag = [start, CGPoint(x: 140, y: 103), CGPoint(x: 200, y: 108)]
        // The pen and the highlighter: one straight line.
        XCTAssertEqual(MarkStroke.points(for: .highlighter, drawn: drag, straight: true).count, 2)
        XCTAssertEqual(MarkStroke.points(for: .pen, drawn: drag, straight: true)[1].y, 100, accuracy: 0.001)
        // The box: a square, towards where the drag went.
        XCTAssertEqual(MarkStroke.points(for: .box, drawn: [start, CGPoint(x: 160, y: 130)], straight: true),
                       [start, CGPoint(x: 160, y: 160)])
        XCTAssertEqual(MarkStroke.points(for: .box, drawn: [start, CGPoint(x: 40, y: 130)], straight: true),
                       [start, CGPoint(x: 40, y: 160)])
    }

    func testABoxIsItsCornersAndAnArrowHasAHead() {
        let box = MarkStroke.path(for: .box, through: [CGPoint(x: 50, y: 40), CGPoint(x: 10, y: 10)])
        XCTAssertEqual(box.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 40, height: 30))
        // An arrow to the right: its line, and a head that opens behind the tip.
        let arrow = MarkStroke.path(for: .arrow, through: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)])
        let bounds = arrow.boundingBoxOfPath
        XCTAssertEqual(bounds.maxX, 100, accuracy: 0.001)
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.001)
        XCTAssertGreaterThan(bounds.height, 8)
        XCTAssertLessThan(bounds.height, 14)
        // A very short arrow's head is no longer than half of it.
        let short = MarkStroke.path(for: .arrow, through: [CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0)])
        XCTAssertLessThan(short.boundingBoxOfPath.height, 4)
    }

    func testAHighlightersAreaIsAsWideAsItsStroke() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let line = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)]
        let pen = MarkStroke.area(of: line, pen: .pen, within: bounds)
        let marker = MarkStroke.area(of: line, pen: .highlighter, within: bounds)
        XCTAssertEqual(pen, MarkStroke.area(of: line, within: bounds))
        XCTAssertGreaterThan(try XCTUnwrap(marker).height, try XCTUnwrap(pen).height + 8)
    }

    func testEachPenIsDrawnOnAPicture() throws {
        let placement = MarkPlacement(origin: .zero, size: .zero, scale: 1, clip: .infinite)
        func drawn(_ pen: MarkPen, _ ink: [CGPoint]) throws -> Pixels {
            let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            var mark = Mark(number: 1, shape: .area(box: .zero, ink: ink), name: pen.word, picture: nil, details: MarkDetails())
            mark.pen = pen
            MarkDrawing.draw(mark, at: placement, colour: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                             in: context, height: 100, badge: false)
            return try XCTUnwrap(Pixels(try XCTUnwrap(context.makeImage())))
        }
        let blue = Pixels.Colour(r: 0, g: 0, b: 255), white = Pixels.Colour(r: 255, g: 255, b: 255)
        // A box: its edge is drawn, its middle is not.
        let box = try drawn(.box, [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60)])
        XCTAssertEqual(box.at(x: 50, y: 20), blue)
        XCTAssertEqual(box.at(x: 50, y: 40), white)
        // An arrow: its line.
        XCTAssertEqual(try drawn(.arrow, [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)]).at(x: 40, y: 50), blue)
        // A highlighter: wide, and what is under it shows through.
        let marker = try drawn(.highlighter, [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)])
        let through = marker.at(x: 50, y: 45)
        XCTAssertEqual(through.b, 255)
        XCTAssertGreaterThan(through.r, 120)
        XCTAssertLessThan(through.r, 200)
        XCTAssertEqual(marker.at(x: 50, y: 30), white)
    }

    // MARK: - Resizing a drawing

    private func assertPoints(_ points: [CGPoint], _ expected: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(points.count, expected.count, file: file, line: line)
        for (point, wanted) in zip(points, expected) {
            XCTAssertEqual(point.x, wanted.x, accuracy: 0.001, "\(points)", file: file, line: line)
            XCTAssertEqual(point.y, wanted.y, accuracy: 0.001, "\(points)", file: file, line: line)
        }
    }

    func testAPensHandlesAreOnTheCornersOfItsInk() {
        let line = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 30)]
        XCTAssertEqual(MarkStroke.handles(for: .pen, points: line), [.topLeft, .topRight, .bottomRight, .bottomLeft])
        // Half the line's width out from its points: around the ink as drawn.
        XCTAssertEqual(MarkStroke.position(of: .topLeft, pen: .pen, points: line), CGPoint(x: 8.5, y: 8.5))
        XCTAssertEqual(MarkStroke.position(of: .bottomRight, pen: .pen, points: line), CGPoint(x: 51.5, y: 41.5))
        XCTAssertEqual(MarkStroke.position(of: .topRight, pen: .pen, points: line), CGPoint(x: 51.5, y: 8.5))
        // A highlighter's are outside its wide stroke, not on it.
        XCTAssertEqual(MarkStroke.position(of: .topLeft, pen: .highlighter, points: line), CGPoint(x: 3, y: 3))
        XCTAssertEqual(MarkStroke.outline(of: line, pen: .pen), CGRect(x: 8.5, y: 8.5, width: 43, height: 33))
        // A small one has one handle, so there is an inside left to take it by.
        XCTAssertEqual(MarkStroke.handles(for: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 18, y: 14)]),
                       [.bottomRight])
    }

    func testAnArrowsHandlesAreItsEnds() {
        let arrow = [CGPoint(x: 20, y: 30), CGPoint(x: 120, y: 80)]
        XCTAssertEqual(MarkStroke.handles(for: .arrow, points: arrow), [.tail, .tip])
        XCTAssertEqual(MarkStroke.position(of: .tail, pen: .arrow, points: arrow), arrow[0])
        XCTAssertEqual(MarkStroke.position(of: .tip, pen: .arrow, points: arrow), arrow[1])
        // However short, it has both.
        XCTAssertEqual(MarkStroke.handles(for: .arrow, points: [.zero, CGPoint(x: 8, y: 0)]), [.tail, .tip])
    }

    func testAPressTakesTheHandleItIsNearest() {
        let line = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 30)]
        XCTAssertEqual(MarkStroke.handle(at: CGPoint(x: 12, y: 12), pen: .pen, points: line), .topLeft)
        // Wider than the 9pt dot: 10 points either way.
        XCTAssertEqual(MarkStroke.handle(at: CGPoint(x: 58, y: 48), pen: .pen, points: line), .bottomRight)
        XCTAssertNil(MarkStroke.handle(at: CGPoint(x: 62, y: 41.5), pen: .pen, points: line))
        // The inside is for moving.
        XCTAssertNil(MarkStroke.handle(at: CGPoint(x: 30, y: 25), pen: .pen, points: line))
        // Where two reach, the nearer.
        let short = [CGPoint.zero, CGPoint(x: 8, y: 0)]
        XCTAssertEqual(MarkStroke.handle(at: CGPoint(x: 5, y: 0), pen: .arrow, points: short), .tip)
        XCTAssertEqual(MarkStroke.handle(at: CGPoint(x: 3, y: 0), pen: .arrow, points: short), .tail)
        XCTAssertNil(MarkStroke.handle(at: .zero, pen: .arrow, points: []))
    }

    func testACornerScalesTheDrawingAboutTheOppositeOne() {
        // Ink from (10, 10) to (50, 30); its bottom-right handle is at
        // (51.5, 31.5), half the 3pt line further out.
        let line = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20), CGPoint(x: 50, y: 30)]
        let free = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: 91.5, y: 61.5),
                                      proportional: false)
        // Twice as wide, two and a half times as tall; the top-left stays.
        assertPoints(free, [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 35), CGPoint(x: 90, y: 60)])
        // Shift: the proportions are kept, at the larger of the two.
        let kept = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: 91.5, y: 61.5),
                                      proportional: true)
        assertPoints(kept, [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 35), CGPoint(x: 110, y: 60)])
        // Option: about the middle, which stays where it is.
        let centred = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: 71.5, y: 41.5),
                                         proportional: false, fromCentre: true)
        assertPoints(centred, [CGPoint(x: -10, y: 0), CGPoint(x: 30, y: 20), CGPoint(x: 70, y: 40)])
    }

    func testACornerDraggedPastTheOppositeOneMirrorsTheDrawing() {
        let line = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20), CGPoint(x: 50, y: 30)]
        let flipped = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: -28.5, y: 1.5),
                                         proportional: false)
        assertPoints(flipped, [CGPoint(x: 10, y: 10), CGPoint(x: -10, y: 5), CGPoint(x: -30, y: 0)])
        // A scale of exactly nothing leaves that side as it was, so a
        // drawing is never flattened for good.
        let level = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: 11.5, y: 61.5),
                                       proportional: false)
        assertPoints(level, [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 35), CGPoint(x: 50, y: 60)])
    }

    func testADrawingIsNeverSmallerThanEightPointsOnItsLongerSide() {
        let line = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)]
        // Dragged to a point from the opposite corner: 8 wide, and its
        // height free.
        let small = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: 12.5, y: 12.5),
                                       proportional: false)
        assertPoints(small, [CGPoint(x: 10, y: 10), CGPoint(x: 18, y: 11)])
        // With Shift, the proportions hold at the floor too.
        let kept = MarkStroke.resized(line, pen: .pen, moving: .bottomRight, to: CGPoint(x: 12.5, y: 12.5),
                                      proportional: true)
        assertPoints(kept, [CGPoint(x: 10, y: 10), CGPoint(x: 18, y: 14)])
        // An arrow is never shorter than 8, and keeps the way it points.
        let arrow = [CGPoint.zero, CGPoint(x: 100, y: 0)]
        assertPoints(MarkStroke.resized(arrow, pen: .arrow, moving: .tip, to: CGPoint(x: 2, y: 0), proportional: false),
                     [.zero, CGPoint(x: 8, y: 0)])
        assertPoints(MarkStroke.resized(arrow, pen: .arrow, moving: .tip, to: .zero, proportional: false),
                     [.zero, CGPoint(x: 8, y: 0)])
    }

    func testABoxsCornerMovesAndTheOtherStays() {
        let box = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)]
        // The top-left handle, half a line out from (10, 10), taken to
        // (-1.5, 3.5): that corner is at (0, 5), the other where it was.
        assertPoints(MarkStroke.resized(box, pen: .box, moving: .topLeft, to: CGPoint(x: -1.5, y: 3.5), proportional: false),
                     [CGPoint(x: 0, y: 5), CGPoint(x: 50, y: 30)])
        // A box drawn with no height gets one.
        assertPoints(MarkStroke.resized([CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10)], pen: .box, moving: .bottomRight,
                                        to: CGPoint(x: 51.5, y: 31.5), proportional: false),
                     [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)])
    }

    func testAnArrowsEndMovesAloneAndShiftTurnsItInSteps() {
        let arrow = [CGPoint.zero, CGPoint(x: 100, y: 0)]
        assertPoints(MarkStroke.resized(arrow, pen: .arrow, moving: .tip, to: CGPoint(x: 100, y: 50), proportional: false),
                     [.zero, CGPoint(x: 100, y: 50)])
        assertPoints(MarkStroke.resized(arrow, pen: .arrow, moving: .tail, to: CGPoint(x: 20, y: 30), proportional: false),
                     [CGPoint(x: 20, y: 30), CGPoint(x: 100, y: 0)])
        // Nearly level with Shift: level, as far as the pointer is.
        assertPoints(MarkStroke.resized(arrow, pen: .arrow, moving: .tip, to: CGPoint(x: 100, y: 10), proportional: true),
                     [.zero, CGPoint(x: hypot(CGFloat(100), CGFloat(10)), y: 0)])
    }

    // MARK: - What is copied

    private let references: [Int: MarkupNote.Reference] = [
        1: .init(text: "button \"Download\"", picture: "/m/1.png"),
        2: .init(text: "area 2", picture: "/m/2.png"),
    ]

    func testAChipBecomesItsNameAndItsPicture() {
        let copied = MarkupNote.copied(
            pieces: [.text("Make "), .mark(1), .text(" the same blue as "), .mark(2)],
            marks: references, subject: .page("http://localhost:4321/"),
            whole: .init(path: "/m/whole.png"), details: "/m/details.json")
        XCTAssertEqual(copied, """
            Make button "Download" (/m/1.png) the same blue as area 2 (/m/2.png)

            Page: http://localhost:4321/
            All marks: /m/whole.png
            Details: /m/details.json
            """)
    }

    func testAChipSitsInTheSentenceAsAWordDoes() {
        func sentence(_ pieces: [MarkupNote.Piece]) -> String {
            MarkupNote.copied(pieces: pieces, marks: references, subject: .page("x"),
                              whole: nil, details: nil)
                .components(separatedBy: "\n")[0]
        }
        // Typed right up against a chip on both sides.
        XCTAssertEqual(sentence([.text("make"), .mark(1), .text("bigger")]),
                       "make button \"Download\" (/m/1.png) bigger")
        // Punctuation after a chip stays against it.
        XCTAssertEqual(sentence([.mark(1), .text(", then "), .mark(2), .text(".")]),
                       "button \"Download\" (/m/1.png), then area 2 (/m/2.png).")
        // Chips alone, and no space left at either end.
        XCTAssertEqual(sentence([.text("  "), .mark(1), .mark(2), .text(" ")]),
                       "button \"Download\" (/m/1.png) area 2 (/m/2.png)")
        // A mark nobody knows is left out, not printed as a number.
        XCTAssertEqual(sentence([.text("a "), .mark(9), .text("b")]), "a b")
    }

    func testWhatAPageCallsAnElementCannotCarryAnInstruction() {
        // An escape sequence, a line break that would start a new prompt,
        // the end of a bracketed paste, a right-to-left override, a
        // zero-width space, and the C1 form of the escape.
        let hostile = "Buy\u{1B}[201~\nrm -rf ~\r\n\u{202E}evil\u{200B}!\u{9B}31m \u{2028}now\u{7F}"
        XCTAssertEqual(MarkText.clean(hostile), "Buy[201~ rm -rf ~ evil!31m now")
        XCTAssertEqual(MarkText.clean("  two   words\t here "), "two words here")
        XCTAssertEqual(MarkText.clean("caf\u{E9} \u{1F600} \u{4E2D}\u{6587}"), "caf\u{E9} \u{1F600} \u{4E2D}\u{6587}")
        // In the details file's HTML a line and a tab stay, an escape does not.
        XCTAssertEqual(MarkText.clean("<p>\n\ta\u{1B}b</p>", lines: true), "<p>\n\tab</p>")

        // And whatever reaches the note, the sentence stays one sentence.
        let copied = MarkupNote.copied(
            pieces: [.mark(1)], marks: [1: .init(text: "button \"x\"\n\u{1B}]0;owned\u{07}", picture: nil)],
            subject: .file(path: "/tmp/a\nb.md", view: "Source"), whole: nil, details: nil)
        XCTAssertEqual(copied, "button \"x\" ]0;owned\n\nFile: /tmp/a b.md (Source)")
        XCTAssertFalse(copied.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
    }

    func testAFileIsNamedWithItsViewAndAPartSaysItIsOne() {
        let copied = MarkupNote.copied(
            pieces: [.mark(2)], marks: [2: .init(text: "area 2", picture: nil)],
            subject: .file(path: "/repo/README.md", view: "Rendered"),
            whole: .init(path: "/m/whole.png", kind: .part), details: nil)
        XCTAssertEqual(copied, """
            area 2

            File: /repo/README.md (Rendered)
            The part with the marks: /m/whole.png
            """)
    }

    func testThePictureOfTheWholeSaysWhatItIsAndWhichMarksAreNotInIt() {
        func line(_ whole: MarkupNote.Whole) -> String {
            MarkupNote.copied(pieces: [.mark(1), .mark(2)], marks: references, subject: .page("x"),
                              whole: whole, details: nil).components(separatedBy: "\n")[3]
        }
        XCTAssertEqual(line(.init(path: "/w.png")), "All marks: /w.png")
        XCTAssertEqual(line(.init(path: "/w.png", kind: .part)), "The part with the marks: /w.png")
        // Markdown is pictured as it was in view, and a mark scrolled away
        // is not in the picture: said, so a reader does not look for it.
        XCTAssertEqual(line(.init(path: "/w.png", kind: .view)), "What was in view: /w.png")
        XCTAssertEqual(line(.init(path: "/w.png", kind: .view, missing: [2])),
                       "What was in view (area 2 is not in it): /w.png")
        XCTAssertEqual(line(.init(path: "/w.png", kind: .all, missing: [1, 2])),
                       "The whole (button \"Download\" and area 2 are not in it): /w.png")
        // A mark nobody knows has no name to give.
        XCTAssertEqual(line(.init(path: "/w.png", kind: .view, missing: [9])), "What was in view: /w.png")
    }

    func testAnAreasPictureShowsWhatIsAroundIt() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // A loop on one word: 60 by 30. The picture is the least it may be,
        // centred on the loop.
        XCTAssertEqual(MarkStroke.pictured(CGRect(x: 370, y: 285, width: 60, height: 30), within: bounds),
                       CGRect(x: 220, y: 220, width: 360, height: 160))
        // A large area has 32 points more a side.
        XCTAssertEqual(MarkStroke.pictured(CGRect(x: 100, y: 100, width: 500, height: 300), within: bounds),
                       CGRect(x: 68, y: 68, width: 564, height: 364))
        // At the view's corner it keeps its size by moving in.
        XCTAssertEqual(MarkStroke.pictured(CGRect(x: 0, y: 0, width: 40, height: 40), within: bounds),
                       CGRect(x: 0, y: 0, width: 360, height: 160))
        // In a view smaller than the least, it is the view.
        XCTAssertEqual(MarkStroke.pictured(CGRect(x: 10, y: 10, width: 40, height: 40),
                                           within: CGRect(x: 0, y: 0, width: 260, height: 120)),
                       CGRect(x: 0, y: 0, width: 260, height: 120))
    }

    func testAMarkOutsideWhatIsPicturedIsSaidToBeMissing() throws {
        // Two marks 30,000 apart in something 60,000 tall: the stretch
        // pictured is cut at 24 screens, and the second mark is past it.
        let whole = MarkupWhole(draw: { _ in }, size: CGSize(width: 400, height: 60_000),
                                visible: CGRect(x: 0, y: 0, width: 400, height: 300),
                                placements: [
                                    1: MarkPlacement(origin: CGPoint(x: 10, y: 1000), size: CGSize(width: 50, height: 20),
                                                     scale: 1, clip: .infinite),
                                    2: MarkPlacement(origin: CGPoint(x: 10, y: 31_000), size: CGSize(width: 50, height: 20),
                                                     scale: 1, clip: .infinite),
                                ])
        let picture = try XCTUnwrap(MarkupPicture.whole(whole, marks: [mark(1), mark(2), mark(3)], colours: [:]))
        XCTAssertEqual(picture.kind, .part)
        // The second is out of the stretch, the third has no place at all.
        XCTAssertEqual(picture.missing, [2, 3])
    }

    func testANoteKeepsItsLines() {
        let copied = MarkupNote.copied(pieces: [.text("one \n two"), .mark(1)], marks: references,
                                       subject: .page("x"), whole: nil, details: nil)
        XCTAssertTrue(copied.hasPrefix("one\ntwo button \"Download\" (/m/1.png)\n\nPage: x"))
    }

    func testTheDetailsFileSaysWhatWasMarkedAndLeavesOutWhatItHasNot() throws {
        var details = MarkDetails()
        details.number = 1
        details.kind = "element"
        details.selector = "#buy"
        let file = MarkupDetailsFile(subject: .page("http://localhost/"), whole: "/m/whole.png", marks: [details])
        let json = try XCTUnwrap(String(data: file.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"page\" : \"http://localhost/\""))
        XCTAssertTrue(json.contains("\"selector\" : \"#buy\""))
        XCTAssertFalse(json.contains("\"html\""))
        XCTAssertFalse(json.contains("\"file\""))
        XCTAssertEqual(try JSONDecoder().decode(MarkupDetailsFile.self, from: file.encoded()), file)
    }

    // MARK: - The folder

    func testANotesFolderIsTheDayAndTheNextNumber() throws {
        let store = MarkupStore(root: folder)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_795_651_200) // 2026-11-26 00:00 UTC
        XCTAssertEqual(MarkupStore.dayName(day, calendar: calendar), "2026-11-26")
        let first = try XCTUnwrap(store.newFolder(now: day, calendar: calendar))
        let second = try XCTUnwrap(store.newFolder(now: day, calendar: calendar))
        XCTAssertEqual(first.path, folder.appendingPathComponent("2026-11-26/1").path)
        XCTAssertEqual(second.lastPathComponent, "2")
        XCTAssertFalse(first.path.contains(" "))
    }

    func testTheSweepRemovesWhatIsOldAndKeepsWhatIsOpen() throws {
        let files = FileManager.default
        let store = MarkupStore(root: folder)
        let now = Date()
        func note(_ day: String, _ number: String, age days: Double) throws -> URL {
            let url = folder.appendingPathComponent(day).appendingPathComponent(number)
            try files.createDirectory(at: url, withIntermediateDirectories: true)
            let picture = url.appendingPathComponent("1.png")
            try Data("x".utf8).write(to: picture)
            let date = now.addingTimeInterval(-days * 86_400)
            try files.setAttributes([.modificationDate: date], ofItemAtPath: picture.path)
            try files.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let old = try note("2026-11-01", "1", age: 8)
        let open = try note("2026-11-01", "2", age: 30)
        let fresh = try note("2026-11-20", "1", age: 6)
        let alone = try note("2026-10-01", "1", age: 40)
        // Something that is not a note is not this sweep's to remove.
        let stray = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: stray)

        store.sweep(keeping: [open.standardizedFileURL.path], now: now)

        XCTAssertFalse(files.fileExists(atPath: old.path))
        XCTAssertTrue(files.fileExists(atPath: open.path))
        XCTAssertTrue(files.fileExists(atPath: fresh.path))
        XCTAssertFalse(files.fileExists(atPath: alone.path))
        // A day with nothing left in it goes too.
        XCTAssertFalse(files.fileExists(atPath: alone.deletingLastPathComponent().path))
        XCTAssertTrue(files.fileExists(atPath: stray.path))
    }

    func testAFolderWithAFileWrittenLatelyIsNotOld() throws {
        let files = FileManager.default
        let store = MarkupStore(root: folder)
        let url = folder.appendingPathComponent("2026-11-01/1")
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("whole-2.png"))
        // The folder itself is old; a second copy rewrote a file in it today.
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86_400)], ofItemAtPath: url.path)
        store.sweep()
        XCTAssertTrue(files.fileExists(atPath: url.path))
    }

    func testAPictureIsWrittenAsAPNG() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let url = folder.appendingPathComponent("1.png")
        XCTAssertTrue(MarkupStore.write(try XCTUnwrap(context.makeImage()), to: url))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: - What a page reports

    private func report(marks: [[Double]] = [[1, 100, 200, 50, 40, 0, 0, 800, 600, 0]],
                        scroll: (Double, Double) = (0, 150)) -> [Any] {
        ([scroll.0, scroll.1, 800, 600, 800, 6000] + marks.flatMap { $0 }).map { NSNumber(value: $0) }
    }

    func testAReportIsRead() throws {
        let read = try XCTUnwrap(WebMarkReport(report()))
        XCTAssertEqual(read.scroll, CGPoint(x: 0, y: 150))
        XCTAssertEqual(read.page, CGSize(width: 800, height: 6000))
        XCTAssertEqual(read.marks[1]?.rect, CGRect(x: 100, y: 200, width: 50, height: 40))
        XCTAssertEqual(read.marks[1]?.lost, false)
        // No marks is a report too.
        XCTAssertEqual(WebMarkReport(report(marks: []))?.marks.count, 0)
    }

    func testAReportThatIsNotWhatItShouldBeIsRefusedWhole() {
        XCTAssertNil(WebMarkReport("hello"))
        XCTAssertNil(WebMarkReport([NSNumber(value: 1)]))
        // A mark cut short.
        XCTAssertNil(WebMarkReport(Array(report().dropLast())))
        // Something that is not a number among the numbers.
        var mixed = report()
        mixed[3] = "600"
        XCTAssertNil(WebMarkReport(mixed))
        // Not finite, or absurd.
        XCTAssertNil(WebMarkReport(report(marks: [[1, .nan, 0, 1, 1, 0, 0, 1, 1, 0]])))
        XCTAssertNil(WebMarkReport(report(marks: [[1, .infinity, 0, 1, 1, 0, 0, 1, 1, 0]])))
        XCTAssertNil(WebMarkReport(report(marks: [[1, 1e12, 0, 1, 1, 0, 0, 1, 1, 0]])))
        // A mark with no number, or half of one.
        XCTAssertNil(WebMarkReport(report(marks: [[0, 0, 0, 1, 1, 0, 0, 1, 1, 0]])))
        XCTAssertNil(WebMarkReport(report(marks: [[1.5, 0, 0, 1, 1, 0, 0, 1, 1, 0]])))
        // More marks than anyone draws.
        let many = (1...(WebMarkReport.most + 1)).map { [Double($0), 0, 0, 1, 1, 0, 0, 1, 1, 0] }
        XCTAssertNil(WebMarkReport(report(marks: many)))
    }

    func testAMarkIsWhereThePageSaysTimesTheZoom() throws {
        let read = try XCTUnwrap(WebMarkReport(report()))
        // Measured: CSS 100, 200 is at 150, 300 in the view at zoom 1.5.
        let placement = try XCTUnwrap(read.placement(of: 1, zoom: 1.5))
        XCTAssertEqual(placement.origin, CGPoint(x: 150, y: 300))
        XCTAssertEqual(placement.size, CGSize(width: 75, height: 60))
        XCTAssertEqual(placement.scale, 1.5)
        XCTAssertEqual(placement.clip, CGRect(x: 0, y: 0, width: 1200, height: 900))
        XCTAssertNil(read.placement(of: 2, zoom: 1))
    }

    func testAMarkWhoseElementIsGoneHasNoPlace() throws {
        let read = try XCTUnwrap(WebMarkReport(report(marks: [[1, 0, 0, 0, 0, 0, 0, 0, 0, 1]])))
        XCTAssertNil(read.placement(of: 1, zoom: 1))
        XCTAssertNil(read.placementInPage(of: 1))
    }

    func testInTheWholePageAMarkIsDownByTheScrollUnlessItStaysPut() throws {
        let read = try XCTUnwrap(WebMarkReport(report(marks: [
            [1, 100, 200, 50, 40, 0, 0, 800, 600, 0],
            [2, 0, 0, 800, 30, 0, 0, 800, 600, 2],
        ])))
        XCTAssertEqual(read.placementInPage(of: 1)?.origin, CGPoint(x: 100, y: 350))
        // A fixed header is at the top of a picture of the whole page.
        XCTAssertEqual(read.placementInPage(of: 2)?.origin, .zero)
    }

    func testAScrollAtThePagesEndMovesNothing() throws {
        let top = try XCTUnwrap(WebMarkReport(report(marks: [], scroll: (0, 0))))
        XCTAssertFalse(top.wouldScroll(deltaX: 0, deltaY: 12))
        XCTAssertTrue(top.wouldScroll(deltaX: 0, deltaY: -12))
        XCTAssertFalse(top.wouldScroll(deltaX: -5, deltaY: 0))
        let bottom = try XCTUnwrap(WebMarkReport(report(marks: [], scroll: (0, 5400))))
        XCTAssertFalse(bottom.wouldScroll(deltaX: 0, deltaY: -12))
        XCTAssertTrue(bottom.wouldScroll(deltaX: 0, deltaY: 12))
    }

    // MARK: - The picture of the whole

    func testAPageOfAFewScreensIsPicturedWhole() {
        let size = CGSize(width: 800, height: 6000)
        let part = MarkupPicture.part(of: size, screen: 600, marks: [CGRect(x: 0, y: 5000, width: 10, height: 10)])
        XCTAssertEqual(part.rect, CGRect(origin: .zero, size: size))
        XCTAssertFalse(part.isPart)
    }

    func testAVeryTallPageIsPicturedAroundItsMarks() {
        let size = CGSize(width: 800, height: 60_000)
        let part = MarkupPicture.part(of: size, screen: 600, marks: [
            CGRect(x: 10, y: 20_000, width: 50, height: 40),
            CGRect(x: 10, y: 21_000, width: 50, height: 40),
        ])
        XCTAssertTrue(part.isPart)
        XCTAssertEqual(part.rect, CGRect(x: 0, y: 19_400, width: 800, height: 2240))
        // Near the top there is no screen above to add.
        let top = MarkupPicture.part(of: size, screen: 600, marks: [CGRect(x: 0, y: 100, width: 10, height: 10)])
        XCTAssertEqual(top.rect.minY, 0)
        // With no mark placed there is nothing to be around.
        XCTAssertFalse(MarkupPicture.part(of: size, screen: 600, marks: []).isPart)
    }

    func testAPictureIsNeverWiderOrTallerThanAllowed() {
        XCTAssertEqual(MarkupPicture.density(for: CGSize(width: 800, height: 6000)), 2)
        XCTAssertEqual(MarkupPicture.density(for: CGSize(width: 1600, height: 900)), 1)
        XCTAssertEqual(MarkupPicture.density(for: CGSize(width: 800, height: 32_000)), 0.5)
    }

    func testEveryMarkIsDrawnOnTheWhole() throws {
        // A white page 100 by 200, a red element outlined and an area inked.
        let whole = MarkupWhole(draw: { _ in }, size: CGSize(width: 100, height: 200),
                                visible: CGRect(x: 0, y: 0, width: 100, height: 100),
                                placements: [
                                    1: MarkPlacement(origin: CGPoint(x: 20, y: 30), size: CGSize(width: 40, height: 20),
                                                     scale: 1, clip: .infinite),
                                    2: MarkPlacement(origin: CGPoint(x: 0, y: 100), size: CGSize(width: 100, height: 100),
                                                     scale: 1, clip: .infinite),
                                ])
        let area = Mark(number: 2, shape: .area(box: CGRect(x: 10, y: 10, width: 60, height: 40),
                                                ink: [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 30)]),
                        name: "area", picture: nil, details: MarkDetails())
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let picture = try XCTUnwrap(MarkupPicture.whole(whole, marks: [mark(1), area], colours: [1: red, 2: blue]))
        XCTAssertEqual(picture.kind, .all)
        XCTAssertEqual(picture.missing, [])
        XCTAssertEqual(picture.image.width, 200)
        XCTAssertEqual(picture.image.height, 400)
        let pixels = try XCTUnwrap(Pixels(picture.image))
        // The outline's top edge, a point above the element: red.
        XCTAssertEqual(pixels.at(x: 80, y: 58), .init(r: 255, g: 0, b: 0))
        // Inside the element nothing is drawn.
        XCTAssertEqual(pixels.at(x: 80, y: 80), .init(r: 255, g: 255, b: 255))
        // The ink, 130 down the page: blue.
        XCTAssertEqual(pixels.at(x: 80, y: 260), .init(r: 0, g: 0, b: 255))
    }

    func testInkIsDrawnOnAnAreasPictureWhereItWasDrawn() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let clean = try XCTUnwrap(context.makeImage())
        // The picture shows 60 by 40 points of the view from (200, 300), at 2x.
        let showing = CGRect(x: 200, y: 300, width: 60, height: 40)
        let placement = MarkPlacement(origin: CGPoint(x: 190, y: 290), size: .zero, scale: 1, clip: .infinite)
        let area = Mark(number: 1, shape: .area(box: CGRect(x: 10, y: 10, width: 60, height: 40),
                                                ink: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 20)]),
                        name: "area", picture: nil, details: MarkDetails())
        let inked = MarkupPicture.inked(clean, showing: showing, mark: area, at: placement,
                                        colour: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let pixels = try XCTUnwrap(Pixels(inked))
        // The ink runs from view (210, 310) to (250, 310): 10 points down the picture.
        XCTAssertEqual(pixels.at(x: 60, y: 20), .init(r: 0, g: 0, b: 255))
        XCTAssertEqual(pixels.at(x: 60, y: 60), .init(r: 255, g: 255, b: 255))
    }
}

/// A picture's pixels, counted from the top-left.
private struct Pixels {
    struct Colour: Equatable { let r, g, b: UInt8 }
    let width: Int, height: Int
    let data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = bytes
    }

    func at(x: Int, y: Int) -> Colour {
        let index = (y * width + x) * 4
        return Colour(r: data[index], g: data[index + 1], b: data[index + 2])
    }
}
