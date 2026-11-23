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

    /// A turn that ends while a piece of its work still waits on a question.
    func testATurnCanEndWhileAChildStillWaits() {
        var asking = records(status(.working))
        asking.apply(.status(status(.blocked, kind: .question, id: "agent-7")))
        var finished = asking
        finished.apply(.status(status(.done)))
        // The question was announced when it was asked; the turn is held
        // until that agent is done, since it carries on once answered.
        XCTAssertEqual(ReportedStatus.effects(from: asking, to: finished), [])
        XCTAssertEqual(finished.effective?.state, .blocked)
        var gone = finished
        gone.apply(.clearRecord("agent-7"))
        XCTAssertEqual(ReportedStatus.effects(from: finished, to: gone),
                       [.answered, .resting, .announceAfterWork(.turnDone)])
    }

    /// A turn that ends while a background command it started still runs is
    /// not over: the spinner stays, and "finished" comes when the command
    /// has ended too.
    func testATurnWithBackgroundWorkEndsWhenTheWorkDoes() {
        var running = records(status(.working))
        running.apply(.status(status(.working, id: "bash_1")))
        var turnEnded = running
        turnEnded.apply(.status(status(.done)))
        // Nothing to say: it was working and still is.
        XCTAssertEqual(ReportedStatus.effects(from: running, to: turnEnded), [])
        XCTAssertEqual(turnEnded.effective?.state, .working)
        var allDone = turnEnded
        allDone.apply(.clearRecord("bash_1"))
        // Later than a turn's end usually is: the program tends to carry on.
        XCTAssertEqual(ReportedStatus.effects(from: turnEnded, to: allDone),
                       [.resting, .announceAfterWork(.turnDone)])
        XCTAssertEqual(allDone.effective?.state, .done)
        // What is kept across a relaunch is what the program said: not a turn
        // held open by work that is not kept.
        XCTAssertEqual(turnEnded.said?.state, .done)
    }

    /// Two pieces of work: the turn is over when the last one is.
    func testTheLastPieceOfWorkEndsTheTurn() {
        var turnEnded = records(status(.working, id: "bash_1"), status(.working, id: "monitor_2"),
                                status(.done))
        var one = turnEnded
        one.apply(.clearRecord("bash_1"))
        XCTAssertEqual(ReportedStatus.effects(from: turnEnded, to: one), [])
        turnEnded = one
        one.apply(.clearRecord("monitor_2"))
        XCTAssertEqual(ReportedStatus.effects(from: turnEnded, to: one),
                       [.resting, .announceAfterWork(.turnDone)])
    }

    /// Work listed after a turn was over does not take back its end, nor
    /// announce it again when it ends.
    func testWorkListedAfterTheTurnChangesNothing() {
        let finished = records(status(.done))
        var listed = finished
        listed.apply(.status(status(.working, id: "bash_1")))
        XCTAssertEqual(ReportedStatus.effects(from: finished, to: listed), [])
        var cleared = listed
        cleared.apply(.clearRecord("bash_1"))
        XCTAssertEqual(ReportedStatus.effects(from: listed, to: cleared), [])
    }

    /// A turn stopped with Esc is stopped, background work or not.
    func testAStoppedTurnIsNotHeld() {
        let stopped = records(status(.working, id: "bash_1"), status(.idle))
        XCTAssertEqual(stopped.effective?.state, .idle)
    }

    /// A background agent that asks a question is not the turn's end: the
    /// question is announced, the turn is not, and once it is answered and
    /// done the turn is announced once.
    func testAQuestionFromHeldWorkIsNotTheTurnsEnd() {
        let held = records(status(.working, id: "agent-7"), status(.done))
        var asking = held
        asking.apply(.status(status(.blocked, kind: .question, message: "Which database?", id: "agent-7")))
        XCTAssertEqual(ReportedStatus.effects(from: held, to: asking),
                       [.announce(.needsInput, words: "Which database?")])
        var answered = asking
        answered.apply(.status(status(.working, id: "agent-7")))
        XCTAssertEqual(ReportedStatus.effects(from: asking, to: answered), [.answered])
        var ended = answered
        ended.apply(.clearRecord("agent-7"))
        XCTAssertEqual(ReportedStatus.effects(from: answered, to: ended),
                       [.resting, .announceAfterWork(.turnDone)])
    }

    /// A turn Claude Code finished beside a server it started is announced
    /// as finished: the server is not work the turn waits on, and before
    /// 2026-11-21 it held the spinner, and the "finished" dot, for as long as
    /// it ran.
    func testAClaudeCodeTurnBesideAServerIsAnnounced() {
        func claude(_ state: ProgramStatus.State, id: String? = nil) -> ProgramStatus {
            ProgramStatus(state: state, app: "claude-code", id: id)
        }
        let working = records(claude(.working), claude(.working, id: "b7f3k2p9z"))
        var finished = working
        finished.apply(.status(claude(.done)))
        XCTAssertEqual(ReportedStatus.effects(from: working, to: finished),
                       [.resting, .announce(.turnDone, words: nil)])
        // The server ending later is no news.
        var stopped = finished
        stopped.apply(.clearRecord("b7f3k2p9z"))
        XCTAssertEqual(ReportedStatus.effects(from: finished, to: stopped), [])
        // A subagent still running does hold it, and is announced when it ends.
        let delegating = records(claude(.working), claude(.working, id: "b7f3k2p9z"),
                                 claude(.working, id: "a3k9x2m1q"))
        var held = delegating
        held.apply(.status(claude(.done)))
        XCTAssertEqual(ReportedStatus.effects(from: delegating, to: held), [])
        var agentDone = held
        agentDone.apply(.clearRecord("a3k9x2m1q"))
        XCTAssertEqual(ReportedStatus.effects(from: held, to: agentDone),
                       [.resting, .announceAfterWork(.turnDone)])
    }

    /// A failed turn and a question are news even with work still going.
    func testErrorAndBlockStandOverBackgroundWork() {
        var running = records(status(.working, id: "bash_1"), status(.working))
        var failed = running
        failed.apply(.status(status(.error, message: "Rate limit reached")))
        XCTAssertEqual(ReportedStatus.effects(from: running, to: failed),
                       [.resting, .announce(.failed, words: "Rate limit reached")])
        running = records(status(.working, id: "bash_1"), status(.working))
        var asking = running
        asking.apply(.status(status(.blocked, kind: .permission)))
        XCTAssertEqual(asking.effective?.state, .blocked)
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
