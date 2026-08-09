import XCTest

/// Argument parsing for the `wortel` CLI.
///
/// This is where a command-line tool rots, and every failure here is quiet: a
/// relative path resolved against the app's directory instead of the caller's
/// opens the wrong file, a typo'd flag that's ignored starts a session somewhere
/// you didn't ask for, and a command that acts on "the current session" without
/// knowing which one acts on the wrong one.
final class WortelCommandTests: XCTestCase {
    private let session = "6C6F1B1E-0000-4000-8000-000000000001"
    private var environment: [String: String] {
        [WortelCommandParser.sessionVariable: session]
    }

    private func parse(
        _ arguments: [String], cwd: String? = "/Users/x/project"
    ) throws -> WortelCommand {
        try WortelCommandParser.parse(arguments, environment: environment, currentDirectory: cwd)
    }

    // MARK: - open

    /// A CLI is nearly always handed a relative path, and the app is nowhere
    /// near the caller's directory.
    func testOpenResolvesRelativePaths() throws {
        XCTAssertEqual(try parse(["open", "src/main.swift"]),
                       .open(path: "/Users/x/project/src/main.swift"))
        XCTAssertEqual(try parse(["open", "./a.txt"]), .open(path: "/Users/x/project/a.txt"))
        XCTAssertEqual(try parse(["open", "../sibling/a.txt"]),
                       .open(path: "/Users/x/sibling/a.txt"))
    }

    func testOpenKeepsAbsolutePathsAndExpandsTilde() throws {
        XCTAssertEqual(try parse(["open", "/etc/hosts"]), .open(path: "/etc/hosts"))
        XCTAssertEqual(try parse(["open", "~/notes.md"]),
                       .open(path: NSHomeDirectory() + "/notes.md"))
    }

    func testOpenWithoutAPath() {
        XCTAssertThrowsError(try parse(["open"])) { error in
            XCTAssertEqual(error as? WortelCommandParser.ParseError, .missing("a path", "open"))
        }
    }

    // MARK: - new

    func testNewDefaultsToTheCallersDirectory() throws {
        XCTAssertEqual(try parse(["new"]),
                       .newSession(cwd: "/Users/x/project", name: nil, branch: nil))
    }

    func testNewFlags() throws {
        let command = try parse(["new", "--cwd", "sub", "--name", "build", "--branch", "fix/x"])
        XCTAssertEqual(command, .newSession(cwd: "/Users/x/project/sub",
                                            name: "build", branch: "fix/x"))
    }

    /// Rejected, not ignored. A dropped flag gives you a session in the wrong
    /// directory and no clue why, which is a worse ten minutes than an error.
    func testUnknownFlagIsRejected() {
        XCTAssertThrowsError(try parse(["new", "--directory", "/tmp"])) { error in
            XCTAssertEqual(error as? WortelCommandParser.ParseError, .unknown("--directory"))
        }
    }

    /// And it has to say which half of the usage to look in: a mistyped
    /// `--brnach` is an option, a mistyped `noew` is a command.
    func testAnUnknownThingIsNamedForWhatItIs() {
        XCTAssertEqual("\(WortelCommandParser.ParseError.unknown("--directory"))",
                       "unknown option \"--directory\"")
        XCTAssertEqual("\(WortelCommandParser.ParseError.unknown("explode"))",
                       "unknown command \"explode\"")
    }

    func testFlagWithoutAValueIsRejected() {
        XCTAssertThrowsError(try parse(["new", "--cwd"])) { error in
            XCTAssertEqual(error as? WortelCommandParser.ParseError, .missing("a value", "--cwd"))
        }
    }

    // MARK: - the calling session

    /// `rename` and `notify` mean "the session I'm running in", which the shell
    /// already knows: every Wortel shell carries WORTEL_SESSION_ID.
    func testCommandsCarryTheCallersSession() throws {
        XCTAssertEqual(try parse(["rename", "build"]), .rename(session: session, name: "build"))
        XCTAssertEqual(try parse(["notify", "Done", "tests passed"]),
                       .notify(session: session, title: "Done", body: "tests passed"))
        XCTAssertEqual(try parse(["notify", "Done"]),
                       .notify(session: session, title: "Done", body: nil))
    }

    /// Run from outside Wortel there is no session, and the command has to say
    /// so rather than guessing at one.
    func testNoSessionOutsideWortel() throws {
        let command = try WortelCommandParser.parse(
            ["rename", "build"], environment: [:], currentDirectory: nil)
        XCTAssertEqual(command, .rename(session: nil, name: "build"))
    }

    func testRenameWithoutAName() {
        XCTAssertThrowsError(try parse(["rename"]))
        XCTAssertThrowsError(try parse(["rename", ""]))
    }

    // MARK: - Shape

    func testNoCommandAndUnknownCommand() {
        XCTAssertThrowsError(try parse([])) { error in
            XCTAssertEqual(error as? WortelCommandParser.ParseError, .noCommand)
        }
        XCTAssertThrowsError(try parse(["explode"])) { error in
            XCTAssertEqual(error as? WortelCommandParser.ParseError, .unknown("explode"))
        }
    }

    /// The wire format has to survive a round trip, since the two ends are
    /// separate binaries that will be updated separately.
    func testCommandsRoundTripThroughJSON() throws {
        let commands: [WortelCommand] = [
            .open(path: "/a/b.txt"),
            .newSession(cwd: "/a", name: "x", branch: "fix/y"),
            .newSession(cwd: nil, name: nil, branch: nil),
            .rename(session: session, name: "build"),
            .notify(session: nil, title: "Done", body: nil),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual(try JSONDecoder().decode(WortelCommand.self, from: data), command)
        }
    }

    func testResponsesRoundTrip() throws {
        for response in [WortelResponse.success("done", value: "id"), .failure("nope")] {
            let data = try JSONEncoder().encode(response)
            XCTAssertEqual(try JSONDecoder().decode(WortelResponse.self, from: data), response)
        }
    }

    /// Every command names itself the same way on the command line and on the
    /// wire, so a log line and a shell history entry read alike.
    func testVerbsMatchTheCommandLine() {
        XCTAssertEqual(WortelCommand.open(path: "/a").verb, "open")
        XCTAssertEqual(WortelCommand.newSession(cwd: nil, name: nil, branch: nil).verb, "new")
        XCTAssertEqual(WortelCommand.rename(session: nil, name: "a").verb, "rename")
        XCTAssertEqual(WortelCommand.notify(session: nil, title: "a", body: nil).verb, "notify")
    }

    func testUsageListsEveryCommand() {
        for verb in ["open", "new", "rename", "notify"] {
            XCTAssertTrue(WortelCommandParser.usage.contains(verb), "usage omits \(verb)")
        }
        XCTAssertTrue(WortelCommandParser.usage.contains(WortelCommandParser.sessionVariable))
    }
}
