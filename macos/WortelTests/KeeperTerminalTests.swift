import XCTest

/// The keeper's terminal: a libghostty-vt terminal that has to be an exact,
/// complete copy of what the program drew, and the one thing that answers the
/// program. Everything the app shows comes from its snapshot, so a snapshot
/// that drops anything (a half-received sequence, the other screen, a line of
/// scrollback) is a terminal the person sees wrong, for good.
final class KeeperTerminalTests: XCTestCase {
    private func terminal(_ columns: UInt16 = 40, _ rows: UInt16 = 10,
                          scrollback: Int = 10_000_000) -> KeeperTerminal {
        guard let terminal = KeeperTerminal(columns: columns, rows: rows, scrollbackBytes: scrollback) else {
            XCTFail("libghostty-vt made no terminal")
            fatalError()
        }
        return terminal
    }

    private func write(_ terminal: KeeperTerminal, _ string: String) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBufferPointer { terminal.write($0.baseAddress!, count: $0.count) }
    }

    /// Everything the terminal says to the program while `body` runs.
    private func replies(of terminal: KeeperTerminal, _ body: () -> Void) -> String {
        var said = [UInt8]()
        terminal.reply = { bytes, count in said += UnsafeBufferPointer(start: bytes, count: count) }
        body()
        terminal.reply = nil
        return String(decoding: said, as: UTF8.self)
    }

    private func roundTrip(_ terminal: KeeperTerminal) -> KeeperTerminal {
        guard let snapshot = terminal.snapshot(),
              let copy = KeeperTerminal(snapshot: snapshot, scrollbackBytes: 10_000_000) else {
            XCTFail("snapshot did not round-trip")
            fatalError()
        }
        return copy
    }

    // MARK: - Snapshots

    func testSnapshotKeepsTheScreenAndTheScrollback() {
        let original = terminal(40, 5)
        for line in 1...300 { write(original, "line \(line)\r\n") }
        let copy = roundTrip(original)
        XCTAssertEqual(copy.text(), original.text())
        XCTAssertTrue(copy.text().hasPrefix("line 1\n"), "the first line, long since scrolled off, is kept")
        XCTAssertTrue(copy.text().contains("line 300"))
        XCTAssertEqual(copy.columns, 40)
        XCTAssertEqual(copy.rows, 5)
    }

    /// A read of the pty can end anywhere, in the middle of an escape
    /// sequence or a UTF-8 character. The snapshot carries the half that came,
    /// and the copy goes on from the next byte as if it had never stopped.
    func testSnapshotTakenMidSequenceGoesOnFromTheNextByte() {
        let original = terminal()
        write(original, "plain \u{1B}[3")             // half a CSI
        let copy = roundTrip(original)
        for t in [original, copy] { write(t, "1mred\u{1B}[0m and é") }
        XCTAssertEqual(copy.text(), original.text())
        XCTAssertEqual(copy.text(), "plain red and é")

        // And half a UTF-8 character: é is C3 A9.
        let split = terminal()
        let first: [UInt8] = Array("café".utf8.dropLast())
        first.withUnsafeBufferPointer { split.write($0.baseAddress!, count: $0.count) }
        let resumed = roundTrip(split)
        let last: [UInt8] = [0xA9]
        for t in [split, resumed] { last.withUnsafeBufferPointer { t.write($0.baseAddress!, count: 1) } }
        XCTAssertEqual(resumed.text(), "café")
    }

    /// An agent in the alternate screen (vim, htop, a full-screen TUI) has a
    /// shell's scrollback waiting under it. Both come back.
    func testSnapshotKeepsBothScreensAndTheModes() {
        let original = terminal()
        write(original, "shell history\r\n")
        write(original, "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?1004h\u{1B}[>5u\u{1B}[Hfull screen")
        let copy = roundTrip(original)
        XCTAssertTrue(copy.mode(1049), "alternate screen")
        XCTAssertTrue(copy.mode(2004), "bracketed paste: without it every pasted line is Enter")
        XCTAssertTrue(copy.mode(1004), "focus reporting")
        XCTAssertEqual(copy.text(), "full screen")
        for t in [original, copy] { write(t, "\u{1B}[?1049l") }
        XCTAssertEqual(copy.text(), original.text())
        XCTAssertTrue(copy.text().hasPrefix("shell history"))
    }

    // MARK: - Size

    /// The primary screen re-wraps on a resize, as the app's does, so a
    /// hidden session's terminal is always at the size its pty has.
    func testResizeReflowsAndReportsInBandWhenAsked() {
        let t = terminal(20, 5)
        write(t, String(repeating: "x", count: 30))
        t.resize(columns: 40, rows: 5, cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(t.text(), String(repeating: "x", count: 30))
        XCTAssertEqual(t.columns, 40)

        write(t, "\u{1B}[?2048h")
        let said = replies(of: t) { t.resize(columns: 50, rows: 6, cellWidth: 8, cellHeight: 16) }
        XCTAssertEqual(said, "\u{1B}[48;6;50;96;400t", "in-band size report (mode 2048)")
    }

    // MARK: - Answers

    /// The keeper answers what Ghostty's own terminal answered, so a program
    /// cannot tell who did.
    func testAnswersQueriesTheWayGhosttyDoes() {
        let t = terminal()
        write(t, "ab")
        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}[6n") }, "\u{1B}[1;3R", "cursor position")
        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}[c") }, "\u{1B}[?62;22;52c", "DA1")
        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}[>c") }, "\u{1B}[>1;10;0c", "DA2")
        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}[?2004$p") }, "\u{1B}[?2004;2$y", "DECRQM, reset")
        XCTAssertTrue(replies(of: t) { write(t, "\u{1B}[>q") }.hasPrefix("\u{1B}P>|ghostty "), "XTVERSION")
    }

    /// Light or dark is not known until the app says; a question before that
    /// goes unanswered rather than answered wrong. After, it is answered, and
    /// a program that subscribed (`?2031`) is told when it changes, with or
    /// without an app attached.
    func testColorSchemeIsAnsweredOnceKnownAndReportedOnChange() {
        let t = terminal()
        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}[?996n") }, "")

        let dark = KeeperTerminal.Appearance(dark: true, foreground: 0xE6EDF3, background: 0x0D1117)
        t.setAppearance(dark)
        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}[?996n") }, "\u{1B}[?997;1n")

        write(t, "\u{1B}[?2031h")
        var light = dark
        light.dark = false
        XCTAssertEqual(replies(of: t) { t.setAppearance(light) }, "\u{1B}[?997;2n")
        XCTAssertEqual(replies(of: t) { t.setAppearance(light) }, "", "no report when nothing changed")

        XCTAssertEqual(replies(of: t) { write(t, "\u{1B}]11;?\u{1B}\\") }.contains("rgb:0d0d/1111/1717"), true,
                       "OSC 11 answers the app's background")
    }

    // MARK: - Memory

    /// Scrollback nobody is reading is compressed, and a compressed terminal
    /// snapshots exactly as it was: it is what an app restores from.
    func testCompressedScrollbackSnapshotsTheSameAndTakesLess() {
        let t = terminal(80, 24)
        for line in 1...20_000 { write(t, "line \(line) of a log nobody is scrolling through\r\n") }
        let before = t.residentBytes, text = t.text()
        var steps = 0
        while t.compressStep(), steps < 10_000 { steps += 1 }
        XCTAssertLessThan(t.residentBytes, before / 2, "compressed \(before) to \(t.residentBytes)")
        XCTAssertEqual(roundTrip(t).text(), text)
        XCTAssertEqual(t.text(), text)
    }

    /// A runaway log can't grow the keeper without bound: scrollback is kept
    /// in whole pages up to the limit, oldest dropped first.
    func testScrollbackIsBounded() {
        let small = terminal(80, 24, scrollback: 1_000_000)
        let line = String(repeating: "y", count: 79) + "\r\n"
        let chunk = String(repeating: line, count: 1000)
        for _ in 0..<100 { write(small, chunk) }            // 8 MB written
        XCTAssertLessThan(small.residentBytes, 4_000_000, "kept: \(small.residentBytes) bytes")
        XCTAssertFalse(small.text().isEmpty)
    }
}
