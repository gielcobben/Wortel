import Foundation

/// Where one session's processes hang from.
struct SessionProcessRoot: Equatable, Sendable {
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
    /// `WORTEL_SESSION_ID`s that mean this session besides its own id: a
    /// side terminal's shell carries its tab's id (which keys its own agent
    /// marker), and what it starts carries that too. On the session's own
    /// root, also the terminals restored but not shown yet, which have a live
    /// shell and no view to report it.
    var tags: [UUID] = []
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
    /// The `WORTEL_SESSION_ID` a process was started with, if it can be read.
    /// See `RunningJobs.scan` on detached servers.
    var sessionTag: (ProcessEntry) -> UUID? = { _ in nil }
    /// The process's terminal session (`getsid`), 0 when it can't be read.
    var terminalSession: (pid_t) -> pid_t = { _ in 0 }

    static let live = ProcessDetails(
        arguments: ProcessTable.arguments(of:),
        footprint: { ProcessTable.footprint(of: $0) ?? 0 },
        listeningPorts: ProcessTable.listeningPorts(of:),
        workingDirectory: ProcessTable.workingDirectory(of:),
        sessionTag: { ProcessTable.sessionTag(of: $0.pid) },
        terminalSession: ProcessTable.terminalSession(of:))
}

/// One process, named so that a recycled pid cannot answer for it.
///
/// A pid alone is not an identity once the process behind it can exit: macOS
/// hands the number out again, and "this pid belonged to that session" would
/// then put somebody else's process on a session's list, and on its close.
/// The start time is what a reused pid cannot also reuse.
struct ProcessKey: Hashable, Sendable {
    let pid: pid_t
    let startedAt: Date

    init(pid: pid_t, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }

    init(_ entry: ProcessEntry) {
        self.init(pid: entry.pid, startedAt: entry.startedAt)
    }
}

/// Which session started which process, as far as any scan has seen.
///
/// See `RunningJobs.recordingOwners`.
typealias ProcessOwners = [ProcessKey: UUID]

/// One thing a session is running: a process group, with the little that
/// describes it.
struct RunningJob: Identifiable, Equatable {
    /// The outermost process of this job. The identity, because a process group
    /// can hold more than one job and `pgid` is therefore not unique.
    let rootPID: pid_t
    /// The process group this job's processes are in.
    let pgid: pid_t
    /// Whether this job is the whole of its process group.
    ///
    /// One command can start several servers: `bun dev` running `dev:web` and
    /// `dev:images` put both trees in one group, with `:3000` and `:3002` in it.
    /// When that happens the group is not a job, it is two, and `kill(-pgid, …)`
    /// would stop both from a row that names one. So a shared group is stopped
    /// by its own processes instead.
    let ownsGroup: Bool
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
    /// Still this session's, but no longer under its shell.
    ///
    /// A `nohup`, a `disown`, or a server that daemonises itself leaves the
    /// shell's tree and is reparented to launchd. It was started in this
    /// session, a scan saw it there, and it stops when the session closes.
    var detached = false
    /// For an orphan: the session that started it, when a scan saw that
    /// happen. That session is closed (or closing), which is exactly the case
    /// where its servers have to be found without a shell to look under.
    var lastSessionID: UUID?

    var id: pid_t { rootPID }

    var processCount: Int { pids.count }

    /// The agent is the user's conversation, and the session shell is the
    /// session. Neither is a background job someone meant to leave running.
    var isKillable: Bool { !isAgent }

    /// The one port to put on the row. The lowest that isn't a debugger's, so a
    /// vite holding `:3000` and `:9231` reads as `:3000`.
    var primaryPort: Int? {
        ports.first { !RunningJobs.inspectorPorts.contains($0) } ?? ports.first
    }

