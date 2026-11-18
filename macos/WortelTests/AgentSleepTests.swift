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

    func testASessionWhosePtyTheAppDoesNotHoldIsLeftAlone() {
        var inputs = finished(hour * 10)
        inputs.hasTerminal = false
        XCTAssertEqual(AgentSleep.decide(inputs), .never(.noTerminal))
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
        XCTAssertEqual(AgentRest(claudeStatus: "shell", since: since), .unknown)
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

    func testAnOlderClaudeWithoutAStatusIsUnknown() {
        let file = Data(#"{"pid":7,"sessionId":"4d98c3d5-653b-4915-8fa3-8db43f551ea7"}"#.utf8)
        let state = AgentResumeStore.claudeProcessState(sessionFile: file, pid: 7)
        XCTAssertEqual(AgentRest(claudeStatus: state?.status, since: state?.statusChangedAt), .unknown)
    }
}
