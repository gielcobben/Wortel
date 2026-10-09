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
                       .newSession(cwd: "/Users/x/project", name: nil, branch: nil, base: nil))
    }

    func testNewFlags() throws {
        let command = try parse(["new", "--cwd", "sub", "--name", "build", "--branch", "fix/x"])
        XCTAssertEqual(command, .newSession(cwd: "/Users/x/project/sub",
                                            name: "build", branch: "fix/x", base: nil))
    }

    /// `--from` is what a script says when it does *not* want the repository's
    /// default branch — including `HEAD`, which is how you stack onto the
    /// current branch on purpose now that nil no longer means that.
    func testNewFrom() throws {
        XCTAssertEqual(
            try parse(["new", "--branch", "fix/x", "--from", "release/2026"]),
            .newSession(cwd: "/Users/x/project", name: nil,
                        branch: "fix/x", base: "release/2026"))
        XCTAssertEqual(
            try parse(["new", "--branch", "fix/x", "--from", "HEAD"]),
            .newSession(cwd: "/Users/x/project", name: nil, branch: "fix/x", base: "HEAD"))
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
        XCTAssertEqual(try parse(["mark", "yellow"]), .mark(session: session, colour: "yellow"))
        XCTAssertEqual(try parse(["mark", "none"]), .mark(session: session, colour: "none"))
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

    func testMarkWithoutAColour() {
        XCTAssertThrowsError(try parse(["mark"]))
        XCTAssertThrowsError(try parse(["mark", ""]))
    }

    /// The colour goes over as typed: the app checks it, because the colours
    /// are the app's and a newer app may have one this CLI doesn't.
    func testMarkLeavesTheColourToTheApp() throws {
        XCTAssertEqual(try parse(["mark", "teal"]), .mark(session: session, colour: "teal"))
    }

    /// What the app accepts, and the other spelling of grey with it.
    func testColourNames() {
        XCTAssertEqual(SessionColour.named("yellow"), .yellow)
        XCTAssertEqual(SessionColour.named("Yellow"), .yellow)
        XCTAssertEqual(SessionColour.named("gray"), .grey)
        XCTAssertEqual(SessionColour.named("grey"), .grey)
        XCTAssertNil(SessionColour.named("teal"))
        XCTAssertNil(SessionColour.named(SessionColour.none))
    }

    // MARK: - Finding its own bundle

    /// How `--version` knows what it is: the tool has no Info.plist of its own,
    /// so it reads the bundle it was copied into.
    func testTheToolFindsTheBundleItShippedIn() {
        XCTAssertEqual(
            WortelCLI.appBundle(containing: "/Applications/Wortel.app/Contents/Resources/bin/wortel"),
            "/Applications/Wortel.app")
        // The same walk has to work wherever a nested binary is put.
        XCTAssertEqual(
            WortelCLI.appBundle(containing: "/Applications/Wortel.app/Contents/MacOS/wortel"),
            "/Applications/Wortel.app")
    }

    /// Installed outside a bundle there is no version to read, and saying
    /// "unknown" beats naming some directory that happens to be up the path.
    func testABinaryOutsideABundleHasNoBundle() {
        XCTAssertNil(WortelCLI.appBundle(containing: "/usr/local/bin/wortel"))
        XCTAssertNil(WortelCLI.appBundle(containing: "wortel"))
        XCTAssertNil(WortelCLI.appBundle(containing: "/"))
    }

    /// The case it exists for: a symlink on the PATH. What we were exec'd as is
    /// the link, which is inside no bundle — the bundle is where it points.
    func testASymlinkResolvesBackToTheBundle() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("V\(UInt32.random(in: 0..<0xFFFF)).app/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let real = bundle.appendingPathComponent("wortel")
        FileManager.default.createFile(atPath: real.path, contents: Data())
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-link-\(UInt32.random(in: 0..<0xFFFF))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(
                at: bundle.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent())
        }

        XCTAssertEqual(WortelCLI.appBundle(containing: link.path)?.hasSuffix(".app"), true)
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
            .newSession(cwd: "/a", name: "x", branch: "fix/y", base: "main"),
            .newSession(cwd: nil, name: nil, branch: nil, base: nil),
            .rename(session: session, name: "build"),
            .notify(session: nil, title: "Done", body: nil),
            .mark(session: session, colour: "yellow"),
            .version,
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
        XCTAssertEqual(WortelCommand.newSession(cwd: nil, name: nil, branch: nil, base: nil).verb, "new")
        XCTAssertEqual(WortelCommand.rename(session: nil, name: "a").verb, "rename")
        XCTAssertEqual(WortelCommand.notify(session: nil, title: "a", body: nil).verb, "notify")
        XCTAssertEqual(WortelCommand.mark(session: nil, colour: "red").verb, "mark")
        XCTAssertEqual(WortelCommand.version.verb, "--version")
    }

    func testUsageListsEveryCommand() {
        for verb in ["open", "new", "rename", "notify", "mark", "--version"] {
            XCTAssertTrue(WortelCommandParser.usage.contains(verb), "usage omits \(verb)")
        }
        // The colours are listed by hand there (the CLI can't see the app's
        // type), so a colour added to the app has to be added to the usage.
        for colour in SessionColour.allCases.map(\.rawValue) + [SessionColour.none] {
            XCTAssertTrue(WortelCommandParser.usage.contains(colour), "usage omits \(colour)")
        }
        XCTAssertTrue(WortelCommandParser.usage.contains(WortelCommandParser.sessionVariable))
    }
}