    /// The ports to put on the row: everything meaningful it holds, capped so a
    /// job with a dozen of them cannot push the name off the row.
    ///
    /// Not just `primaryPort`. A single row can legitimately serve several, and
    /// showing the lowest hid the rest: a `bun dev` fanning out to `dev:web` and
    /// `dev:images` read as `:3000` with no sign that `:3002` existed at all.
    var shownPorts: [Int] {
        let meaningful = ports.filter { !RunningJobs.inspectorPorts.contains($0) }
        return Array((meaningful.isEmpty ? ports : meaningful).prefix(3))
    }

    /// The address to copy, and the one to hand a browser: `localhost:3000`.
    ///
    /// **`localhost`, never `127.0.0.1`.** Node tooling commonly binds the IPv6
    /// loopback only — the vite this was built against was listening on
    /// `[::1]:3000` and nothing else, so `http://127.0.0.1:3000` refused the
    /// connection outright while `http://localhost:3000` answered 200. A browser
    /// gets away with `localhost` because it resolves to both families and tries
    /// each; hard-coding the v4 literal would have broken the most common case
    /// this feature exists for.
    ///
    /// Host and port rather than a URL because it has to serve the things that
    /// are not web servers too: it is what `psql -h`, `redis-cli -h` and a gRPC
    /// client want, and pasting it into a browser still navigates.
    var localAddress: String? {
        primaryPort.map { "localhost:\($0)" }
    }

    /// The same address as something to open.
    ///
    /// Offered for anything holding a port, without trying to work out whether
    /// it speaks HTTP. Probing answers the wrong question — the node inspector
    /// answers HTTP and is useless to open, while a real vite returned nothing
    /// to a `HEAD` and a workerd returned 400 — and a list of known web tools
    /// goes stale. The cost of guessing wrong here is a browser tab that doesn't
    /// load, which is cheap and obvious, unlike a wrong Quit.
    var localURL: URL? {
        primaryPort.flatMap { URL(string: "http://localhost:\($0)") }
    }

