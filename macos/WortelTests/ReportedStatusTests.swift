import XCTest

/// What a program's own reports come to. Each rule here is a banner that
/// arrives, or one that must not.
final class ReportedStatusTests: XCTestCase {

    private func status(_ state: ProgramStatus.State, kind: ProgramStatus.Kind? = nil,
                        message: String? = nil, id: String? = nil) -> ProgramStatus {
        ProgramStatus(state: state, kind: kind, app: "codex", message: message, id: id)
    }

    /// The records a program has after saying these, in order.
    private func records(_ statuses: ProgramStatus...) -> ProgramRecords {
        var records = ProgramRecords()
        statuses.forEach { records.apply(.status($0)) }
        return records
    }

    /// What follows from the program itself going from one state to another.
    private func effects(_ state: ProgramStatus.State, kind: ProgramStatus.Kind? = nil,
                         message: String? = nil, after previous: ProgramStatus? = nil,
                         replayed: Bool = false, idleEndsTurn: Bool = false) -> [ReportedStatus.Effect] {
        ReportedStatus.effects(from: previous.map { records($0) },
                               to: records(status(state, kind: kind, message: message)),
                               replayed: replayed, idleEndsTurn: idleEndsTurn)
    }

    // MARK: - A turn

    func testATurnFromStartToEnd() {
        XCTAssertEqual(effects(.working, after: status(.idle)), [.working])
        XCTAssertEqual(effects(.done, after: status(.working)),
                       [.resting, .announce(.turnDone, words: nil)])
        // The user touched the program: Codex takes `done` back to `idle`.
        XCTAssertEqual(effects(.idle, after: status(.done)), [.resting])
    }

    func testAnErrorIsAFailureInItsOwnWords() {
        XCTAssertEqual(effects(.error, message: "Rate limit reached", after: status(.working)),
                       [.resting, .announce(.failed, words: "Rate limit reached")])
        XCTAssertEqual(effects(.error, after: status(.working)),
                       [.resting, .announce(.failed, words: nil)])
    }

    /// Interrupted: `working` to `idle`, and nothing to tell anyone.
    func testAnInterruptedTurnAnnouncesNothing() {
        XCTAssertEqual(effects(.idle, after: status(.working)), [.resting])
    }

    /// opencode says `working`, `blocked` and `idle`, never `done`. Its turns
    /// end by going idle, and that has to be heard, since nothing else is
    /// listening.
    func testAProgramThatNeverSaysDoneEndsItsTurnsByGoingIdle() {
        XCTAssertEqual(effects(.idle, after: status(.working), idleEndsTurn: true),
                       [.resting, .announce(.turnDone, words: nil)])
        XCTAssertEqual(effects(.idle, after: status(.working), replayed: true, idleEndsTurn: true),
                       [.resting, .mark(.turnDone, words: nil)])
        // Only out of working: an answered question that led nowhere, or a
        // program that starts idle, finished nothing.
        XCTAssertEqual(effects(.idle, after: status(.blocked), idleEndsTurn: true), [.answered, .resting])
        XCTAssertEqual(effects(.idle, idleEndsTurn: true), [.resting])
        XCTAssertEqual(effects(.idle, after: status(.done), idleEndsTurn: true), [.resting])
    }

    /// The agents read to say `done`: for them `idle` is a stop.
    func testTheAgentsThatSayDone() {
        for app in ["codex", "claude-code", "pi", "crush"] {
            XCTAssertTrue(ReportedStatus.saysDone.contains(app), app)
        }
        XCTAssertFalse(ReportedStatus.saysDone.contains("opencode"))
    }

    /// Pi's `done` carries the session's name, which the banner already has.
    func testDoneDoesNotQuoteItsMessage() {
        XCTAssertEqual(effects(.done, message: "Fix the login", after: status(.working)),
                       [.resting, .announce(.turnDone, words: nil)])
    }

    // MARK: - Blocked

    func testBlockedSaysWhatItWaitsFor() {
        XCTAssertEqual(effects(.blocked, kind: .permission, after: status(.working)),
                       [.resting, .announce(.needsInput, words: "Waiting for your approval")])
        XCTAssertEqual(effects(.blocked, kind: .question, after: status(.working)),
                       [.resting, .announce(.needsInput, words: "Asking you a question")])
        XCTAssertEqual(effects(.blocked, kind: .auth, after: status(.working)),
                       [.resting, .announce(.needsInput, words: "Waiting for you to sign in")])
        XCTAssertEqual(effects(.blocked, after: status(.working)),
                       [.resting, .announce(.needsInput, words: "Waiting on you")])
    }

    func testBlockedPrefersTheProgramsOwnWords() {
        XCTAssertEqual(effects(.blocked, kind: .permission, message: "trust this folder"),
                       [.resting, .announce(.needsInput, words: "trust this folder")])
    }

    /// Answered in the terminal, approved by a rule of the program's own, or
    /// given up on: either way the block is over, and so is its dot.
    func testABlockThatEndsIsAnswered() {
        let blocked = status(.blocked, kind: .permission)
        XCTAssertEqual(effects(.working, after: blocked), [.answered, .working])
        XCTAssertEqual(effects(.idle, after: blocked), [.answered, .resting])
        XCTAssertEqual(effects(.done, after: blocked),
                       [.answered, .resting, .announce(.turnDone, words: nil)])
        XCTAssertEqual(ReportedStatus.effects(from: records(blocked), to: nil, gone: true), [.answered, .gone])
    }

