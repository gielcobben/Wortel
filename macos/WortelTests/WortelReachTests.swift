import XCTest

/// The four verbs that reach another session (`list`, `read`, `send`,
/// `wait`): their arguments, which session a name means, and what counts as
/// text appearing on a screen.
///
/// Every failure here does the wrong thing quietly. A name that matches two
/// sessions and picks one types a prompt into the wrong agent; a `--lines`
/// that takes "abc" as nothing reads the screen instead; a wait that counts
/// the text already on screen ends before the work it was waiting for began.
final class WortelReachTests: XCTestCase {
    private let caller = "6C6F1B1E-0000-4000-8000-000000000001"

    private func parse(_ arguments: [String], stdin: String? = nil) throws -> WortelCommandParser.Invocation {
        try WortelCommandParser.parseInvocation(
            arguments, environment: [WortelCommandParser.sessionVariable: caller],
            currentDirectory: "/Users/x/project",
            standardInput: stdin.map { text in { text } })
    }

    private func assertError(_ arguments: [String], stdin: String? = nil,
                             _ expected: WortelCommandParser.ParseError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(arguments, stdin: stdin), file: file, line: line) { error in
            XCTAssertEqual(error as? WortelCommandParser.ParseError, expected, file: file, line: line)
        }
    }

    // MARK: - list

    func testListCarriesTheCallerSoItCanSayWhichRowIsYou() throws {
        XCTAssertEqual(try parse(["list"]), .init(command: .list(caller: caller)))
        XCTAssertEqual(try parse(["list", "--json"]), .init(command: .list(caller: caller), json: true))
    }

    func testListTakesNoWords() {
        assertError(["list", "agents"], .unexpected("agents", "list"))
        assertError(["list", "--all"], .unknown("--all"))
    }

    // MARK: - read

    func testRead() throws {
        XCTAssertEqual(try parse(["read", "agent two"]).command, .read(session: "agent two", lines: nil))
        XCTAssertEqual(try parse(["read", "--lines", "50", "3F2A91C0"]).command,
                       .read(session: "3F2A91C0", lines: 50))
        XCTAssertTrue(try parse(["read", "x", "--json"]).json)
    }

    /// A count that isn't one is refused, not read as "the screen".
    func testReadRefusesALineCountThatIsntOne() {
        assertError(["read", "x", "--lines", "abc"], .invalid("--lines", "abc", "a number of lines, 1 or more"))
        assertError(["read", "x", "--lines", "0"], .invalid("--lines", "0", "a number of lines, 1 or more"))
        assertError(["read", "x", "--lines"], .missing("a value", "--lines"))
    }

    /// An unquoted name with a space is two words; reading the first would
    /// read some other session, or none.
    func testReadNeedsExactlyOneSession() {
        assertError(["read"], .missing("a session (an id or a name; `wortel list` shows them)", "read"))
        assertError(["read", "agent", "two"], .unexpected("two", "read"))
    }

    // MARK: - send

    func testSendTextAndEnter() throws {
        XCTAssertEqual(try parse(["send", "x", "fix the tests"]).command,
                       .send(session: "x", text: "fix the tests", enter: false))
        XCTAssertEqual(try parse(["send", "--enter", "x", "fix the tests"]).command,
                       .send(session: "x", text: "fix the tests", enter: true))
        XCTAssertEqual(try parse(["send", "x", "fix the tests", "--enter"]).command,
                       .send(session: "x", text: "fix the tests", enter: true))
    }

    /// A multi-line prompt goes over as it is: one paste, its newlines inside.
    func testSendKeepsNewlinesInTheText() throws {
        XCTAssertEqual(try parse(["send", "x", "one\ntwo\n"]).command,
                       .send(session: "x", text: "one\ntwo\n", enter: false))
    }

    /// Return on its own: answering a prompt that's waiting for it.
    func testSendEnterAloneIsJustReturn() throws {
        XCTAssertEqual(try parse(["send", "x", "--enter"]).command, .send(session: "x", text: "", enter: true))
    }

    func testSendNeedsSomethingToSend() {
        assertError(["send", "x"], .missing("text, --stdin or --enter", "send"))
        assertError(["send"], .missing("a session", "send"))
        assertError(["send", "x", "one", "two"], .unexpected("two", "send"))
    }

    /// One trailing newline off, as `$(…)` takes it, and only one: a prompt
    /// that ends in a blank line meant that.
    func testSendReadsStandardInput() throws {
        XCTAssertEqual(try parse(["send", "x", "--stdin"], stdin: "a prompt\n").command,
                       .send(session: "x", text: "a prompt", enter: false))
        XCTAssertEqual(try parse(["send", "x", "--stdin", "--enter"], stdin: "one\ntwo\n\n").command,
                       .send(session: "x", text: "one\ntwo\n", enter: true))
        XCTAssertEqual(try parse(["send", "x", "--stdin"], stdin: "crlf\r\n").command,
                       .send(session: "x", text: "crlf", enter: false))
    }

    func testSendStdinAndTextAreOneOrTheOther() {
        assertError(["send", "x", "hi", "--stdin"], stdin: "there", .conflict("--stdin", "text on the command line"))
    }

    /// Text that starts with a dash goes after `--`, like any command's.
    func testSendTextAfterDoubleDash() throws {
        XCTAssertEqual(try parse(["send", "x", "--enter", "--", "--help"]).command,
                       .send(session: "x", text: "--help", enter: true))
        XCTAssertEqual(try parse(["send", "x", "-"]).command, .send(session: "x", text: "-", enter: false))
        assertError(["send", "x", "--force"], .unknown("--force"))
    }

    func testSendRefusesAWholeFile() {
        let big = String(repeating: "x", count: WortelCLI.maximumSendBytes + 1)
        assertError(["send", "x", big], .invalid("the text", "\(big.utf8.count) bytes", "at most 256 KB"))
    }

    // MARK: - wait

    /// Nothing asked for means idle, with the default timeout.
    func testWaitDefaultsToIdleForThirtySeconds() throws {
        XCTAssertEqual(try parse(["wait", "x"]).command,
                       .wait(session: "x", text: nil, fromStart: false, idle: true, exit: false, timeout: 30))
    }

    /// Asking for text or an exit replaces the default rather than adding
    /// idle to it: a wait for "DONE" must not end because a turn did.
    func testWaitConditions() throws {
        XCTAssertEqual(try parse(["wait", "x", "--for", "DONE"]).command,
                       .wait(session: "x", text: "DONE", fromStart: false, idle: false, exit: false, timeout: 30))
        XCTAssertEqual(try parse(["wait", "x", "--exit"]).command,
                       .wait(session: "x", text: nil, fromStart: false, idle: false, exit: true, timeout: 30))
        XCTAssertEqual(try parse(["wait", "x", "--for", "DONE", "--from-start", "--idle", "--exit",
                                  "--timeout", "0"]).command,
                       .wait(session: "x", text: "DONE", fromStart: true, idle: true, exit: true, timeout: 0))
    }

    func testWaitTimeouts() throws {
        func timeout(_ text: String) throws -> Double? {
            guard case .wait(_, _, _, _, _, let seconds) = try parse(["wait", "x", "--timeout", text]).command
            else { return nil }
            return seconds
        }
        XCTAssertEqual(try timeout("90s"), 90)
        XCTAssertEqual(try timeout("5m"), 300)
        XCTAssertEqual(try timeout("1h"), 3600)
        XCTAssertEqual(try timeout("1.5m"), 90)
        XCTAssertEqual(try timeout("500ms"), 0.5)
        XCTAssertEqual(try timeout("45"), 45)
        XCTAssertEqual(try timeout("0"), 0)
        assertError(["wait", "x", "--timeout", "soon"], .invalid("--timeout", "soon", "a duration like 30s, 5m or 0"))
        assertError(["wait", "x", "--timeout", "-5s"], .invalid("--timeout", "-5s", "a duration like 30s, 5m or 0"))
        assertError(["wait", "x", "--timeout", "m"], .invalid("--timeout", "m", "a duration like 30s, 5m or 0"))
    }

    func testWaitMistakes() {
        assertError(["wait", "x", "--from-start"], .missing("--for", "--from-start"))
        assertError(["wait", "x", "--for", ""], .invalid("--for", "\"\"", "some text to wait for"))
        assertError(["wait", "x", "--for"], .missing("a value", "--for"))
        assertError(["wait"], .missing("a session (an id or a name; `wortel list` shows them)", "wait"))
        assertError(["wait", "x", "y"], .unexpected("y", "wait"))
    }

    // MARK: - --session on the labelling verbs

    /// The three that only label a session can name another one; the env
    /// stays the default.
    func testSessionOptionOnRenameNotifyAndMark() throws {
        XCTAssertEqual(try parse(["rename", "--session", "agent two", "Review"]).command,
                       .rename(session: "agent two", name: "Review"))
        XCTAssertEqual(try parse(["rename", "Review"]).command, .rename(session: caller, name: "Review"))
        XCTAssertEqual(try parse(["notify", "Done", "--session", "3F2A"]).command,
                       .notify(session: "3F2A", title: "Done", body: nil))
        XCTAssertEqual(try parse(["mark", "--session", "x", "red"]).command, .mark(session: "x", colour: "red"))
        assertError(["mark", "red", "--session"], .missing("a value", "--session"))
    }

    /// `fork` and `cd` act on the agent inside, by who's asking; naming
    /// another session there is refused rather than half-supported.
    func testForkAndCdStayWithTheCaller() {
        assertError(["fork", "--session", "x"], .unknown("--session"))
        XCTAssertThrowsError(try parse(["cd", "--session", "x", "/tmp"]))
    }

    // MARK: - Which session a name means

    private let one = UUID(uuidString: "3F2A91C0-0000-4000-8000-000000000001")!
    private let two = UUID(uuidString: "3F2B0000-0000-4000-8000-000000000002")!
    private let three = UUID(uuidString: "9B1E0000-0000-4000-8000-000000000003")!

    private var sessions: [WortelSessionAddress.Candidate] {
        [.init(id: one, name: "Wortel/agent one", leaf: "agent one"),
         .init(id: two, name: "Wortel/agent two", leaf: "agent two"),
         .init(id: three, name: "Agent", leaf: "Agent")]
    }

    private func resolve(_ query: String) -> WortelSessionAddress.Resolution {
        WortelSessionAddress.resolve(query, among: sessions)
    }

    func testAWholeIdOrAnExactName() {
        XCTAssertEqual(resolve(two.uuidString), .found(two))
        XCTAssertEqual(resolve(two.uuidString.lowercased()), .found(two))
        XCTAssertEqual(resolve("Wortel/agent two"), .found(two))
        XCTAssertEqual(resolve("agent two"), .found(two))
    }

    /// An exact name wins over being the start of others: "Agent" is a
    /// session, even though "agent one" and "agent two" start with it too.
    func testAnExactNameBeatsPrefixes() {
        XCTAssertEqual(resolve("Agent"), .found(three))
        XCTAssertEqual(resolve("agent"), .found(three), "an exact name, ignoring case, is still exact")
    }

    func testAUniquePrefixIgnoringCase() {
        XCTAssertEqual(resolve("AGENT T"), .found(two))
        XCTAssertEqual(resolve("wortel/agent o"), .found(one))
    }

    /// Two matches are an error naming both, never a pick.
    func testAnAmbiguousPrefixNamesTheCandidates() {
        XCTAssertEqual(resolve("wortel/agent"), .ambiguous([sessions[0], sessions[1]]))
        XCTAssertEqual(resolve("3F2"), .none, "an id prefix needs four characters")
        XCTAssertEqual(resolve("3f2a"), .found(one))
        XCTAssertEqual(resolve("3F2"), .none)
        XCTAssertEqual(resolve("3f2a91c0"), .found(one), "the short id list prints")
    }

    func testNothingMatches() {
        XCTAssertEqual(resolve("nope"), .none)
        XCTAssertEqual(resolve(""), .none)
        XCTAssertEqual(resolve(UUID().uuidString), .none, "a closed session's id is no one's")
    }

    // MARK: - Screen text

    func testTidyTrimsTheGridNotTheOutput() {
        let raw = "$ make   \n  building\t\n\nok\n   \n\n"
        XCTAssertEqual(ScreenText.tidy(raw), "$ make\n  building\n\nok")
        XCTAssertEqual(ScreenText.tidy("\n\n"), "")
    }

    /// The last N lines with something at the bottom, counted after the trim.
    func testTidyKeepsTheLastLines() {
        let raw = "one\ntwo\nthree\nfour\n\n\n"
        XCTAssertEqual(ScreenText.tidy(raw, lastLines: 2), "three\nfour")
        XCTAssertEqual(ScreenText.tidy(raw, lastLines: 10), "one\ntwo\nthree\nfour")
    }

    func testOccurrences() {
        XCTAssertEqual(ScreenText.occurrences(of: "DONE", in: "DONE\nnot done\nDONE!"), 2)
        XCTAssertEqual(ScreenText.occurrences(of: "aa", in: "aaaa"), 2, "not overlapping")
        XCTAssertEqual(ScreenText.occurrences(of: "x", in: ""), 0)
        XCTAssertEqual(ScreenText.occurrences(of: "", in: "anything"), 0)
    }

    // MARK: - The table

    func testTheTableLinesUpAndMarksYouAndTheSelection() {
        let rows = [
            WortelSessionInfo(id: one.uuidString, name: "Wortel/agent one", folder: "Wortel",
                              directory: "/Users/x/Developer/wortel", branch: nil, worktree: nil,
                              agent: "claude", state: .working, selected: true, caller: false),
            WortelSessionInfo(id: two.uuidString, name: "notes", folder: nil, directory: "/Users/x",
                              branch: "fix/1482", worktree: "/Users/x/.wortel/worktrees/w/fix-1482",
                              agent: nil, state: .needsYou, selected: false, caller: true),
        ]
        XCTAssertEqual(WortelSessionInfo.table(rows, home: "/Users/x"), """
              ID       NAME             STATE     AGENT  BRANCH   DIRECTORY
            * 3F2A91C0 Wortel/agent one working   claude -        ~/Developer/wortel
              3F2B0000 notes (you)      needs-you -      fix/1482 ~
            """)
    }

    /// The JSON is the scripting contract: these names, these values.
    func testTheJSONFieldNames() throws {
        let info = WortelSessionInfo(id: "A", name: "n", folder: nil, directory: nil, branch: nil, worktree: nil,
                                     agent: nil, state: .needsYou, selected: false, caller: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "needs-you")
        XCTAssertEqual(Set(object.keys), ["id", "name", "state", "selected", "caller"],
                       "nil fields are left out, not written as null")
        XCTAssertEqual(WortelSessionInfo.State.allCases.map(\.rawValue),
                       ["working", "needs-you", "finished", "failed", "idle", "preparing"])
    }
}