    /// The same job, claimed for a session it has drifted away from.
    func attributed(to session: UUID) -> RunningJob {
        var job = RunningJob(rootPID: rootPID, pgid: pgid, ownsGroup: ownsGroup,
                             sessionID: session, label: label, pids: pids,
                             footprint: footprint, ports: ports, startedAt: startedAt,
                             workingDirectory: workingDirectory, isAgent: isAgent)
        job.detached = true
        return job
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

    /// The part of the picture that is one session's: its jobs, agent included,
    /// and anything it started that has already been filed as an orphan.
    func scoped(to sessionID: UUID) -> RunningJobsSnapshot {
        RunningJobsSnapshot(jobs: jobs(for: sessionID),
                            orphans: orphans.filter { $0.lastSessionID == sessionID })
    }

    /// Everything closing this session has to stop: its work, detached or
    /// not, and anything it started that a scan already filed as an orphan
    /// because the session stopped being listed first.
    func workToStop(for sessionID: UUID) -> [RunningJob] {
        work(for: sessionID) + orphans.filter { $0.lastSessionID == sessionID }
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

    /// What the titlebar's running button says, at a glance and without
    /// opening anything.
    ///
    /// The server is the headline because the server is what you come looking
    /// for: one of them is named (`bun dev`), several are counted, and their
    /// addresses ride alongside, because `:3000` is the fact most often wanted
    /// from this whole feature. Work that serves nothing is only counted.
    var status: RunningStatus {
        let all = work + orphans
        let serving = all.filter { $0.primaryPort != nil }
        let ports = Array(Set(serving.compactMap(\.primaryPort))).sorted()
        var shown = ports.prefix(RunningStatus.maxPorts).map { ":\($0)" }
        if ports.count > RunningStatus.maxPorts {
            shown.append("+\(ports.count - RunningStatus.maxPorts)")
        }
        switch serving.count {
        case 0:
            return RunningStatus(title: all.count == 1 ? all[0].label : "\(all.count) running",
                                 ports: [], isServing: false)
        case 1:
            return RunningStatus(title: serving[0].label, ports: shown, isServing: true)
        default:
            return RunningStatus(title: "\(serving.count) servers", ports: shown, isServing: true)
        }
    }
}

/// The titlebar's running button's content. See `RunningJobsSnapshot.status`.
struct RunningStatus: Equatable {
    /// Two addresses, then a count: past that the pill is a sentence, and the
    /// popover is one click away.
    static let maxPorts = 2

    let title: String
    let ports: [String]
    /// Whether anything is listening, which is what turns the dot green.
    let isServing: Bool
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

    /// What an abandoned group has to be costing to be worth mentioning, when it
    /// is not serving anything.
    ///
    /// A session's own jobs are listed whatever they cost, because you started
    /// them and they are still yours. An orphan is a guess by comparison, and the
    /// guesses that are wrong are small: a `chrome_crashpad_handler` sitting in a
    /// project directory at 2.8 MB is not a server anybody forgot to stop, it is
    /// a helper of a helper. Either hold a port somebody could reach, or be big
    /// enough that stopping it is the point.
    static let orphanFootprintFloor: UInt64 = 20 * 1_048_576

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
        Set(AgentResumeStore.resumeCommands.keys).union(["claude"]).union(unresumableAgents)

    /// Agents Wortel does not know how to resume but must still recognise.
    ///
    /// Recognition and resume are different questions, and this is the list
    /// where getting them confused is expensive: Kimi and Factory droid run a
    /// tool's command **in their own process group** (`create_subprocess_exec`
    /// with no new session; droid's foreground `Execute` passes
    /// `detached: false`), so an unrecognised one is not a hidden agent, it is
    /// a killable row whose Quit ends the user's conversation.
    static let unresumableAgents: Set<String> = ["qwen", "kimi", "droid", "copilot"]

    // MARK: - The scan

    /// Every job under every live session, plus the orphans.
    ///
    /// `excludedPGIDs` keeps Wortel and its keeper out of their own list; the
    /// caller passes its own group.
    ///
    /// `owners` is what earlier scans saw (`recordingOwners`). A group that has
    /// left every shell's tree but holds a process one of them owned is still
    /// that session's: listed under it as `detached` while the session is open,
    /// and as an orphan carrying `lastSessionID` once it is not. Either way it
    /// skips the orphan guesswork below, because it is not a guess.
    static func scan(
        table: [ProcessEntry],
        roots: [SessionProcessRoot],
        projectRoots: [String] = [],
        uid: uid_t = getuid(),
        excludedPGIDs: Set<pid_t> = [],
        owners: ProcessOwners = [:],
        details: ProcessDetails = .live
    ) -> RunningJobsSnapshot {
        guard !table.isEmpty else { return .empty }

        // Reading a process's arguments is a `sysctl` each, and the same
        // processes are read twice: once to decide whether a group is the
        // agent's, once to label it. Memoised for the length of this scan, which
        // is the only span over which the answer cannot change.
        let details = details.memoisingArguments()

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
                if agentPGIDs.contains(pgid) {
                    jobs.append(contentsOf: agentJobs(pgid: pgid, members: members,
                                                      agentName: root.agentName,
                                                      sessionID: root.sessionID,
                                                      parentOf: parentOf, details: details))
                    continue
                }
                jobs.append(contentsOf: RunningJobs.jobs(pgid: pgid, members: members,
                                                        sessionID: root.sessionID,
                                                        isAgent: agentPGIDs.contains(pgid),
                                                        parentOf: parentOf, details: details))
            }
        }

        // What left a shell's tree but was seen starting in one. Before the
        // orphan pass, so a server a session started never has to pass for a
        // stray in a project directory to be found.
        var owned: [RunningJob] = []
        if !owners.isEmpty {
            let open = Set(roots.map(\.sessionID))
            for pgid in membersOf.keys.sorted() where !claimed.contains(pgid) {
                guard let members = membersOf[pgid],
                      members.allSatisfy({ $0.uid == uid }),
                      let owner = members.lazy.compactMap({ owners[ProcessKey($0)] }).first
                else { continue }
                claimed.insert(pgid)
                let shaped = RunningJobs.jobs(pgid: pgid, members: members, sessionID: nil,
                                              isAgent: false, parentOf: parentOf,
                                              details: details)
                for var job in shaped {
                    if open.contains(owner) {
                        job = job.attributed(to: owner)
                        jobs.append(job)
                    } else {
                        job.lastSessionID = owner
                        owned.append(job)
                    }
                }
            }
        }

        // Servers that left a session before any scan saw them there.
        //
        // The shape agents reach for most: `nohup pnpm dev > log 2>&1 &` in a
        // shell tool that returns as soon as the line does. The `sh -c` exits
        // in milliseconds, the server is reparented to launchd, and neither
        // ancestry nor the ownership map above ever saw it under the session.
        // Measured with a real login shell: every such server was invisible.
        //
        // What it cannot shed is its environment. Every session's shell is
        // started with `WORTEL_SESSION_ID`, and whatever it runs inherits it
        // through any number of forks, `setsid`s and `nohup`s. The kernel will
        // not hand over an Apple platform binary's environment, but it does for
        // node, bun, deno, and a Homebrew, uv or nix python, which is what
        // serves a port.
        //
        // Only groups holding a port are claimed, and that is the whole of the
        // test. A tag says where a process was started, not that it is a job:
        // `code .` from a session starts an editor carrying the same variable,
        // and a Quit button on an editor would be wrong. A port is what makes
        // a server, and it is also the line an app bundle cannot be judged by:
        // an Electron or Tauri dev build *is* an `.app` (under `node_modules`,
        // or `target/debug`), and Apple's own python lives inside
        // `Xcode.app/…/Python.app`, so excluding bundles hid a dev app and a
        // `python3 -m http.server` alike. An editor that really is serving
        // something (a Live Server on `:5500`) is a server too.
        // Every tag a live shell hands down, to the session it belongs to: a
        // side terminal's is its tab's id, not the session's.
        var sessionOfTag: [UUID: UUID] = [:]
        for root in roots {
            sessionOfTag[root.sessionID] = root.sessionID
            for tag in root.tags { sessionOfTag[tag] = root.sessionID }
        }
        let openSessions = Set(sessionOfTag.keys)
        // The session each shell's terminal session belongs to. `getsid` is the
        // second half of the answer, and the half that needs no environment:
        // a terminal session changes only when something calls `setsid`, so
        // `( npm run dev & )` and `nohup … &` keep the one their shell had.
        // It is what finds a server on an Apple platform binary, whose
        // environment the kernel will not hand over: `/usr/bin/python3 -m
        // http.server` reads as a session of its own otherwise.
        var sessionOfSID: [pid_t: UUID] = [:]
        for root in roots {
            let sid = details.terminalSession(root.shellPID)
            if sid > 0 { sessionOfSID[sid] = root.sessionID }
        }
        if !openSessions.isEmpty {
            for pgid in membersOf.keys.sorted() where !claimed.contains(pgid) {
                guard let members = membersOf[pgid],
                      members.allSatisfy({ $0.uid == uid }) else { continue }
                let tagged = members.lazy.compactMap({ details.sessionTag($0) })
                    .compactMap({ sessionOfTag[$0] }).first
                // The terminal session is only asked when the environment did
                // not answer: `??` does not evaluate its right side otherwise,
                // and this runs for every group no session's tree holds.
                guard let tag = tagged ?? members.lazy
                    .compactMap({ sessionOfSID[details.terminalSession($0.pid)] }).first
                else { continue }
                let servers = RunningJobs.jobs(pgid: pgid, members: members, sessionID: nil,
                                               isAgent: false, parentOf: parentOf,
                                               details: details)
                    .filter { !$0.ports.isEmpty }
                guard !servers.isEmpty else { continue }
                claimed.insert(pgid)
                jobs.append(contentsOf: servers.map { $0.attributed(to: tag) })
            }
        }

        let orphans = owned + orphans(
            table: table, membersOf: membersOf, parentOf: parentOf, byPID: byPID,
            shellPIDs: shellPIDs, claimed: claimed, projectRoots: projectRoots,
            uid: uid, details: details)

        return RunningJobsSnapshot(jobs: jobs.sorted { $0.footprint > $1.footprint },
                                   orphans: orphans.sorted { $0.footprint > $1.footprint })
    }

