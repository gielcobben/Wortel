import Foundation

/// Where one session's processes hang from.
struct SessionProcessRoot: Equatable {
    let sessionID: UUID
    /// The session's shell. From the keeper's attachment, not from the agent
    /// marker — a session has a shell whether or not an agent is running in it.
    let shellPID: pid_t
    /// The agent CLI running in this session, by command basename (`claude`,
    /// `codex`), when one is. Its process group is listed but never killable.
    ///
    /// A name rather than a pid on purpose. A pid would have to be cached
    /// somewhere and would go stale between refreshes, and "stale" here means
    /// offering a Quit button on the user's agent — so it is resolved against
    /// the same table every scan reads, and is never older than the rows it
    /// guards.
    let agentName: String?
}

/// The per-process facts that cost a syscall each, behind closures.
///
/// This is the seam that makes everything below testable. `live` reads the real
/// machine; a test hands over dictionaries and gets to assert on shaping without
/// needing a dev server running.
struct ProcessDetails {
    var arguments: (pid_t) -> [String]
    var footprint: (pid_t) -> UInt64
    var listeningPorts: (pid_t) -> [Int]
    var workingDirectory: (pid_t) -> String?

    static let live = ProcessDetails(
        arguments: ProcessTable.arguments(of:),
        footprint: { ProcessTable.footprint(of: $0) ?? 0 },
        listeningPorts: ProcessTable.listeningPorts(of:),
        workingDirectory: ProcessTable.workingDirectory(of:))
}

/// One thing a session is running: a process group, with the little that
/// describes it.
struct RunningJob: Identifiable, Equatable {
    /// The process group. Both the identity and the kill target.
    let pgid: pid_t
    /// The session this belongs to, or nil for an orphan whose session is gone.
    let sessionID: UUID?
    /// What to call it, read from argv. Never `p_comm`.
    let label: String
    /// Every process in the group when it was scanned, outermost first.
    ///
    /// Kept so the SIGKILL escalation can target the processes it actually
    /// asked to stop rather than re-signalling `-pgid` blind: by the time the
    /// grace window is up, that group number may belong to something else.
    let pids: [pid_t]
    /// Physical footprint across the whole group, in bytes.
    let footprint: UInt64
    /// Listening ports worth showing, lowest first. See `displayPorts`.
    let ports: [Int]
    let startedAt: Date
    let workingDirectory: String?
    /// The agent CLI's own group. Listed so the numbers add up (claude was
    /// 409 MB of one session's 1.39 GB) but never killable.
    let isAgent: Bool

    var id: pid_t { pgid }

    var processCount: Int { pids.count }

    /// The agent is the user's conversation, and the session shell is the
    /// session. Neither is a background job someone meant to leave running.
    var isKillable: Bool { !isAgent }

    /// The one port to put on the row. The lowest that isn't a debugger's, so a
    /// vite holding `:3000` and `:9231` reads as `:3000`.
    var primaryPort: Int? {
        ports.first { !RunningJobs.inspectorPorts.contains($0) } ?? ports.first
    }
}

/// Everything running under Wortel right now.
struct RunningJobsSnapshot: Equatable {
    /// Jobs belonging to a live session, including each session's agent row.
    let jobs: [RunningJob]
    /// Groups whose session is gone. See `RunningJobs.orphans`.
    let orphans: [RunningJob]

    static let empty = RunningJobsSnapshot(jobs: [], orphans: [])

    func jobs(for sessionID: UUID) -> [RunningJob] {
        jobs.filter { $0.sessionID == sessionID }
    }

    /// The things someone actually started and might want to stop.
    ///
    /// Separate from `agents` because the first list built here was mostly
    /// `claude`: five sessions, five agent rows, and the two dev servers the
    /// list exists for buried among them. An agent is not a stray process, it is
    /// the session's whole point, so it belongs in the accounting rather than in
    /// the list.
    var work: [RunningJob] { jobs.filter { !$0.isAgent } }

    var agents: [RunningJob] { jobs.filter(\.isAgent) }

    func work(for sessionID: UUID) -> [RunningJob] {
        work.filter { $0.sessionID == sessionID }
    }

    /// What the sessions' agents cost between them, for the one line that keeps
    /// the numbers honest without spending a row each on them.
    var agentFootprint: UInt64 { agents.reduce(0) { $0 + $1.footprint } }

