import SwiftUI
import XCTest

/// Mark-up over a file, against the real views in a window that is never
/// shown: `DiffView`'s table and an image view.
@MainActor
final class MarkupFileTests: XCTestCase {
    /// Counts from the top-left, as the mark-up layer does.
    private final class Layer: NSView {
        override var isFlipped: Bool { true }
    }

    private var window: NSWindow!
    private var layer: Layer!
    private let views = MarkupViews()

    private func lines(_ texts: [String], added: Set<Int> = []) -> [DiffLine] {
        texts.enumerated().map { index, text in
            DiffLine(id: index, kind: added.contains(index) ? .addition : .context, text: text,
                     oldLine: added.contains(index) ? nil : index + 1, newLine: index + 1, path: "a.swift")
        }
    }

    private func numbered(_ count: Int) -> [String] {
        (1...count).map { "let line\($0) = \($0)" }
    }

    /// A window with a view filling it, and the layer over that.
    private func show<Content: View>(_ content: Content, size: NSSize = NSSize(width: 600, height: 400)) -> NSHostingView<Content> {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        // Or closing it releases it once more than the test owns it.
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        let host = NSHostingView(rootView: content)
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        layer = Layer(frame: root.bounds)
        layer.autoresizingMask = [.width, .height]
        root.addSubview(layer)
        settle()
        return host
    }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func diff(_ texts: [String], added: Set<Int> = [], fontSize: CGFloat = 13) -> DiffView {
        DiffView(lines: lines(texts, added: added), fontSize: fontSize, gutter: .file, markup: views)
    }

    // Every adapter below is held as `any MarkupSurface`, which is how the
    // layer holds one. Held by its own type, a member the protocol only
    // gives a default for is the adapter's; through the protocol it is the
    // default. `attach(to:)` was such a member, and no mark on a file was
    // tied to anything while these tests passed.
    private func tie(_ surface: any MarkupSurface, _ number: Int, to box: CGRect) -> MarkTie? {
        var answer: MarkTie?
        surface.tie(number, to: box) { answer = $0 }
        return answer
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        layer = nil
    }

    // MARK: - Source and Diff

    func testAMarkIsTiedToTheRowItWasDrawnOnAndScrollsWithIt() throws {
        _ = show(diff(numbered(200)))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        var moves = 0
        surface.activate(moved: { moves += 1 })
        let table = try XCTUnwrap(views.table)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let height = table.rowHeight
        XCTAssertGreaterThan(table.numberOfRows, 0, "the table has no rows: nothing was laid out")

        // Drawn starting in the fourth row.
        let made = try XCTUnwrap(tie(surface, 1, to: CGRect(x: 80, y: height * 3 + 4, width: 120, height: 30)))
        XCTAssertEqual(made.placement.origin.y, height * 3, accuracy: 0.5)
        XCTAssertEqual(made.placement.scale, 1)

        // Ten rows down: the mark is ten rows up, and the layer was told.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height * 10))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(moves, 0)
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, height * -7, accuracy: 0.5)

