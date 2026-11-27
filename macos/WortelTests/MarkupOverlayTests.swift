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
        func attach(to layer: NSView) {}
        func activate(moved: @escaping () -> Void) {}
        func deactivate(forgetting: Bool) {}
        func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
        func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void) {
            picks += 1
            tied[number] = CGSize(width: 40, height: 20)
            reply(.tied(MarkTie(placement: placement(of: number)!, name: "button", details: MarkDetails())))
        }
        func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
            ties.append(box)
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

    override func tearDown() async throws {
        window?.close()
        window = nil
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
}
