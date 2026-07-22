import Foundation

/// One agent CLI that was running in a session, as recorded by the shell
/// integration's marker file. Written at `preexec` (when the agent launches)
/// and removed at the next prompt (when it exits), so a marker on disk means
/// "this agent is running right now"; a marker that *outlives an app quit* means
/// "it was still running at quit" — which is when we resume it.
struct AgentMarker {
    /// The agent's command basename, e.g. `claude`, `codex`, `aider`.
    let agent: String
    /// The `--model`/`-m` value if the launch command carried one, for the
    /// sidebar badge. nil when the agent used its default model.
    let model: String?
    /// The directory the agent was launched in — used to resume the right
    /// project's conversation (and to locate agent-specific session files).
    let cwd: String?
    /// The exact command line, sanitized to one line. Used as the resume
    /// fallback for agents with no "continue last" primitive (re-run verbatim).
    let argv: String?
    /// The pid of the shell the agent was launched from. The agent always runs as
    /// a descendant of it, so this turns "is the agent running?" from something
    /// inferred from a file into something the process table can answer. nil for
    /// markers written before the field existed.
    let shellPID: pid_t?
    /// When the agent was launched. Identifies which transcript it created, and so
    /// which conversation it is in — see `AgentLiveness.claudeConversationID`.
    let startedAt: Date?
}

/// Answers "is this agent actually still running?" from the process table rather
/// than from the presence of a marker file.
///
/// The marker is only *inferred* evidence: it's written when an agent starts and
/// removed at the next shell prompt, so an agent killed without its shell ever
/// reaching a prompt leaves one behind, and Wortel would resume a conversation
/// that had already stopped.
///
/// **This deliberately fails open.** The two ways to be wrong are not equal: a
/// false negative drops a resume the user wanted (the exact bug this feature
/// exists to fix), while a false positive merely reopens a finished conversation.
/// So anything uncertain — no recorded pid, an unreadable process table — counts
/// as running, and only a definitive "that shell has no such descendant" is
/// allowed to say no.
enum AgentLiveness {
    /// `p_comm` is truncated to `MAXCOMLEN`, so compare on that basis.
    private static let maxCommandNameLength = 16

    static func isRunning(agent: String, shellPID: pid_t?) -> Bool {
        guard shellPID != nil else { return true }     // nothing recorded — assume alive
        switch locate(agent: agent, shellPID: shellPID) {
        case .running, .unknown: return true
        case .gone: return false
        }
    }

    /// Whether the agent could be found, and its pid when it could. `unknown` is
    /// the fail-open case: we couldn't read enough to make a claim either way.
    enum Located {
        case running(pid_t)
        case gone
        case unknown
    }

    static func locate(agent: String, shellPID: pid_t?) -> Located {
        guard let shellPID else { return .unknown }
        let table = processTable()
        guard !table.isEmpty else { return .unknown }  // couldn't read — no claim

        var parentOf: [pid_t: pid_t] = [:]
        parentOf.reserveCapacity(table.count)
        for entry in table { parentOf[entry.pid] = entry.ppid }
        // The shell itself is gone, so nothing can still be running under it.
        guard parentOf[shellPID] != nil else { return .gone }

        let needle = String(agent.prefix(maxCommandNameLength - 1))
        for entry in table where entry.name == agent || entry.name == needle {
            if isDescendant(entry.pid, of: shellPID, parentOf: parentOf) { return .running(entry.pid) }
        }
        return .gone
    }