        // Let go of, it hears nothing more.
        surface.deactivate(forgetting: false)
        moves = 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height * 20))
        XCTAssertEqual(moves, 0)
        // The mark is still tied: a tab that comes back has it.
        XCTAssertNotNil(surface.placement(of: 1))
        surface.deactivate(forgetting: true)
        XCTAssertNil(surface.placement(of: 1))
    }

    /// A chip's click brings its mark's own box into what the note bar
    /// leaves showing, not the row it is tied to into the view.
    func testAClickedChipBringsItsMarkOutFromUnderTheNoteBar() throws {
        _ = show(diff(numbered(200)))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let table = try XCTUnwrap(views.table)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let height = table.rowHeight
        let covered: CGFloat = 98
        let room = MarkReveal.room(layer.bounds.size, coveredBelow: covered)

        // Eight rows tall, its first row in view and the rest under the bar.
        let box = CGRect(x: 80, y: 2, width: 120, height: height * 8)
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 80, y: height * 40 + 2, width: 120, height: height * 8)))
        let mark = Mark(number: 1, shape: .area(box: box, ink: []), name: "box", details: MarkDetails())
        func shown() throws -> CGRect { try XCTUnwrap(surface.placement(of: 1)).box(of: mark.shape) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height * 40 - (room.maxY - 2 * height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let under = try shown()
        XCTAssertTrue(layer.bounds.intersects(under) && !room.contains(under), "\(under)")

        surface.reveal(mark, coveredBelow: covered)
        let revealed = try shown()
        XCTAssertTrue(room.contains(revealed), "\(revealed) is not in \(room)")
        XCTAssertEqual(revealed.midY, room.midY, accuracy: 1)

        // Clicked again, where it is now: it stays.
        let before = try shown()
        surface.reveal(mark, coveredBelow: covered)
        XCTAssertEqual(try shown(), before)

        // From far away.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height * 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        surface.reveal(mark, coveredBelow: covered)
        XCTAssertEqual(try shown().midY, room.midY, accuracy: 1)
    }

    func testAMarkFindsItsLineAgainWhenTheFileIsRewrittenAndHasNoPlaceWhenItIsGone() throws {
        var texts = numbered(60)
        let host = show(diff(texts))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let height = try XCTUnwrap(views.table).rowHeight
        // On "let line10 = 10", the tenth row.
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 80, y: height * 9 + 2, width: 100, height: 10)))

        // An agent adds three lines above it.
        texts.insert(contentsOf: ["// one", "// two", "// three"], at: 2)
        host.rootView = diff(texts)
        settle()
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, height * 12, accuracy: 0.5)

        // And then deletes the line itself.
        texts.removeAll { $0 == "let line10 = 10" }
        host.rootView = diff(texts)
        settle()
        XCTAssertNil(surface.placement(of: 1))

        // And puts it back: the mark has its place again.
        texts.insert("let line10 = 10", at: 20)
        host.rootView = diff(texts)
        settle()
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, height * 20, accuracy: 0.5)
    }

    func testAMarkFindsItsLineWhenTheFileWasRewrittenWhileMarkUpWasOff() throws {
        var texts = numbered(60)
        let host = show(diff(texts))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let height = try XCTUnwrap(views.table).rowHeight
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 80, y: height * 9 + 2, width: 100, height: 10)))

        // A copy turns mark-up off and keeps the note. The agent that was
        // handed it adds three lines above, with nothing listening.
        surface.deactivate(forgetting: false)
        texts.insert(contentsOf: ["// one", "// two", "// three"], at: 2)
        host.rootView = diff(texts)
        settle()

        // Turned on again, the mark is on its line.
        surface.activate(moved: {})
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, height * 12, accuracy: 0.5)
    }

    func testAMarkOnALineLikeManyOthersFindsItsOwn() throws {
        // Code as code is: every function ends in the same three lines.
        var texts = (1...12).flatMap { ["func f\($0)() {", "    work(\($0))", "    return 0", "}", ""] }
        let host = show(diff(texts))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let height = try XCTUnwrap(views.table).rowHeight
        // On the brace that closes the third function, row 13.
        XCTAssertEqual(texts[13], "}")
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 80, y: height * 13 + 2, width: 100, height: 10)))

        // Three lines added above. The nearest brace to row 13 is now the
        // second function's, at row 11; the mark's own is at 16.
        texts.insert(contentsOf: ["// one", "// two", "// three"], at: 0)
        host.rootView = diff(texts)
        settle()
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, height * 16, accuracy: 0.5)

        // The first two functions removed: ten rows up.
        texts.removeSubrange(3..<13)
        host.rootView = diff(texts)
        settle()
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, height * 6, accuracy: 0.5)
    }

    func testAMarkOnRenderedMarkdownFindsItsBlockWhenTheFileWasRewrittenWhileMarkUpWasOff() throws {
        // The stack as `MarkdownView` signs it in: a view as large as the
        // blocks, in a scroll view, and each block's frame in it.
        let size = NSSize(width: 600, height: 400)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        let scroll = NSScrollView(frame: root.bounds)
        let stack = Layer(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        scroll.documentView = stack
        root.addSubview(scroll)
        layer = Layer(frame: root.bounds)
        root.addSubview(layer)
        settle()

        var texts = ["# Title", "one", "two", "three", "four", "five"]
        func signIn() {
            let held = texts
            views.stack = stack
            views.blockFrames = Dictionary(uniqueKeysWithValues: held.indices.map {
                ($0, CGRect(x: 20, y: CGFloat($0) * 50, width: 500, height: 40))
            })
            views.blockKey = { held.indices.contains($0) ? held[$0].hashValue : nil }
            views.changed()
        }
        signIn()
        let surface: any MarkupSurface = BlocksMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        // On "three", the fourth block.
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 40, y: 155, width: 100, height: 20)))
        let before = try XCTUnwrap(surface.placement(of: 1)).origin.y

        // Off with the note kept, and two paragraphs added above it. The
        // document says where its blocks are before the layer is back in
        // its window, so no word of the change comes after.
        surface.deactivate(forgetting: false)
        texts.insert(contentsOf: ["new", "newer"], at: 1)
        signIn()
        surface.activate(moved: {})
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).origin.y, before + 100, accuracy: 0.5)

        // And when the paragraph itself is gone, the mark has no place.
        surface.deactivate(forgetting: false)
        texts.removeAll { $0 == "three" }
        signIn()
        surface.activate(moved: {})
        XCTAssertNil(surface.placement(of: 1))
    }

    func testAMarkGrowsWithTheText() throws {
        let host = show(diff(numbered(40)))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let table = try XCTUnwrap(views.table)
        let before = table.rowHeight
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 80, y: before * 5 + 1, width: 100, height: 10)))
        host.rootView = diff(numbered(40), fontSize: 20)
        settle()
        let after = try XCTUnwrap(views.table).rowHeight
        XCTAssertGreaterThan(after, before)
        let placement = try XCTUnwrap(surface.placement(of: 1))
        XCTAssertEqual(placement.scale, after / before, accuracy: 0.001)
        XCTAssertEqual(placement.origin.y, after * 5, accuracy: 0.5)
    }

    func testAPictureOfAnAreaIsWhatTheTableShowsThereOnThePagesColour() throws {
        _ = show(diff(numbered(100), added: [2]))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let height = try XCTUnwrap(views.table).rowHeight
        var capture: MarkCapture?
        surface.capture(CGRect(x: 0, y: 0, width: 300, height: height * 4)) { capture = $0 }
        let picture = try XCTUnwrap(capture)
        XCTAssertEqual(picture.showing, CGRect(x: 0, y: 0, width: 300, height: (height * 4).rounded(.up)))
        let pixels = try XCTUnwrap(Pixels(picture.image))
        let scale = CGFloat(picture.image.width) / 300
        // No pixel is see-through, and the page's colour is behind the text.
        let corner = pixels.at(x: picture.image.width - 2, y: 2)
        XCTAssertEqual(corner.a, 255)
        // The added line is tinted, a plain one is not: the rows were drawn.
        let plain = pixels.at(x: picture.image.width - 2, y: Int(height * 0.5 * scale))
        let added = pixels.at(x: picture.image.width - 2, y: Int(height * 2.5 * scale))
        XCTAssertNotEqual(plain, added)
        // Past the view's edge there is nothing to picture.
        surface.capture(CGRect(x: 0, y: 5000, width: 10, height: 10)) { capture = $0 }
        XCTAssertNil(capture)
    }

    func testTheWholeFileIsPicturedByScrollingAndTheScrollIsPutBack() throws {
        // 200 lines in a view that shows about 20: the added line near the
        // end is far out of view.
        _ = show(diff(numbered(200), added: [180]))
        let surface: any MarkupSurface = LinesMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        let table = try XCTUnwrap(views.table)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let height = table.rowHeight
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height * 30))
        scroll.reflectScrolledClipView(scroll.contentView)
        let mark = Mark(number: 1, shape: .area(box: CGRect(x: 60, y: 2, width: 100, height: 10), ink: []),
                        name: "area", picture: nil, details: MarkDetails())
        XCTAssertNotNil(tie(surface, 1, to: CGRect(x: 60, y: height * 3 + 2, width: 100, height: 10)))

        var answer: MarkupWhole?
        surface.whole([mark]) { answer = $0 }
        let whole = try XCTUnwrap(answer)
        XCTAssertEqual(scroll.documentVisibleRect.minY, height * 30, accuracy: 0.5, "the scroll was not put back")
        XCTAssertEqual(whole.size.height, height * 200, accuracy: 1)
        // The mark is on row 33 of the file, wherever the view is.
        XCTAssertEqual(try XCTUnwrap(whole.placements[1]).origin.y, height * 33, accuracy: 0.5)

        guard case .canvas(let canvas) = whole.source else { return XCTFail("a table comes with its picture made") }
        XCTAssertFalse(canvas.isPart)
        let picture = try XCTUnwrap(MarkupPicture.whole(whole, marks: [mark], colours: [:]))
        let pixels = try XCTUnwrap(Pixels(picture.image))
        let density = CGFloat(picture.image.height) / whole.size.height
        func row(_ index: Int) -> Pixels.Colour {
            pixels.at(x: picture.image.width - 3, y: Int((CGFloat(index) + 0.5) * height * density))
        }
        // The tinted row was drawn where it is in the file, and its
        // neighbours and the very last row were drawn plain.
        XCTAssertNotEqual(row(180), row(179))
        XCTAssertEqual(row(179), row(181))
        XCTAssertEqual(row(199), row(5))
        XCTAssertEqual(row(180).a, 255)
    }

    // MARK: - An image

    private func picture(_ width: Int, _ height: Int) throws -> NSImage {
        // Red on the left half, blue on the right, at two pixels a point.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: width / 2, y: 0, width: width / 2, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func testAMarkOnAnImageIsInThePicturesOwnPointsAndItsPictureInItsOwnPixels() throws {
        // A 400 by 200 picture in a view half that size: shown at half.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = root
        let imageView = NSImageView(frame: NSRect(x: 50, y: 100, width: 200, height: 100))
        imageView.imageScaling = .scaleProportionallyDown
        imageView.image = try picture(400, 200)
        root.addSubview(imageView)
        layer = Layer(frame: root.bounds)
        root.addSubview(layer)
        views.image = imageView

        let surface: any MarkupSurface = ImageMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})
        // Beside the picture there is nothing to mark.
        XCTAssertNil(tie(surface, 1, to: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let made = try XCTUnwrap(tie(surface, 1, to: CGRect(x: 140, y: 110, width: 20, height: 20)))
        // The view is 100 points down from the top of a 300 point layer.
        XCTAssertEqual(made.placement.origin, CGPoint(x: 50, y: 100))
        XCTAssertEqual(made.placement.scale, 0.5)

        // 20 by 20 points of the view, across the seam between the halves:
        // 40 by 40 points of the picture, which is 80 by 80 of its pixels.
        var capture: MarkCapture?
        surface.capture(CGRect(x: 140, y: 110, width: 20, height: 20)) { capture = $0 }
        let cut = try XCTUnwrap(capture)
        XCTAssertEqual(cut.image.width, 80)
        XCTAssertEqual(cut.image.height, 80)
        let pixels = try XCTUnwrap(Pixels(cut.image))
        XCTAssertEqual(pixels.at(x: 5, y: 40), .init(r: 255, g: 0, b: 0, a: 255))
        XCTAssertEqual(pixels.at(x: 75, y: 40), .init(r: 0, g: 0, b: 255, a: 255))

        // The whole is the picture, in its own points.
        var answer: MarkupWhole?
        surface.whole([]) { answer = $0 }
        let whole = try XCTUnwrap(answer)
        XCTAssertEqual(whole.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(whole.placements[1]?.scale, 1)

        // The view made smaller: the mark's unit follows.
        imageView.frame = NSRect(x: 50, y: 100, width: 100, height: 50)
        XCTAssertEqual(try XCTUnwrap(surface.placement(of: 1)).scale, 0.25)
    }
}

extension MarkupFileTests {
    func testAPictureThatDeclaresAnEnormousSizeIsNotDrawnAtIt() throws {
        // What an SVG can say of itself: 100,000 points a side. Drawn at
        // twice that it would be a bitmap of 160 GB.
        let huge = NSImage(size: NSSize(width: 100_000, height: 100_000), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = root
        let imageView = NSImageView(frame: root.bounds)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.image = huge
        root.addSubview(imageView)
        layer = Layer(frame: root.bounds)
        root.addSubview(layer)
        let views = MarkupViews()
        views.image = imageView
        let surface: any MarkupSurface = ImageMarkupSurface(views: views)
        surface.attach(to: layer)
        surface.activate(moved: {})

        var capture: MarkCapture?
        surface.capture(CGRect(x: 0, y: 0, width: 300, height: 300)) { capture = $0 }
        let cut = try XCTUnwrap(capture)
        XCTAssertLessThanOrEqual(cut.image.width, ViewPicture.mostPixels)
        XCTAssertLessThanOrEqual(cut.image.height, ViewPicture.mostPixels)
        XCTAssertGreaterThan(cut.image.width, 1000)
    }

    func testAPictureLargerThanAllowedIsMadeSmaller() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 6000, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let wide = try XCTUnwrap(context.makeImage())
        let fitted = try XCTUnwrap(ViewPicture.onBackground(wide, CGColor(gray: 1, alpha: 1)))
        XCTAssertEqual(fitted.width, ViewPicture.mostPixels)
        XCTAssertEqual(fitted.height, 205)
        // One that fits is left at its size.
        let small = try XCTUnwrap(wide.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 60)))
        XCTAssertEqual(ViewPicture.onBackground(small, CGColor(gray: 1, alpha: 1))?.width, 80)
    }
}

/// A picture's pixels, counted from the top-left.
private struct Pixels {
    struct Colour: Equatable { let r, g, b, a: UInt8 }
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
        let index = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return Colour(r: data[index], g: data[index + 1], b: data[index + 2], a: data[index + 3])
    }
}
