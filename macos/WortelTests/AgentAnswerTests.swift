import XCTest

/// What a turn-end notification says: the start of the agent's last answer.
/// Every failure here is a banner, not an error: `## Summary` or a code fence
/// where a sentence should be, an answer from the turn before, or the agent's
/// "let me run the tests" announced as if it were the result.
final class AgentAnswerTests: XCTestCase {
    private func summary(_ markdown: String) -> String? { AgentAnswer.summary(ofMarkdown: markdown) }

    // MARK: - Markdown to a sentence

    func testPlainProseIsKeptAndItsLinesJoined() {
        XCTAssertEqual(summary("Fixed the flaky test.\nIt was a race in the watcher."),
                       "Fixed the flaky test. It was a race in the watcher.")
    }

    func testOnlyTheFirstParagraphIsUsed() {
        XCTAssertEqual(summary("Done, all green.\n\nHere is what changed in detail."), "Done, all green.")
    }

    func testInlineMarkdownIsUnwrapped() {
        XCTAssertEqual(
            summary("**Fixed** the _flaky_ test in [`Watcher.swift`](src/Watcher.swift), see ![shot](a.png) and <https://x.dev>. ~~Old~~ *new*."),
            "Fixed the flaky test in Watcher.swift, see shot and https://x.dev. Old new.")
    }

    /// Underscores inside words and stars inside code spans are not emphasis.
    func testSnakeCaseAndCodeSpansSurvive() {
        XCTAssertEqual(summary("Renamed `a*b*c` to snake_case_name, 2*3*4 stays."),
                       "Renamed a*b*c to snake_case_name, 2*3*4 stays.")
    }

    func testHeadingsAreSkippedForTheProseUnderThem() {
        XCTAssertEqual(summary("## Summary\n\nThe build works again."), "The build works again.")
        XCTAssertEqual(summary("# Summary\nThe build works again."), "The build works again.")
    }

    func testAHeadingAloneIsUsedWhenThereIsNothingElse() {
        XCTAssertEqual(summary("# Plan: away detection\n\n```swift\nlet x = 1\n```"), "Plan: away detection")
    }

    func testListItemsLoseTheirMarkersAndBecomeSentences() {
        XCTAssertEqual(summary("- Fixed the test\n- Added a [x] checkbox!\n1. Bumped the version"),
                       "Fixed the test. Added a [x] checkbox! Bumped the version.")
        XCTAssertEqual(summary("- [x] Ship it"), "Ship it.")
    }

    func testQuotesTablesAndRulesAreNotProse() {
        XCTAssertEqual(summary("| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\n> Quoted reply"), "Quoted reply")
    }

    func testCodeBlocksAreSkipped() {
        XCTAssertEqual(summary("```diff\n- old\n+ new\n```\n\nApplied the patch."), "Applied the patch.")
        XCTAssertEqual(summary("~~~\nraw\n~~~\nAfter."), "After.")
        XCTAssertEqual(summary("    indented code\n\nThe prose."), "The prose.")
    }

    /// Nothing to quote: the caller keeps its fixed text.
    func testACodeOnlyAnswerHasNoSummary() {
        XCTAssertNil(summary("```swift\nprint(\"hi\")\n```"))
        XCTAssertNil(summary("{\n  \"ok\": true,\n  \"count\": 3\n}"))
        XCTAssertNil(summary("[1, 2, 3]"))
        XCTAssertNil(summary("   \n\n"))
        XCTAssertNil(summary("| a | b |\n|---|---|"))
    }

    func testALinkAtTheStartIsNotTakenForJSON() {
        XCTAssertEqual(summary("[The docs](https://x.dev) say otherwise."), "The docs say otherwise.")
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(summary("Lots   of\tspace  here."), "Lots of space here.")
    }

    // MARK: - Length

    func testALongAnswerIsCutAtAWordWithAnEllipsis() throws {
        let long = String(repeating: "word ", count: 80) + "end."
        let cut = try XCTUnwrap(summary(long))
        XCTAssertLessThanOrEqual(cut.count, AgentAnswer.limit)
        XCTAssertTrue(cut.hasSuffix("word\u{2026}"), cut)
    }