    /// Servers first, lowest port first, because the server is what you open
    /// this list to find and its port is how you find it. Everything else after
    /// them, biggest first, since memory is the only thing that sets one build
    /// helper apart from another.
    static func partitioned(_ jobs: [RunningJob]) -> (servers: [RunningJob], others: [RunningJob]) {
        let servers = jobs.filter { $0.primaryPort != nil }
            .sorted { ($0.primaryPort ?? 0, $0.rootPID) < ($1.primaryPort ?? 0, $1.rootPID) }
        let others = jobs.filter { $0.primaryPort == nil }
            .sorted { ($0.footprint, $1.rootPID) > ($1.footprint, $0.rootPID) }
        return (servers, others)
    }

    /// Carry forward who started what.
    ///
    /// Every process in a session's work is recorded against that session, and
    /// every record whose process is gone (or whose pid now belongs to a
    /// different start time) is dropped, so the map is never bigger than what
    /// is running. Agents are left out: the agent is the session, and its HUP
    /// is the shell's business.
    ///
    /// This is what makes a server belong to its session for its whole life.
    /// Ancestry alone forgets the moment the server leaves the shell's tree,
    /// which is precisely the moment it starts to matter: it is the server that
    /// would otherwise outlive the session.
    static func recordingOwners(_ snapshot: RunningJobsSnapshot,
                                table: [ProcessEntry],
                                previous: ProcessOwners) -> ProcessOwners {
        let live = Dictionary(table.map { ($0.pid, ProcessKey($0)) },
                              uniquingKeysWith: { first, _ in first })
        var owners = previous.filter { live[$0.key.pid] == $0.key }
        for job in snapshot.work {
            guard let session = job.sessionID else { continue }
            for pid in job.pids {
                if let key = live[pid] { owners[key] = session }
            }
        }
        return owners
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
        let isAgent = agentMatcher(named: agent, details: details)
        var groups: Set<pid_t> = []
        for entry in table
        where ProcessTable.isDescendant(entry.pid, of: shellPID, parentOf: parentOf)
            && isAgent(entry) {
            groups.insert(entry.pgid)
        }
        return groups
    }

