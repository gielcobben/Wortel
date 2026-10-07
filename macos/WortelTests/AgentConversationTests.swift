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
}
