import XCTest

/// What a quiet Claude turn is announced as. Lines are shaped like Claude Code
/// 2.1.299's transcripts (checked against real ones on 2026-10-14), trimmed to
/// the fields the verdict reads.
///
/// Every failure here is a wrong dot, not an error: an API error announced as
/// "Finished, your move", or a question Claude is waiting on announced as a
/// turn that's done.
final class ClaudeTranscriptTailTests: XCTestCase {
    private let since = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func assistant(_ blocks: [[String: Any]], at time: String = "2026-10-14T12:01:00.000Z",
                           apiError: Bool = false, sidechain: Bool = false) -> String {
        var entry: [String: Any] = [
            "type": "assistant", "timestamp": time, "isSidechain": sidechain,
            "message": ["role": "assistant", "content": blocks],
        ]
        if apiError { entry["isApiErrorMessage"] = true; entry["error"] = "server_error" }
        return line(entry)
    }

    private func user(_ content: Any, at time: String = "2026-10-14T12:02:00.000Z") -> String {
        line(["type": "user", "timestamp": time, "message": ["role": "user", "content": content]])
    }

    private func bookkeeping(_ type: String) -> String {
        line(["type": type, "timestamp": "2026-10-14T12:03:00.000Z"])
    }

    private func verdict(_ lines: [String]) -> ClaudeTranscriptTail.Verdict? {
        ClaudeTranscriptTail.verdict(Data(lines.joined(separator: "\n").utf8), since: since)
    }

    private let toolUse = { (name: String) -> [String: Any] in
        ["type": "tool_use", "id": "toolu_1", "name": name, "input": [:] as [String: Any]]
    }

    // MARK: - API errors

    func testApiErrorIsAFailureWithItsMessage() {
        let lines = [
            user("make it so", at: "2026-10-14T12:00:30.000Z"),
            assistant([["type": "thinking", "thinking": "…"]]),
            assistant([["type": "text", "text": "API Error: Your computer went to sleep mid-response. The response above may be incomplete."]], apiError: true),
            bookkeeping("system"),
            bookkeeping("last-prompt"),
        ]
        XCTAssertEqual(verdict(lines),
                       .apiError("Your computer went to sleep mid-response. The response above may be incomplete."))
    }

    /// Not every error says "API Error:" first.
    func testApiErrorWithoutPrefixKeepsItsText() {
        let lines = [assistant([["type": "text", "text": "Prompt is too long"]], apiError: true)]
        XCTAssertEqual(verdict(lines), .apiError("Prompt is too long"))
    }

    func testLongApiErrorIsShortened() {
        let long = String(repeating: "x", count: 500)
        guard case .apiError(let message)? = verdict([assistant([["type": "text", "text": long]], apiError: true)])
        else { return XCTFail("expected an API error") }
        XCTAssertEqual(message.count, ClaudeTranscriptTail.messageLimit)
        XCTAssertTrue(message.hasSuffix("\u{2026}"))
    }

    // MARK: - Waiting on the user

    func testPendingQuestionNeedsInput() {
        let lines = [
            assistant([["type": "text", "text": "Two options:"]]),
            assistant([toolUse("AskUserQuestion")]),
            bookkeeping("attachment"),
        ]
        XCTAssertEqual(verdict(lines), .question)
    }

    func testAnsweredQuestionIsNothing() {
        let lines = [
            assistant([toolUse("AskUserQuestion")]),
            user([["type": "tool_result", "tool_use_id": "toolu_1", "content": "Your questions have been answered"]]),
            assistant([["type": "text", "text": "Done."]], at: "2026-10-14T12:04:00.000Z"),
        ]
        XCTAssertNil(verdict(lines))
    }

    func testPendingPlanNeedsInput() {
        XCTAssertEqual(verdict([assistant([toolUse("ExitPlanMode")])]), .plan)
    }

    /// Any other tool call at the end is a turn still in flight, or one whose
    /// result simply hasn't been written; neither is a question.
    func testOtherToolUseIsNothing() {
        XCTAssertNil(verdict([assistant([toolUse("Bash")])]))
    }

    // MARK: - Ordinary ends and noise

    func testOrdinaryAnswerIsNothing() {
        XCTAssertNil(verdict([assistant([["type": "text", "text": "All done."]]), bookkeeping("system")]))
    }

    /// A subagent's traffic is not the turn on screen, even if it's last.
    func testSidechainIsSkipped() {
        let lines = [
            assistant([toolUse("AskUserQuestion")]),
            assistant([["type": "text", "text": "API Error: boom"]], apiError: true, sidechain: true),
        ]
        XCTAssertEqual(verdict(lines), .question)
    }

    /// An error from a turn the user already saw end says nothing about this one.
    func testEntryOlderThanTheTurnIsNothing() {
        let old = assistant([["type": "text", "text": "API Error: boom"]], at: "2026-10-14T11:00:00.000Z",
                            apiError: true)
        XCTAssertNil(verdict([old]))
    }

    /// A tail read starts mid-line; that fragment is skipped, not fatal.
    func testTruncatedFirstLineIsSkipped() {
        let fragment = "\"text\":\"half a line\"}]}}"
        XCTAssertEqual(verdict([fragment, assistant([toolUse("ExitPlanMode")])]), .plan)
    }

    func testEmptyTailIsNothing() {
        XCTAssertNil(ClaudeTranscriptTail.verdict(Data(), since: since))
    }

    // MARK: - Reading the tail

    func testReadTailReturnsOnlyTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "a", count: ClaudeTranscriptTail.tailBytes) + "\n"
        try (filler + assistant([toolUse("ExitPlanMode")])).write(to: url, atomically: true, encoding: .utf8)
        let tail = try XCTUnwrap(ClaudeTranscriptTail.readTail(of: url))
        XCTAssertEqual(tail.count, ClaudeTranscriptTail.tailBytes)
        XCTAssertEqual(ClaudeTranscriptTail.verdict(tail, since: since), .plan)
    }
}
