import XCTest

/// The end of a Claude Code transcript, as it is read for the words a finished
/// turn is announced with. What Claude last said is pinned in
/// `AgentAnswerTests`; this is the read itself.
final class ClaudeTranscriptTailTests: XCTestCase {
    private let since = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!

    private func assistant(_ text: String, at time: String = "2026-10-14T12:01:00.000Z") -> String {
        let object: [String: Any] = [
            "type": "assistant", "timestamp": time,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A transcript runs to tens of megabytes. Only its end is read, and the
    /// last answer is still found there, though the read starts mid-line.
    func testReadTailReturnsOnlyTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "a", count: ClaudeTranscriptTail.tailBytes) + "\n"
        try (filler + assistant("The tests pass.")).write(to: url, atomically: true, encoding: .utf8)
        let tail = try XCTUnwrap(ClaudeTranscriptTail.readTail(of: url))
        XCTAssertEqual(tail.count, ClaudeTranscriptTail.tailBytes)
        XCTAssertEqual(ClaudeTranscriptTail.lastAnswer(tail, since: since), "The tests pass.")
    }

    func testAMissingTranscriptIsNoTail() {
        XCTAssertNil(ClaudeTranscriptTail.readTail(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")))
    }
}
