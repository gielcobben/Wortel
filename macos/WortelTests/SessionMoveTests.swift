import XCTest

/// Whether, and when, a session may move to another directory (`wortel cd`),
/// and what gets typed. A wrong row here doesn't throw: it quits an agent in
/// the middle of a question, types `cd` into vim, or tells an agent it moved
/// when it didn't.
final class SessionMoveTests: XCTestCase {
    private let path = "/Users/x/site"

    private func decide(_ change: (inout SessionMove.Situation) -> Void) -> SessionMove.Decision {
        var situation = SessionMove.Situation()
        change(&situation)
        return SessionMove.decide(situation, to: path)
    }

    /// The agent's situation when it runs `wortel cd` from its shell tool.
    private func agentAsking(_ situation: inout SessionMove.Situation) {
        situation.agent = "claude"
        situation.conversationID = "80297191-7afb-4301-8566-909b3e04fdfc"
        situation.shellInForeground = false
        situation.agentInForeground = true
        situation.callerIsAgent = true
    }

    private func isRefusal(_ decision: SessionMove.Decision, mentioning text: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard case .refuse(let message) = decision else {
            return XCTFail("expected a refusal, got \(decision)", file: file, line: line)
        }
        XCTAssertTrue(message.contains(text), "\"\(message)\" doesn't mention \(text)", file: file, line: line)
        XCTAssertFalse(message.contains("\u{2014}"), "no em-dashes in what a user reads", file: file, line: line)
    }

    // MARK: - A plain shell

    /// At its prompt, from the menu: there's nothing to wait for.
    func testAShellAtItsPromptMovesNow() {
        XCTAssertEqual(decide { _ in }, .now)
    }

    /// `wortel cd` typed at the prompt: the shell is busy running `wortel`
    /// itself, and the `cd` goes in once it's back.
    func testAShellRunningTheCommandMovesAtThePrompt() {
        XCTAssertEqual(decide {
            $0.shellInForeground = false
            $0.callerInForeground = true
        }, .atPrompt)
    }

    /// Something else has the terminal: a `cd` typed now would land in it.
    func testSomethingInTheForegroundIsRefused() {
        isRefusal(decide {
            $0.shellInForeground = false
            $0.foregroundName = "vim notes.md"
        }, mentioning: "vim notes.md")
    }

    // MARK: - An agent

    /// The agent asked: it is mid-turn by definition, so it waits for a turn
    /// that ends after it asked, however quiet it looks now.
    func testTheAgentAskingWaitsForItsTurnToEnd() {
        XCTAssertEqual(decide(agentAsking), .whenIdle(needsTurnEnd: true))
    }

    /// From the menu (or a side terminal), an agent that's idle can go as soon
    /// as it's seen idle; one mid-turn waits for that turn the same way.
    func testTheMenuWaitsOnlyForIdle() {
        XCTAssertEqual(decide {
            agentAsking(&$0)
            $0.callerIsAgent = false
        }, .whenIdle(needsTurnEnd: false))
    }

    func testAnAgentThatCantBeCarriedIsRefused() {
        isRefusal(decide {
            agentAsking(&$0)
            $0.agent = "aider"
        }, mentioning: "Quit aider first")
    }

    /// ^Z keeps the agent's marker, and nothing it is asked will happen until
    /// `fg`, so waiting for its turn would wait forever.
    func testASuspendedAgentIsRefused() {
        isRefusal(decide {
            agentAsking(&$0)
            $0.agentStopped = true
            $0.agentInForeground = false
            $0.shellInForeground = true
        }, mentioning: "suspended")
    }

    func testAnAgentInTheBackgroundIsRefused() {
        isRefusal(decide {
            agentAsking(&$0)
            $0.agentInForeground = false
            $0.shellInForeground = true
        }, mentioning: "background")
    }

    /// Without the conversation there's nothing to resume: the move would
    /// leave a fresh agent where the old one was.
    func testAnUnknownConversationIsRefused() {
        isRefusal(decide {
            agentAsking(&$0)
            $0.conversationID = nil
        }, mentioning: "which claude conversation")
    }

    /// `exec claude`: the agent is the session's shell, and quitting it
    /// would end the session with nothing to type the resume into.
    func testAnAgentThatReplacedItsShellIsRefused() {
        isRefusal(decide {
            agentAsking(&$0)
            $0.agentIsShell = true
        }, mentioning: "exec")
    }

