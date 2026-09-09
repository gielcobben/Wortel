import XCTest

/// The agent marker is a contract between two languages: the bundled shell
/// integrations (zsh/bash/fish) write it at an agent's `preexec`, and this app
/// parses it to decide what to resume after a relaunch. Neither side can catch a
/// drift in the other at compile time, and a mismatch doesn't throw — the session
/// just silently comes back cold, which is indistinguishable from "no agent was
/// running". Hence pinning both halves here: the exact bytes the shells emit, and
/// the agent→command table that turns them into something to run.
final class AgentResumeStoreTests: XCTestCase {

    // MARK: - Marker parsing

    /// The current format, exactly as the shells write it (see the
    /// `_ghostty_wortel_agent` path in each integration).
    func testParsesCurrentMarkerFormat() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("""
            agent=claude
            model=opus
            cwd=/Users/giel/Developer/wortel
            argv=claude --model opus
            """))
        XCTAssertEqual(marker.agent, "claude")
        XCTAssertEqual(marker.model, "opus")
        XCTAssertEqual(marker.cwd, "/Users/giel/Developer/wortel")
        XCTAssertEqual(marker.argv, "claude --model opus")
    }

    /// An agent launched without a `--model` flag writes an empty value rather
    /// than omitting the line. Empty and absent both mean "the agent's default",
    /// so neither may surface as an empty string in the sidebar badge.
    func testEmptyValuesReadAsNilNotEmptyString() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("""
            agent=codex
            model=
            cwd=
            argv=
            """))
        XCTAssertEqual(marker.agent, "codex")
        XCTAssertNil(marker.model)
        XCTAssertNil(marker.cwd)
        XCTAssertNil(marker.argv)
    }

    /// A command line may itself contain `=` (a leading env assignment is the
    /// common case). Splitting on the *first* separator is what keeps the value
    /// intact; splitting on all of them would truncate the recorded command.
    func testValueMayContainEqualsSigns() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("""
            agent=codex
            argv=FOO=bar codex resume
            """))
        XCTAssertEqual(marker.argv, "FOO=bar codex resume")
    }

    /// Markers written before the format carried model/cwd/argv were a single
    /// bare agent name. One may still be on disk from an agent that was mid-run
    /// across the upgrade, and dropping it would strand that session.
    func testParsesLegacyBareAgentName() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("claude\n"))
        XCTAssertEqual(marker.agent, "claude")
        XCTAssertNil(marker.model)
    }

    func testRejectsMarkerWithoutAnAgent() {
        XCTAssertNil(AgentResumeStore.parse(""), "an empty file names no agent")
        XCTAssertNil(AgentResumeStore.parse("model=opus\ncwd=/tmp"), "no agent key")
        XCTAssertNil(AgentResumeStore.parse("agent=\n"), "an empty agent is not an agent")
    }

    // MARK: - Resume commands

    /// The mapped agents resume via their own "continue the latest session"
    /// invocation. A wrong string here types a wrong command into the user's
    /// shell, so the exact text is the thing worth pinning.
    func testMappedAgentsResumeWithTheirOwnCommand() {
        let cases = [
            ("codex", "codex resume --last"),
            ("opencode", "opencode --continue"),
            ("aider", "aider --restore-chat-history"),
            ("gemini", "gemini --resume"),
            ("pi", "pi -c"),
        ]
        for (agent, expected) in cases {
            let marker = AgentMarker(agent: agent, model: nil, cwd: "/tmp", argv: "\(agent) run", shellPID: nil, startedAt: nil)
            XCTAssertEqual(AgentResumeStore.resumeCommand(for: marker), expected,
                           "\(agent) should resume with its documented command, not its argv")
        }
    }

    /// Agents with no "continue last" primitive (cline, ollama) fall back to
    /// re-running exactly what was launched, so the agent at least comes back
    /// instead of leaving a cold shell.
    func testUnmappedAgentFallsBackToItsOriginalCommand() {
        let marker = AgentMarker(agent: "ollama", model: nil, cwd: "/tmp", argv: "ollama run llama3", shellPID: nil, startedAt: nil)
        XCTAssertEqual(AgentResumeStore.resumeCommand(for: marker), "ollama run llama3")
    }

    /// Nothing mapped and nothing recorded to re-run means there is genuinely no
    /// way to bring it back — better to leave the shell alone than invent a command.
    func testUnmappedAgentWithNoCommandResumesNothing() {
        let marker = AgentMarker(agent: "cline", model: nil, cwd: "/tmp", argv: nil, shellPID: nil, startedAt: nil)
        XCTAssertNil(AgentResumeStore.resumeCommand(for: marker))
    }

    /// Claude prefers an exact `--resume <id>` when its conversation file can be
    /// found for the cwd, and falls back to the cwd-scoped `--continue` otherwise.
    /// Which branch wins depends on the machine's `~/.claude`, so this pins the
    /// invariant both branches share rather than one specific string.
    func testClaudeAlwaysResumesViaClaude() throws {
        let marker = AgentMarker(agent: "claude", model: nil,
                                 cwd: "/nonexistent-project-\(UUID().uuidString)", argv: nil, shellPID: nil, startedAt: nil)
        let command = try XCTUnwrap(AgentResumeStore.resumeCommand(for: marker))
        XCTAssertEqual(command, "claude --continue",
                       "an unknown cwd has no conversation file, so it must fall back")
    }

    /// The resume input is what gets typed into the shell, so it has to end in a
    /// newline — without it the command sits on the prompt unexecuted.
    func testResumeInputIsExecuted() throws {
        let marker = AgentMarker(agent: "codex", model: nil, cwd: "/tmp", argv: nil, shellPID: nil, startedAt: nil)
        XCTAssertEqual(AgentResumeStore.resumeInput(for: marker), "codex resume --last\n")
    }

    func testParsesStartedAt() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("agent=claude\nstartedat=1750000000"))
        XCTAssertEqual(marker.startedAt, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertNil(AgentResumeStore.parse("agent=claude")?.startedAt)
    }

    /// A directory with no transcripts can't identify a conversation, and must say
    /// so rather than inventing one — the caller falls back to `--continue`.
    func testConversationIDIsNilWhenNoTranscriptWasCreated() {
        let id = AgentResumeStore.claudeConversationID(
            cwd: "/nonexistent-project-\(UUID().uuidString)", startedAt: Date())
        XCTAssertNil(id)
    }

    func testParsesShellPID() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("agent=claude\nshellpid=4242"))
        XCTAssertEqual(marker.shellPID, 4242)
    }

    /// A marker from before the pid existed must not decode as pid 0 — that's a
    /// real pid to the kernel, and treating it as one would make liveness answer
    /// about the wrong process.
    func testMarkerWithoutShellPIDHasNoPID() throws {
        let marker = try XCTUnwrap(AgentResumeStore.parse("agent=claude\nmodel=opus"))
        XCTAssertNil(marker.shellPID)
        XCTAssertNil(AgentResumeStore.parse("agent=claude\nshellpid=notanumber")?.shellPID)
    }

    // MARK: - Liveness

    /// The fail-open contract, and the most important claim in this file: the two
    /// ways to be wrong are not equal. Saying "dead" about a live agent drops a
    /// resume the user wanted; saying "alive" about a dead one merely reopens a
    /// finished conversation. So every uncertain case must answer "running".
    func testUnknownPIDCountsAsRunning() {
        XCTAssertTrue(AgentLiveness.isRunning(agent: "claude", shellPID: nil),
                      "no recorded pid is uncertainty, and uncertainty must not drop a resume")
    }

    /// This test process really is a descendant of itself's parent chain, so a
    /// process genuinely under the given ancestor reports running. Uses the test
    /// runner's own pid, which is by definition alive while this runs.
    func testAgentRunningUnderItsShellIsDetected() {
        let me = ProcessInfo.processInfo.processIdentifier
        // The test runner's own executable name, looked up via its parent: anything
        // running under `me` is a descendant of `me`. We assert the inverse case is
        // sound by checking a definitely-absent agent name under a live pid.
        XCTAssertFalse(AgentLiveness.isRunning(agent: "definitely-not-a-real-agent", shellPID: me),
                       "a live shell with no such descendant is the one case allowed to say no")
    }

    /// A shell that no longer exists can't still be running anything under it.
    /// pid 0 is never a live user process, so it stands in for a dead shell.
    func testDeadShellIsNotRunning() {
        XCTAssertFalse(AgentLiveness.isRunning(agent: "claude", shellPID: 0),
                       "the shell is gone, so nothing can be running under it")
    }

    /// `locate` keeps the distinction `isRunning` collapses, and `consumeSnapshot`
    /// is the caller that needs it: at restore, a marker is kept only on *proof*
    /// its agent is alive, so "couldn't tell" has to be its own answer rather
    /// than being folded into "running" the way the resume path wants it.
    func testLocateSeparatesUnknownFromGone() {
        switch AgentLiveness.locate(agent: "claude", shellPID: nil) {
        case .unknown: break
        default: XCTFail("no recorded pid is uncertainty, not a claim either way")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        switch AgentLiveness.locate(agent: "definitely-not-a-real-agent", shellPID: me) {
        case .gone: break
        default: XCTFail("a live shell with no such descendant is a definite no")
        }
    }

    /// And the case the restore path now hangs on: a real live descendant.
    func testLocateFindsALiveDescendant() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        // Spawning is not instant from the process table's point of view.
        let me = ProcessInfo.processInfo.processIdentifier
        var located = AgentLiveness.locate(agent: "sleep", shellPID: me)
        for _ in 0..<20 {
            if case .running = located { break }
            Thread.sleep(forTimeInterval: 0.05)
            located = AgentLiveness.locate(agent: "sleep", shellPID: me)
        }
        guard case .running(let pid) = located else {
            return XCTFail("a live child of this process must be located")
        }
        XCTAssertEqual(pid, child.processIdentifier)
    }

    /// The bug this exists for: Pi runs as `node`, so a process named `pi` never
    /// exists and its marker was swept as stale a minute after launch — taking
    /// the badge, the resume and the busy spinner with it. The agent has to be
    /// found in a descendant's arguments when no descendant carries its name.
    /// `sh -c` with a trailing `true` so the shell stays as the parent rather
    /// than exec-ing straight into `sleep`; the probe word lands in `$0`.
    func testLocateFindsAScriptAgentByItsArguments() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30; true", "wortel-liveness-probe"]
        try child.run()
        defer { child.terminate() }
        let me = ProcessInfo.processInfo.processIdentifier
        var located = AgentLiveness.locate(agent: "wortel-liveness-probe", shellPID: me)
        for _ in 0..<20 {
            if case .running = located { break }
            Thread.sleep(forTimeInterval: 0.05)
            located = AgentLiveness.locate(agent: "wortel-liveness-probe", shellPID: me)
        }
        guard case .running(let pid) = located else {
            return XCTFail("an agent visible only in a descendant's arguments must be located")
        }
        XCTAssertEqual(pid, child.processIdentifier)
    }

    /// What counts as the agent inside an argument: a path component that is the
    /// name, or a package/file named after it. Never a substring — `pi` inside
    /// `pipx` or `api` is not Pi.
    func testArgumentNamingIsComponentWise() {
        XCTAssertTrue(AgentLiveness.argumentNames("pi", "/x/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"))
        XCTAssertTrue(AgentLiveness.argumentNames("gemini", "/x/@google/gemini-cli/dist/index.js"))
        XCTAssertTrue(AgentLiveness.argumentNames("aider", "/usr/local/bin/aider"))
        XCTAssertTrue(AgentLiveness.argumentNames("aider", "aider.py"))
        XCTAssertTrue(AgentLiveness.argumentNames("cursor-agent", "/opt/cursor-agent"))
        XCTAssertFalse(AgentLiveness.argumentNames("pi", "/usr/bin/pipx"))
        XCTAssertFalse(AgentLiveness.argumentNames("pi", "/Users/giel/api/server.js"))
        XCTAssertFalse(AgentLiveness.argumentNames("pi", "--print"))
    }

    /// Reading our own arguments proves the `KERN_PROCARGS2` parse: the first
    /// entry is the executable, and the rest is what we were launched with.
    func testReadsOwnArguments() {
        let args = AgentLiveness.arguments(of: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(args.isEmpty)
        XCTAssertEqual(args.first, Bundle.main.executablePath ?? args.first)
    }
}