    func testTheCutDropsTrailingPunctuation() {
        XCTAssertEqual(AgentAnswer.truncate("one two, three four five six", to: 12), "one two\u{2026}")
    }

    func testAShortAnswerIsLeftAlone() {
        XCTAssertEqual(AgentAnswer.truncate("short", to: 10), "short")
    }

    /// A string with no space in reach is cut where it is, not back to nothing.
    func testAnUnbrokenStringIsCutMidWord() {
        let cut = AgentAnswer.truncate("see " + String(repeating: "x", count: 300), to: 20)
        XCTAssertEqual(cut.count, 20)
        XCTAssertTrue(cut.hasSuffix("x\u{2026}"))
    }

    // MARK: - Claude

    private let since = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func claude(_ blocks: [[String: Any]], at time: String = "2026-10-14T12:01:00.000Z",
                        sidechain: Bool = false) -> String {
        line(["type": "assistant", "timestamp": time, "isSidechain": sidechain,
              "message": ["role": "assistant", "content": blocks]])
    }

    private func claudeUser(_ content: Any, at time: String = "2026-10-14T12:00:30.000Z") -> String {
        line(["type": "user", "timestamp": time, "message": ["role": "user", "content": content]])
    }

    private func lastAnswer(_ lines: [String]) -> String? {
        ClaudeTranscriptTail.lastAnswer(Data(lines.joined(separator: "\n").utf8), since: since)
    }

