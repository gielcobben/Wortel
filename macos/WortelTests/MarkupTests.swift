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
