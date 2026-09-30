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
///
/// "Such descendant" is judged by process name first and by arguments second,
/// because a script-based agent's process is named after its interpreter (see
/// `locate`).
enum AgentLiveness {
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
        let table = ProcessTable.snapshot()
        guard !table.isEmpty else { return .unknown }  // couldn't read — no claim

        var parentOf: [pid_t: pid_t] = [:]
        parentOf.reserveCapacity(table.count)
        for entry in table { parentOf[entry.pid] = entry.ppid }
        // The shell itself is gone, so nothing can still be running under it.
        guard parentOf[shellPID] != nil else { return .gone }

        let needle = String(agent.prefix(ProcessTable.maxCommandNameLength - 1))
        for entry in table where entry.name == agent || entry.name == needle {
            if ProcessTable.isDescendant(entry.pid, of: shellPID, parentOf: parentOf) {
                return .running(entry.pid)
            }
        }
        // Not every agent is a process by its own name. Pi, Gemini and Amp are
        // node scripts, aider is a Python one, and a version-manager shim can put
        // a `sh` in between: `p_comm` then says `node` or `python3`, and the
        // agent is only visible in the arguments (`…/pi-coding-agent/dist/cli.js`,
        // `…/bin/aider`). Reading arguments is a sysctl per process, so it is
        // done only for the shell's own descendants, which is a handful at most,
        // and only after the cheap name pass has failed. Before this pass, a
        // marker for any script-based agent was swept as stale within a minute
        // of launch, which took the sidebar badge, the resume, and the screen
        // sampler's interest in the session with it.
        //
        // A read that *fails* is not a process that doesn't match: `KERN_PROCARGS2`
        // probes for a size and then reads, and a live process can grow its argv
        // in between, so the second call fails routinely on a perfectly healthy
        // one. Flattened to an empty array, that convicted the agent it was
        // looking for and deleted its marker — permanently, since nothing writes
        // one again until the shell reaches a prompt the agent never gives it
        // back. So an unreadable descendant makes the whole answer `.unknown`,
        // which the caller already knows to treat as "still alive".
        var unreadable = false
        for entry in table
        where ProcessTable.isDescendant(entry.pid, of: shellPID, parentOf: parentOf) {
            guard let arguments = ProcessTable.argumentsIfReadable(of: entry.pid) else {
                unreadable = true
                continue
            }
            if arguments.contains(where: { argumentNames(agent, $0) }) {
                return .running(entry.pid)
            }
        }
        return unreadable ? .unknown : .gone
    }

    /// Whether one argument is, or is a path to, the agent: a path component that
    /// equals the name (`…/bin/aider`, `cursor-agent`) or starts it as a package
    /// or file name (`pi-coding-agent`, `gemini-cli`, `aider.py`). Deliberately
    /// no substring match: `pi` must not be found inside `pipx` or `api`.
    static func argumentNames(_ agent: String, _ argument: String) -> Bool {
        argument.split(separator: "/").contains { component in
            component == agent[...]
                || component.hasPrefix(agent + "-")
                || component.hasPrefix(agent + ".")
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
    /// Shared with the shell integration, which derives the same path: the
    /// data folder's `agents`, `WORTEL_DATA_DIR` included.
    static let directory: URL = DataDirectory.url.appendingPathComponent("agents", isDirectory: true)

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

    /// Read the previous run's markers, and clear out the ones whose agent died
    /// with the last launch. Markers for sessions that no longer exist shouldn't
    /// linger, and an agent that is genuinely gone re-registers at its next
    /// preexec anyway.
    ///
    /// **An agent that is still running keeps its marker**, and that exception is
    /// the whole of this function. Clearing the directory wholesale was right
    /// when a shell died with the app; now the keeper owns the pty and the shell
    /// outlives us, so a long-lived agent's marker was being deleted out from
    /// under a process still sitting in the same turn it was in at quit. Nothing
    /// rewrites it: the next preexec is the one after the agent exits, which for
    /// something you leave open for days is never. The session then spends the
    /// rest of the launch with `runningAgent` nil, which costs it the sidebar's
    /// agent line *and* the whole screen-activity tier, since that tier is gated
    /// on a live marker. A terminal that quietly stops noticing the agents it
    /// was built to notice, the longer they run.
    ///
    /// Deliberately the strict test rather than `isRunning`'s fail-open one: a
    /// marker survives only on proof its shell is still there. The asymmetry
    /// runs the other way here than it does for resume — an unprovable marker
    /// kept is a phantom agent badge and a sampler watching a dead screen, an
    /// unprovable marker dropped is at worst a duplicate resume, which is the
    /// behaviour this had all along. (`sweepDeadAgentMarkers` is the backstop
    /// either way, but it reaches only what `isRunning` calls dead, so a marker
    /// with no recorded pid would sit here forever.)
    static func consumeSnapshot() -> [UUID: AgentMarker] {
        let fm = FileManager.default
        let markers = currentMarkers()
        for (id, marker) in markers {
            guard case .running = AgentLiveness.locate(agent: marker.agent,
                                                       shellPID: marker.shellPID)
            else {
                try? fm.removeItem(at: markerURL(for: id))
                continue
            }
        }
        // Anything the directory holds that isn't a marker we could read is not
        // going to become one; it would only be re-read every launch.
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in entries where UUID(uuidString: url.lastPathComponent)
                .map({ markers[$0] == nil }) ?? true {
                try? fm.removeItem(at: url)
            }
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