    /// Whether there is anything a person would call "running": real jobs, or
    /// something left behind. Agents alone are just sessions being open.
    var hasWork: Bool { !work.isEmpty || !orphans.isEmpty }

    /// What a session costs, agent included. The agent row is part of the sum
    /// on purpose: a total that excluded it would not match the rows above it.
    func footprint(for sessionID: UUID) -> UInt64 {
        jobs(for: sessionID).reduce(0) { $0 + $1.footprint }
    }

    var isEmpty: Bool { jobs.isEmpty && orphans.isEmpty }
}

/// Turning a process table into the list of things a session is running.
///
/// **A job is a process group, not a subtree.** That is a measured fact about
/// how shells work rather than a heuristic: an interactive shell puts each job
/// it starts into its own group, and so does each `zsh -c` an agent spawns for
/// its shell tool. On a real session `zsh -c` (15614) led
/// `bun → bun → node → workerd`, every one of them pgid 15614, while the agent
/// sat alone at 37616 and the session's shell at 37499.
///
/// Two things follow, and both are why this is worth pinning with tests rather
/// than eyeballing:
///
/// - **The group is a safe kill target.** `kill(-15614, …)` reaches that job and
///   provably nothing else, because the agent and the shell are not in it. A
///   subtree walk would have had to get the same answer by being careful, and a
///   wrong answer kills the user's agent mid-turn.
/// - **A group survives its leader.** An orphaned dev server's five processes
///   still shared pgid 38931 four days after 38931 itself died, so orphans need
///   no separate handling at all: they are groups with nothing above them.
///
/// The failure here is silent in the worst way. A wrong grouping doesn't throw,
/// it puts a Quit button on the wrong row.
enum RunningJobs {
    /// Ports at or above this are the kernel handing out anonymous numbers, not
    /// a person choosing one. Eleven of fifteen ports on a real two-server
    /// session were in this range; showing them buries `:3000`.
    static let ephemeralFloor = 49152

    /// Node's `--inspect` lands here. Real, but never the port you meant.
    static let inspectorPorts = 9229...9249

    /// Shells. Used both for "this is the session's login shell" and for "look
    /// past this to the program it was told to run".
    ///
    /// Every shell Wortel ships integration for
    /// (`Resources/ghostty/shell-integration`) plus the ones people swap in:
    /// nothing here is zsh-specific, and a shell missing from this list costs a
    /// readable label and an unwanted row, so it errs wide. The dash-prefixed
    /// argv[0] that marks a login shell is a POSIX convention `login` applies
    /// whatever shell it execs, so it works for all of them.
    static let shellWrappers: Set<String> = [
        "zsh", "bash", "sh", "dash", "ash", "ksh", "fish", "elvish", "nu",
        "xonsh", "tcsh", "csh", "pwsh",
    ]

    /// Programs whose whole job is to run another program. The label should look
    /// straight through them to the thing they launched.
    ///
    /// The same list the shell integration skips when it works out which command
    /// you actually ran (`_ghostty_wortel_agent`), so the two halves agree about
    /// what counts as scaffolding.
    static let commandWrappers: Set<String> = [
        "login", "env", "sudo", "doas", "command", "exec", "nohup", "nice",
        "stdbuf", "setsid", "time", "arch", "caffeinate",
    ]