    func testClaudesFinalTextIsTheAnswer() {
        XCTAssertEqual(lastAnswer([
            claudeUser("fix it"),
            claude([["type": "text", "text": "Let me look."]]),
            claude([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]),
            claudeUser([["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]),
            claude([["type": "thinking", "thinking": "…"]]),
            claude([["type": "text", "text": "## Done\n\nThe **watcher** no longer races."]]),
            line(["type": "system", "timestamp": "2026-10-14T12:02:00.000Z"]),
        ]), "The watcher no longer races.")
    }

    /// Thinking written after the text (or alone) points back to the text.
    func testAThinkingOnlyEntryLooksFurtherBack() {
        XCTAssertEqual(lastAnswer([
            claude([["type": "text", "text": "All set."]]),
            claude([["type": "thinking", "thinking": "…"]]),
        ]), "All set.")
    }

    func testClaudesPendingQuestionIsTheQuestion() {
        let ask: [String: Any] = [
            "type": "tool_use", "id": "t2", "name": "AskUserQuestion",
            "input": ["questions": [
                ["question": "Should I also update the **docs**?", "header": "Docs", "options": []],
                ["question": "And the changelog?", "header": "Log", "options": []],
            ]],
        ]
        XCTAssertEqual(lastAnswer([
            claude([["type": "text", "text": "Before I go on:"]]),
            claude([ask]),
        ]), "Should I also update the docs?")
    }

    func testClaudesPlanIsItsFirstParagraph() {
        let plan: [String: Any] = [
            "type": "tool_use", "id": "t3", "name": "ExitPlanMode",
            "input": ["plan": "# Plan\n\nAdd an idle check before raising attention."],
        ]
        XCTAssertEqual(lastAnswer([claude([plan])]), "Add an idle check before raising attention.")
    }

    /// A Bash call waiting on permission: its "let me run" is no answer.
    func testAToolWaitingOnPermissionHasNoAnswer() {
        XCTAssertNil(lastAnswer([
            claude([["type": "text", "text": "I'll run the tests."]]),
            claude([["type": "tool_use", "id": "t4", "name": "Bash", "input": ["command": "make test"]]]),
        ]))
    }

    func testAPromptWithNoReplyHasNoAnswer() {
        XCTAssertNil(lastAnswer([
            claude([["type": "text", "text": "Old answer."]]),
            claudeUser("and now this?", at: "2026-10-14T12:05:00.000Z"),
        ]))
    }

    func testAnAnswerFromBeforeTheTurnIsNotThisTurns() {
        XCTAssertNil(lastAnswer([claude([["type": "text", "text": "Yesterday's."]], at: "2026-10-14T11:00:00.000Z")]))
    }

    func testSidechainsAreNotTheAnswer() {
        XCTAssertEqual(lastAnswer([
            claude([["type": "text", "text": "The real answer."]]),
            claude([["type": "text", "text": "Subagent chatter."]], sidechain: true),
        ]), "The real answer.")
    }

    func testAnApiErrorIsLeftToTheVerdict() {
        let error = line(["type": "assistant", "timestamp": "2026-10-14T12:01:00.000Z", "isApiErrorMessage": true,
                          "message": ["role": "assistant", "content": [["type": "text", "text": "API Error: boom"]]]])
        XCTAssertNil(lastAnswer([error]))
    }

    func testAClaudeAnswerThatIsOnlyCodeHasNone() {
        XCTAssertNil(lastAnswer([claude([["type": "text", "text": "```json\n{\"a\": 1}\n```"]])]))
    }

    // MARK: - Codex

    private func codex(_ type: String, _ payload: [String: Any], at time: String = "2026-10-14T12:01:00.000Z") -> String {
        line(["timestamp": time, "type": type, "payload": payload])
    }

    private func codexAnswer(_ lines: [String]) -> String? {
        AgentAnswer.codex(Data(lines.joined(separator: "\n").utf8), since: since)
    }

    func testCodexTaskCompleteCarriesTheAnswer() {
        XCTAssertEqual(codexAnswer([
            codex("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "go"]]],
                  at: "2026-10-14T12:00:10.000Z"),
            codex("response_item", ["type": "message", "role": "assistant", "phase": "commentary",
                                    "content": [["type": "output_text", "text": "Looking."]]]),
            codex("response_item", ["type": "message", "role": "assistant",
                                    "content": [["type": "output_text", "text": "Saved it [here](/tmp/x.png).\n\n![img](/tmp/x.png)"]]]),
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Saved it [here](/tmp/x.png).\n\n![img](/tmp/x.png)"]),
            codex("event_msg", ["type": "token_count", "info": [:] as [String: Any]]),
        ]), "Saved it here.")
    }

    func testCodexWithoutTaskCompleteUsesTheLastAssistantMessage() {
        XCTAssertEqual(codexAnswer([
            codex("response_item", ["type": "message", "role": "assistant",
                                    "content": [["type": "output_text", "text": "Done."]]]),
        ]), "Done.")
    }

    func testAnInterruptedCodexTurnHasNoAnswer() {
        XCTAssertNil(codexAnswer([
            codex("response_item", ["type": "message", "role": "assistant",
                                    "content": [["type": "output_text", "text": "Working on it."]]]),
            codex("event_msg", ["type": "turn_aborted", "reason": "interrupted"]),
        ]))
    }

    func testAnOldCodexAnswerIsNotThisTurns() {
        XCTAssertNil(codexAnswer([
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Old."], at: "2026-10-14T10:00:00.000Z"),
        ]))
    }

    // MARK: - Codex: was there a turn at all

    private func codexTookTurn(_ lines: [String]) -> Bool {
        AgentConversation.Codex.tookTurn(Data(lines.joined(separator: "\n").utf8), since: since)
    }

    /// A title spinner or a moving screen on a session idle since its last
    /// answer: the rollout's newest line is that answer, before the busy
    /// began. Seen as "Finished, your move" on every Codex session at once.
    func testAnIdleCodexTookNoTurn() {
        XCTAssertFalse(codexTookTurn([
            codex("event_msg", ["type": "task_started"], at: "2026-10-14T09:59:00.000Z"),
            codex("response_item", ["type": "message", "role": "assistant",
                                    "content": [["type": "output_text", "text": "Done."]]],
                  at: "2026-10-14T09:59:30.000Z"),
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Done."],
                  at: "2026-10-14T09:59:30.100Z"),
        ]))
    }

    /// Lines that belong to no turn are written to a rollout too (a real one
    /// got `thread_settings_applied` months after its last turn), and a resume
    /// starting its MCP servers spins the title meanwhile.
    func testCodexBookkeepingAfterTheBusyBeganIsNoTurn() {
        XCTAssertFalse(codexTookTurn([
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Done."],
                  at: "2026-10-14T09:59:30.000Z"),
            codex("event_msg", ["type": "thread_settings_applied"]),
            codex("session_meta", ["id": "x", "cwd": "/tmp"]),
        ]))
    }

    func testACodexTurnIsSeenFromItsStart() {
        XCTAssertTrue(codexTookTurn([
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Old."],
                  at: "2026-10-14T09:59:30.000Z"),
            codex("event_msg", ["type": "task_started"], at: "2026-10-14T12:00:01.000Z"),
        ]))
    }

