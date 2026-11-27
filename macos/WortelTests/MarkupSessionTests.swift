import AppKit
import XCTest

/// A note held by its session, with no window and no layer: what its
/// pictures are called, and what a copy puts on the clipboard.
@MainActor
final class MarkupSessionTests: XCTestCase {
    /// A preview whose picture of the whole is handed over only when the
    /// test says: a slow copy, held as long as it likes.
    private final class HeldSurface: MarkupSurface {
        var replies: [(MarkupWhole?) -> Void] = []

        var view: NSView? { nil }
        var picksThings: Bool { false }
        var scrollsInside: Bool { false }
        var readingColumn: CGRect? { nil }
        func attach(to layer: NSView) {}
        func activate(moved: @escaping () -> Void) {}
        func deactivate(forgetting: Bool) {}
        func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
        func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void) {
            reply(nil)
        }
        func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) { reply(nil) }
        func placement(of number: Int) -> MarkPlacement? { nil }
        func forget(_ number: Int) {}
        func reveal(_ mark: Mark, coveredBelow covered: CGFloat) {}
        func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool { false }
        func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void) { reply(nil) }
        func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void) { replies.append(reply) }
    }

    private var folder: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        // A copy asks the app for its appearance, and these tests run with
        // no app of their own.
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-markup-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: .init("wortel-markup-session-tests-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func session() -> MarkupSession {
        let session = MarkupSession()
        session.store = MarkupStore(root: folder)
        session.pasteboard = pasteboard
        return session
    }

    private func mark(_ number: Int) -> Mark {
        Mark(number: number, shape: .area(box: CGRect(x: 10, y: 20, width: 100, height: 50), ink: []),
             name: "box", picture: nil, details: MarkDetails())
    }

    /// One pixel of one grey, to tell the pictures apart on disk.
    private func picture(_ grey: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext.picture(width: 1, height: 1))
        context.setFillColor(CGColor(gray: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    /// What is on the queue is written, and what it handed to the main
    /// thread has run.
    private func settle() {
        MarkupStore.queue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Pictures

    func testAPicturesNameIsNeverUsedTwiceInOneNote() throws {
        let session = session()
        session.turnOn()
        XCTAssertEqual(session.takeNumber(), 1)
        session.add(mark(1))
        session.keep(try picture(0), for: 1)
        XCTAssertEqual(session.marks.first?.picture, "1.png")

        // Every chip deleted: the next mark is 1 again, in the same folder.
        session.text.setAttributedString(NSAttributedString())
        XCTAssertEqual(session.takeNumber(), 1)
        session.add(mark(1))
        session.keep(try picture(1), for: 1)
        let second = try XCTUnwrap(session.marks.first?.picture)
        XCTAssertNotEqual(second, "1.png")

        // A drawing moved is pictured again: a third name, not the second.
        session.replace(mark(1))
        session.keep(try picture(0.5), for: 1)
        let third = try XCTUnwrap(session.marks.first?.picture)
        XCTAssertNotEqual(third, "1.png")
        XCTAssertNotEqual(third, second)

        // The first path, if it was copied, still shows the first picture.
        settle()
        let note = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).first).appendingPathComponent("1")
        let first = try XCTUnwrap(CGImageSourceCreateWithURL(note.appendingPathComponent("1.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(first, 0, nil))
        XCTAssertEqual(Pixels(image)?.at(x: 0, y: 0).r, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.appendingPathComponent(second).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.appendingPathComponent(third).path))
    }

    // MARK: - Copying

    func testACopyCutShortDoesNotTakeTheClipboardFromANewerOne() throws {
        let session = session()
        let surface = HeldSurface()
        session.surface = surface
        session.turnOn()
        session.add(mark(session.takeNumber()))
        session.text.append(NSAttributedString(string: " the older note"))
        session.copyNote()
        XCTAssertTrue(session.isCopying)

        // The page went elsewhere while the old note's pictures were taken,
        // and a new note was copied before they were.
        session.end()
        session.turnOn()
        session.add(mark(session.takeNumber()))
        session.text.append(NSAttributedString(string: " the newer note"))
        session.copyNote()
        XCTAssertEqual(surface.replies.count, 2)

        surface.replies[0](nil)
        settle()
        surface.replies[1](nil)
        settle()
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("the newer note"), copied)
        XCTAssertFalse(copied.contains("the older note"), copied)
        XCTAssertFalse(session.isCopying)
    }
}
