import XCTest

/// What a resume carries over from the line that started the agent. A slip
/// here is silent: a resumed agent that asks for permission at every step, on
/// another model, or a flag's value typed in as a prompt.
final class AgentCommandLineTests: XCTestCase {
    private let id = "80297191-7afb-4301-8566-909b3e04fdfc"

    private func resume(_ agent: String, _ argv: String?, id: String? = nil) -> String? {
        AgentResumeStore.resumeCommand(
            for: AgentMarker(agent: agent, model: nil, cwd: nil, argv: argv, shellPID: nil, startedAt: nil),
            knownConversationID: id)
    }

    func testPermissionModeAndModelComeBack() {
        XCTAssertEqual(
            resume("claude", "claude --dangerously-skip-permissions --model opus fix the build", id: id),
            "claude --resume \(id) --dangerously-skip-permissions --model opus")
        XCTAssertEqual(
            resume("claude", "claude --permission-mode=plan --resume 11111111-1111-1111-1111-111111111111", id: id),
            "claude --resume \(id) --permission-mode=plan")
    }

    func testTheConversationFlagsAndPromptsAreNotCarried() {
        XCTAssertEqual(resume("claude", "claude -c -p hello", id: id), "claude --resume \(id)")
        XCTAssertEqual(resume("pi", "pi --session abc --model sonnet", id: "def"),
                       "pi --session def --model sonnet")
    }

    func testAValueTheShellWouldHaveToReadIsDropped() {
        XCTAssertEqual(resume("claude", "claude --model \"$MODEL\" --dangerously-skip-permissions", id: id),
                       "claude --resume \(id) --dangerously-skip-permissions")
        // A flag followed by another flag has no value to carry.
        XCTAssertEqual(resume("claude", "claude --model --verbose", id: id), "claude --resume \(id) --verbose")
    }

    func testTheLauncherComesBack() {
        XCTAssertEqual(resume("claude", "CLAUDE_CONFIG_DIR=/Users/me/.work claude", id: id),
                       "CLAUDE_CONFIG_DIR=/Users/me/.work claude --resume \(id)")
        XCTAssertEqual(resume("pi", "devx pi --model x", id: "abc"), "devx pi --session abc --model x")
        XCTAssertEqual(resume("claude", "/opt/bin/claude", id: id), "/opt/bin/claude --resume \(id)")
        // `exec` would replace the shell the resume is typed into.
        XCTAssertEqual(resume("claude", "exec claude", id: id), "claude --resume \(id)")
        // Not named by a word of its own, or something in front needs a shell.
        XCTAssertEqual(resume("claude", "npx @anthropic-ai/claude-code", id: id), "claude --resume \(id)")
        XCTAssertEqual(resume("claude", "FOO=\"a b\" claude", id: id), "claude --resume \(id)")
    }

    /// The marker records the line from the agent to its end; what follows
    /// a separator belongs to another command.
    func testOnlyTheAgentsOwnCommandCounts() {
        XCTAssertEqual(resume("claude", "claude; codex --model gpt-5", id: id), "claude --resume \(id)")
        XCTAssertEqual(resume("claude", "claude --model opus && say done", id: id),
                       "claude --resume \(id) --model opus")
        XCTAssertEqual(AgentCommandLine.words("claude --verbose; ls"), ["claude", "--verbose"])
        XCTAssertNil(AgentResumeStore.claudeResumeTarget(argv: "claude | claude --resume \(id)"))
    }

    func testCodexTakesItsOptionsAfterResume() {
        XCTAssertEqual(resume("codex", "codex --full-auto -m o3", id: "abc"), "codex resume --full-auto -m o3 abc")
        XCTAssertEqual(resume("codex", "codex -m o3", id: nil), "codex resume -m o3 --last")
    }

    func testAnIdThatCantBeTypedIsNotUsed() {
        XCTAssertEqual(resume("pi", "pi", id: "abc; rm -rf ~"), "pi -c")
        XCTAssertEqual(resume("pi", "pi", id: "--evil"), "pi -c")
    }

    /// Re-run as typed only when it is one simple command; otherwise typed
    /// and left at the prompt, so `; rm -rf build` doesn't run again.
    func testACompoundLineIsNotRunAgain() {
        func input(_ argv: String) -> String? {
            AgentResumeStore.resumeInput(for: AgentMarker(agent: "ollama", model: nil, cwd: nil,
                                                          argv: argv, shellPID: nil, startedAt: nil))
        }
        XCTAssertEqual(input("ollama run llama3"), "ollama run llama3\n")
        XCTAssertEqual(input("ollama run x; rm -rf build"), "ollama run x; rm -rf build")
        XCTAssertEqual(input("ollama run x && git push -f"), "ollama run x && git push -f")
    }

    func testClaudeNamesItsConversationOnTheCommandLine() {
        XCTAssertEqual(AgentResumeStore.claudeResumeTarget(argv: "claude --session-id \(id)"), id)
        XCTAssertNil(AgentResumeStore.claudeResumeTarget(argv: "claude --resume \(id) --fork-session"))
    }

    /// Claude's folder for a project is the physical path, escaped per UTF-16
    /// unit. A wrong folder drops an exact conversation id as "not found".
    func testClaudeProjectFolderName() {
        XCTAssertEqual(AgentResumeStore.claudeProjectName(for: "/Users/me/Developer/wortel"),
                       "-Users-me-Developer-wortel")
        XCTAssertEqual(AgentResumeStore.claudeProjectName(for: "/a/é😀"), "-a----")
        XCTAssertEqual(AgentResumeStore.physicalPath("/tmp"), "/private/tmp")
        XCTAssertEqual(AgentConversation.resolved("/tmp"), "/private/tmp")
        XCTAssertEqual(AgentResumeStore.physicalPath("/no/such/place"), "/no/such/place")
    }

    /// The resume, then the carried flags; Codex's go between its `resume`
    /// and the conversation.
    func testTheResumeCommand() {
        XCTAssertEqual(
            AgentCommandLine.command(agent: "claude", argv: "claude --model opus",
                                     resume: ["--resume", "/Users/x/.claude/projects/-a/\(id).jsonl"]),
            "claude --resume /Users/x/.claude/projects/-a/\(id).jsonl --model opus")
        XCTAssertEqual(
            AgentCommandLine.command(agent: "codex", argv: "codex -m o3", resume: ["resume", id]),
            "codex resume -m o3 \(id)")
    }
}
