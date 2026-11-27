import AppKit
import XCTest

/// The mark-up layer itself, its note bar and its session, over a preview
/// that answers as the test says, in a window that is never shown. Events
/// are handed to the layer as the mouse would hand them.
@MainActor
final class MarkupOverlayTests: XCTestCase {
    /// A preview whose content is where the test puts it. A mark is tied
    /// with its origin at `content`, and moving `content` is the page
    /// scrolling or moving things under the marks.
    private final class Page: MarkupSurface {
        let view: NSView?
        var content = CGPoint.zero
        var clip: CGRect
        var picks = 0
        /// A click lands on nothing that can be picked.
        var picksNothing = false
        var ties: [CGRect] = []
        /// Ties wait for `answer()`, as a page's do for its script.
        var holdsTies = false
        private var waiting: [() -> Void] = []
        private var tied: [Int: CGSize] = [:]

        init(view: NSView) {
            self.view = view
            clip = view.bounds
        }

        var picksThings: Bool { true }
        var scrollsInside: Bool { false }
        var readingColumn: CGRect? { nil }
        /// The layer marks are placed and tied through, as a file's
        /// adapter converts through it, and the one each tie went through.
        weak var attached: NSView?
        var tiedThrough: [ObjectIdentifier?] = []
        var isActive = false
        func attach(to layer: NSView) { attached = layer }
        func activate(moved: @escaping () -> Void) { isActive = true }
        func deactivate(forgetting: Bool) { isActive = false }
        func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
        func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void) {
            picks += 1
            if picksNothing { return reply(nil) }
            tied[number] = CGSize(width: 40, height: 20)
            reply(.tied(MarkTie(placement: placement(of: number)!, name: "button", details: MarkDetails())))
        }
        func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
            ties.append(box)
            tiedThrough.append(attached.map(ObjectIdentifier.init))
            let answer = { [self] in
                tied[number] = box.size
                reply(MarkTie(placement: placement(of: number)!, name: nil, details: MarkDetails()))
            }
            if holdsTies { waiting.append(answer) } else { answer() }
        }
        func answer() {
            let all = waiting
            waiting = []
            for reply in all { reply() }
        }
        func placement(of number: Int) -> MarkPlacement? {
            tied[number].map { MarkPlacement(origin: content, size: $0, scale: 1, clip: clip) }
        }
        func forget(_ number: Int) { tied[number] = nil }
        func reveal(_ mark: Mark, coveredBelow covered: CGFloat) {}
        func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool { false }
        func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void) { reply(nil) }
        func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void) { reply(nil) }
    }

    private var window: NSWindow!
    private var root: NSView!
    private var preview: NSView!
    private var page: Page!
    private var session: MarkupSession!
    private var folder: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        let size = NSSize(width: 600, height: 400)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        preview = NSView(frame: root.bounds)
        root.addSubview(preview)
        page = Page(view: preview)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-markup-overlay-tests-\(UUID().uuidString)", isDirectory: true)
        session = MarkupSession()
        session.store = MarkupStore(root: folder)
        session.pasteboard = NSPasteboard(name: .init("wortel-markup-overlay-tests-\(UUID().uuidString)"))
        session.surface = page
        session.turnOn()
    }

    /// Windows of a test's own, beside the one every test has.
    private var others: [NSWindow] = []

    override func tearDown() async throws {
        window?.close()
        window = nil
        others.forEach { $0.close() }
        others = []
        session?.pasteboard.releaseGlobally()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A layer over the preview, mounted the way a page mounts it.
    private func mount() -> MarkupOverlayView {
        let overlay = MarkupOverlayView(session: session, surface: page)
        overlay.follow(preview)
        root.addSubview(overlay, positioned: .above, relativeTo: preview)
        settle()
        return overlay
    }

    private func settle() {
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, on overlay: MarkupOverlayView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ overlay: MarkupOverlayView, from start: CGPoint, to end: CGPoint, letGo: Bool = true) {
        overlay.mouseDown(with: event(.leftMouseDown, start, on: overlay))
        for step in 1...6 {
            let t = CGFloat(step) / 6
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            overlay.mouseDragged(with: event(.leftMouseDragged, point, on: overlay))
        }
        if letGo { overlay.mouseUp(with: event(.leftMouseUp, end, on: overlay)) }
    }

    // MARK: - Leaving

    /// Fading out after mark-up went off, the layer is still in its window
    /// for a moment. A click then goes to the page, and picks nothing.
    func testALayerFadingOutTakesNoClickAndMakesNoMark() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "no fade with Reduce Motion")
        let overlay = mount()
        let point = CGPoint(x: 300, y: 120)
        XCTAssertTrue(root.hitTest(point)?.isDescendant(of: overlay) == true, "the layer takes clicks while on")

        session.turnOff()
        overlay.leave()
        XCTAssertNotNil(overlay.superview, "the layer goes once it has faded")
        XCTAssertNil(overlay.hitTest(point))
        XCTAssertTrue(root.hitTest(point) === preview, "\(String(describing: root.hitTest(point)))")

        // And a press handed to it anyway is nothing.
        overlay.mouseDown(with: event(.leftMouseDown, point, on: overlay))
        overlay.mouseUp(with: event(.leftMouseUp, point, on: overlay))
        XCTAssertEqual(page.picks, 0)
        XCTAssertTrue(session.marks.isEmpty)
    }

    // MARK: - Carrying a drawing

    /// A drawing carried with the Move tool stays under the pointer when the
    /// marks are placed again mid-drag, by a page's report or by the content
    /// moving under it, and lands where it was let go.
    func testADrawingCarriedStaysUnderThePointerWhateverMovesUnderIt() throws {
        let overlay = mount()
        session.tool = .box
        drag(overlay, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))
        let drawn = try XCTUnwrap(page.ties.first)
        let layer = try XCTUnwrap(overlay.markLayers[1])
        XCTAssertEqual(layer.frame.origin, page.clip.origin)

        session.tool = .move
        drag(overlay, from: CGPoint(x: 150, y: 130), to: CGPoint(x: 210, y: 170), letGo: false)
        let carried = CGPoint(x: page.clip.minX + 60, y: page.clip.minY + 40)
        XCTAssertEqual(layer.frame.origin, carried, "carried with the pointer")

        // Placed again with nothing moved: a report, the note growing a line.
        overlay.place()
        XCTAssertEqual(layer.frame.origin, carried, "placed again mid-drag")

        // The page scrolls under it.
        page.content.y -= 30
        overlay.place()
        XCTAssertEqual(layer.frame.origin, carried, "the content moved under it")

        // Let go: tied where it was drawn, 60 by 40 from where it was, not
        // where the content took it.
        page.holdsTies = true
        overlay.mouseUp(with: event(.leftMouseUp, CGPoint(x: 210, y: 170), on: overlay))
        let landed = try XCTUnwrap(page.ties.last)
        XCTAssertEqual(page.ties.count, 2)
        XCTAssertEqual(landed, drawn.offsetBy(dx: 60, dy: 40))

        // Until the page answers it stays there, whatever is placed.
        overlay.place()
        XCTAssertEqual(layer.frame.origin, carried, "let go, not yet tied")

        page.answer()
        XCTAssertEqual(layer.affineTransform(), .identity)
        let mark = try XCTUnwrap(session.mark(1))
        XCTAssertEqual(try XCTUnwrap(page.placement(of: 1)).box(of: mark.shape), landed)
    }

    // MARK: - One note in two windows

    /// A layer on the same note in a window of its own, over a preview of
    /// its own, as a file shown in a second window has.
    private func mountElsewhere() -> MarkupOverlayView {
        let size = NSSize(width: 600, height: 400)
        let other = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        others.append(other)
        let otherRoot = NSView(frame: NSRect(origin: .zero, size: size))
        other.contentView = otherRoot
        let otherPreview = NSView(frame: otherRoot.bounds)
        otherRoot.addSubview(otherPreview)
        let overlay = MarkupOverlayView(session: session, surface: page)
        overlay.follow(otherPreview)
        otherRoot.addSubview(overlay, positioned: .above, relativeTo: otherPreview)
        otherRoot.layoutSubtreeIfNeeded()
        settle()
        return overlay
    }

    /// The file in mark-up in two windows, and the newer one closed: the
    /// marks go to the one left. They were let go of, so the one left drew
    /// no new mark and its preview was no longer followed.
    func testWhenTheLayerWithTheMarksGoesTheOtherOnTheNoteTakesThem() throws {
        let first = mount()
        drag(first, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))
        settle()
        let second = mountElsewhere()
        XCTAssertTrue(session.overlay === second)
        XCTAssertTrue(page.attached === second)
        XCTAssertTrue(second.hasMarks)
        XCTAssertNotNil(second.markLayers[1])
        XCTAssertFalse(first.hasMarks, "placed through the other window's preview")

        second.removeFromSuperview()
        settle()
        XCTAssertTrue(session.overlay === first)
        XCTAssertTrue(page.attached === first)
        XCTAssertTrue(page.isActive, "the layer left was let go of with the one that went")
        XCTAssertTrue(first.hasMarks)

        drag(first, from: CGPoint(x: 300, y: 100), to: CGPoint(x: 400, y: 160))
        settle()
        XCTAssertEqual(session.marks.map(\.number), [1, 2])
        XCTAssertNotNil(first.markLayers[2], "a new mark is drawn on the layer left")
    }

    /// The file in mark-up in two windows: a press in the one without the
    /// marks takes them, and what it draws is tied through its own preview.
    func testAPressOnTheOtherLayerOnTheNoteTiesThroughIt() throws {
        let first = mount()
        let second = mountElsewhere()
        XCTAssertTrue(session.overlay === second)

        drag(first, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))
        settle()
        XCTAssertEqual(session.marks.map(\.number), [1])
        XCTAssertEqual(page.tiedThrough.last, ObjectIdentifier(first), "tied through the other window's layer")
        XCTAssertTrue(session.overlay === first)
        XCTAssertTrue(first.hasMarks)
        XCTAssertNotNil(first.markLayers[1])
        XCTAssertFalse(second.hasMarks)

        // The first going leaves the second with the marks.
        first.removeFromSuperview()
        settle()
        XCTAssertTrue(session.overlay === second)
        XCTAssertNotNil(second.markLayers[1])
        XCTAssertTrue(page.isActive)

        // And the last going lets the preview go.
        second.removeFromSuperview()
        settle()
        XCTAssertNil(session.overlay)
        XCTAssertFalse(page.isActive)
    }

    // MARK: - Pins

    /// A pin is pressed only while it is drawn. A mark whose content went
    /// is hidden, its pin with it, and a press where the pin was begins a
    /// drawing like any other.
    func testAPressWhereAHiddenMarksPinWasDrawsAMark() throws {
        let overlay = mount()
        session.tool = .box
        drag(overlay, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))
        XCTAssertEqual(session.marks.map(\.number), [1])

        // Scrolled far below the mark: it leaves a pin at the top edge.
        page.content.y -= 1000
        overlay.place()
        let layer = try XCTUnwrap(overlay.markLayers[1])
        let pin = try XCTUnwrap(layer.pin, "a mark out of view leaves a pin")
        let at = CGPoint(x: pin.midX, y: pin.midY)
        XCTAssertEqual(overlay.pinned(at: at), 1)

        // What it was on is gone: the mark is hidden, and so is its pin.
        page.forget(1)
        overlay.place()
        XCTAssertTrue(layer.isHidden)
        XCTAssertNil(overlay.pinned(at: at))
        drag(overlay, from: at, to: CGPoint(x: at.x + 100, y: at.y + 60))
        XCTAssertEqual(session.marks.map(\.number), [1, 2], "the hidden pin took the press")
    }

    // MARK: - The note's undo

    /// A tab moving rows has a new layer before the old one is taken down,
    /// both on the same note. What was typed can still be undone after.
    func testUndoOutlivesTheBarALayerMadeAnewReplaces() throws {
        let old = mount()
        old.noteBar.textView.insertText("make it bigger", replacementRange: NSRange(location: 0, length: 0))
        settle()
        XCTAssertTrue(session.undo.canUndo)

        let new = mount()
        old.removeFromSuperview()
        settle()
        XCTAssertTrue(session.overlay === new)
        XCTAssertTrue(session.undo.canUndo, "the new bar's undo was cleared by the old one going")
        session.undo.undo()
        XCTAssertEqual(session.text.string, "")
        XCTAssertEqual(new.noteBar.textView.string, "")
        session.undo.redo()
        XCTAssertEqual(new.noteBar.textView.string, "make it bigger")

        // The last bar on the note going takes the stack with it.
        new.removeFromSuperview()
        settle()
        XCTAssertFalse(session.undo.canUndo)
    }

    /// A note longer than the bar's six lines scrolls, and the line being
    /// typed on stays in sight. The text view stayed the box's height once,
    /// its words ran on below the bar and nothing scrolled.
    func testALongNoteScrollsAndKeepsTheCaretInSight() throws {
        let overlay = mount()
        let text = overlay.noteBar.textView
        window.makeFirstResponder(text)
        for line in 1...12 {
            if line > 1 { text.insertNewlineIgnoringFieldEditor(nil) }
            text.insertText("line \(line)", replacementRange: text.selectedRange())
            settle()
        }
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let visible = scroll.contentView.bounds
        XCTAssertGreaterThan(text.frame.height, visible.height, "the text view grows past the box")
        XCTAssertGreaterThan(visible.minY, 0, "the note scrolled to its end")
        let caret = text.firstRect(forCharacterRange: text.selectedRange(), actualRange: nil)
        let inText = text.convert(window.convertFromScreen(caret), from: nil)
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(inText), "caret \(inText) out of \(visible)")
        // Its line whole, not cut by the bar's edge.
        XCTAssertEqual(visible.maxY, text.frame.height, accuracy: 1)
    }

    /// Lines typed into the note as a person types them, one Return apart.
    private func type(_ lines: [String], into overlay: MarkupOverlayView) {
        let text = overlay.noteBar.textView
        window.makeFirstResponder(text)
        for (index, line) in lines.enumerated() {
            if index > 0 { text.insertNewlineIgnoringFieldEditor(nil) }
            text.insertText(line, replacementRange: text.selectedRange())
            settle()
        }
    }

    /// Whether the line the caret is on is in the note's box.
    private func caretInSight(_ overlay: MarkupOverlayView) throws -> Bool {
        let text = overlay.noteBar.textView
        let layout = try XCTUnwrap(text.layoutManager)
        let end = NSMaxRange(text.selectedRange())
        let line = end < (text.string as NSString).length || layout.extraLineFragmentRect.isEmpty
            ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: max(end - 1, 0)),
                                      effectiveRange: nil)
            : layout.extraLineFragmentRect
        let box = try XCTUnwrap(text.enclosingScrollView).contentView.bounds
        return box.minY <= line.minY + 1 && line.maxY <= box.maxY + 1
    }

    /// A long note put back (its layer left the window and came back) opens
    /// at its caret, and not at its first lines.
    func testALongNoteComesBackAtItsCaret() throws {
        let overlay = mount()
        type((1...12).map { "line \($0)" }, into: overlay)
        overlay.removeFromSuperview()
        settle()
        root.addSubview(overlay, positioned: .above, relativeTo: preview)
        settle()
        let box = try XCTUnwrap(overlay.noteBar.textView.enclosingScrollView).contentView.bounds
        XCTAssertGreaterThan(box.minY, 0, "the note opened at its top")
        XCTAssertTrue(try caretInSight(overlay))
    }

    /// The preview made narrower wraps a long note onto more lines: the
    /// caret, in sight before, stays in sight. A note scrolled back to read
    /// stays where it was through a resize.
    func testAResizeKeepsTheCaretOrTheReadingPlace() throws {
        let overlay = mount()
        type((1...10).map { "line \($0), long enough to wrap when the preview is narrow" }, into: overlay)
        XCTAssertTrue(try caretInSight(overlay))

        preview.frame.size.width = 320
        settle()
        XCTAssertTrue(try caretInSight(overlay), "the caret went out of sight as the words wrapped")

        let text = overlay.noteBar.textView
        text.scroll(.zero)
        settle()
        XCTAssertFalse(try caretInSight(overlay))
        preview.frame.size.width = 600
        settle()
        let box = try XCTUnwrap(text.enclosingScrollView).contentView.bounds
        XCTAssertEqual(box.minY, 0, "a resize jumped the note back to its caret")
    }

    /// The note cleared as the trash button clears it: one edit of the text.
    private func clear(_ overlay: MarkupOverlayView) {
        let text = overlay.noteBar.textView
        text.breakUndoCoalescing()
        text.insertText("", replacementRange: NSRange(location: 0, length: session.text.length))
        text.breakUndoCoalescing()
        settle()
    }

    private func click(_ overlay: MarkupOverlayView, at point: CGPoint) {
        overlay.mouseDown(with: event(.leftMouseDown, point, on: overlay))
        overlay.mouseUp(with: event(.leftMouseUp, point, on: overlay))
        settle()
    }

    /// Two boxes drawn, each its own turn of the run loop, which is what
    /// closes an undo group: one group for both and ⌘Z took both out.
    private func drawTwo(_ overlay: MarkupOverlayView) {
        drag(overlay, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))
        settle()
        drag(overlay, from: CGPoint(x: 300, y: 100), to: CGPoint(x: 400, y: 160))
        settle()
    }

    /// Cleared, then a click on nothing: no mark was made, so nothing has
    /// started over, and ⌘Z still brings the note back. The count started
    /// over at the click, before the page had answered, and took the undo
    /// with it.
    func testAClickThatMakesNoMarkAfterClearingKeepsTheUndo() throws {
        let overlay = mount()
        drawTwo(overlay)
        XCTAssertEqual(session.marks.map(\.number), [1, 2])

        clear(overlay)
        XCTAssertTrue(session.marks.isEmpty)
        page.picksNothing = true
        click(overlay, at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(page.picks, 1)
        XCTAssertTrue(session.marks.isEmpty)
        XCTAssertEqual(session.upcomingNumber, 1, "the next mark still counts from 1")

        XCTAssertTrue(session.undo.canUndo, "the click on nothing took the undo")
        session.undo.undo()
        XCTAssertEqual(session.marks.map(\.number), [1, 2])
        XCTAssertNotNil(page.placement(of: 1))
        XCTAssertNotNil(page.placement(of: 2))
        XCTAssertEqual(session.upcomingNumber, 3)
    }

    /// Cleared, then a mark made: it is 1, and the cleared marks are let go
    /// for good, on the page too. An undo takes the new chip out and
    /// brings none of the old ones back beside it.
    func testAMarkMadeAfterClearingStartsOverAndLetsTheClearedGo() throws {
        let overlay = mount()
        drawTwo(overlay)
        clear(overlay)

        click(overlay, at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(session.marks.map(\.number), [1])
        XCTAssertEqual(session.mark(1)?.shape, .thing, "the new mark, not the cleared drawing")
        XCTAssertNil(page.placement(of: 2), "the cleared mark is still tied on the page")

        session.undo.undo()
        XCTAssertTrue(session.marks.isEmpty)
        XCTAssertFalse(session.undo.canUndo)
    }
}