    /// Walk up the parent chain, bounded so a cycle in a torn process table can't
    /// spin here — this runs on the main thread during termination.
    private static func isDescendant(_ pid: pid_t, of ancestor: pid_t,
                                     parentOf: [pid_t: pid_t]) -> Bool {
        var current = pid
        for _ in 0..<64 {
            guard let parent = parentOf[current], parent > 0 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    /// Every process visible to this user, as (pid, ppid, command name). One
    /// `sysctl` — no forking a `ps`, which matters because the caller runs inside
    /// `applicationWillTerminate`.
    private static func processTable() -> [(pid: pid_t, ppid: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between sizing and reading; over-allocate a little so
        // a process spawned in that window doesn't truncate the result.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).map { proc in
            var proc = proc
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            return (proc.kp_proc.p_pid, proc.kp_eproc.e_ppid, name)
        }
    }
}

/// Resume long-lived agent CLIs (Claude Code, Codex, …) across an app relaunch.
///
/// The bundled shell integration writes a marker file named by the surface's
/// `WORTEL_SESSION_ID` into `agents/` when an agent CLI launches (preexec) and
/// removes it at the next shell prompt (precmd) — i.e. when the agent exits. A
/// marker that outlives an app quit therefore means "an agent was still running
/// in this session", which is exactly when we want to resume it.
///
/// On restore, `SessionManager` calls `consumeSnapshot()` to read the leftover
/// markers, then seeds each matching session's `pendingResumeInput` (via
/// `resumeInput(for:)`) so its first shell auto-runs the agent's resume command.
/// `currentMarkers()` is the non-destructive read the live sidebar badge uses.
/// See `Resources/ghostty/shell-integration/*` (the `_ghostty_wortel_agent`
/// path in each shell).
enum AgentResumeStore {
    /// Shared with the shell integration, which hard-codes the same path.
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wortel/agents", isDirectory: true)

    /// The command that reopens an agent's most recent conversation for the
    /// current directory, keyed by the agent's basename. Each maps to a
    /// non-interactive "continue the latest session" invocation verified against
    /// the tool's current CLI (mid-2026). `claude` is resolved separately in
    /// `resumeCommand(for:)` so it can prefer an exact `--resume <id>` when the
    /// session id can be recovered from disk.
    ///
    /// Three of these — `goose`, `amp`, `llm` — resume the globally most-recent
    /// session rather than one scoped to `cwd`, so on relaunch they can reattach
    /// to a different project's conversation. That trade-off is deliberate (see
    /// the relaunch design): they auto-run like the rest.
    ///
    /// Agents the shell detects but that have no "continue last" primitive
    /// (`cline`, `ollama`) are intentionally absent — `resumeCommand(for:)` falls
    /// back to re-running their exact launch command so the agent at least comes
    /// back rather than leaving a cold shell.
    static let resumeCommands: [String: String] = [
        "codex": "codex resume --last",
        "opencode": "opencode --continue",
        "pi": "pi -c",
        "crush": "crush -C",
        "cursor-agent": "cursor-agent --continue",
        "gemini": "gemini --resume",
        "aider": "aider --restore-chat-history",
        "goose": "goose session --resume",
        "amp": "amp threads continue",
        "llm": "llm chat -c",
    ]

    private static func markerURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString)
    }

