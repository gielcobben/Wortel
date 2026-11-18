import XCTest

/// Settings ▸ New sessions start with. The line is typed into a shell that
/// hasn't started reading, so a wrong byte here is a wrong key in every new
/// session, and a wrong decision is an agent nobody asked for.
final class NewSessionCommandTests: XCTestCase {
    private func line(_ text: String) -> String? {
        try? NewSessionCommand.check(text).get()
    }

    // MARK: - The line

    func testEmptyIsAPlainTerminal() {
        XCTAssertEqual(NewSessionCommand.check(""), .success(nil))
        XCTAssertEqual(NewSessionCommand.check("   "), .success(nil))
        XCTAssertNil(NewSessionCommand.line(for: ""))
    }

    func testACommandIsTypedWithItsReturn() {
        XCTAssertEqual(line("claude"), "claude\n")
        XCTAssertEqual(line("  claude  "), "claude\n", "what is stored is trimmed")
    }

    /// The difference from `wortel new -- <command>`, whose words are quoted
    /// back together: this is one line as its author wrote it.
    func testArgumentsAreTypedAsWrittenNotQuoted() {
        XCTAssertEqual(line("claude --model opus"), "claude --model opus\n")
        XCTAssertEqual(line("CLAUDE_CONFIG_DIR=~/work claude"), "CLAUDE_CONFIG_DIR=~/work claude\n")
        XCTAssertEqual(line("pi \"fix it\""), "pi \"fix it\"\n")
    }

    func testAControlCharacterIsRefused() {
        for text in ["cla\tude", "cla\u{1B}ude", "claude\u{03}", "a\u{7F}b"] {
            XCTAssertEqual(NewSessionCommand.check(text), .failure(.controlCharacter), text.debugDescription)
        }
    }

    /// A tab at either end goes with the spaces there. Only one inside the
    /// line would be typed, and so would complete.
    func testATabAtTheEndIsTrimmedLikeASpace() {
        XCTAssertEqual(line("claude\t"), "claude\n")
    }

    /// A second line here could only be a second command pasted by accident.
    func testANewlineIsRefused() {
        XCTAssertEqual(NewSessionCommand.check("claude\nrm -rf x"), .failure(.controlCharacter))
        XCTAssertEqual(NewSessionCommand.check("claude\r"), .failure(.controlCharacter))
    }

    func testEmojiAndAccentsAreFine() {
        XCTAssertEqual(line("echo café 👨‍👩‍👧"), "echo café 👨‍👩‍👧\n")
    }

    func testALineTheKernelWouldDropIsRefused() {
        let limit = WortelCommandParser.typedLineLimit
        XCTAssertNotNil(line(String(repeating: "a", count: limit - 1)), "with its newline, exactly the limit")
        XCTAssertEqual(NewSessionCommand.check(String(repeating: "a", count: limit)), .failure(.tooLong))
    }

    func testAStoredValueThatCannotBeTypedCountsAsNone() {
        XCTAssertNil(NewSessionCommand.line(for: "cla\tude"))
    }

    // MARK: - Who gets it

    func testTheAppsOwnWaysInFollowSettings() {
        XCTAssertEqual(SessionStart.preferred.input(preferred: "claude"), "claude\n")
        XCTAssertNil(SessionStart.preferred.input(preferred: ""))
    }

    func testNewTerminalAndALaunchNeverDo() {
        XCTAssertNil(SessionStart.plain.input(preferred: "claude"))
    }

    func testTheCommandLinesOwnLineWinsOverSettings() {
        XCTAssertEqual(SessionStart.line("ls\n").input(preferred: "claude"), "ls\n")
    }

    func testOnlyASessionStartedWithSettingsCommandIsCountedAsOne() {
        XCTAssertTrue(SessionStart.preferred.usesPreferredCommand(stored: "claude"))
        XCTAssertFalse(SessionStart.preferred.usesPreferredCommand(stored: ""))
        XCTAssertFalse(SessionStart.plain.usesPreferredCommand(stored: "claude"))
        XCTAssertFalse(SessionStart.line("claude\n").usesPreferredCommand(stored: "claude"))
    }
}
