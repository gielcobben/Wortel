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
        XCTAssertEqual(AgentResumeStore.claudeProjectName(for: "/Users/giel/Developer/wortel"),
                       "-Users-giel-Developer-wortel")
        XCTAssertEqual(AgentResumeStore.claudeProjectName(for: "/a/é😀"), "-a----")
        XCTAssertEqual(AgentResumeStore.physicalPath("/tmp"), "/private/tmp")
        XCTAssertEqual(AgentConversation.resolved("/tmp"), "/private/tmp")
        XCTAssertEqual(AgentResumeStore.physicalPath("/no/such/place"), "/no/such/place")
    }

    // MARK: - Moving (`wortel cd`)

    /// After the `cd`, a relative path names somewhere else or nothing, so
    /// every one the resume carries is made absolute where the agent started.
    func testRelativePathsBecomeAbsolute() {
        XCTAssertEqual(
            AgentCommandLine.absolutized(agent: "claude", argv: "claude --add-dir ../shared --model opus",
                                         from: "/Users/x/app"),
            "claude --add-dir /Users/x/shared --model opus")
        XCTAssertEqual(
            AgentCommandLine.absolutized(agent: "claude", argv: "claude --settings=./s.json --plugin-dir p",
                                         from: "/Users/x/app"),
            "claude --settings=/Users/x/app/s.json --plugin-dir /Users/x/app/p")
        XCTAssertEqual(
            AgentCommandLine.absolutized(agent: "claude", argv: "claude --add-dir /abs --add-dir ~/home",
                                         from: "/Users/x/app"),
            "claude --add-dir /abs --add-dir ~/home", "already absolute, or the shell's to expand")
    }

    /// The launcher too: a relative path to the agent, and an assignment
    /// whose value is a relative path. Other assignments are left alone.
    func testARelativeLauncherBecomesAbsolute() {
        XCTAssertEqual(
            AgentCommandLine.absolutized(agent: "claude", argv: "CLAUDE_CONFIG_DIR=./cfg DEBUG=1 ./bin/claude",
                                         from: "/Users/x/app"),
            "CLAUDE_CONFIG_DIR=/Users/x/app/cfg DEBUG=1 /Users/x/app/bin/claude")
    }

    /// Only what's carried can change: a prompt that looks like a path, or a
    /// flag that isn't a path, stays as typed (and isn't carried anyway).
    func testOtherWordsAreLeftAlone() {
        XCTAssertEqual(
            AgentCommandLine.absolutized(agent: "claude", argv: "claude --model opus fix ./src", from: "/a"),
            "claude --model opus fix ./src")
    }

    /// The resume typed for a move: the transcript's path, the carried flags,
    /// and never Codex's `--cd`, which would send it back.
    func testTheMoveResume() {
        let words = AgentConversation.moveWords(agent: "claude", id: id, transcript: "/Users/x/.claude/projects/-a/\(id).jsonl")!
        XCTAssertEqual(
            AgentCommandLine.command(agent: "claude", argv: "claude --model opus", resume: words),
            "claude --resume /Users/x/.claude/projects/-a/\(id).jsonl --model opus")
        XCTAssertEqual(
            AgentCommandLine.command(agent: "codex", argv: "codex -C /a -m o3", resume: ["resume", id],
                                     excluding: ["--cd", "-C"]),
            "codex resume -m o3 \(id)")
    }
}
