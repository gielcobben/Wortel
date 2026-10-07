import XCTest

/// Which conversation a `claude` command line names.
///
/// This is the exact answer for an agent that resumed: a resume appends to
/// the original transcript and creates nothing, so there is no new file to
/// date. Every resume Wortel types is `claude --resume <id>`, so getting this
/// wrong turns every restored session back into a newest-file guess, which is
/// how two sessions in one repo ended up in the same conversation.
final class ClaudeResumeTargetTests: XCTestCase {
    private let id = "5131fb0c-345b-4a6c-9d49-49084d92b570"

    func testTheResumeWortelTypes() {
        XCTAssertEqual(AgentResumeStore.claudeResumeTarget(argv: "claude --resume \(id)"), id)
    }

    func testTheOtherSpellings() {
        XCTAssertEqual(AgentResumeStore.claudeResumeTarget(argv: "claude -r \(id)"), id)
        XCTAssertEqual(AgentResumeStore.claudeResumeTarget(argv: "claude --resume=\(id)"), id)
        XCTAssertEqual(
            AgentResumeStore.claudeResumeTarget(argv: "claude --model opus --resume \(id) --verbose"), id)
    }

    /// A bare `--resume` opens a picker; whatever follows is not an id.
    func testNoIdMeansNoTarget() {
        XCTAssertNil(AgentResumeStore.claudeResumeTarget(argv: "claude --resume"))
        XCTAssertNil(AgentResumeStore.claudeResumeTarget(argv: "claude --resume --verbose"))
        XCTAssertNil(AgentResumeStore.claudeResumeTarget(argv: "claude"))
        XCTAssertNil(AgentResumeStore.claudeResumeTarget(argv: nil))
    }

    /// Claude Code's per-process file, `~/.claude/sessions/<pid>.json`, is the
    /// exact answer for a live agent. A file whose pid doesn't match is a
    /// stale one for a reused pid and must not be believed.
    func testTheLiveProcessFileNamesTheConversation() {
        let file = Data(#"{"pid":62426,"sessionId":"9274E8D8-FBDF-4255-ACF3-81C3E08791EE","cwd":"/x","kind":"interactive"}"#.utf8)
        XCTAssertEqual(AgentResumeStore.claudeConversationID(sessionFile: file, pid: 62426),
                       "9274e8d8-fbdf-4255-acf3-81c3e08791ee")
        XCTAssertNil(AgentResumeStore.claudeConversationID(sessionFile: file, pid: 99999))
        XCTAssertNil(AgentResumeStore.claudeConversationID(
            sessionFile: Data(#"{"pid":1,"sessionId":"not-an-id"}"#.utf8), pid: 1))
        XCTAssertNil(AgentResumeStore.claudeConversationID(sessionFile: Data("junk".utf8), pid: 1))
    }

    func testContinueIsRecognised() {
        XCTAssertTrue(AgentResumeStore.claudeContinuesLatest(argv: "claude --continue"))
        XCTAssertTrue(AgentResumeStore.claudeContinuesLatest(argv: "claude -c"))
        XCTAssertFalse(AgentResumeStore.claudeContinuesLatest(argv: "claude --resume \(id)"))
    }
}
