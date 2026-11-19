import XCTest

/// A program that reports its own state is taken at its word, and nothing
/// else corrects it. A report misread is a wrong dot; one missed is an agent
/// that finished and told nobody.
final class ProgramStatusTests: XCTestCase {

    private func parse(_ body: String) -> ProgramStatusReport? {
        ProgramStatusReport.parse(Array(body.utf8))
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private func hear(_ chunks: [String], scanner: inout ProgramSignalScanner) -> [ProgramSignal] {
        var heard: [ProgramSignal] = []
        for chunk in chunks {
            Array(chunk.utf8).withUnsafeBufferPointer { heard += scanner.scan($0) }
        }
        return heard
    }

    private func hear(_ chunks: String...) -> [ProgramSignal] {
        var scanner = ProgramSignalScanner()
        return hear(chunks, scanner: &scanner)
    }

    /// The status reports among what was heard.
    private func scan(_ chunks: String...) -> [ProgramStatusReport] {
        var scanner = ProgramSignalScanner()
        return hear(chunks, scanner: &scanner).compactMap {
            if case .status(let report) = $0 { return report }
            return nil
        }
    }

    // MARK: - Reports as the agents send them

    func testCodexReports() {
        XCTAssertEqual(parse("state=working:app=codex"),
                       .status(ProgramStatus(state: .working, app: "codex")))
        XCTAssertEqual(parse("state=blocked:app=codex:kind=permission"),
                       .status(ProgramStatus(state: .blocked, kind: .permission, app: "codex")))
        XCTAssertEqual(parse("state=done:app=codex"),
                       .status(ProgramStatus(state: .done, app: "codex")))
        XCTAssertEqual(parse("state=error:app=codex"),
                       .status(ProgramStatus(state: .error, app: "codex")))
        XCTAssertEqual(parse("state=clear"), .clear)
    }

    /// Captured from Claude Code 2.1.328 at the trust dialog (2026-11-19).
    func testClaudeCodeBlockedWithMessage() {
        XCTAssertEqual(
            parse("state=blocked:app=claude-code:kind=permission:msg=dHJ1c3QgdGhpcyBmb2xkZXI="),
            .status(ProgramStatus(state: .blocked, kind: .permission, app: "claude-code",
                                  message: "trust this folder")))
    }

    func testQuery() {
        XCTAssertEqual(parse("?"), .query)
    }

    /// The terminal's side of the exchange. Reading it as a query would have
    /// Wortel answer an answer.
    func testAReplyIsNotAQuery() {
        XCTAssertNil(parse("?:states=idle,working,done,blocked,error"))
    }

    // MARK: - The spec's rules

    func testStateIsRequiredAndMustBeKnown() {
        XCTAssertNil(parse("app=codex"))
        XCTAssertNil(parse("state=paused:app=codex"))
        XCTAssertNil(parse(""))
    }

    func testUnknownKeysAndMalformedPairsAreSkipped() {
        XCTAssertEqual(parse("colour=red:state=done:nonsense:=x:app=codex"),
                       .status(ProgramStatus(state: .done, app: "codex")))
        // A byte outside the value set spoils its pair, not the report.
        XCTAssertEqual(parse("state=done:app=co dex"),
                       .status(ProgramStatus(state: .done)))
    }

    func testARepeatedKeyTakesTheLastValue() {
        XCTAssertEqual(parse("state=working:state=done"), .status(ProgramStatus(state: .done)))
    }

    func testWhitespaceAroundKeysAndValuesIsRemoved() {
        XCTAssertEqual(parse(" state = done : app = pi "),
                       .status(ProgramStatus(state: .done, app: "pi")))
    }

    func testKindOnlyCountsWhenBlocked() {
        XCTAssertEqual(parse("state=working:kind=permission"), .status(ProgramStatus(state: .working)))
        XCTAssertEqual(parse("state=blocked:kind=telepathy"), .status(ProgramStatus(state: .blocked)))
        XCTAssertEqual(parse("state=blocked:kind=auth"),
                       .status(ProgramStatus(state: .blocked, kind: .auth)))
    }

    /// A record with an id is one piece of the program's work. Claude Code
    /// lists its background commands and remote agents this way.
    func testChildRecords() {
        XCTAssertEqual(parse("state=blocked:id=build/test:kind=permission:title=\(base64("EU West"))"),
                       .status(ProgramStatus(state: .blocked, kind: .permission, id: "build/test",
                                             title: "EU West")))
        XCTAssertEqual(parse("state=clear:id=build"), .clearRecord("build"))
    }

    /// One that is no valid id ignores the report: falling back to the root
    /// would let a malformed id overwrite it.
    func testABadIdIgnoresTheReport() {
        XCTAssertNil(parse("state=done:id=a//b"))
        XCTAssertNil(parse("state=done:id=/a"))
        XCTAssertNil(parse("state=done:id=a,b"))
        XCTAssertNil(parse("state=done:id=\(String(repeating: "a", count: 33))"))
        XCTAssertNil(parse("state=done:id=1/2/3/4/5/6/7/8/9"))
        XCTAssertNotNil(parse("state=done:id=1/2/3/4/5/6/7/8"))
        XCTAssertNil(parse("state=clear:id=a b"))
    }

    /// The log says what state and whose, never the program's own words.
    func testTheLogLeavesOutTheWords() {
        XCTAssertEqual(parse("state=blocked:kind=permission:app=codex:msg=\(base64("rm -rf build"))")?.logDescription,
                       "blocked/permission app=codex +msg")
        XCTAssertEqual(parse("state=working:id=bash_1:title=\(base64("secret plan"))")?.logDescription,
                       "working record=bash_1")
        XCTAssertEqual(parse("state=clear:id=bash_1")?.logDescription, "clear record=bash_1")
        XCTAssertEqual(ProgramStatusReport.clear.logDescription, "clear")
    }

    // MARK: - The records a terminal holds

    private func records(_ bodies: String...) -> ProgramRecords {
        var records = ProgramRecords()
        for body in bodies {
            guard let report = parse(body) else { XCTFail("unreadable: \(body)"); continue }
            records.apply(report)
        }
        return records
    }

    func testTheRootIsWhatTheSessionComesTo() {
        XCTAssertNil(ProgramRecords().effective)
        XCTAssertEqual(records("state=working:app=codex").effective,
                       ProgramStatus(state: .working, app: "codex"))
        // Each report replaces its record completely.
        XCTAssertEqual(records("state=blocked:kind=permission:app=codex", "state=done").effective,
                       ProgramStatus(state: .done))
    }

    /// A program waiting on its own background work says `working` itself.
    /// The pieces being listed changes nothing.
    func testWorkingChildrenChangeNothing() {
        XCTAssertEqual(records("state=done:app=claude-code", "state=working:id=bash-1").effective,
                       ProgramStatus(state: .done, app: "claude-code"))
    }

    /// A piece of work blocked on the user is the program waiting on the
    /// user, whatever the root says meanwhile.
    func testABlockedChildIsABlockedSession() {
        let blocked = records(
            "state=done:app=claude-code",
            "state=blocked:kind=question:id=agent-7:title=\(base64("Migration plan")):msg=\(base64("Which database?"))")
        XCTAssertEqual(blocked.effective,
                       ProgramStatus(state: .blocked, kind: .question, app: "claude-code",
                                     message: "Migration plan: Which database?"))
    }

    /// What it waits on, apart from what it says of itself: the two are read
    /// separately, so a question answered is never a turn ending.
    func testTheBlockIsApartFromTheRoot() {
        XCTAssertNil(records("state=working").block)
        XCTAssertNil(records("state=done", "state=working:id=bash-1").block)
        XCTAssertEqual(records("state=blocked:kind=auth").block?.kind, .auth)
        let child = records("state=done:app=claude-code", "state=blocked:kind=question:id=agent-7")
        XCTAssertEqual(child.root?.state, .done)
        XCTAssertEqual(child.block?.kind, .question)
        XCTAssertEqual(child.effective?.state, .blocked)
    }

    func testTheRootsOwnBlockComesFirst() {
        let both = records("state=blocked:kind=permission:msg=\(base64("Run npm test"))",
                           "state=blocked:kind=question:id=agent-7")
        XCTAssertEqual(both.effective?.message, "Run npm test")
    }

    /// Which of two waiting pieces is shown must not move as others report.
    func testTheFirstBlockedChildByIdIsShown() {
        let two = records("state=working", "state=blocked:id=b:msg=\(base64("second"))",
                          "state=blocked:id=a:msg=\(base64("first"))", "state=working:id=c")
        XCTAssertEqual(two.effective?.message, "first")
    }

    func testClearingARecordTakesWhatIsBeneathIt() {
        var cleared = records("state=working", "state=blocked:id=build", "state=blocked:id=build/test",
                              "state=working:id=builder")
        XCTAssertEqual(cleared.effective?.state, .blocked)
        cleared.apply(.clearRecord("build"))
        XCTAssertEqual(cleared.effective, ProgramStatus(state: .working))
        XCTAssertEqual(cleared.childrenInOrder.map(\.id), ["builder"])
    }

    func testClearTakesEverything() {
        var all = records("state=working", "state=blocked:id=a")
        all.apply(.clear)
        XCTAssertNil(all.effective)
        XCTAssertEqual(all, ProgramRecords())
    }

    /// Past the cap, the record updated longest ago makes room.
    func testTheOldestChildMakesRoom() {
        var many = ProgramRecords()
        for index in 0...ProgramRecords.maximumChildren {
            many.apply(.status(ProgramStatus(state: .working, id: "t\(index)")))
        }
        XCTAssertEqual(many.childrenInOrder.count, ProgramRecords.maximumChildren)
        XCTAssertEqual(many.childrenInOrder.first?.id, "t1")
        // Written again, a record is the newest.
        many.apply(.status(ProgramStatus(state: .blocked, id: "t1")))
        XCTAssertEqual(many.childrenInOrder.last?.id, "t1")
    }

    func testMessageWithoutPadding() {
        XCTAssertEqual(parse("state=done:msg=aGk"), .status(ProgramStatus(state: .done, message: "hi")))
    }

    /// Bad base64 or a control character discards the whole report: nothing
    /// from it is applied.
    func testABadMessageDiscardsTheReport() {
        // In the value set, and not base64. (A byte outside the set spoils
        // only its pair: see `testUnknownKeysAndMalformedPairsAreSkipped`.)
        XCTAssertNil(parse("state=done:msg=a"))
        XCTAssertNil(parse("state=done:msg=\(base64("two\nlines"))"))
        XCTAssertNil(parse("state=done:msg=\(base64("bell\u{07}"))"))
        XCTAssertNil(parse("state=done:title=\(base64("tab\there"))"))
    }

    func testLimits() {
        let long = String(repeating: "a", count: ProgramStatusReport.maximumDecodedMessage + 1)
        XCTAssertNil(parse("state=done:msg=\(base64(long))"))
        let fits = String(repeating: "a", count: ProgramStatusReport.maximumDecodedMessage)
        XCTAssertNotNil(parse("state=done:msg=\(base64(fits))"))
        // A limit broken discards the report whole, unlike a malformed pair.
        let app = String(repeating: "a", count: ProgramStatusReport.maximumAppLength + 1)
        XCTAssertNil(parse("state=done:app=\(app)"))
        let key = String(repeating: "k", count: ProgramStatusReport.maximumKeyLength + 1)
        XCTAssertNil(parse("state=done:\(key)=1"))
    }

    /// An app name outside its own character set is absent, and the report
    /// still counts.
    func testAnAppNameOutsideItsCharacterSetIsAbsent() {
        XCTAssertEqual(parse("state=done:app=a/b"), .status(ProgramStatus(state: .done)))
        XCTAssertEqual(parse("state=done:app=claude-code"),
                       .status(ProgramStatus(state: .done, app: "claude-code")))
    }

    /// An id that is no valid id must not fall back to the root record.
    func testAnEmptyIdIsNotTheRoot() {
        XCTAssertNil(parse("state=done:id="))
    }

    /// What Claude Code sends for a background command, by its own builder
    /// (2.1.328): state, app, id, a rounded progress, a title, a message.
    func testClaudeCodeChildRecord() {
        XCTAssertEqual(
            parse("state=working:app=claude-code:id=bash_3:progress=40:title=\(base64("npm run build"))"),
            .status(ProgramStatus(state: .working, app: "claude-code", id: "bash_3", title: "npm run build")))
        XCTAssertEqual(parse("state=clear:id=bash_3"), .clearRecord("bash_3"))
    }

    /// `progress` and `title` are read past: the spinner has no percentage,
    /// and the root's label is the session's name.
    func testProgressAndTitleAreReadPast() {
        XCTAssertEqual(parse("state=working:progress=40:title=VVMgRWFzdA==:app=deploy"),
                       .status(ProgramStatus(state: .working, app: "deploy")))
    }

    /// The message ends up in a banner, outside the terminal's grid.
    func testMessageLosesDirectionOverridesAndInvisibles() {
        let sly = "safe\u{202E}txt.exe\u{200B}\u{2066}"
        XCTAssertEqual(parse("state=blocked:msg=\(base64(sly))"),
                       .status(ProgramStatus(state: .blocked, message: "safetxt.exe")))
    }

    // MARK: - Finding reports in the output

    func testFindsAReportAmongOutput() {
        XCTAssertEqual(
            scan("hello \u{1B}[31mred\u{1B}[0m\u{1B}]7501;state=working:app=codex\u{1B}\\ more"),
            [.status(ProgramStatus(state: .working, app: "codex"))])
    }

    func testBothTerminators() {
        XCTAssertEqual(scan("\u{1B}]7501;state=done\u{07}\u{1B}]7501;state=idle\u{1B}\\"),
                       [.status(ProgramStatus(state: .done)), .status(ProgramStatus(state: .idle))])
    }

    /// A read can end anywhere, the middle of the number included.
    func testAReportSplitAtEveryByte() {
        let sequence = "\u{1B}]7501;state=blocked:kind=question:app=pi\u{1B}\\"
        let bytes = Array(sequence.utf8)
        for cut in 1..<bytes.count {
            var scanner = ProgramSignalScanner()
            var heard: [ProgramSignal] = []
            Array(bytes[..<cut]).withUnsafeBufferPointer { heard += scanner.scan($0) }
            Array(bytes[cut...]).withUnsafeBufferPointer { heard += scanner.scan($0) }
            XCTAssertEqual(heard, [.status(.status(ProgramStatus(state: .blocked, kind: .question, app: "pi")))],
                           "cut at \(cut)")
        }
    }

    func testOtherSequencesAreNotReports() {
        XCTAssertEqual(hear("\u{1B}]0;state=done\u{07}"), [])
        XCTAssertEqual(hear("\u{1B}]75010;state=done\u{07}"), [])
        XCTAssertEqual(hear("\u{1B}]9;4;3\u{07}\u{1B}]133;D;0\u{07}"), [])
        XCTAssertEqual(hear("\u{1B}]7501\u{07}"), [])
        XCTAssertEqual(hear("]7501;state=done\u{07}"), [])
        XCTAssertEqual(hear("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\"), [])
    }

    // MARK: - A program's own notifications

    /// The three ways a program asks for one, heard off the output so that
    /// libghostty's one-a-second limit for the whole app is not in the way.
    func testNotificationsAreHeard() {
        XCTAssertEqual(hear("\u{1B}]9;Approval requested: npm test\u{07}"),
                       [.notification(TerminalNotification(title: "", body: "Approval requested: npm test"))])
        XCTAssertEqual(hear("\u{1B}]777;notify;Amp;Waiting for Approval\u{1B}\\"),
                       [.notification(TerminalNotification(title: "Amp", body: "Waiting for Approval"))])
        XCTAssertEqual(hear("\u{1B}]99;i=1:d=0;Build\u{1B}\\", "\u{1B}]99;i=1:p=body;done\u{1B}\\"),
                       [.notification(TerminalNotification(title: "Build", body: "done"))])
    }

    /// OSC 9 is ConEmu's too: a number first is one of its subcommands, and
    /// `9;4` is progress, which is the terminal's to read.
    func testProgressIsNotANotification() {
        XCTAssertEqual(hear("\u{1B}]9;4;3\u{07}\u{1B}]9;4;0\u{07}\u{1B}]9;12\u{07}"), [])
    }

    /// Two in the same read, saying the same: both heard. The limit that
    /// drops one of these is the one this exists to get past.
    func testTwoAtOnceAreBothHeard() {
        let said = "\u{1B}]9;Approval requested: npm test\u{07}"
        XCTAssertEqual(hear(said + said).count, 2)
    }

    func testReportsAndNotificationsKeepTheirOrder() {
        XCTAssertEqual(
            hear("\u{1B}]7501;state=blocked:kind=permission\u{1B}\\\u{1B}]9;Approval requested: ls\u{07}"),
            [.status(.status(ProgramStatus(state: .blocked, kind: .permission))),
             .notification(TerminalNotification(title: "", body: "Approval requested: ls"))])
    }

    /// A notification longer than libghostty would take is dropped whole.
    func testAnOversizedNotificationIsDropped() {
        let long = String(repeating: "a", count: 2049)
        XCTAssertEqual(hear("\u{1B}]9;\(long)\u{07}\u{1B}]9;short\u{07}"),
                       [.notification(TerminalNotification(title: "", body: "short"))])
    }

    /// An ESC inside a report that is not the terminator cuts it off, and may
    /// start the next one.
    func testACutOffReportIsDroppedAndTheNextOneRead() {
        XCTAssertEqual(scan("\u{1B}]7501;state=wor\u{1B}]7501;state=done\u{1B}\\"),
                       [.status(ProgramStatus(state: .done))])
        XCTAssertEqual(scan("\u{1B}]7501;state=wor\u{18}king\u{07}"), [])
        XCTAssertEqual(scan("\u{1B}\u{1B}]7501;state=done\u{07}"), [.status(ProgramStatus(state: .done))])
    }

    func testAnOversizedReportIsDroppedWhole() {
        let padding = String(repeating: "a", count: ProgramStatusReport.maximumSequenceLength)
        XCTAssertEqual(scan("\u{1B}]7501;state=done:x=\(padding)\u{07}\u{1B}]7501;state=idle\u{07}"),
                       [.status(ProgramStatus(state: .idle))])
    }

    func testAQueryIsFound() {
        XCTAssertEqual(scan("\u{1B}]7501;?\u{1B}\\"), [.query])
    }

    func testTheReplyIsAQueryBody() {
        // What Wortel writes back is what a program checks for: the same body.
        XCTAssertEqual(String(decoding: ProgramStatusReport.reply, as: UTF8.self), "\u{1B}]7501;?\u{1B}\\")
    }
}
