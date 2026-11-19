import XCTest

/// When an idle agent may be ended. Each test is one rule, and each rule is a
/// reason to stay awake: the wrong answer here is an agent killed while it
/// was working, or with a question the person had not seen answered.
final class AgentSleepTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var hour: TimeInterval { AgentSleep.finishedAfter }
    private var day: TimeInterval { AgentSleep.waitingAfter }

    /// A Claude that finished `ago` seconds back, in a session out of sight
    /// since before that, with everything else in order.
    private func finished(_ ago: TimeInterval) -> AgentSleep.Inputs {
        AgentSleep.Inputs(agent: "claude", resumable: true,
                          rest: .finished(since: now.addingTimeInterval(-ago)),
                          hiddenSince: now.addingTimeInterval(-ago - 1), now: now)
    }

    // MARK: - The two clocks

    func testAFinishedAgentSleepsAfterItsHour() {
        XCTAssertEqual(AgentSleep.decide(finished(hour + 1)), .sleep(waiting: false))
    }

    func testAndNotBefore() {
        XCTAssertEqual(AgentSleep.decide(finished(hour - 60)),
                       .notBefore(now.addingTimeInterval(60)))
    }

    func testAnAgentWaitingOnYouGetsTheLongClock() {
        var inputs = finished(hour + 1)
        inputs.rest = .waiting(since: now.addingTimeInterval(-hour - 1))
        guard case .notBefore = AgentSleep.decide(inputs) else {
            return XCTFail("a question an hour old is still a question")
        }
        inputs.rest = .waiting(since: now.addingTimeInterval(-day - 1))
        inputs.hiddenSince = now.addingTimeInterval(-day - 2)
        XCTAssertEqual(AgentSleep.decide(inputs), .sleep(waiting: true))
    }

    func testSomethingStillRunningUnderItGetsTheLongClock() {
        var inputs = finished(hour + 1)
        inputs.hasWorkUnder = true
        guard case .notBefore = AgentSleep.decide(inputs) else {
            return XCTFail("the dev server you are looking at in a browser")
        }
    }

    /// Keys went in after the agent came to rest: maybe a prompt half written.
    func testSomethingTypedAndNotSentGetsTheLongClock() {
        var inputs = finished(hour + 1)
        inputs.typedSinceRest = true
        guard case .notBefore = AgentSleep.decide(inputs) else { return XCTFail("a draft would be lost") }
    }

    /// Remote Control on: you may come back to it from your phone, which
    /// can't wake a sleeping agent. The long clock, not never, and a memory
    /// warning doesn't shorten it.
    func testRemoteControlGetsTheLongClock() {
        var inputs = finished(hour + 1)
        inputs.remoteControl = true
        let eightHoursFromRest = now.addingTimeInterval(-hour - 1 + day)
        XCTAssertEqual(AgentSleep.decide(inputs), .notBefore(eightHoursFromRest),
                       "the session you were going to answer from your phone")
        XCTAssertEqual(AgentSleep.decide(inputs, pressure: true), .notBefore(eightHoursFromRest),
                       "a memory warning is no reason to cut off your phone")
        inputs = finished(day + 1)
        inputs.remoteControl = true
        XCTAssertEqual(AgentSleep.decide(inputs), .sleep(waiting: true))
    }

    // MARK: - What restarts the clock

    func testLookingAtTheSessionRestartsTheClock() {
        var inputs = finished(hour * 3)
        inputs.hiddenSince = now.addingTimeInterval(-60)
        XCTAssertEqual(AgentSleep.decide(inputs), .notBefore(now.addingTimeInterval(hour - 60)))
    }

    func testWorkWortelSawEndingLaterThanTheAgentSaysRestartsTheClock() {
        var inputs = finished(hour * 3)
        inputs.quietSince = now.addingTimeInterval(-120)
        XCTAssertEqual(AgentSleep.decide(inputs), .notBefore(now.addingTimeInterval(hour - 120)))
    }

    // MARK: - Never

    func testAWorkingAgentNeverSleeps() {
        var inputs = finished(hour * 10)
        inputs.busy = true
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.busy))
        XCTAssertEqual(AgentSleep.decide(inputs, pressure: true), .never(.busy))
    }

    func testTheSelectedSessionNeverSleeps() {
        var inputs = finished(hour * 10)
        inputs.selected = true
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.selected))
    }

    /// `busy`, a status a later Claude invents, or no file at all.
    func testAnAgentThatDoesNotSayItIsRestingNeverSleeps() {
        var inputs = finished(hour * 10)
        inputs.rest = .unknown
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.restUnknown))
    }

    func testAPlainShellAndAnAgentNotCheckedAreLeftAlone() {
        var inputs = finished(hour * 10)
        inputs.agent = nil
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.notAnAgent))
        inputs.agent = "codex"
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.notEnabled))
    }

    func testAnAgentThatCannotBeBroughtBackExactlyIsLeftAlone() {
        var inputs = finished(hour * 10)
        inputs.resumable = false
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.notResumable))
    }

    /// After `claude; make`, ending the agent would let the shell run `make`.
    func testAnAgentWithMoreOnItsCommandLineIsLeftAlone() {
        var inputs = finished(hour * 10)
        inputs.launchIsSimple = false
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.launchNotSimple))
    }

    // MARK: - Painted for the other appearance

    /// An agent at rest for `ago` seconds, out of sight since before that,
    /// that drew itself for light on a Mac that is now dark.
    private func painted(_ ago: TimeInterval, _ agent: String = "codex") -> AgentSleep.Inputs {
        var inputs = finished(ago)
        inputs.agent = agent
        inputs.repaint = true
        return inputs
    }
    private var soon: TimeInterval { AgentSleep.repaintAfter }

    func testAnAgentPaintedForTheOtherAppearanceGoesOnceItHasRestedOutOfSight() {
        XCTAssertEqual(AgentSleep.decide(painted(soon + 1)), .repaint)
        XCTAssertEqual(AgentSleep.decide(painted(soon + 1, "claude")), .repaint)
        XCTAssertEqual(AgentSleep.decide(painted(soon - 5)), .notBefore(now.addingTimeInterval(5)))
    }

    /// Stepping away from a session for a moment must not end its agent.
    func testASessionJustLeftWaitsOutTheShortClock() {
        var inputs = painted(hour)
        inputs.hiddenSince = now.addingTimeInterval(-2)
        XCTAssertEqual(AgentSleep.decide(inputs), .notBefore(now.addingTimeInterval(soon - 2)))
    }

    func testOnlyAgentsCheckedForItAreRepainted() {
        var inputs = painted(hour)
        inputs.agent = "pi"
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.notEnabled))
        // And one painted right has no clock at all, unless it is Claude's.
        inputs = painted(hour * 10)
        inputs.repaint = false
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.notEnabled))
    }

    func testAWorkingOrUnreadableAgentIsNotRepainted() {
        var inputs = painted(hour)
        inputs.busy = true
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.busy))
        inputs = painted(hour)
        inputs.rest = .unknown
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.restUnknown))
        inputs = painted(hour)
        inputs.resumable = false
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.notResumable))
        inputs = painted(hour)
        inputs.launchIsSimple = false
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.launchNotSimple))
    }

    /// A prompt half written, a question, something still running, Remote
    /// Control: none of them is worth a repaint. Codex has no clock of its
    /// own, so it stays; Claude falls back to its long one.
    func testTextTypedAQuestionWorkUnderItOrRemoteControlKeepARepaintOff() {
        for hold in [\AgentSleep.Inputs.keysSinceWork, \.hasWorkUnder, \.remoteControl] {
            var inputs = painted(hour)
            inputs[keyPath: hold] = true
            XCTAssertEqual(AgentSleep.decide(inputs), .never(.held))
        }
        var inputs = painted(hour)
        inputs.rest = .waiting(since: now.addingTimeInterval(-hour))
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.held))

        inputs = painted(hour + 1, "claude")
        inputs.keysSinceWork = true
        XCTAssertEqual(AgentSleep.decide(inputs), .sleep(waiting: false),
                       "its ordinary hour is up, and text typed before it rested is no reason against")
        inputs = painted(soon + 1, "claude")
        inputs.keysSinceWork = true
        guard case .notBefore = AgentSleep.decide(inputs) else {
            return XCTFail("with text typed it waits for its ordinary clock")
        }
    }

    /// A click or a scroll after it finished is someone reading the answer.
    func testAClickOrAScrollDoesNotKeepARepaintOff() {
        var inputs = painted(soon + 1)
        inputs.typedSinceRest = true
        XCTAssertEqual(AgentSleep.decide(inputs), .repaint)
    }

    // MARK: - The one in front

    func testTheOneInFrontAtTheChangeIsRestartedWhereItStands() {
        var inputs = painted(AgentSleep.repaintInPlaceAfter + 1)
        inputs.selected = true
        inputs.hiddenSince = now
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.selected), "in front, and not asked for")
        inputs.inPlace = true
        XCTAssertEqual(AgentSleep.decide(inputs), .repaint)
    }

    /// A turn that ended a second ago is still being read.
    func testNotWhileItsAnswerIsFresh() {
        var inputs = painted(1)
        inputs.selected = true
        inputs.inPlace = true
        XCTAssertEqual(AgentSleep.decide(inputs),
                       .notBefore(now.addingTimeInterval(AgentSleep.repaintInPlaceAfter - 1)))
    }

    func testTheOneInFrontIsNeverEndedForAnythingElse() {
        var inputs = painted(hour * 10, "claude")
        inputs.selected = true
        inputs.inPlace = true
        inputs.keysSinceWork = true
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.selected))
        inputs = finished(hour * 10)
        inputs.selected = true
        inputs.inPlace = true
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.selected), "painted right: nothing to restart for")
    }

    // MARK: - What a report says of rest

    private func records(_ root: ProgramStatus.State, child: ProgramStatus.State? = nil) -> ProgramRecords {
        var records = ProgramRecords(root: ProgramStatus(state: root))
        if let child {
            var piece = ProgramStatus(state: child)
            piece.id = "task_1"
            records.apply(.status(piece))
        }
        return records
    }

    func testIdleAndDoneAreRest() {
        let since = now.addingTimeInterval(-60)
        XCTAssertEqual(AgentRest(reported: records(.idle), since: since), .finished(since: since))
        XCTAssertEqual(AgentRest(reported: records(.done), since: since), .finished(since: since))
    }

    func testWorkingBlockedAndFailedAreNot() {
        let since = now.addingTimeInterval(-60)
        XCTAssertEqual(AgentRest(reported: records(.working), since: since), .unknown)
        XCTAssertEqual(AgentRest(reported: records(.error), since: since), .unknown)
        XCTAssertEqual(AgentRest(reported: records(.blocked), since: since), .waiting(since: since))
    }

    /// Claude Code's root reads `done` while a background command runs, or a
    /// remote agent waits for an answer.
    func testAPieceOfWorkStillGoingOrWaitingIsNotRest() {
        let since = now.addingTimeInterval(-60)
        XCTAssertEqual(AgentRest(reported: records(.done, child: .working), since: since), .waiting(since: since))
        XCTAssertEqual(AgentRest(reported: records(.done, child: .blocked), since: since), .waiting(since: since))
    }

    func testNothingSaidIsUnknown() {
        XCTAssertEqual(AgentRest(reported: nil, since: now), .unknown)
        XCTAssertEqual(AgentRest(reported: ProgramRecords(), since: now), .unknown)
        XCTAssertEqual(AgentRest(reported: records(.idle), since: nil), .unknown)
    }

    // MARK: - Memory pressure

    func testPressureShortensTheFinishedClockToItsFloor() {
        let inputs = finished(AgentSleep.pressureFloor + 1)
        guard case .notBefore = AgentSleep.decide(inputs) else { return XCTFail("not without pressure") }
        XCTAssertEqual(AgentSleep.decide(inputs, pressure: true), .sleep(waiting: false))
    }

    func testPressureDoesNotTouchAnAgentThatJustFinished() {
        guard case .notBefore = AgentSleep.decide(finished(30), pressure: true) else {
            return XCTFail("half a minute after its turn is not idle")
        }
    }

    func testPressureDoesNotShortenTheLongClock() {
        var inputs = finished(hour + 1)
        inputs.rest = .waiting(since: now.addingTimeInterval(-hour - 1))
        guard case .notBefore = AgentSleep.decide(inputs, pressure: true) else {
            return XCTFail("a question is not given up for memory")
        }
    }

    // MARK: - Claude's own word

    func testClaudesStatusMapsToRest() {
        let since = now
        XCTAssertEqual(AgentRest(claudeStatus: "idle", since: since), .finished(since: since))
        XCTAssertEqual(AgentRest(claudeStatus: "waiting", since: since), .waiting(since: since))
        XCTAssertEqual(AgentRest(claudeStatus: "busy", since: since), .unknown)
        XCTAssertEqual(AgentRest(claudeStatus: "shell", since: since), .waiting(since: since),
                       "a background command of its own is running: the long clock")
        XCTAssertEqual(AgentRest(claudeStatus: "compacting", since: since), .unknown)
        XCTAssertEqual(AgentRest(claudeStatus: nil, since: since), .unknown)
        XCTAssertEqual(AgentRest(claudeStatus: "idle", since: nil), .unknown, "idle since when?")
    }

    /// The file as Claude Code 2.1.327 wrote it at a permission prompt
    /// (2026-11-18), cut down to the fields read.
    func testClaudesProcessFileIsRead() {
        let file = Data("""
            {"pid":68635,"sessionId":"4D98C3D5-653B-4915-8FA3-8DB43F551EA7","status":"waiting",
             "waitingFor":"permission prompt","statusUpdatedAt":1795019450000,"version":"2.1.327"}
            """.utf8)
        let state = AgentResumeStore.claudeProcessState(sessionFile: file, pid: 68635)
        XCTAssertEqual(state?.conversationID, "4d98c3d5-653b-4915-8fa3-8db43f551ea7")
        XCTAssertEqual(state?.status, "waiting")
        XCTAssertEqual(state?.statusChangedAt, Date(timeIntervalSince1970: 1_795_019_450))
        XCTAssertNil(AgentResumeStore.claudeProcessState(sessionFile: file, pid: 1),
                     "a stale file for a pid since reused is nobody's")
    }

    /// Claude Code 2.1.327 writes the Remote Control session's id while it is
    /// linked and `null` once it is not.
    func testRemoteControlIsReadFromClaudesProcessFile() {
        func state(_ bridge: String) -> AgentResumeStore.ClaudeProcessState? {
            AgentResumeStore.claudeProcessState(sessionFile: Data("""
                {"pid":7,"sessionId":"4d98c3d5-653b-4915-8fa3-8db43f551ea7","status":"idle",
                 "statusUpdatedAt":1795019450000\(bridge)}
                """.utf8), pid: 7)
        }
        XCTAssertEqual(state(#","bridgeSessionId":"session_01ABCDEFGHJKMNPQRSTVWXYZ""#)?.remoteControl, true)
        XCTAssertEqual(state(#","bridgeSessionId":null"#)?.remoteControl, false)
        XCTAssertEqual(state(#","bridgeSessionId":"""#)?.remoteControl, false)
        XCTAssertEqual(state("")?.remoteControl, false)
    }

    func testAnOlderClaudeWithoutAStatusIsUnknown() {
        let file = Data(#"{"pid":7,"sessionId":"4d98c3d5-653b-4915-8fa3-8db43f551ea7"}"#.utf8)
        let state = AgentResumeStore.claudeProcessState(sessionFile: file, pid: 7)
        XCTAssertEqual(AgentRest(claudeStatus: state?.status, since: state?.statusChangedAt), .unknown)
    }
}
