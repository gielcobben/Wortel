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
    /// `table`: a snapshot to read instead of taking one. A caller asking
    /// about every session (the save) takes one and shares it, rather than
    /// reading the whole process table once per agent on the main thread.
    static func isRunning(agent: String, shellPID: pid_t?,
                          table: [ProcessEntry]? = nil) -> Bool {
        guard shellPID != nil else { return true }     // nothing recorded — assume alive
        switch locate(agent: agent, shellPID: shellPID, table: table) {
        case .running, .unknown: return true
        case .gone: return false
        }
    }

    /// Whether the shell an agent was started from has itself gone, which
    /// `locate` reports as `.gone` just the same as an agent that exited and
    /// left its shell at a prompt. The difference decides whether the agent is
    /// owed a resume: you quit an agent yourself, but nothing you do ends the
    /// shell under a running one. An unreadable table claims nothing.
    static func shellIsGone(shellPID: pid_t, table: [ProcessEntry]? = nil) -> Bool {
        let table = table ?? ProcessTable.snapshot()
        guard !table.isEmpty else { return false }
        return !table.contains { $0.pid == shellPID && !$0.isExiting }
    }

    /// Whether the agent could be found, and its pid when it could. `unknown` is
    /// the fail-open case: we couldn't read enough to make a claim either way.
    enum Located {
        case running(pid_t)
        case gone
        case unknown
    }

    static func locate(agent: String, shellPID: pid_t?,
                       table: [ProcessEntry]? = nil) -> Located {
        guard let shellPID else { return .unknown }
        let table = table ?? ProcessTable.snapshot()
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
/// markers, then gives each matching session an `OwedResume` (via
/// `resumeInput(for:)`) so its first shell types the agent's resume command.
/// `currentMarkers()` is the non-destructive read the live sidebar badge uses.
/// See `Resources/ghostty/shell-integration/*` (the `_ghostty_wortel_agent`
/// path in each shell).
enum AgentResumeStore {
    /// Shared with the shell integration, which derives the same path: the
    /// data folder's `agents`, `WORTEL_DATA_DIR` included.
    static let directory: URL = DataDirectory.url.appendingPathComponent("agents", isDirectory: true)

    /// Where the shell integration notes every agent's exit: one line per exit,
    /// `<epoch> session=<id> agent=<name> status=<n> shellpid=<pid>`, written
    /// at the prompt that clears the marker (see `_ghostty_wortel_clear_agent`
    /// in the zsh copy). A status of 129 and up is a signal. It exists because
    /// on 2026-10-07 nine agents exited within a minute of a relaunch and
    /// nothing on the machine could say how: the scrollback was gone, the
    /// transcripts record prompts, not exits. Nothing in the app reads it; it
    /// is for the next investigation.
    static let exitLog: URL = directory.appendingPathComponent("exits.log")

    /// Keep the exit log bounded: once it passes `limit`, it becomes
    /// `exits.log.1` (replacing the previous one) and the shells start a new
    /// one. One line per agent exit grows slowly, but unbounded is unbounded.
    ///
    /// A rename rather than a rewrite. Shells append with `>>` at any moment,
    /// including the launch this runs in, which is exactly when restored
    /// agents start and sometimes die; a line appended between reading the
    /// file and writing a trimmed copy back would vanish. A rename keeps the
    /// inode, so an append already under way lands in `.1` instead.
    static func rotateExitLog(over limit: Int = 256 * 1024) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: exitLog.path))?[.size] as? Int,
              size > limit else { return }
        let previous = exitLog.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: exitLog, to: previous)
    }

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

    /// The agent running in one session right now, by its marker: one small
    /// file, for a reattach that needs to know before anything else does.
    static func currentMarker(for sessionID: UUID) -> AgentMarker? {
        (try? String(contentsOf: markerURL(for: sessionID), encoding: .utf8)).flatMap(parse)
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
    /// Only a marker proven dead goes. `.unknown` is kept: it is what a failed
    /// argument read gives for a live Pi, Gemini or aider (routine; see
    /// `AgentLiveness.locate`), and dropping it lost the agent for the whole
    /// launch, so a keeper lost later had nothing to resume. A marker with no
    /// shell pid (an integration from before the field) can't be proven
    /// either way and goes, as it always did; `sweepDeadAgentMarkers` catches
    /// any kept one that turns out dead.
    static func consumeSnapshot() -> [UUID: AgentMarker] {
        let fm = FileManager.default
        let table = ProcessTable.snapshot()
        let markers = currentMarkers()
        for (id, marker) in markers {
            let dead: Bool
            if marker.shellPID == nil {
                dead = true
            } else if case .gone = AgentLiveness.locate(agent: marker.agent, shellPID: marker.shellPID,
                                                        table: table) {
                dead = true
            } else {
                dead = false
            }
            if dead { try? fm.removeItem(at: markerURL(for: id)) }
        }
        // Anything the directory holds that isn't a marker we could read is not
        // going to become one; it would only be re-read every launch. The exit
        // log lives here too and is not a marker to sweep, and neither is a
        // dot-file: a marker being written, a moment from its rename into place.
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in entries where !url.lastPathComponent.hasPrefix(exitLog.lastPathComponent)
                && !url.lastPathComponent.hasPrefix(".")
                && (UUID(uuidString: url.lastPathComponent).map({ markers[$0] == nil }) ?? true) {
                try? fm.removeItem(at: url)
            }
        }
        return markers
    }

    /// The literal input that resumes `marker`'s agent, or nil if there's no
    /// way to bring it back. Ends in a newline, so it runs, except for a
    /// command line re-run as typed that is more than one simple command: that
    /// is typed and left at the prompt, because running it again would also
    /// run whatever came after the agent (`ollama run x; rm -rf build`).
    static func resumeInput(for marker: AgentMarker, knownConversationID: String? = nil) -> String? {
        guard let command = resumeCommand(for: marker, knownConversationID: knownConversationID)
        else { return nil }
        let runsAsTyped = command == marker.argv && !AgentCommandLine.isSimple(command)
        return runsAsTyped ? command : command + "\n"
    }

    /// The command that resumes a marker's agent, started the way it was
    /// (`AgentCommandLine`): an exact conversation when one is known (which is
    /// what keeps two sessions in one folder apart); otherwise the agent's own
    /// "continue the latest"; and for an agent with neither, its launch line
    /// as typed.
    static func resumeCommand(for marker: AgentMarker, knownConversationID: String? = nil) -> String? {
        let agent = marker.agent
        if let id = knownConversationID, let words = AgentConversation.resumeWords(agent: agent, id: id) {
            return AgentCommandLine.command(agent: agent, argv: marker.argv, resume: words)
        }
        if agent == "claude" {
            // No conversation known: the newest in the folder, which is what
            // `--continue` would pick, but named so the next save records it.
            if let cwd = marker.cwd, let id = latestClaudeSessionID(cwd: cwd),
               let words = AgentConversation.resumeWords(agent: agent, id: id) {
                return AgentCommandLine.command(agent: agent, argv: marker.argv, resume: words)
            }
            return AgentCommandLine.command(agent: agent, argv: marker.argv, resume: ["--continue"])
        }
        if let mapped = resumeCommands[agent] {
            return AgentCommandLine.command(
                agent: agent, argv: marker.argv, resume: Array(AgentCommandLine.words(mapped).dropFirst()))
        }
        return marker.argv
    }

    /// The id of the conversation an agent started at `startedAt` is writing to,
    /// identified by the transcript **created** when that agent launched.
    ///
    /// A fresh `claude` creates `~/.claude/projects/<escaped-cwd>/<id>.jsonl`
    /// with its first exchange, so the transcript born just after the agent
    /// started *is* that agent's conversation — even when several conversations
    /// share the directory, which is the case `--continue` and a newest-modified
    /// guess both get wrong.
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
    ///
    /// **Bounded on both sides**, and the last resort: see
    /// `claudeConversationID(pid:)` for the exact answer. Unbounded, "the first
    /// transcript born after launch" for an agent that *resumed* (and so
    /// created nothing) was whichever conversation anyone opened next in the
    /// same directory, hours later. On 2026-10-07 that put two Wortel sessions,
    /// resumed at 09:20, into a third session's conversation created at 09:28,
    /// and the next relaunch resumed all three into it.
    static func claudeConversationID(cwd: String, startedAt: Date) -> String? {
        // The agent starts a moment before its transcript appears, and both clocks
        // are second-granularity, so allow a small window on either side. A
        // transcript appears with the first exchange, so the window allows for
        // a prompt being typed, but not for the rest of the day.
        let earliest = startedAt.addingTimeInterval(-5)
        let latest = startedAt.addingTimeInterval(120)
        return transcripts(cwd: cwd)
            .filter { $0.created >= earliest && $0.created <= latest }
            .min { $0.created < $1.created }?      // the first one born after launch
            .id
    }

    /// The conversation a **running** Claude process is in, read from the file
    /// Claude Code keeps for each live process: `~/.claude/sessions/<pid>.json`,
    /// whose `sessionId` is the conversation. Exact however it was started
    /// (fresh, `--resume`, `--continue`) and after a `/resume` inside it, which
    /// no command line or file date can see. Observation only, like every other
    /// read of Claude's files here. nil for an older Claude that doesn't keep
    /// the file, or a pid that isn't one.
    static func claudeConversationID(pid: pid_t) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return claudeConversationID(sessionFile: data, pid: pid)
    }

    /// The `sessionId` of a `~/.claude/sessions/<pid>.json`, if it is a
    /// conversation id and the file is for `pid` (pids are reused, and a stale
    /// file must not hand a new process someone else's conversation).
    static func claudeConversationID(sessionFile data: Data, pid: pid_t) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == pid,
              let id = object["sessionId"] as? String, UUID(uuidString: id) != nil
        else { return nil }
        return id.lowercased()
    }

    private static func transcripts(cwd: String) -> [(id: String, created: Date, modified: Date)] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        return claudeProjectDirectories(for: cwd).flatMap { dir -> [(id: String, created: Date, modified: Date)] in
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
    }

    static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The folders Claude keeps `cwd`'s conversations in: usually one.
    ///
    /// Claude names it after the **physical** path (`/tmp/x` is held under
    /// `-private-tmp-x`, a symlinked `~/code` under wherever it points), while
    /// the shell reports the path as typed; both are tried. Past 200
    /// characters Claude cuts the name and appends a hash of its own, which
    /// isn't reproduced here: a long path's folder is found by its first 200.
    /// A wrong folder here drops an exact conversation id as "not found", and
    /// the resume falls back to a guess.
    static func claudeProjectDirectories(for cwd: String) -> [URL] {
        let root = claudeProjectsRoot
        var names: [String] = []
        for path in [physicalPath(cwd), cwd] {
            let name = claudeProjectName(for: path)
            guard !names.contains(name) else { continue }
            names.append(name)
        }
        var found: [URL] = []
        for name in names {
            if name.count <= claudeProjectNameLimit {
                let dir = root.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: dir.path) { found.append(dir) }
            } else if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                let prefix = String(name.prefix(claudeProjectNameLimit)) + "-"
                found += entries.filter { $0.hasPrefix(prefix) }
                    .map { root.appendingPathComponent($0, isDirectory: true) }
            }
        }
        return found
    }

    /// Claude's escape: every UTF-16 unit that isn't an ASCII letter or digit
    /// becomes `-` (`replace(/[^a-zA-Z0-9]/g, "-")` in Claude Code itself), so
    /// one emoji is two dashes.
    static func claudeProjectName(for path: String) -> String {
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(Unicode.Scalar(unit)!)
            default: return "-"
            }
        })
    }

    static let claudeProjectNameLimit = 200

    /// `realpath`, or the path itself if it doesn't exist any more. Not
    /// `URL.resolvingSymlinksInPath`, which drops `/private` from
    /// `/private/tmp` and so undoes the very thing being resolved.
    static func physicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func latestClaudeSessionID(cwd: String) -> String? {
        transcripts(cwd: cwd).max { $0.modified < $1.modified }?.id
    }

    /// Whether conversation `id` belongs to `cwd`: Claude only resumes a
    /// conversation from the directory it was held in, so an id remembered from
    /// another directory is no id at all there.
    static func claudeTranscriptExists(id: String, cwd: String) -> Bool {
        claudeProjectDirectories(for: cwd).contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(id).jsonl").path)
        }
    }

    /// The conversation a `claude` command line names: `--resume <id>`,
    /// `--resume=<id>` or `-r <id>`. nil for anything else, including a bare
    /// `--resume`, which opens a picker.
    ///
    /// The command line is the one exact answer for an agent that resumed: a
    /// resume appends to the original transcript and creates nothing, so
    /// `claudeConversationID(cwd:startedAt:)` has nothing to find. And every
    /// resume Wortel types is of this form.
    ///
    /// `--session-id <id>` names it too. `--fork-session` names none: the
    /// conversation it resumes is copied into a new one with an id of its own.
    static func claudeResumeTarget(argv: String?) -> String? {
        let words = AgentCommandLine.words(argv)
        guard !words.contains("--fork-session") else { return nil }
        for (index, word) in words.enumerated() {
            var value: String?
            for flag in ["--resume", "-r", "--session-id"] {
                if word.hasPrefix(flag + "=") {
                    value = String(word.dropFirst(flag.count + 1))
                } else if word == flag, index + 1 < words.count {
                    value = words[index + 1]
                }
            }
            if let value, UUID(uuidString: value) != nil { return value.lowercased() }
        }
        return nil
    }

    /// Whether a `claude` command line continues the directory's latest
    /// conversation (`--continue`, `-c`). While such an agent is running, the
    /// transcript it appends to is the newest in the directory, which makes the
    /// newest-file guess exact for that one moment.
    static func claudeContinuesLatest(argv: String?) -> Bool {
        AgentCommandLine.words(argv).contains { $0 == "--continue" || $0 == "-c" }
    }

    /// Drop a session's marker when it's closed, so the killed shell (which never
    /// reaches its prompt to clean up) doesn't leave a stale entry.
    static func remove(sessionID: UUID) {
        try? FileManager.default.removeItem(at: markerURL(for: sessionID))
    }
}
