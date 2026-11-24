import XCTest

/// A new session opens on an empty page until its program is up. Lifted too
/// early, the startup it hides is on screen again; ended the wrong way, what
/// was typed under it goes to a shell or is thrown away.
final class StartCoverTests: XCTestCase {

    // MARK: - The scanner

    private func scan(_ chunks: [String], scanner: inout StartScanner) -> [StartCover.Event] {
        var events: [StartCover.Event] = []
        for chunk in chunks {
            let bytes = Array(chunk.utf8)
            bytes.withUnsafeBufferPointer { events += scanner.scan($0) }
        }
        return events
    }

    private func scan(_ chunks: String...) -> [StartCover.Event] {
        var scanner = StartScanner()
        return scan(chunks, scanner: &scanner)
    }

    /// Every way of cutting `text` in two gives the same events as one read.
    private func assertHoldsAcrossReads(_ text: String, _ expected: [StartCover.Event],
                                        file: StaticString = #filePath, line: UInt = #line) {
        let scalars = Array(text.utf8)
        for cut in 1..<scalars.count {
            var scanner = StartScanner()
            var events: [StartCover.Event] = []
            for part in [scalars[..<cut], scalars[cut...]] {
                Array(part).withUnsafeBufferPointer { events += scanner.scan($0) }
            }
            XCTAssertEqual(events.filter { $0 != .output }, expected, "cut at \(cut)", file: file, line: line)
        }
    }

    func testPlainOutputIsOnlyOutput() {
        XCTAssertEqual(scan("hello \u{1B}[31mred\u{1B}[0m\r\n"), [.output])
        XCTAssertEqual(scan(""), [])
    }

    func testCommandMarksWithEitherTerminator() {
        XCTAssertEqual(scan("\u{1B}]133;C\u{07}"), [.commandStarted, .output])
        XCTAssertEqual(scan("\u{1B}]133;C\u{1B}\\"), [.commandStarted, .output])
        XCTAssertEqual(scan("\u{1B}]133;D;127\u{07}"), [.commandEnded, .output])
        XCTAssertEqual(scan("\u{1B}]133;D\u{07}"), [.commandEnded, .output])
    }

    func testOtherPromptMarksAndOtherOSCsSayNothing() {
        XCTAssertEqual(scan("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}"), [.output])
        XCTAssertEqual(scan("\u{1B}]2;133;C\u{07}"), [.output])
        XCTAssertEqual(scan("\u{1B}]1330;C\u{07}"), [.output])
        XCTAssertEqual(scan("\u{1B}]133;Cx\u{07}"), [.output])
        XCTAssertEqual(scan("\u{1B}]7;file://host/Users/someone/a/very/long/path/that/goes/on\u{07}"), [.output])
    }

    func testInterfaceModes() {
        XCTAssertEqual(scan("\u{1B}[?2004h"), [.interfaceMode, .output])
        XCTAssertEqual(scan("\u{1B}[?1049h"), [.interfaceMode, .output])
        XCTAssertEqual(scan("\u{1B}[?1000;1002;1006h"), [.interfaceMode, .output])
        XCTAssertEqual(scan("\u{1B}[>5u"), [.interfaceMode, .output])
    }

    func testWhatIsNotAnInterface() {
        // Turned off, the cursor, synchronised output, what a line editor
        // sets for itself, flags of nothing, and sequences with no `?`.
        XCTAssertEqual(scan("\u{1B}[?2004l"), [.output])
        XCTAssertEqual(scan("\u{1B}[?25l\u{1B}[?2026h\u{1B}[?1h"), [.output])
        XCTAssertEqual(scan("\u{1B}[>u\u{1B}[>0u\u{1B}[<u"), [.output])
        XCTAssertEqual(scan("\u{1B}[2004h\u{1B}[1;1H\u{1B}[c"), [.output])
    }

    func testOrderInsideOneRead() {
        // zsh at its prompt with the line already waiting, as one read.
        let read = "\u{1B}]133;A\u{07}% \u{1B}[?2004hclaude\r\n\u{1B}[?2004l\u{1B}]133;C\u{07}"
        XCTAssertEqual(scan(read), [.interfaceMode, .commandStarted, .output])
    }