    /// Whether a process is itself one of the agents, by name first and argv
    /// for whatever the name misses. See `agentGroups`.
    static func agentMatcher(named agent: String?,
                             details: ProcessDetails) -> (ProcessEntry) -> Bool {
        var names = knownAgents
        if let agent, !agent.isEmpty { names.insert(agent) }
        // `p_comm` is truncated, so each name needs its short form too.
        var truncated: Set<String> = []
        for name in names {
            truncated.insert(String(name.prefix(ProcessTable.maxCommandNameLength - 1)))
        }
        return { entry in
            let comm = plainName(entry.name)
            if names.contains(comm) || truncated.contains(comm) { return true }
            // The argv pass, for agents whose process is named after their
            // interpreter (Pi, Gemini, aider) or after their own version
            // (`claude` reports `p_comm` as `2.1.267`).
            return namesAgent(in: details.arguments(entry.pid), among: names)
        }
    }

    /// The agent's group as rows: the agent, plus any server it started without
    /// giving it a group of its own.
    ///
    /// A job is a process group, and an agent's shell tool normally keeps to
    /// that: Claude Code's `zsh -c` and Pi's own bash tool each start a new
    /// group. A Pi extension's background-job tool did not. On a real machine
    /// `pi` (19665) led a group holding `chrome-devtools-mcp`, then
    /// `pnpm run preview` and the vite under it serving `:5188`, all pgid 19665.
    /// The whole group was the agent, the agent is never work, and the server
    /// the session was running vanished from the pill and the list.
    ///
    /// So a child of the agent whose tree holds a listening port is split out
    /// as work. Only one holding a port: the agent's other children are its
    /// scaffolding (an MCP server over stdio), and a Quit button on one of those
    /// breaks the agent mid-turn. A split job never owns the group, which is
    /// the agent's, so stopping it signals its own processes and never
    /// `-pgid`.
    static func agentJobs(
        pgid: pid_t,
        members: [ProcessEntry],
        agentName: String?,
        sessionID: UUID,
        parentOf: [pid_t: pid_t],
        details: ProcessDetails
    ) -> [RunningJob] {
        let isAgent = agentMatcher(named: agentName, details: details)
        let agentPIDs = Set(members.filter(isAgent).map(\.pid))
        var childrenOf: [pid_t: [ProcessEntry]] = [:]
        for member in members {
            if let parent = parentOf[member.pid] { childrenOf[parent, default: []].append(member) }
        }

        var splitOff: Set<pid_t> = []
        var servers: [RunningJob] = []
        // The agent's children, and anything in its group whose parent is not:
        // `exec("pnpm dev &")` leaves the server in the agent's group but
        // adopted by launchd once its `sh -c` returns.
        let inGroup = Set(members.map(\.pid))
        let candidates = members
            .filter { member in
                guard !agentPIDs.contains(member.pid) else { return false }
                let parent = parentOf[member.pid] ?? 0
                return agentPIDs.contains(parent) || !inGroup.contains(parent)
            }
            .sorted { $0.pid < $1.pid }
        for child in candidates {
            var tree: [ProcessEntry] = []
            var queue = [child]
            while !queue.isEmpty {
                let entry = queue.removeFirst()
                // A sub-agent under it stays the agent's.
                guard !agentPIDs.contains(entry.pid),
                      !tree.contains(where: { $0.pid == entry.pid }) else { continue }
                tree.append(entry)
                queue.append(contentsOf: (childrenOf[entry.pid] ?? []).sorted { $0.pid < $1.pid })
            }
            guard tree.contains(where: { !displayPorts(details.listeningPorts($0.pid)).isEmpty }),
                  let server = job(pgid: pgid, tree: tree, ownsGroup: false,
                                   sessionID: sessionID, isAgent: false, details: details)
            else { continue }
            servers.append(server)
            splitOff.formUnion(tree.map(\.pid))
        }

        let rest = members.filter { !splitOff.contains($0.pid) }
        return servers + jobs(pgid: pgid, members: rest, sessionID: sessionID, isAgent: true,
                              parentOf: parentOf, details: details)
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
    /// `zsh -c 'source /Users/me/.claude/shell-snapshots/snapshot-zsh-….sh …'`,
    /// so every job an agent starts carries a mention of `.claude` in its
    /// command string. Both of a session's dev servers were classified as the
    /// agent and vanished from the list they existed for.
    ///
    /// Within those three it looks only where a program's *name* lives, not at
    /// every directory on the way to it. Matching any path component made
    /// `/Users/x/claude-demo/server.js` Claude Code and
    /// `/Users/x/Developer/pi-site/…/vite` Pi, because `claude-demo` starts
    /// with `claude-`, and the server vanished into the agent's row.
    static func namesAgent(in arguments: [String], among names: Set<String>) -> Bool {
        for argument in arguments.prefix(3) where !argument.isEmpty {
            // A flag is never a program name, and `-c` is what precedes the
            // command string this rule exists to ignore.
            guard !argument.hasPrefix("-") else { continue }
            if names.contains(where: { programNames($0, argument) }) {
                return true
            }
        }
        return false
    }

    /// Whether this path is the agent's program: its file (`…/bin/aider`,
    /// `aider.py`, `claude`), or a file inside its installed package
    /// (`node_modules/@earendil-works/pi-coding-agent/dist/cli.js`,
    /// `@google/gemini-cli/dist/index.js`).
    static func programNames(_ agent: String, _ argument: String) -> Bool {
        let components = argument.split(separator: "/")
        guard let file = components.last else { return false }
        let name = plainName(String(file))
        if name == agent || name.hasPrefix(agent + ".") { return true }
        // A package directory: the component after `node_modules`, or after
        // an `@scope`. The only places a directory is named for the program in
        // it rather than for the project around it.
        for (index, component) in components.dropLast().enumerated() {
            guard component == "node_modules" || component.hasPrefix("@") else { continue }
            let package = components[index + 1]
            if package == agent[...] || package.hasPrefix(agent + "-") { return true }
        }
        return false
    }

    /// A program's name with the decoration a packager put on it: the dot and
    /// `-wrapped` nixpkgs' `wrapProgram` leaves behind (`.pi-wrapped`), and the
    /// `.exe` Bun-compiled binaries carry on macOS too (`amp.exe`). Both are
    /// what `p_comm` and the executable path then read as, and neither is a
    /// different program.
    static func plainName(_ name: String) -> String {
        var name = name
        if name.hasPrefix(".") { name.removeFirst() }
        for suffix in ["-wrapped", ".exe"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
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

        // Every pid under any session, worked out once. The membership test used
        // to walk each candidate's parent chain once per session, which is the
        // same answer computed over and over: with nine sessions and eight
        // hundred processes it was most of the cost of the whole scan.
        var underSession: Set<pid_t> = []
        for entry in table where shellPIDs.contains(entry.pid)
            || shellPIDs.contains(where: {
                ProcessTable.isDescendant(entry.pid, of: $0, parentOf: parentOf)
            }) {
            underSession.insert(entry.pid)
        }

        var found: [RunningJob] = []
        var seen = claimed

        for pgid in Set(table.map(\.pgid)).sorted() {
            guard !seen.contains(pgid), let members = membersOf[pgid] else { continue }
            guard members.allSatisfy({ $0.uid == uid }) else { continue }
            // Anything still under a live session is that session's, not an orphan.
            guard !members.contains(where: { underSession.contains($0.pid) }) else { continue }
            // A group whose leader is still alive and parented normally is
            // somebody else's business — a login shell, an app's helper.
            guard byPID[pgid] == nil || members.contains(where: { $0.ppid <= 1 }) else { continue }

            seen.insert(pgid)
            for tree in independentTrees(members, parentOf: parentOf) {
                // The directory decides whether this is ours at all, and it is
                // one cheap syscall. Asked *before* the job is built, because
                // building one reads arguments for every process in the tree and
                // almost every candidate here is about to be thrown away.
                guard tree.contains(where: { member in
                    guard let cwd = details.workingDirectory(member.pid) else { return false }
                    return projectRoots.contains { FolderRoot.root($0, contains: cwd) }
                }) else { continue }

                guard let candidate = job(pgid: pgid, tree: tree,
                                          ownsGroup: members.count == tree.count,
                                          sessionID: nil, isAgent: false, details: details),
                      candidate.workingDirectory != nil,
                      !candidate.ports.isEmpty || candidate.footprint >= orphanFootprintFloor
                else { continue }
                found.append(candidate)
            }
        }
        return found
    }

    // MARK: - One group

    /// Shape one process group into a row, or nil when it has nothing to say.
    /// Shape one process group into rows: usually one, sometimes several.
    ///
    /// A group holds one job when a shell started it, which is what an
    /// interactive shell and an agent's `zsh -c` both do. It holds *several*
    /// when one command starts several: `bun dev` fanning out to `dev:web` and
    /// `dev:images` leaves two independent trees sharing a group, and reporting
    /// that as one row named after whichever came first hides the second
    /// server's port and puts a Quit on a row that would stop both.
    ///
    /// So the split is by tree: every member with no parent inside the group
    /// starts a job, and its descendants within the group belong to it.
    static func jobs(
        pgid: pid_t,
        members: [ProcessEntry],
        sessionID: UUID?,
        isAgent: Bool,
        parentOf: [pid_t: pid_t],
        details: ProcessDetails
    ) -> [RunningJob] {
        let trees = independentTrees(members, parentOf: parentOf)
        return trees.compactMap {
            job(pgid: pgid, tree: $0, ownsGroup: trees.count == 1, sessionID: sessionID,
                isAgent: isAgent, details: details)
        }
    }

    /// The members of a group split into the separate trees it contains,
    /// outermost first within each.
    static func independentTrees(_ members: [ProcessEntry],
                                 parentOf: [pid_t: pid_t]) -> [[ProcessEntry]] {
        let inGroup = Set(members.map(\.pid))
        var childrenOf: [pid_t: [ProcessEntry]] = [:]
        var roots: [ProcessEntry] = []
        for member in members {
            if let parent = parentOf[member.pid], inGroup.contains(parent) {
                childrenOf[parent, default: []].append(member)
            } else {
                roots.append(member)
            }
        }
        // A group that is entirely a cycle (a torn table) has no root to start
        // from; treat the whole thing as one tree rather than losing it.
        guard !roots.isEmpty else { return [members.sorted { $0.pid < $1.pid }] }

        return roots.sorted { $0.pid < $1.pid }.map { root in
            var tree: [ProcessEntry] = []
            var queue = [root]
            var visited: Set<pid_t> = []
            while !queue.isEmpty {
                let entry = queue.removeFirst()
                guard visited.insert(entry.pid).inserted else { continue }
                tree.append(entry)
                queue.append(contentsOf: (childrenOf[entry.pid] ?? []).sorted { $0.pid < $1.pid })
            }
            return tree
        }
    }

    private static func job(
        pgid: pid_t,
        tree ordered: [ProcessEntry],
        ownsGroup: Bool,
        sessionID: UUID?,
        isAgent: Bool,
        details: ProcessDetails
    ) -> RunningJob? {
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
            rootPID: head.pid,
            pgid: pgid,
            ownsGroup: ownsGroup,
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
    /// `node /Users/me/Developer/…/node_modules/.bin/vite dev`.
    static func label(forArguments arguments: [String]) -> String? {
        // `arguments` is [executable path, argv0, argv1, …]; argv0 is the more
        // honest name (it is what the user typed), so prefer it and fall back.
        var tokens = Array(arguments.dropFirst())
        if tokens.isEmpty { tokens = Array(arguments.prefix(1)) }
        tokens = tokens.filter { !$0.isEmpty && !isEnvironmentAssignment($0) }
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

    /// Whether a token is a `NAME=value` environment assignment rather than
    /// part of the command.
    ///
    /// Two reasons, and the second is why it matters. `FOO=1 npm run dev` puts
    /// the assignment in argv, and it is not what the job is called. And a
    /// program that renames its own process (`process.title = "pi"`, which Pi
    /// does) writes over the argv area, so the read comes back as the new name
    /// followed by whatever of the old argv and **the environment** is still
    /// lying there: the real label was
    /// `pi CLAUDE_CODE_MESSAGING_TOKEN=34af1b03…`. A row in the popover is not
    /// the place for the contents of someone's environment.
    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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

extension ProcessDetails {
    /// The same reads, with `arguments` answered once per process.
    ///
    /// Valid only for the span of a single scan: a pid's arguments are fixed for
    /// its lifetime, but a pid is not.
    func memoisingArguments() -> ProcessDetails {
        final class Cache { var values: [pid_t: [String]] = [:] }
        let cache = Cache()
        let read = arguments
        var copy = self
        copy.arguments = { pid in
            if let cached = cache.values[pid] { return cached }
            let value = read(pid)
            cache.values[pid] = value
            return value
        }
        return copy
    }
}