    /// A second question straight after the first is news; the same one said
    /// again is not.
    func testANewBlockIsAnnouncedAndARepeatIsNot() {
        let first = status(.blocked, kind: .permission, message: "Run npm test")
        XCTAssertEqual(effects(.blocked, kind: .permission, message: "Run git push", after: first),
                       [.resting, .announce(.needsInput, words: "Run git push")])
        XCTAssertEqual(effects(.blocked, kind: .permission, message: "Run npm test", after: first), [])
    }

    // MARK: - A piece of the program's work that is blocked

    /// Claude Code's root reads `done` while a remote agent it started asks a
    /// question. That is the session wanting you, and when it is answered
    /// the turn that had already finished is not announced a second time.
    func testAChildsQuestionIsNotASecondFinishedTurn() {
        let finished = records(status(.done))
        var asking = finished
        asking.apply(.status(status(.blocked, kind: .question, message: "Which database?", id: "agent-7")))
        XCTAssertEqual(ReportedStatus.effects(from: finished, to: asking),
                       [.announce(.needsInput, words: "Which database?")])
        var answered = asking
        answered.apply(.clearRecord("agent-7"))
        XCTAssertEqual(ReportedStatus.effects(from: asking, to: answered), [.answered])
    }

    /// The spinner is the root's to say. A piece of work waiting on you does
    /// not stop the rest, and its being answered does not start it.
    func testABlockedChildLeavesTheSpinnerAlone() {
        let working = records(status(.working))
        var asking = working
        asking.apply(.status(status(.blocked, kind: .permission, id: "ses_1")))
        XCTAssertEqual(ReportedStatus.effects(from: working, to: asking),
                       [.announce(.needsInput, words: "Waiting for your approval")])
        var answered = asking
        answered.apply(.clearRecord("ses_1"))
        XCTAssertEqual(ReportedStatus.effects(from: asking, to: answered), [.answered])
    }

    /// A turn that ends while a piece of its work still waits: both are said.
    func testATurnCanEndWhileAChildStillWaits() {
        var asking = records(status(.working))
        asking.apply(.status(status(.blocked, kind: .question, id: "agent-7")))
        var finished = asking
        finished.apply(.status(status(.done)))
        XCTAssertEqual(ReportedStatus.effects(from: asking, to: finished),
                       [.resting, .announce(.turnDone, words: nil)])
    }

    /// Children that are only working change nothing at all.
    func testWorkingChildrenAreNoNews() {
        let finished = records(status(.done))
        var listed = finished
        listed.apply(.status(status(.working, id: "bash_1")))
        XCTAssertEqual(ReportedStatus.effects(from: finished, to: listed), [])
        var cleared = listed
        cleared.apply(.clearRecord("bash_1"))
        XCTAssertEqual(ReportedStatus.effects(from: listed, to: cleared), [])
    }

    // MARK: - Repeats, and the program leaving

    func testTheSameReportTwiceChangesNothing() {
        XCTAssertEqual(effects(.working, after: status(.working)), [])
        XCTAssertEqual(effects(.done, after: status(.done)), [])
        XCTAssertEqual(effects(.idle, after: status(.idle)), [])
    }

    /// What a finished turn raised stays when the program exits: the result
    /// is still there to look at.
    func testClearLeavesAFinishedTurnsDot() {
        XCTAssertEqual(ReportedStatus.effects(from: records(status(.done)), to: nil, gone: true), [.gone])
        XCTAssertEqual(ReportedStatus.effects(from: nil, to: nil, gone: true), [.gone])
    }

    /// A program may send 2048 bytes. A banner holds a sentence.
    func testALongLineIsCutAtAWord() {
        let long = Array(repeating: "word", count: 80).joined(separator: " ")
        let cut = ReportedStatus.banner(long)
        XCTAssertLessThanOrEqual(cut.count, ReportedStatus.bannerLength + 1)
        XCTAssertTrue(cut.hasSuffix("word…"))
        XCTAssertEqual(ReportedStatus.banner("Run npm test"), "Run npm test")
        guard case .announce(_, let words)? = effects(.error, message: long, after: status(.working)).last
        else { return XCTFail("an error is announced") }
        XCTAssertEqual(words, cut)
    }

    // MARK: - Replayed: what is true, not what happened

    /// Finished, or stuck on a question, while Wortel was closed: the dot,
    /// with no banner for old news.
    func testReplayedReportsMarkWithoutAnnouncing() {
        XCTAssertEqual(effects(.done, replayed: true), [.resting, .mark(.turnDone, words: nil)])
        XCTAssertEqual(effects(.blocked, kind: .question, replayed: true),
                       [.resting, .mark(.needsInput, words: "Asking you a question")])
        XCTAssertEqual(effects(.error, message: "Out of credits", replayed: true),
                       [.resting, .mark(.failed, words: "Out of credits")])
        XCTAssertEqual(effects(.working, replayed: true), [.working])
        XCTAssertEqual(effects(.idle, replayed: true), [.resting])
    }
}