    func testSequencesCutAnywhere() {
        assertHoldsAcrossReads("\u{1B}]133;C\u{07}\u{1B}[?2004h\u{1B}[>7u\u{1B}]133;D;0\u{1B}\\",
                               [.commandStarted, .interfaceMode, .interfaceMode, .commandEnded])
    }

    func testStringsAreNotReadInto() {
        // tmux passes another terminal's sequences through in a DCS.
        XCTAssertEqual(scan("\u{1B}Ptmux;\u{1B}\u{1B}[?2004h\u{1B}\\"), [.output])
        XCTAssertEqual(scan("\u{1B}_G\u{1B}]133;C\u{07}"), [.output])
        // And reads on after one.
        XCTAssertEqual(scan("\u{1B}Pq\u{1B}\\\u{1B}[?2004h"), [.interfaceMode, .output])
    }

    // MARK: - What is typed meanwhile

    /// A host typing into a pipe, and the pipe's other end to read it from.
    private func typingHost() -> (host: PtyHost, typed: () -> String, close: () -> Void) {
        var typing: [Int32] = [0, 0], channel: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&typing), 0)
        XCTAssertEqual(pipe(&channel), 0)
        _ = fcntl(typing[0], F_SETFL, O_NONBLOCK)
        let host = PtyHost(channel: channel[0], typing: typing[1])
        let typed = { () -> String in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(typing[0], &buffer, buffer.count)
            return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        }
        return (host, typed, {
            host.release() // closes its two ends
            close(typing[0])
            close(channel[1])
        })
    }

    private func type(_ text: String, into host: PtyHost) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { host.write($0.baseAddress!, count: $0.count) }
    }

    func testTypingGoesStraightThroughWhenNothingHoldsIt() {
        let (host, typed, close) = typingHost()
        defer { close() }
        type("a", into: host)
        XCTAssertEqual(typed(), "a")
        host.releaseTyping(deliver: true)
        XCTAssertEqual(typed(), "")
    }

    func testHeldTypingIsHandedOverInOrder() {
        let (host, typed, close) = typingHost()
        defer { close() }
        host.holdTyping()
        for key in ["f", "i", "x", " ", "i", "t"] { type(key, into: host) }
        XCTAssertEqual(typed(), "")
        host.releaseTyping(deliver: true)
        XCTAssertEqual(typed(), "fix it")
        type("!", into: host)
        XCTAssertEqual(typed(), "!")
    }

    func testHeldTypingIsDroppedWhenTheShellWouldReadIt() {
        let (host, typed, close) = typingHost()
        defer { close() }
        host.holdTyping()
        type("rm -rf build", into: host)
        type("\r", into: host)
        host.releaseTyping(deliver: false)
        XCTAssertEqual(typed(), "")
        type("x", into: host)
        XCTAssertEqual(typed(), "x")
    }

    func testAHeldReturnIsNeverTypedNorWhatFollowsIt() {
        // It was pressed at a screen nobody had seen, which may be asking
        // something Return says yes to.
        let (host, typed, close) = typingHost()
        defer { close() }
        host.holdTyping()
        for key in ["g", "o", "\r", "y", "\r"] { type(key, into: host) }
        host.releaseTyping(deliver: true)
        XCTAssertEqual(typed(), "go")
        // One pressed after that is the person's own, at a screen they see.
        type("\r", into: host)
        XCTAssertEqual(typed(), "\r")
    }

    func testAPasteWithAReturnInItIsNotAHeldReturn() {
        // Only the key: text that happens to hold one is one write, kept whole.
        let (host, typed, close) = typingHost()
        defer { close() }
        host.holdTyping()
        type("one\rtwo", into: host)
        host.releaseTyping(deliver: true)
        XCTAssertEqual(typed(), "one\rtwo")
    }

    // MARK: - The rule

    private let patience = StartCover.Patience(shell: 3, interface: 4, marker: 0.15, quiet: 0.05, frame: 0.3)

    /// Feed `events` at their times; the end and when it came. Between
    /// events the waits are checked as the watch's timer would.
    private func run(_ events: [(TimeInterval, StartCover.Event)],
                     until last: TimeInterval = 10) -> (end: StartCover.End, at: TimeInterval)? {
        var cover = StartCover(now: 0, patience: patience)
        for (time, event) in events {
            if let deadline = cover.deadline, deadline < time, let end = cover.check(at: deadline) {
                return (end, deadline)
            }
            if let end = cover.heard(event, at: time) { return (end, time) }
        }
        if let deadline = cover.deadline, deadline <= last, let end = cover.check(at: deadline) {
            return (end, deadline)
        }
        return nil
    }

    private func assertEnds(_ result: (end: StartCover.End, at: TimeInterval)?,
                            _ end: StartCover.End, at time: TimeInterval,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result?.end, end, file: file, line: line)
        XCTAssertEqual(result?.at ?? -1, time, accuracy: 0.0001, file: file, line: line)
    }

    func testAnAgentIsShownWhenItsFirstFrameIsWhole() {
        let result = run([
            (0.20, .interfaceMode),   // zsh's own prompt: before the line, so nothing
            (0.20, .commandStarted),
            (0.21, .agentKnown),
            (0.80, .interfaceMode),
            (0.80, .output),
            (0.82, .output),
        ])
        assertEnds(result, .ready, at: 0.87)
        XCTAssertTrue(StartCover.End.ready.deliversTyping)
    }

    func testAProgramThatNeverGoesQuietIsShownAnyway() {
        var events: [(TimeInterval, StartCover.Event)] = [
            (0.2, .commandStarted), (0.21, .agentKnown), (0.5, .interfaceMode),
        ]
        for step in 0..<40 { events.append((0.5 + Double(step) * 0.02, .output)) }
        assertEnds(run(events), .ready, at: 0.8)
    }

    func testAnInterfaceWithoutAMarkerIsStillAnInterface() {
        // `vim`, or an agent the integration does not know by name.
        assertEnds(run([(0.2, .commandStarted), (0.3, .interfaceMode)]), .ready, at: 0.35)
    }

    func testALineThatIsNoAgentIsNotWaitedFor() {
        let result = run([(0.2, .commandStarted), (0.25, .output), (0.5, .output)])
        assertEnds(result, .notAnAgent, at: 0.35)
        XCTAssertTrue(StartCover.End.notAnAgent.deliversTyping)
    }

    func testAnAgentThatIsNotThere() {
        // `claude` on a Mac without it: the marker is written from the
        // command line, then the shell says it found nothing.
        let result = run([(0.2, .commandStarted), (0.21, .agentKnown), (0.22, .output), (0.23, .commandEnded)])
        assertEnds(result, .ended, at: 0.23)
        XCTAssertFalse(StartCover.End.ended.deliversTyping)
    }

    func testALineOverBeforeTheMarkerWait() {
        assertEnds(run([(0.2, .commandStarted), (0.21, .commandEnded)]), .ended, at: 0.21)
    }

    func testTheProgramsOwnMarksAfterItsInterfaceAreNotAnEnd() {
        // Pi wraps what it renders in prompt marks.
        let result = run([
            (0.2, .commandStarted), (0.21, .agentKnown), (0.5, .interfaceMode),
            (0.51, .commandEnded), (0.51, .output),
        ])
        assertEnds(result, .ready, at: 0.56)
    }

    func testAShellThatNeverRunsTheLine() {
        let result = run([(0.2, .output), (0.3, .interfaceMode), (1.0, .commandEnded)])
        assertEnds(result, .noCommand, at: 3)
        XCTAssertFalse(StartCover.End.noCommand.deliversTyping)
    }

    func testAnAgentThatTakesTooLong() {
        let result = run([(0.5, .commandStarted), (0.52, .agentKnown), (2, .output)])
        assertEnds(result, .tookTooLong, at: 4.5)
        XCTAssertTrue(StartCover.End.tookTooLong.deliversTyping)
    }

    func testTheMarkerArrivingLateIsTooLate() {
        // Past the wait the page is off already; the marker changes nothing.
        let result = run([(0.2, .commandStarted), (0.5, .agentKnown)])
        assertEnds(result, .notAnAgent, at: 0.35)
    }

    func testNothingIsSaidTwice() {
        var cover = StartCover(now: 0, patience: patience)
        XCTAssertNil(cover.heard(.commandStarted, at: 0.2))
        XCTAssertEqual(cover.heard(.commandEnded, at: 0.3), .ended)
        XCTAssertNil(cover.heard(.interfaceMode, at: 0.4))
        XCTAssertNil(cover.check(at: 100))
        XCTAssertNil(cover.deadline)
        XCTAssertEqual(cover.end, .ended)
    }
}