    /// Interpreters worth dropping from a label when they are followed by the
    /// script they are running: `node …/bin/vite dev` reads better as
    /// `vite dev`. Only when something follows, so a bare `node` REPL keeps its
    /// name.
    static let runtimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "php",
    ]

    /// Agent CLIs, recognised by name whether or not the session says one is
    /// running.
    ///
    /// The session's own `agentName` comes from the shell integration's marker
    /// file, and a marker is only written when an agent launches *under a shell
    /// carrying the integration*. Anything older than the integration, or
    /// started before the app restarted, leaves no marker: on a real machine the
    /// marker directory was empty while eleven agents were running, so every one
    /// of them was listed as a stray job with a Quit button on it.
    ///
    /// So the marker is a hint, not the source of truth. These are the agents
    /// `AgentResumeStore` already knows how to resume, plus `claude`, which it
    /// handles separately.
    static let knownAgents: Set<String> =
        Set(AgentResumeStore.resumeCommands.keys).union(["claude"])

    // MARK: - The scan

    /// Every job under every live session, plus the orphans.
    ///
    /// `excludedPGIDs` keeps Wortel and its keeper out of their own list; the
    /// caller passes its own group.
    static func scan(
        table: [ProcessEntry],
        roots: [SessionProcessRoot],
        projectRoots: [String] = [],
        uid: uid_t = getuid(),
        excludedPGIDs: Set<pid_t> = [],
        details: ProcessDetails = .live
    ) -> RunningJobsSnapshot {
        guard !table.isEmpty else { return .empty }

        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let parentOf = byPID.mapValues(\.ppid)
        var membersOf: [pid_t: [ProcessEntry]] = [:]
        for entry in table { membersOf[entry.pgid, default: []].append(entry) }

        // The shells themselves, and the groups they sit in, are never jobs.
        //
        // Two groups per session, not one. The keeper forks `/usr/bin/login`
        // (see `ShellSpawn`), so the pid it reports is login's, and login gives
        // the real shell a session of its own — a separate process group. Left
        // to itself that shell is indistinguishable from a job, and every
        // session grew a permanent `zsh -l` row holding 4 MB. The login shell is
        // the session; the giveaway is argv[0], which login prefixes with a dash
        // (`-/bin/zsh`) and nothing else on the machine does.
        let shellPIDs = Set(roots.map(\.shellPID))
        var reserved = excludedPGIDs
        for shell in shellPIDs { reserved.insert(byPID[shell]?.pgid ?? shell) }
        for entry in table where isLoginShell(details.arguments(entry.pid)) {
            guard shellPIDs.contains(where: {
                entry.pid == $0 || ProcessTable.isDescendant(entry.pid, of: $0, parentOf: parentOf)
            }) else { continue }
            reserved.insert(entry.pgid)
        }

        var jobs: [RunningJob] = []
        var claimed: Set<pid_t> = reserved

        for root in roots {
            guard byPID[root.shellPID] != nil else { continue }  // shell already gone
            // Groups, plural. Claude Code runs its sub-agents as further
            // `claude` processes in groups of their own, and matching only the
            // first put a Quit button on every one of them.
            let agentPGIDs = agentGroups(named: root.agentName, shellPID: root.shellPID,
                                         table: table, parentOf: parentOf, details: details)

            // Every group with a member descended from this session's shell.
            var groupsHere: Set<pid_t> = []
            for entry in table
            where !reserved.contains(entry.pgid)
                && ProcessTable.isDescendant(entry.pid, of: root.shellPID, parentOf: parentOf) {
                groupsHere.insert(entry.pgid)
            }

            for pgid in groupsHere.sorted() {
                guard !claimed.contains(pgid), let members = membersOf[pgid] else { continue }
                claimed.insert(pgid)
                if let job = job(pgid: pgid, members: members, sessionID: root.sessionID,
                                 isAgent: agentPGIDs.contains(pgid), parentOf: parentOf,
                                 details: details) {
                    jobs.append(job)
                }
            }
        }

        let orphans = orphans(
            table: table, membersOf: membersOf, parentOf: parentOf, byPID: byPID,
            shellPIDs: shellPIDs, claimed: claimed, projectRoots: projectRoots,
            uid: uid, details: details)

        return RunningJobsSnapshot(jobs: jobs.sorted { $0.footprint > $1.footprint },
                                   orphans: orphans.sorted { $0.footprint > $1.footprint })
    }

    /// Which process groups the session's agent occupies.
    ///
    /// Two passes, the same two and in the same order as `AgentLiveness.locate`,
    /// and for the same reason: an agent is usually a process by its own name,
    /// but a script-based one (Pi, Gemini, aider) is named after its
    /// interpreter, and `claude` renames itself to its version string — the real
    /// tree here had `p_comm` reading `2.1.267`. So the cheap name check runs
    /// first and argv decides whatever it misses.
    ///
    /// Getting this wrong in the permissive direction is the expensive one: an
    /// unrecognised agent becomes a row with a Quit button on it.
    static func agentGroups(named agent: String?, shellPID: pid_t,
                            table: [ProcessEntry], parentOf: [pid_t: pid_t],
                            details: ProcessDetails) -> Set<pid_t> {
        var names = knownAgents
        if let agent, !agent.isEmpty { names.insert(agent) }
        // `p_comm` is truncated, so each name needs its short form too.
        var truncated: [String: String] = [:]
        for name in names {
            truncated[String(name.prefix(ProcessTable.maxCommandNameLength - 1))] = name
        }

        var groups: Set<pid_t> = []
        for entry in table
        where ProcessTable.isDescendant(entry.pid, of: shellPID, parentOf: parentOf) {
            if names.contains(entry.name) || truncated[entry.name] != nil {
                groups.insert(entry.pgid)
                continue
            }
            // The argv pass, for agents whose process is named after their
            // interpreter (Pi, Gemini, aider) or after their own version
            // (`claude` reports `p_comm` as `2.1.267`).
            if namesAgent(in: details.arguments(entry.pid), among: names) {
                groups.insert(entry.pgid)
            }
        }
        return groups
    }

    /// Whether these arguments say the process **is** one of these agents.
    ///
    /// Only the program is looked at: the executable path, `argv[0]`, and
    /// `argv[1]`, which is where a script-based agent's identity lives
    /// (`node …/pi-coding-agent/dist/cli.js`). Deliberately **not** the rest of
    /// the command line.
    ///
    /// That restriction is the whole point. `AgentLiveness` matches an agent
    /// name anywhere in argv, which is safe for the question it asks: it fails
    /// open, and a false positive there merely keeps a marker alive a little
    /// longer. Here a false positive is expensive, because it takes a real
    /// server off the list and hides the Quit button that was the reason for
    /// looking.
    ///
    /// And it fired immediately. Claude Code's shell tool runs
    /// `zsh -c 'source /Users/giel/.claude/shell-snapshots/snapshot-zsh-….sh …'`,
    /// so every job an agent starts carries a mention of `.claude` in its
    /// command string. Both of a session's dev servers were classified as the
    /// agent and vanished from the list they existed for.
    static func namesAgent(in arguments: [String], among names: Set<String>) -> Bool {
        for argument in arguments.prefix(3) where !argument.isEmpty {
            // A flag is never a program name, and `-c` is what precedes the
            // command string this rule exists to ignore.
            guard !argument.hasPrefix("-") else { continue }
            if names.contains(where: { AgentLiveness.argumentNames($0, argument) }) {
                return true
            }
        }
        return false
    }

    /// Groups nothing is watching any more.
    ///
    /// The cwd filter is not a nicety. On a real machine 338 processes had
    /// `ppid == 1` under one uid — every login agent, XPC service and app
    /// helper. Requiring the group to be sitting in a directory Wortel has
    /// actually opened a session in cuts that to the one dev server that really
    /// did outlive its terminal.
    private static func orphans(
        table: [ProcessEntry],
        membersOf: [pid_t: [ProcessEntry]],
        parentOf: [pid_t: pid_t],
        byPID: [pid_t: ProcessEntry],
        shellPIDs: Set<pid_t>,
        claimed: Set<pid_t>,
        projectRoots: [String],
        uid: uid_t,
        details: ProcessDetails
    ) -> [RunningJob] {
        guard !projectRoots.isEmpty else { return [] }

        var found: [RunningJob] = []
        var seen = claimed

        for pgid in Set(table.map(\.pgid)).sorted() {
            guard !seen.contains(pgid), let members = membersOf[pgid] else { continue }
            guard members.allSatisfy({ $0.uid == uid }) else { continue }
            // Anything still under a live session is that session's, not an orphan.
            guard !members.contains(where: { member in
                shellPIDs.contains(member.pid)
                    || shellPIDs.contains(where: {
                        ProcessTable.isDescendant(member.pid, of: $0, parentOf: parentOf)
                    })
            }) else { continue }
            // A group whose leader is still alive and parented normally is
            // somebody else's business — a login shell, an app's helper.
            guard byPID[pgid] == nil || members.contains(where: { $0.ppid <= 1 }) else { continue }

            seen.insert(pgid)
            guard let candidate = job(pgid: pgid, members: members, sessionID: nil,
                                      isAgent: false, parentOf: parentOf, details: details),
                  let cwd = candidate.workingDirectory,
                  projectRoots.contains(where: { FolderRoot.root($0, contains: cwd) })
            else { continue }
            found.append(candidate)
        }
        return found
    }

    // MARK: - One group

    /// Shape one process group into a row, or nil when it has nothing to say.
    static func job(
        pgid: pid_t,
        members: [ProcessEntry],
        sessionID: UUID?,
        isAgent: Bool,
        parentOf: [pid_t: pid_t],
        details: ProcessDetails
    ) -> RunningJob? {
        guard !members.isEmpty else { return nil }

        let ordered = depthOrdered(members, parentOf: parentOf)
        guard let head = ordered.first else { return nil }

        // The first member that isn't a way of running something else. The
        // leader is often `zsh -c …`, which describes nothing.
        let labelled = ordered.first { !isWrapper(details.arguments($0.pid)) } ?? head
        // `p_comm` last, and only because the alternative is dropping the row.
        // Argv is unreadable for a process that exits mid-scan, and a silently
        // omitted job is worse than a badly named one — the whole point is to
        // show what is holding memory, and 385 MB with an ugly label still says
        // more than nothing at all.
        let label = label(forArguments: details.arguments(labelled.pid))
            ?? label(forArguments: details.arguments(head.pid))
            ?? (labelled.name.isEmpty ? head.name : labelled.name)
        guard !label.isEmpty else { return nil }

        var ports: [Int] = []
        var footprint: UInt64 = 0
        for member in ordered {
            footprint += details.footprint(member.pid)
            ports.append(contentsOf: details.listeningPorts(member.pid))
        }

        return RunningJob(
            pgid: pgid,
            sessionID: sessionID,
            label: label,
            pids: ordered.map(\.pid),
            footprint: footprint,
            ports: displayPorts(ports),
            startedAt: ordered.map(\.startedAt).min() ?? head.startedAt,
            workingDirectory: details.workingDirectory(labelled.pid)
                ?? details.workingDirectory(head.pid),
            isAgent: isAgent)
    }

    /// Members ordered from the outside in, so "the shallowest" is `first`.
    ///
    /// Breadth-first from whichever members have no parent inside the group —
    /// which is how this keeps working for an orphan whose leader has died and
    /// whose survivors were reparented to launchd.
    static func depthOrdered(_ members: [ProcessEntry],
                             parentOf: [pid_t: pid_t]) -> [ProcessEntry] {
        let inGroup = Set(members.map(\.pid))
        var childrenOf: [pid_t: [ProcessEntry]] = [:]
        var frontier: [ProcessEntry] = []
        for member in members {
            if let parent = parentOf[member.pid], inGroup.contains(parent) {
                childrenOf[parent, default: []].append(member)
            } else {
                frontier.append(member)
            }
        }
        // A group that is entirely a cycle (a torn table) would leave nothing to
        // start from; fall back to the whole list rather than returning none.
        if frontier.isEmpty { return members.sorted { $0.pid < $1.pid } }

        var ordered: [ProcessEntry] = []
        var queue = frontier.sorted { $0.pid < $1.pid }
        var visited: Set<pid_t> = []
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            guard visited.insert(entry.pid).inserted else { continue }
            ordered.append(entry)
            queue.append(contentsOf: (childrenOf[entry.pid] ?? []).sorted { $0.pid < $1.pid })
        }
        // Anything unreachable (again, a torn table) still belongs to the group.
        for member in members where !visited.contains(member.pid) { ordered.append(member) }
        return ordered
    }

    // MARK: - Labels

    /// Whether this argv is a way of running something else rather than the
    /// thing itself.
    static func isWrapper(_ arguments: [String]) -> Bool {
        guard let command = commandName(arguments) else { return true }
        // `sudo`, `env`, `nohup` and friends exist only to run something else.
        if commandWrappers.contains(command) { return true }
        guard shellWrappers.contains(command) else { return false }
        // A shell you are sitting in is a real job; a shell handed a command to
        // run is scaffolding. The command flag is what tells them apart, and it
        // is `-c` in every shell Wortel ships integration for, including fish,
        // elvish and nushell. PowerShell spells it `-Command`.
        let flags = arguments.dropFirst()
        return flags.contains { $0 == "-c" || $0.hasPrefix("-c") }
            || flags.contains { $0.lowercased().hasPrefix("-command") }
            || arguments.count <= 2
    }

    /// Whether this is a shell started as a login shell.
    ///
    /// `login` marks one by prefixing argv[0] with a dash, which is the
    /// convention every shell reads to decide whether to run the login profile,
    /// and which `login` applies whatever shell it execs. It is the only
    /// reliable sign that a shell is a session rather than a job: the command
    /// name is the same either way.
    static func isLoginShell(_ arguments: [String]) -> Bool {
        let tokens = arguments.count > 1 ? Array(arguments.dropFirst()) : arguments
        guard let argv0 = tokens.first, argv0.hasPrefix("-") else { return false }
        let name = (String(argv0.dropFirst()) as NSString).lastPathComponent
        return shellWrappers.contains(name)
    }

    /// What to call a process, from its arguments. nil when there is nothing
    /// readable there at all.
    ///
    /// Paths are stripped from every token, because argv is full of them and
    /// none of it fits a row: the real thing here was
    /// `node /Users/giel/Developer/…/node_modules/.bin/vite dev`.
    static func label(forArguments arguments: [String]) -> String? {
        // `arguments` is [executable path, argv0, argv1, …]; argv0 is the more
        // honest name (it is what the user typed), so prefer it and fall back.
        var tokens = Array(arguments.dropFirst())
        if tokens.isEmpty { tokens = Array(arguments.prefix(1)) }
        tokens = tokens.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        // `node …/bin/vite dev` is really `vite dev`. Only when the next token
        // is a *path* though: the runtime is hiding the program there, whereas
        // in `bun dev:web` it is running one of its own scripts and dropping it
        // would leave a label saying `dev:web`, which names nothing.
        if tokens.count > 1,
           runtimes.contains(((tokens[0]) as NSString).lastPathComponent),
           tokens[1].contains("/") {
            tokens.removeFirst()
        }

        let parts = tokens.map { ($0 as NSString).lastPathComponent }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var label = parts.prefix(4).joined(separator: " ")
        if label.count > 48 { label = String(label.prefix(47)) + "…" }
        return label.isEmpty ? nil : label
    }

    /// The command a process was invoked as, path stripped.
    static func commandName(_ arguments: [String]) -> String? {
        let tokens = arguments.count > 1 ? Array(arguments.dropFirst()) : arguments
        guard let first = tokens.first, !first.isEmpty else { return nil }
        let name = (first as NSString).lastPathComponent
        // A login shell is argv0-prefixed with a dash: `-zsh`.
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    // MARK: - Copy

    /// What to tell someone closing a session, given what it is running.
    ///
    /// The old text was "A process is still running in this session", which is
    /// true of a session holding one `sleep` and equally true of one holding
    /// 1.4 GB across two dev servers, and it cannot tell you which you are
    /// about to lose. Naming them is the entire improvement.
    ///
    /// nil when there is nothing worth naming, so the caller keeps its generic
    /// wording rather than printing an empty sentence.
    ///
    /// The agent is named too. Closing the session does stop it, and "you are
    /// about to end your agent's turn" is the most important thing on the
    /// screen at that moment.
    static func closeSummary(for jobs: [RunningJob], maximumNames: Int = 3) -> String? {
        guard !jobs.isEmpty else { return nil }

        let ranked = jobs.sorted { $0.footprint > $1.footprint }
        let named = ranked.prefix(maximumNames).map { job -> String in
            guard let port = job.primaryPort else { return job.label }
            return "\(job.label) (:\(port))"
        }
        let remainder = ranked.count - named.count
        var list = named.joined(separator: ", ")
        if remainder > 0 {
            list += " and \(remainder) more"
        }

        let processes = ranked.reduce(0) { $0 + $1.processCount }
        let bytes = ranked.reduce(0) { $0 + $1.footprint }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        let plural = processes == 1 ? "process" : "processes"
        return "Still running: \(list). Closing stops \(processes) \(plural) and frees \(size)."
    }

    /// Ports worth putting in front of a person: deduplicated, sorted, and with
    /// the kernel's anonymous ones dropped.
    static func displayPorts(_ ports: [Int]) -> [Int] {
        Array(Set(ports.filter { $0 > 0 && $0 < ephemeralFloor })).sorted()
    }
}