    /// A turn still waiting on an approval has written its steps, and an
    /// interrupted one its abort: both happened.
    func testACodexTurnMidwayOrAbortedIsATurn() {
        XCTAssertTrue(codexTookTurn([
            codex("response_item", ["type": "function_call", "name": "shell"]),
        ]))
        XCTAssertTrue(codexTookTurn([
            codex("event_msg", ["type": "turn_aborted", "reason": "interrupted"]),
        ]))
    }

    func testAnEmptyCodexTailTookNoTurn() {
        XCTAssertFalse(codexTookTurn([]))
        XCTAssertFalse(codexTookTurn(["{\"cut mid-line"]))
    }

    // MARK: - Pi

    private func pi(_ role: String, _ content: [[String: Any]], stop: String? = nil,
                    at time: String = "2026-10-14T12:01:00.000Z") -> String {
        var message: [String: Any] = ["role": role, "content": content]
        if let stop { message["stopReason"] = stop }
        return line(["type": "message", "id": "a1", "timestamp": time, "message": message])
    }

    private func piAnswer(_ lines: [String]) -> String? {
        AgentAnswer.pi(Data(lines.joined(separator: "\n").utf8), since: since)
    }

    func testPisLastTextIsTheAnswer() {
        XCTAssertEqual(piAnswer([
            line(["type": "session", "version": 3, "id": "x", "timestamp": "2026-10-14T11:00:00.000Z"]),
            pi("user", [["type": "text", "text": "hi"]], at: "2026-10-14T12:00:30.000Z"),
            pi("assistant", [["type": "thinking", "thinking": "…"], ["type": "text", "text": "Hello, *what* next?"]], stop: "stop"),
        ]), "Hello, what next?")
    }

    func testAPiToolCallOrErrorHasNoAnswer() {
        XCTAssertNil(piAnswer([pi("assistant", [["type": "toolCall", "name": "bash"]], stop: "toolUse")]))
        XCTAssertNil(piAnswer([pi("assistant", [], stop: "error")]))
        XCTAssertNil(piAnswer([
            pi("assistant", [["type": "text", "text": "Done."]], stop: "stop"),
            pi("toolResult", [["type": "text", "text": "out"]]),
        ]))
    }

    /// When the turn last wrote is its `task_complete`, not the bookkeeping
    /// after it: that is the moment the answer on screen was final, which is
    /// what decides whether someone already read it.
    func testACodexTurnLastWroteAtItsCompletion() {
        let lines = [
            codex("event_msg", ["type": "task_started"], at: "2026-10-14T12:01:00.000Z"),
            codex("response_item", ["type": "message", "role": "assistant",
                                    "content": [["type": "output_text", "text": "Done."]]],
                  at: "2026-10-14T12:01:20.000Z"),
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Done."],
                  at: "2026-10-14T12:01:20.500Z"),
            codex("event_msg", ["type": "token_count"], at: "2026-10-14T12:01:21.000Z"),
            codex("event_msg", ["type": "thread_settings_applied"], at: "2026-10-14T12:03:00.000Z"),
        ]
        XCTAssertEqual(
            AgentConversation.Codex.lastTurnWrite(Data(lines.joined(separator: "\n").utf8), since: since),
            AgentFiles.date("2026-10-14T12:01:20.500Z"))
    }
}
