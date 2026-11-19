import XCTest

/// What `wortel cd` types and says. A wrong `cd` line runs something else in
/// the person's shell; a wrong message has an agent tell its person the move
/// happened when it hasn't.
final class SessionMoveTests: XCTestCase {
    func testAPlainPathIsTypedAsItIs() {
        XCTAssertEqual(SessionMove.cdLine("/Users/x/Developer/opmaak"), "cd /Users/x/Developer/opmaak")
    }

    func testAnythingElseIsSingleQuoted() {
        XCTAssertEqual(SessionMove.cdLine("/Users/x/My Project"), "cd '/Users/x/My Project'")
        XCTAssertEqual(SessionMove.cdLine("/Users/x/it's"), "cd '/Users/x/it'\\''s'")
        XCTAssertEqual(SessionMove.cdLine("/Users/x/$HOME;rm"), "cd '/Users/x/$HOME;rm'")
    }

    /// Typed into zsh, bash or fish alike: what one of them reads differently
    /// is refused, and so is anything not absolute.
    func testWhatCantBeTypedSafelyIsRefused() {
        XCTAssertNil(SessionMove.cdLine("relative/path"))
        XCTAssertNil(SessionMove.cdLine("/Users/x/a\\b"))
        XCTAssertNil(SessionMove.cdLine("/Users/x/a\nrm -rf b"))
        XCTAssertNil(SessionMove.cdLine("/Users/x/\u{1B}[31m"))
    }

    /// The shell may report a link where the request named its target.
    func testTheSameFolderThroughALink() throws {
        let base = NSTemporaryDirectory() + "move-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: base + "/real", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        defer { try? fm.removeItem(atPath: base) }
        XCTAssertTrue(SessionMove.samePath(base + "/link", base + "/real"))
        XCTAssertTrue(SessionMove.samePath(base + "/real/", base + "/real"))
        XCTAssertFalse(SessionMove.samePath(base + "/real", base))
    }

    /// The agent that asked reads this: it must not think it has moved.
    func testWaitingForTheTurnSaysNothingHasMovedYet() {
        let text = SessionMove.acceptedMessage(to: NSHomeDirectory() + "/Developer/opmaak", waitsForTurn: true)
        XCTAssertTrue(text.hasPrefix("Not moved yet."))
        XCTAssertTrue(text.contains("~/Developer/opmaak"))
        XCTAssertFalse(text.contains("\u{2014}"), "no em-dashes in what a person may read")
    }

    func testASecondAskSaysWhichWins() {
        let text = SessionMove.acceptedMessage(to: "/a/new", waitsForTurn: true, instead: "/a/old")
        XCTAssertTrue(text.hasPrefix("Moving to /a/new instead of /a/old."))
    }

    func testTheGuideAsksFirstAndHasNoDashes() {
        XCTAssertTrue(ChatFolder.guide.contains("wortel cd"))
        XCTAssertTrue(ChatFolder.guide.contains("Once \nthe person agrees") || ChatFolder.guide.contains("Once the person agrees"))
        XCTAssertFalse(ChatFolder.guide.contains("\u{2014}"))
    }
}
