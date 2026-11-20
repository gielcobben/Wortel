import XCTest

/// Exact conversations for Pi and Codex, against folders laid out the way
/// each agent lays them out (checked against Pi's `session-manager.js` and a
/// real Codex 0.142 rollout on 2026-10-07).
///
/// Every failure here is silent in the app: a session resumes into "the
/// latest conversation in this folder", which is right until two sessions run
/// the same agent in one folder.
final class AgentConversationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentconv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let cwd = "/Users/someone/Developer/app"
    private let a = "01a083f5-a13c-7b70-b215-1593799518d0"
    private let b = "019f135f-fada-7d42-a92f-5d96b6fc16f8"

    private func iso(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    // MARK: - Pi

    func testPiDirectoryNameMatchesPi() {
        XCTAssertEqual(AgentConversation.Pi.directoryName(cwd: "/Users/someone/Developer/app"),
                       "--Users-someone-Developer-app--")
        // A path segment that already starts with a dash keeps it, which is
        // where Pi's doubled dashes come from.
        XCTAssertEqual(AgentConversation.Pi.directoryName(cwd: "/x/-Users-y/z:w"), "--x--Users-y-z-w--")
    }

    func testPiFileNameGivesIdAndStart() throws {
        let parsed = try XCTUnwrap(AgentConversation.Pi.parse(fileName: "2026-09-09T02-18-28-028Z_\(a)"))
        XCTAssertEqual(parsed.id, a)
        XCTAssertEqual(parsed.started, iso("2026-09-09T02:18:28.028Z"))
        XCTAssertNil(AgentConversation.Pi.parse(fileName: "notes"))
    }

    private func makePi(_ stamp: String, _ id: String) throws {
        let dir = root.appendingPathComponent(AgentConversation.Pi.directoryName(cwd: cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("\(stamp)_\(id).jsonl"))
    }

    /// Two Pi sessions in one folder: each is found by when it started, not by
    /// which one was touched last.
    func testPiConversationIsFoundByStartTime() throws {
        try makePi("2026-10-07T13-00-00-100Z", a)
        try makePi("2026-10-07T13-05-00-100Z", b)
        let pi = AgentConversation.Pi.self
        XCTAssertEqual(pi.started(near: iso("2026-10-07T13:00:02.000Z"), cwd: cwd, root: root), a)
        XCTAssertEqual(pi.started(near: iso("2026-10-07T13:04:59.000Z"), cwd: cwd, root: root), b)
        // Started between the two and far from both: no claim.
        XCTAssertNil(pi.started(near: iso("2026-10-07T13:02:30.000Z"), cwd: cwd, root: root))
    }

    func testPiCommandLineNamesTheConversation() throws {
        try makePi("2026-10-07T13-00-00-100Z", a)
        let pi = AgentConversation.Pi.self
        XCTAssertEqual(pi.target(argv: "pi --session \(a)", cwd: cwd, root: root), a)
        XCTAssertEqual(pi.target(argv: "pi --session-id \(a)", cwd: cwd, root: root), a)
        XCTAssertEqual(pi.target(argv: "pi --session /x/2026-10-07T13-00-00-100Z_\(a).jsonl",
                                 cwd: cwd, root: root), a)
        // A partial id, resolved against the folder only when unambiguous.
        XCTAssertEqual(pi.target(argv: "pi --session 01a083f5", cwd: cwd, root: root), a)
        XCTAssertNil(pi.target(argv: "pi -c", cwd: cwd, root: root))
        XCTAssertTrue(pi.continuesLatest(argv: "pi -c"))
    }

    // MARK: - Codex

    private func makeCodex(day: String, stamp: String, id: String, cwd: String) throws {
        let dir = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = #"{"timestamp":"x","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","base_instructions":"…"}}"#
        try Data((meta + "\n{\"type\":\"event\"}\n").utf8)
            .write(to: dir.appendingPathComponent("rollout-\(stamp)-\(id).jsonl"))
    }

    private func local(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: text)!
    }

    func testCodexFileNameGivesIdAndLocalStart() throws {
        let parsed = try XCTUnwrap(AgentConversation.Codex.parse(
            fileName: "rollout-2026-06-29T08-34-45-\(b)"))
        XCTAssertEqual(parsed.id, b)
        XCTAssertEqual(parsed.started, local("2026-06-29T08-34-45"))
    }

    /// Codex keeps every folder's conversations in one tree by day, so the
    /// folder is read from each candidate's first line.
    func testCodexConversationIsFoundByStartTimeAndFolder() throws {
        try makeCodex(day: "2026/10/07", stamp: "2026-10-07T13-00-00", id: a, cwd: "/elsewhere")
        try makeCodex(day: "2026/10/07", stamp: "2026-10-07T13-00-01", id: b, cwd: cwd)
        let found = AgentConversation.Codex.started(
            near: local("2026-10-07T13-00-00"), cwd: cwd, root: root)
        XCTAssertEqual(found, b, "the same start in another folder must not win")
    }

    func testCodexCommandLine() {
        let codex = AgentConversation.Codex.self
        XCTAssertEqual(codex.target(argv: "codex resume \(b)"), b)
        XCTAssertEqual(codex.target(argv: "codex exec resume \(b) fix it"), b)
        XCTAssertNil(codex.target(argv: "codex resume --last"))
        XCTAssertNil(codex.target(argv: "codex"))
        XCTAssertTrue(codex.resumesLatest(argv: "codex resume --last"))
    }

    /// A Codex id is a UUIDv7: its first 48 bits date it, which is how a
    /// remembered id is checked without walking the whole tree.
    func testCodexIdDatesItself() throws {
        let date = try XCTUnwrap(AgentConversation.Codex.uuidV7Date(b))
        XCTAssertEqual(date.timeIntervalSince1970, 1_782_736_485.082, accuracy: 0.001)
        XCTAssertNil(AgentConversation.Codex.uuidV7Date("39027937-053d-49f7-ae3b-1eb98a87a811"))
    }

    /// A rollout made at `made` (its id dates it, as Codex's do), holding
    /// one turn line stamped `turnAt`.
    @discardableResult
    private func makeCodexRollout(made: Date, cwd: String, turnAt: Date) throws -> String {
        let millis = UInt64(made.timeIntervalSince1970 * 1000)
        let hex = String(format: "%012llx", millis)
        let id = "\(hex.prefix(8))-\(hex.dropFirst(8))-7000-8000-000000000000"
        let c = Calendar.current.dateComponents([.year, .month, .day], from: made)
        let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: turnAt)
        let lines = [
            #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#,
            #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"task_started"}}"#,
        ]
        let name = DateFormatter()
        name.locale = Locale(identifier: "en_US_POSIX")
        name.timeZone = .current
        name.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        try Data(lines.joined(separator: "\n").utf8)
            .write(to: dir.appendingPathComponent("rollout-\(name.string(from: made))-\(id).jsonl"))
        return id
    }

    // MARK: - The last sign of being in a conversation

    /// What ending an agent to bring it back goes by: text typed after the
    /// last sign of it being in the conversation Wortel knows may have moved
    /// it to another (`/new`), and then the wrong one would come back.
    func testCodexWasLastSeenInAConversationWhenItsFileWasWritten() throws {
        let made = Date(timeIntervalSinceNow: -3600)
        let id = try makeCodexRollout(made: made, cwd: cwd, turnAt: made)
        let file = try XCTUnwrap(AgentConversation.Codex.file(id: id, root: root))
        let written = Date(timeIntervalSinceNow: -600)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        let seen = try XCTUnwrap(AgentConversation.lastSeenIn(
            agent: "codex", id: id, cwd: cwd, argv: "codex", startedAt: made, codexRoot: root))
        XCTAssertEqual(seen.timeIntervalSince(written), 0, accuracy: 1)
    }

    /// Resumed by name and not written to since: its start is the sign.
    func testOrWhenItWasStartedByName() throws {
        let made = Date(timeIntervalSinceNow: -86_400)
        let id = try makeCodexRollout(made: made, cwd: cwd, turnAt: made)
        let file = try XCTUnwrap(AgentConversation.Codex.file(id: id, root: root))
        try FileManager.default.setAttributes([.modificationDate: made], ofItemAtPath: file.path)
        let started = Date(timeIntervalSinceNow: -60)
        XCTAssertEqual(AgentConversation.lastSeenIn(
            agent: "codex", id: id, cwd: cwd, argv: "codex resume \(id)", startedAt: started,
            codexRoot: root), started)
        // Started plainly, the old write is all there is.
        let plain = try XCTUnwrap(AgentConversation.lastSeenIn(
            agent: "codex", id: id, cwd: cwd, argv: "codex", startedAt: started, codexRoot: root))
        XCTAssertEqual(plain.timeIntervalSince(made), 0, accuracy: 1)
        // Named another conversation: no sign of this one from the start.
        let other = try XCTUnwrap(AgentConversation.lastSeenIn(
            agent: "codex", id: id, cwd: cwd, argv: "codex resume \(b)", startedAt: started, codexRoot: root))
        XCTAssertEqual(other.timeIntervalSince(made), 0, accuracy: 1)
    }

    func testNoFileAndNoNameIsNoSign() {
        XCTAssertNil(AgentConversation.lastSeenIn(agent: "codex", id: b, cwd: cwd, argv: "codex",
                                                  startedAt: Date(), codexRoot: root))
        XCTAssertNil(AgentConversation.lastSeenIn(agent: "claude", id: b, cwd: cwd, argv: "claude",
                                                  startedAt: Date(), codexRoot: root))
    }

    private func reading(_ id: String?, cwd: String? = nil, others: Set<String> = [],
                         since: Date) -> String {
        switch AgentConversation.Codex.turnReading(conversation: id, cwd: cwd ?? self.cwd, since: since,
                                                   others: others, root: root) {
        case .turn: return "turn"
        case .noTurn: return "noTurn"
        case .unknown: return "unknown"
        }
    }

    /// The id a session knows can be one Codex has left (`/new`, `/resume`
    /// inside it): a turn written since in another conversation of the folder
    /// is still its turn, unless another session owns that conversation.
    func testACodexTurnIsLookedForInTheFoldersOtherRolloutsToo() throws {
        let now = Date()
        let since = now.addingTimeInterval(-60)
        let old = try makeCodexRollout(made: now.addingTimeInterval(-3600), cwd: cwd,
                                       turnAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(reading(old, since: since), "noTurn")
        try makeCodexRollout(made: now.addingTimeInterval(-10), cwd: "/elsewhere", turnAt: now)
        XCTAssertEqual(reading(old, since: since), "noTurn", "another folder's turn is not this session's")
        let moved = try makeCodexRollout(made: now.addingTimeInterval(-5), cwd: cwd, turnAt: now)
        XCTAssertEqual(reading(old, since: since), "turn")
        XCTAssertEqual(reading(old, others: [moved.uppercased()], since: since), "noTurn",
                       "a conversation another session is in answers only for that session")
    }

    /// A conversation made weeks ago and resumed is appended to in the day
    /// folder it was made in, which is where a session with no known id finds it.
    func testAnOldResumedConversationIsFound() throws {
        let now = Date()
        try makeCodexRollout(made: now.addingTimeInterval(-40 * 86_400), cwd: cwd, turnAt: now)
        XCTAssertEqual(reading(nil, since: now.addingTimeInterval(-60)), "turn")
    }

    /// A session that knows its conversation but can't read it gets no verdict,
    /// whatever else the folder holds; one with no conversation and nothing
    /// written has taken no turn (Codex writes the rollout at the first prompt).
    func testCodexWithoutAReadableRollout() throws {
        let now = Date()
        let since = now.addingTimeInterval(-60)
        try makeCodexRollout(made: now.addingTimeInterval(-3600), cwd: cwd,
                             turnAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(reading("39027937-053d-49f7-ae3b-1eb98a87a811", since: since), "unknown",
                       "a v4 id has no day folder to be found in")
        XCTAssertEqual(reading(a, since: since), "unknown")
        XCTAssertEqual(reading(nil, since: since), "noTurn")
        XCTAssertEqual(reading(nil, cwd: "/nowhere", since: since), "noTurn")
    }

    // MARK: - Resume commands

    func testExactResumeCommands() {
        func command(_ agent: String, _ id: String?) -> String? {
            AgentResumeStore.resumeCommand(
                for: AgentMarker(agent: agent, model: nil, cwd: nil, argv: nil, shellPID: nil, startedAt: nil),
                knownConversationID: id)
        }
        XCTAssertEqual(command("pi", a), "pi --session \(a)")
        XCTAssertEqual(command("codex", b), "codex resume \(b)")
        XCTAssertEqual(command("claude", a), "claude --resume \(a)")
        // Without a known conversation: the old "continue the latest".
        XCTAssertEqual(command("pi", nil), "pi -c")
        XCTAssertEqual(command("codex", nil), "codex resume --last")
        // An agent without exact resume ignores an id.
        XCTAssertEqual(command("opencode", a), "opencode --continue")
    }

    // MARK: - A lost keeper

    private func marker(_ agent: String, argv: String? = nil) -> AgentMarker {
        AgentMarker(agent: agent, model: nil, cwd: "/p", argv: argv, shellPID: nil, startedAt: nil)
    }

    /// 2026-10-10: started as `claude --resume A`, then `/clear` into B. The
    /// command line still said A, and the keeper's loss resumed A.
    func testWhatTheProcessSaidBeatsTheCommandLine() {
        let point = AgentConversation.resumePoint(
            said: b, named: AgentResumeStore.claudeResumeTarget(argv: "claude --resume \(a)"),
            guessed: a, last: a, exists: { _ in true })
        XCTAssertEqual(point, .conversation(b))
    }

    /// 2026-11-20: four Claudes opened in one folder, one used. The other
    /// three said which conversation they were in, but never wrote it; the
    /// start-time guess then gave all three the used one's, and they resumed
    /// into it. One that never had a conversation starts afresh.
    func testAnAgentThatNeverWroteItsConversationStartsAfresh() {
        let point = AgentConversation.resumePoint(
            said: b, named: nil, guessed: a, last: a, exists: { $0 == a })
        XCTAssertEqual(point, .fresh)
    }

    /// The guess, and then the last one seen, only when the agent said
    /// nothing; and only a conversation that can still be resumed.
    func testWithoutTheAgentsWordTheRestIsTriedInOrder() {
        XCTAssertEqual(AgentConversation.resumePoint(said: nil, named: a, guessed: b, last: b,
                                                     exists: { _ in true }), .conversation(a))
        XCTAssertEqual(AgentConversation.resumePoint(said: nil, named: nil, guessed: b, last: a,
                                                     exists: { _ in true }), .conversation(b))
        XCTAssertEqual(AgentConversation.resumePoint(said: nil, named: a, guessed: nil, last: b,
                                                     exists: { $0 == b }), .conversation(b))
        XCTAssertEqual(AgentConversation.resumePoint(said: nil, named: nil, guessed: nil, last: a,
                                                     exists: { _ in false }), .unknown)
    }

    /// A fresh start runs the command the agent was started with; a command
    /// line that is more than one command is typed and left at the prompt.
    func testAFreshStartRunsWhatStartedIt() {
        XCTAssertEqual(AgentResumeStore.resumeInput(for: marker("claude", argv: "claude --model haiku"), at: .fresh),
                       "claude --model haiku\n")
        XCTAssertEqual(AgentResumeStore.resumeInput(for: marker("claude"), at: .fresh), "claude\n")
        XCTAssertEqual(AgentResumeStore.resumeInput(for: marker("claude", argv: "claude; rm -rf build"), at: .fresh),
                       "claude; rm -rf build")
        XCTAssertEqual(AgentResumeStore.resumeInput(for: marker("claude", argv: "claude"), at: .unknown),
                       AgentResumeStore.resumeInput(for: marker("claude", argv: "claude"), knownConversationID: nil))
    }

    /// The conversation saved at quit is this run's only if the marker is of
    /// the same run: a crash can leave a marker for a later one.
    func testASavedConversationCountsOnlyForTheSameRun() {
        let started = Date(timeIntervalSince1970: 1_795_000_000)
        func entry(startedAt: Date?, argv: String = "claude") -> PersistedSession {
            PersistedSession(id: UUID(), name: "s", title: "", cwd: "/p", selected: false, nameSource: "user",
                             gitPanelVisible: nil, runningAgent: "claude", runningArgv: argv,
                             runningConversationID: a, runningStartedAt: startedAt)
        }
        func run(at date: Date?, argv: String = "claude") -> AgentMarker {
            AgentMarker(agent: "claude", model: nil, cwd: "/p", argv: argv, shellPID: 1, startedAt: date)
        }
        XCTAssertEqual(entry(startedAt: started).savedConversation(forRunOf: run(at: started)), a)
        XCTAssertNil(entry(startedAt: started).savedConversation(forRunOf: run(at: started.addingTimeInterval(60))))
        XCTAssertEqual(entry(startedAt: started).savedConversation(forRunOf: nil), a)
        // Saved by a build that kept no start time: by its command line.
        XCTAssertEqual(entry(startedAt: nil).savedConversation(forRunOf: run(at: started)), a)
        XCTAssertNil(entry(startedAt: nil).savedConversation(forRunOf: run(at: started, argv: "claude -c")))
    }

    func testTheRunningAgentIsOwedItsResume() throws {
        let lost = Date()
        let owed = try XCTUnwrap(AgentConversation.lostWithKeeper(
            running: marker("claude"), liveConversationID: b, ended: nil, keeperLostAt: lost))
        XCTAssertEqual(owed.marker.agent, "claude")
        XCTAssertEqual(owed.conversationID, b)
    }

    /// The shell reached its prompt before its own hangup and cleared the
    /// marker, as on 2026-10-10 for three agents of nine.
    func testAnAgentThatEndedAsTheKeeperWentIsStillOwedItsResume() throws {
        let lost = Date()
        for endedAt in [lost.addingTimeInterval(-1), lost.addingTimeInterval(0.3)] {
            let ended = AgentConversation.EndedAgent(marker: marker("claude"), conversationID: b, at: endedAt)
            let owed = try XCTUnwrap(AgentConversation.lostWithKeeper(
                running: nil, liveConversationID: nil, ended: ended, keeperLostAt: lost))
            XCTAssertEqual(owed.conversationID, b)
        }
    }

    /// A resume is owed until the agent shows up running, not merely until it
    /// is typed: a shell that died before running it must not lose it.
    func testATypedResumeIsOwedUntilItsAgentRuns() {
        var owed = OwedResume(agent: marker("claude"), conversationID: b, input: "claude --resume \(b)\n")
        XCTAssertFalse(AgentConversation.confirms(marker("claude"), owed), "not typed yet")
        owed.typedAt = Date()
        XCTAssertFalse(AgentConversation.confirms(marker("pi"), owed))
        XCTAssertTrue(AgentConversation.confirms(marker("claude"), owed))
        XCTAssertTrue(owed.isOwed(at: Date()))
        XCTAssertFalse(owed.isOwed(at: Date().addingTimeInterval(OwedResume.answerWithin + 1)),
                       "a resume that never starts is not retried forever")
    }

    /// A logout ends the keeper's shells, which clear their markers, and then
    /// quits the app: the quit's save must still name the agent.
    func testAnAgentThatEndedWithItsShellIsSavedForResume() {
        let now = Date()
        let shell: pid_t = 4242
        let ended = AgentConversation.EndedAgent(
            marker: AgentMarker(agent: "claude", model: nil, cwd: "/p", argv: nil, shellPID: shell, startedAt: nil),
            conversationID: b, at: now.addingTimeInterval(-2))
        XCTAssertTrue(AgentConversation.endedWithItsShell(ended, now: now, shellIsGone: { _ in true }))
        XCTAssertFalse(AgentConversation.endedWithItsShell(ended, now: now, shellIsGone: { _ in false }),
                       "you quit an agent at its prompt and the shell stays")
        XCTAssertFalse(AgentConversation.endedWithItsShell(
            ended, now: now.addingTimeInterval(60), shellIsGone: { _ in true }))
    }

    /// A shell that outlived a lost keeper (the app holds its own copy of
    /// every pty) ends like any other later on: `exit` closes it, and the
    /// agent you quit first doesn't come back.
    func testAShellThatOutlivedTheKeeperEndsNormallyLater() {
        let lost = Date()
        XCTAssertTrue(AgentConversation.restartsAfterLoss(
            lostAt: lost, endedAt: lost.addingTimeInterval(2), isSessionTerminal: false, agentRunning: false))
        XCTAssertFalse(AgentConversation.restartsAfterLoss(
            lostAt: lost, endedAt: lost.addingTimeInterval(3600), isSessionTerminal: true, agentRunning: false))
        // Its agent never handed it a prompt: still the keeper's doing.
        XCTAssertTrue(AgentConversation.restartsAfterLoss(
            lostAt: lost, endedAt: lost.addingTimeInterval(30), isSessionTerminal: true, agentRunning: true))
        XCTAssertFalse(AgentConversation.restartsAfterLoss(
            lostAt: lost, endedAt: lost.addingTimeInterval(30), isSessionTerminal: false, agentRunning: true))
        let quitLater = AgentConversation.EndedAgent(marker: marker("claude"), conversationID: b,
                                                     at: lost.addingTimeInterval(3600))
        XCTAssertNil(AgentConversation.lostWithKeeper(
            running: nil, liveConversationID: nil, ended: quitLater, keeperLostAt: lost))
    }

    func testAnAgentQuitEarlierIsNotBroughtBack() {
        let lost = Date()
        let ended = AgentConversation.EndedAgent(
            marker: marker("claude"), conversationID: b, at: lost.addingTimeInterval(-60))
        XCTAssertNil(AgentConversation.lostWithKeeper(
            running: nil, liveConversationID: nil, ended: ended, keeperLostAt: lost))
        XCTAssertNil(AgentConversation.lostWithKeeper(
            running: nil, liveConversationID: nil, ended: nil, keeperLostAt: lost))
    }
}
