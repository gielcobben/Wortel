import XCTest

/// The terminal's answers to a replay's old queries, held back until the
/// marker comes home. Both ways of being wrong are silent: an answer let
/// through lands in an agent's prompt as `^[[24;1R`, and a window that never
/// opens eats every key the user types afterwards.
final class ReplayAnswersTests: XCTestCase {

    private func admit(_ gate: inout ReplayAnswers, _ text: String, now: UInt64 = 1) -> String? {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { raw in
            gate.admit(raw, now: now).map { String(decoding: bytes[$0], as: UTF8.self) }
        }
    }

    private var sentinelAnswer: String { "\u{1B}[?\(ReplayAnswers.sentinelMode);0$y" }

    // MARK: - The window

    func testOldAnswersAreDroppedUntilTheMarkerComesBack() {
        var gate = ReplayAnswers(now: 0)
        XCTAssertNil(admit(&gate, "\u{1B}[24;1R"))                   // DSR
        XCTAssertNil(admit(&gate, "\u{1B}[?62;22;52c"))              // DA1
        XCTAssertNil(admit(&gate, "\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\")) // OSC 11
        XCTAssertNil(admit(&gate, "\u{1B}P>|ghostty 1.2.3\u{1B}\\"))  // XTVERSION
        XCTAssertNil(admit(&gate, "\u{1B}[?0u"))                     // kitty keyboard
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(admit(&gate, sentinelAnswer), "")
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.dropped, 5)
        // After the marker, everything is live: a key, and an answer to a
        // query the program is asking now.
        XCTAssertEqual(admit(&gate, "a"), "a")
        XCTAssertEqual(admit(&gate, "\u{1B}[3;7R"), "\u{1B}[3;7R")
    }

    /// The answer queue hands writes over one by one, but nothing promises
    /// that; what follows the marker in the same write is live.
    func testWhatFollowsTheMarkerInOneWriteGoesThrough() {
        var gate = ReplayAnswers(now: 0)
        XCTAssertEqual(admit(&gate, "\u{1B}[1;1R" + sentinelAnswer + "x"), "x")
        XCTAssertTrue(gate.isOpen)
    }

    /// A mode request for some other mode is somebody's real question, not
    /// the marker.
    func testAnotherModeRequestIsNotTheMarker() {
        var gate = ReplayAnswers(now: 0)
        XCTAssertNil(admit(&gate, "\u{1B}[?2004;1$y"))
        XCTAssertNil(admit(&gate, "\u{1B}[?\(ReplayAnswers.sentinelMode)1;0$y"))
        XCTAssertFalse(gate.isOpen)
    }

    func testTheDeadlineOpensTheWindowWhenNoMarkerComes() {
        var gate = ReplayAnswers(now: 0)
        gate.replayWritten(markerSent: false, now: 1_000)
        XCTAssertNil(admit(&gate, "\u{1B}[24;1R", now: 1_000 + ReplayAnswers.unmarkedPatience - 1))
        XCTAssertEqual(admit(&gate, "k", now: 1_000 + ReplayAnswers.unmarkedPatience), "k")
        XCTAssertTrue(gate.isOpen)
    }

    /// While the replay is still being written there is no deadline worth
    /// the name: answers come out as it goes, and a long one waits on the
    /// main thread's mailbox.
    func testTheWindowHoldsWhileTheReplayIsWritten() {
        var gate = ReplayAnswers(now: 0)
        XCTAssertNil(admit(&gate, "\u{1B}[24;1R", now: 3_000_000_000))
        gate.replayWritten(markerSent: true, now: 3_000_000_000)
        XCTAssertNil(admit(&gate, "\u{1B}[24;1R", now: 3_000_000_001))
        XCTAssertEqual(admit(&gate, "k", now: 3_000_000_000 + ReplayAnswers.markerPatience), "k")
    }

    // MARK: - What describes the terminal now

    func testReportsOfTheTerminalNowAreLetThrough() {
        var gate = ReplayAnswers(now: 0)
        XCTAssertEqual(admit(&gate, "\u{1B}[I"), "\u{1B}[I")
        XCTAssertEqual(admit(&gate, "\u{1B}[O"), "\u{1B}[O")
        XCTAssertEqual(admit(&gate, "\u{1B}[?997;1n"), "\u{1B}[?997;1n")
        XCTAssertEqual(admit(&gate, "\u{1B}[48;50;120;1000;2400t"), "\u{1B}[48;50;120;1000;2400t")
        // A size *query*'s answer is a question asked long ago.
        XCTAssertNil(admit(&gate, "\u{1B}[8;50;120t"))
        XCTAssertFalse(gate.isOpen)
    }

    // MARK: - Where the marker may go

    private func clean(_ text: String) -> Bool { ReplayAnswers.endsCleanly(Data(text.utf8)) }

    func testAReplayThatEndsBetweenSequencesIsClean() {
        XCTAssertTrue(clean(""))
        XCTAssertTrue(clean("hello"))
        XCTAssertTrue(clean("\u{1B}[0mdone\r\n"))
        XCTAssertTrue(clean("\u{1B}[38;2;1;2;3m"))
        XCTAssertTrue(clean("\u{1B}]0;✳ title\u{07}"))
        XCTAssertTrue(clean("\u{1B}]0;title\u{1B}\\"))
        XCTAssertTrue(clean("\u{1B}P>|x\u{1B}\\"))
        XCTAssertTrue(clean("\u{1B}7"))
        XCTAssertTrue(clean("\u{1B}(B"))
        XCTAssertTrue(clean("naïve ✳"))
    }

    /// The stream goes on in the first live read; a marker in between would
    /// cut these short and print their tails.
    func testAReplayCutMidSequenceIsNotClean() {
        XCTAssertFalse(clean("text\u{1B}"))
        XCTAssertFalse(clean("\u{1B}[38;2;1;2"))
        XCTAssertFalse(clean("\u{1B}[?"))
        XCTAssertFalse(clean("\u{1B}]0;half a tit"))
        XCTAssertFalse(clean("\u{1B}_Gf=100;AAAA"))
        XCTAssertFalse(clean("\u{1B}("))
        // ✳ is three bytes; two of them.
        XCTAssertFalse(ReplayAnswers.endsCleanly(Data("a".utf8 + Array("✳".utf8).prefix(2))))
    }
}