    /// Parse a marker file's contents. The current format is `key=value` lines
    /// (`agent`, `model`, `cwd`, `argv`); a bare single-line token is the legacy
    /// format (agent name only) and is still accepted so an in-flight agent from
    /// a pre-upgrade launch still resumes.
    static func parse(_ text: String) -> AgentMarker? {
        let lines = text.split(whereSeparator: \.isNewline)
        // Legacy marker: one bare token, no key=value structure.
        if lines.count == 1, !lines[0].contains("=") {
            let agent = lines[0].trimmingCharacters(in: .whitespaces)
            return agent.isEmpty ? nil : AgentMarker(agent: agent, model: nil, cwd: nil,
                                                     argv: nil, shellPID: nil, startedAt: nil)
        }
        var kv: [String: String] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            kv[key] = String(line[line.index(after: eq)...])
        }
        guard let agent = kv["agent"], !agent.isEmpty else { return nil }
        func nonEmpty(_ k: String) -> String? { kv[k].flatMap { $0.isEmpty ? nil : $0 } }
        return AgentMarker(agent: agent, model: nonEmpty("model"),
                           cwd: nonEmpty("cwd"), argv: nonEmpty("argv"),
                           shellPID: nonEmpty("shellpid").flatMap(pid_t.init),
                           startedAt: nonEmpty("startedat").flatMap(TimeInterval.init)
                               .map(Date.init(timeIntervalSince1970:)))
    }

    /// Read the current markers *without* removing them — the non-destructive
    /// read the live sidebar badge uses to reflect which agent is running.
    static func currentMarkers() -> [UUID: AgentMarker] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var result: [UUID: AgentMarker] = [:]
        for url in entries {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let marker = parse(text) else { continue }
            result[id] = marker
        }
        return result
    }

    /// Read the previous run's markers, then clear the directory: every still-live
    /// agent re-registers on its next preexec, and markers for sessions that no
    /// longer exist shouldn't linger.
    static func consumeSnapshot() -> [UUID: AgentMarker] {
        let fm = FileManager.default
        let markers = currentMarkers()
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in entries { try? fm.removeItem(at: url) }
        }
        return markers
    }

    /// The literal input to auto-run to resume `marker`'s agent (command plus a
    /// trailing newline), or nil if there's no way to bring the agent back.
    static func resumeInput(for marker: AgentMarker, knownConversationID: String? = nil) -> String? {
        resumeCommand(for: marker, knownConversationID: knownConversationID).map { $0 + "\n" }
    }

    /// Resolve the resume command for a marker. Claude prefers an exact
    /// `--resume <id>` when the conversation file can be found for its cwd (this
    /// also disambiguates two sessions in one directory, which `--continue`
    /// cannot); everything else uses the mapped "continue last" command, falling
    /// back to re-running the original invocation for agents with no resume flag.
    static func resumeCommand(for marker: AgentMarker, knownConversationID: String? = nil) -> String? {
        if marker.agent == "claude" {
            // An id observed from the running agent's own open transcript is exact.
            // Only fall back to the newest-file guess when we never got to look.
            if let id = knownConversationID { return "claude --resume \(id)" }
            if let cwd = marker.cwd, let id = latestClaudeSessionID(cwd: cwd) {
                return "claude --resume \(id)"
            }
            return "claude --continue"
        }
        if let mapped = resumeCommands[marker.agent] { return mapped }
        return marker.argv
    }

    /// The id of the most recently touched Claude Code conversation for `cwd`, by
    /// reading Claude's own store: `~/.claude/projects/<escaped-cwd>/<id>.jsonl`,
    /// where the cwd is escaped by replacing every non-alphanumeric character with
    /// `-` (verified against the on-disk layout). Returns nil if the directory or
    /// a valid session file isn't found, in which case the caller falls back to
    /// `claude --continue`.
    ///
    /// **Known limitation:** "most recently touched" is the same heuristic
    /// `--continue` uses, so when several Claude conversations share one directory
    /// — two sessions in the same repo, or an editor-hosted agent running
    /// alongside — this can reattach to the wrong one. Resolving it properly needs
    /// the id captured *while* the agent runs, which the shell can't do: the id
    /// doesn't exist yet at `preexec`, and reading it back later would mean
    /// writing into the agent's own config, which Wortel deliberately won't do.
    /// The id of the conversation an agent started at `startedAt` is writing to,
    /// identified by the transcript **created** when that agent launched.
    ///
    /// A fresh `claude` creates `~/.claude/projects/<escaped-cwd>/<id>.jsonl` at
    /// launch, so the transcript born at the moment the agent started *is* that
    /// agent's conversation — even when several conversations share the directory,
    /// which is the case `--continue` and a newest-modified guess both get wrong.
    ///
    /// Returns nil when no transcript was created at that moment, which is the
    /// normal signal that the agent **resumed** an existing conversation rather
    /// than starting one (a resume appends to the original file). The caller
    /// carries the previously known id forward in that case.
    ///
    /// Observation only — it reads timestamps the agent already wrote, and touches
    /// nothing. (The tempting alternative, reading the transcript from the agent's
    /// open file descriptors, does not work: Claude appends and closes rather than
    /// holding the file open — verified with `lsof` against a live process.)
    static func claudeConversationID(cwd: String, startedAt: Date) -> String? {
        // The agent starts a moment before its transcript appears, and both clocks
        // are second-granularity, so allow a small window on either side.
        let earliest = startedAt.addingTimeInterval(-5)
        return transcripts(cwd: cwd)
            .filter { $0.created >= earliest }
            .min { $0.created < $1.created }?      // the first one born after launch
            .id
    }

    private static func transcripts(cwd: String) -> [(id: String, created: Date, modified: Date)] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(escapedProjectDirectory(for: cwd))",
                                    isDirectory: true)
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (id,
                    values?.creationDate ?? .distantPast,
                    values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Claude names a project directory after its cwd with every non-alphanumeric
    /// character replaced by `-` (verified against the on-disk layout).
    private static func escapedProjectDirectory(for cwd: String) -> String {
        String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    private static func latestClaudeSessionID(cwd: String) -> String? {
        transcripts(cwd: cwd).max { $0.modified < $1.modified }?.id
    }

    /// Drop a session's marker when it's closed, so the killed shell (which never
    /// reaches its prompt to clean up) doesn't leave a stale entry.
    static func remove(sessionID: UUID) {
        try? FileManager.default.removeItem(at: markerURL(for: sessionID))
    }
}