    func testAnAgentThatCantBeFoundIsRefused() {
        isRefusal(decide {
            agentAsking(&$0)
            $0.agentFound = false
        }, mentioning: "process")
    }

    // MARK: - Before anything else

    func testTheDirectoryHasToExist() {
        isRefusal(decide { $0.directoryExists = false }, mentioning: "No such directory")
    }

    func testTheSameDirectoryIsRefused() {
        isRefusal(decide { $0.sameDirectory = true }, mentioning: "Already in")
    }

    func testASessionBeingSetUpIsRefused() {
        isRefusal(decide { $0.preparing = true }, mentioning: "set up")
    }

    /// The exec backend owns its pty, so there's nothing to type into.
    func testNoPtyIsRefused() {
        isRefusal(decide { $0.hasPty = false }, mentioning: "can't type")
    }

    // MARK: - What's typed

    /// Two lines, never `cd x && claude …`: the shell integration reads the
    /// agent's directory from `$PWD` when it starts, and only zsh follows a
    /// quoted `cd` on the same line.
    func testTheCdAndTheResumeAreTwoLines() {
        XCTAssertEqual(SessionMove.lines(path: "/Users/x/site", resume: "claude --resume abc"),
                       ["cd /Users/x/site", "claude --resume abc"])
        XCTAssertEqual(SessionMove.lines(path: "/Users/x/site", resume: nil), ["cd /Users/x/site"])
    }

    /// Quoted only when it has to be, and a quote inside survives every shell.
    func testAPathIsQuotedWhenItHasTo() {
        XCTAssertEqual(SessionMove.lines(path: "/Users/x/My Site", resume: nil), ["cd '/Users/x/My Site'"])
        XCTAssertEqual(SessionMove.lines(path: "/Users/x/Giel's", resume: nil), ["cd '/Users/x/Giel'\\''s'"])
    }

    /// Fish reads a backslash as an escape even inside single quotes, and a
    /// control character could end the line early: neither is typed.
    func testAPathThatCantBeTypedSafelyIsRefused() {
        XCTAssertNil(SessionMove.lines(path: "/Users/x/a\\b", resume: nil))
        XCTAssertNil(SessionMove.lines(path: "/Users/x/a\nrm -rf b", resume: nil))
        XCTAssertNil(SessionMove.lines(path: "relative/path", resume: nil))
    }

    // MARK: - What the caller is told

    /// A command called `cd` reads as if it took effect at once; the reply
    /// says it hasn't, and what will happen, so the agent can tell you.
    func testTheAgentIsToldItHasntMovedYet() {
        let message = SessionMove.acceptedMessage(.whenIdle(needsTurnEnd: true), agent: "claude",
                                                  path: "/tmp/site")
        XCTAssertTrue(message.hasPrefix("Not moved yet."))
        XCTAssertTrue(message.contains("When this turn ends"))
        XCTAssertTrue(message.contains("waits for you"))
        XCTAssertFalse(message.contains("\u{2014}"))
    }

    func testBackgroundJobsThatWillStopAreNamed() {
        let message = SessionMove.acceptedMessage(.whenIdle(needsTurnEnd: true), agent: "claude",
                                                  path: "/tmp/site", stopping: ["npm run dev"])
        XCTAssertTrue(message.contains("npm run dev (started by claude) stops when it quits."))
    }

    func testARetargetSaysWhereItWasGoing() {
        let message = SessionMove.acceptedMessage(.now, agent: nil, path: "/tmp/b", instead: "/tmp/a")
        XCTAssertEqual(message, "Moving to /tmp/b instead of /tmp/a.")
    }

    func testASideTerminalIsToldItStays() {
        let message = SessionMove.acceptedMessage(.now, agent: nil, path: "/tmp/b",
                                                  fromSideTerminal: true, terminalStaysIn: "/tmp/a")
        XCTAssertTrue(message.hasSuffix("This terminal stays in /tmp/a."))
    }

    func testTheRowSaysWhereAndWhen() {
        XCTAssertEqual(SessionMove.pendingLine(to: "/Users/x/new-site"), "Moving to new-site after this turn")
    }
}
