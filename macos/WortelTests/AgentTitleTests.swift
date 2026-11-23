import XCTest

/// An agent's terminal title read as a session name. Every miss here is
/// silent: a marker glyph the parser doesn't know leaves a session on its
/// placeholder for good, and a state word it lets through names one "Working".
final class AgentTitleTests: XCTestCase {

    // MARK: - Claude Code

    /// The resting title, and the same title while working. The text is the
    /// name; the glyph only says whether the agent is busy.
    func testClaudeTitleAtRestAndWhileWorking() {
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✳ Session naming improvement"),
                       "Session naming improvement")
        for frame in ["◐", "◑", "◒", "◓"] {
            XCTAssertEqual(AgentTitle.sessionName(fromTitle: "\(frame) Session naming improvement"),
                           "Session naming improvement", frame)
        }
    }

    /// Older builds animated a braille spinner, and older still the dingbat
    /// asterisks. A marker set that stops matching doesn't fail, it just hands
    /// every session back to the placeholder.
    func testEarlierSpinnerFramesStillCount() {
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "⠋ Fix quiesce race"), "Fix quiesce race")
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✻ Fix quiesce race"), "Fix quiesce race")
        // U+2800 is the blank braille cell TUIs pad with, then a real frame.
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "\u{2800}⠙ Fix quiesce race"),
                       "Fix quiesce race")
    }

    /// Titles keep whatever /rename gave them, slashes included: the folder
    /// split happens later, on the name the manager builds.
    func testKeepsPunctuationInsideTheName() {
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✳ 002 border-radius video corners"),
                       "002 border-radius video corners")
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✳   Debug  Wortel   crash  "),
                       "Debug Wortel crash")
    }

    // MARK: - Not a name

    /// A shell's own title has no marker and is not an agent's.
    func testShellTitlesAreIgnored() {
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "me@mac: ~/Developer/wortel"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "npm run build"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: ""))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✳"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✳   "))
    }

    /// Gemini CLI and Codex put *state* after the glyph.
    func testStateTitlesAreIgnored() {
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✦ Working"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "⏲ working"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "◇ Ready"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✋ Action Required"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✳ [ ! ] Action Required"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✳ Claude Code"))
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✳ claude"))
    }

    /// Whole-word only: a name that merely starts with a state word is a name.
    func testStateWordsMatchWholeTitlesOnly() {
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✳ Ready the release notes"),
                       "Ready the release notes")
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✳ Working tree cleanup"),
                       "Working tree cleanup")
    }

    /// An agent that echoes the directory back has not named anything.
    func testPlaceholderEchoIsIgnored() {
        XCTAssertNil(AgentTitle.sessionName(fromTitle: "✳ wortel", placeholder: "wortel"))
        XCTAssertEqual(AgentTitle.sessionName(fromTitle: "✳ wortel", placeholder: "other"), "wortel")
    }
}
