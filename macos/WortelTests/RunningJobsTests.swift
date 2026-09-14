import XCTest

/// A job is a process group, and getting the grouping wrong doesn't throw — it
/// puts a Quit button on the wrong row. That is the whole reason this is pinned:
/// the failure mode is a user losing an agent mid-turn because a kill reached
/// further than the row it was attached to.
///
/// The fixture is a real session, transcribed from a live machine:
///
///     zsh [37499] pgid 37499                       <- the session shell
///       claude [37616] pgid 37616                  <- the agent, own group
///         zsh -c … [15614] pgid 15614              <- job 1's leader
///           bun dev:web [15616] pgid 15614
///             bun [15617] pgid 15614
///               node …/vite dev [15618] pgid 15614   :3000 :9231 :49748
///                 workerd [15623] pgid 15614         :49749
///         zsh -c … [15631] pgid 15631              <- job 2's leader
///           bun dev:images [15633] pgid 15631
///
/// The nesting is the point. "Child of the session shell" would have produced
/// one row called `claude` and nothing else.
final class RunningJobsTests: XCTestCase {

    private let sessionID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Fixture

    private func entry(_ pid: pid_t, _ ppid: pid_t, _ pgid: pid_t, _ name: String,
                       uid: uid_t = 501, ageSeconds: TimeInterval = 0) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, pgid: pgid, uid: uid, name: name,
                     startedAt: t0.addingTimeInterval(ageSeconds))
    }

    /// The tree above.
    private var table: [ProcessEntry] {
        [
            entry(37499, 37498, 37499, "zsh"),
            entry(37616, 37499, 37616, "2.1.267"),        // claude renames itself
            entry(15614, 37616, 15614, "zsh"),
            entry(15616, 15614, 15614, "bun"),
            entry(15617, 15616, 15614, "bun"),
            entry(15618, 15617, 15614, "node", ageSeconds: 5),
            entry(15623, 15618, 15614, "workerd", ageSeconds: 7),
            entry(15631, 37616, 15631, "zsh"),
            entry(15633, 15631, 15631, "bun"),
        ]
    }

    private let argv: [pid_t: [String]] = [
        37499: ["/bin/zsh", "-zsh"],
        37616: ["/Users/giel/.local/bin/claude", "claude"],
        15614: ["/bin/zsh", "zsh", "-c", "source /Users/giel/.claude/shell-snapshots/snapshot-zsh-17"],
        15616: ["/usr/local/bin/bun", "bun", "dev:web"],
        15617: ["/usr/local/bin/bun", "bun", "--cwd", "workers/web", "dev"],
        15618: ["/opt/node", "node", "/Users/giel/dev/node_modules/.bin/vite", "dev"],
        15623: ["/opt/workerd", "workerd", "serve"],
        15631: ["/bin/zsh", "zsh", "-c", "source /Users/giel/.claude/shell-snapshots/snapshot-zsh-17"],
        15633: ["/usr/local/bin/bun", "bun", "dev:images"],
    ]

    private let footprints: [pid_t: UInt64] = [
        37499: 2_000_000, 37616: 408_700_000,
        15614: 2_000_000, 15616: 2_600_000, 15617: 2_700_000,
        15618: 572_000_000, 15623: 133_400_000,
        15631: 2_000_000, 15633: 2_800_000,
        // The real orphan's three survivors, as measured: 385 MB between them.
        38938: 1_280_000, 38940: 176_100_000, 38942: 162_000_000,
    ]

    private let ports: [pid_t: [Int]] = [
        15618: [3000, 9231, 49748],
        15623: [49749, 49750],
    ]

    /// The orphan's own arguments, kept apart so one test can take them away
    /// and check that an unreadable argv doesn't cost us the row.
    private let orphanArgv: [pid_t: [String]] = [
        38938: ["/opt/node", "node", "/Users/giel/dev/node_modules/.bin/wrangler", "dev"],
        38940: ["/opt/node", "node", "--enable-source-maps", "worker.js"],
        38942: ["/opt/workerd", "workerd", "serve"],
    ]

    private func details(cwd: [pid_t: String] = [:],
                         extraArgv: [pid_t: [String]] = [:]) -> ProcessDetails {
        let argv = self.argv.merging(extraArgv) { _, new in new }
        return ProcessDetails(
            arguments: { argv[$0] ?? [] },
            footprint: { [footprints] in footprints[$0] ?? 0 },
            listeningPorts: { [ports] in ports[$0] ?? [] },
            workingDirectory: { cwd[$0] })
    }

    private var root: SessionProcessRoot {
        SessionProcessRoot(sessionID: sessionID, shellPID: 37499, agentName: "claude")
    }

    private func scan(projectRoots: [String] = [],
                      cwd: [pid_t: String] = [:]) -> RunningJobsSnapshot {
        RunningJobs.scan(table: table, roots: [root], projectRoots: projectRoots,
                         uid: 501, details: details(cwd: cwd))
    }

    // MARK: - Grouping

    /// Three groups under the shell: the agent, and one per `bun dev` job. The
    /// shell's own group is not a job — it is the session.
    func testGroupsBecomeOneRowEach() {
        let jobs = scan().jobs
        XCTAssertEqual(Set(jobs.map(\.pgid)), [37616, 15614, 15631],
                       "each process group is one row, and the shell's own group is not a job")
        XCTAssertFalse(jobs.contains { $0.pgid == 37499 },
                       "the session's shell is the session, never a job you can quit")
    }

    /// The five processes of `bun dev:web` are one row, not five.
    func testAWholeGroupCollapsesIntoOneRow() throws {
        let web = try XCTUnwrap(scan().jobs.first { $0.pgid == 15614 })
        XCTAssertEqual(web.processCount, 5,
                       "leader, two buns, node and workerd are one job between them")
    }

    /// The keeper forks `/usr/bin/login`, so the pid it reports is login's and
    /// the real shell gets a session (and a process group) of its own. Left
    /// alone that shell is indistinguishable from a job, and every session grew
    /// a permanent `zsh -l` row holding 4 MB of nothing.
    func testTheLoginShellIsNotAJob() {
        // The real shape: keeper -> login(37498) -> -/bin/zsh(37499), each in
        // its own group, with the reported pid being login's.
        let withLogin = [entry(37498, 65344, 37498, "login")] + table
        let argvWithLogin = argv.merging([37499: ["/bin/zsh", "-/bin/zsh", "-l"]]) { _, new in new }
        let snapshot = RunningJobs.scan(
            table: withLogin,
            roots: [SessionProcessRoot(sessionID: sessionID, shellPID: 37498, agentName: "claude")],
            uid: 501, details: details(extraArgv: argvWithLogin))

        XCTAssertFalse(snapshot.jobs.contains { $0.pgid == 37499 },
                       "the login shell is the session, not something running in it")
        XCTAssertEqual(Set(snapshot.work.map(\.pgid)), [15614, 15631],
                       "what is left is the two dev servers, which is the point")
    }

    func testLoginShellDetection() {
        XCTAssertTrue(RunningJobs.isLoginShell(["/bin/zsh", "-/bin/zsh", "-l"]),
                      "login marks a login shell by prefixing argv0 with a dash")
        XCTAssertTrue(RunningJobs.isLoginShell(["/bin/bash", "-bash"]))
        XCTAssertFalse(RunningJobs.isLoginShell(["/bin/zsh", "zsh", "-l"]),
                       "a shell you started yourself is a job like any other")
        XCTAssertFalse(RunningJobs.isLoginShell(["/usr/local/bin/bun", "bun", "dev:web"]))
        XCTAssertFalse(RunningJobs.isLoginShell(["/opt/thing", "-flaglike"]),
                       "a dash alone is not enough; it has to name a shell")
    }

    // MARK: - Agents are accounted for, not listed

    /// The first build of the list was five `claude` rows and five `zsh -l` rows
    /// with the two dev servers it exists for buried in the middle.
    func testWorkExcludesTheAgent() {
        XCTAssertEqual(Set(scan().work.map(\.pgid)), [15614, 15631])
        XCTAssertEqual(scan().agents.map(\.pgid), [37616])
        XCTAssertEqual(scan().agentFootprint, 408_700_000,
                       "the agents still have to add up somewhere, just not in a row each")
    }

    /// The marker file is a hint, not the source of truth. On a real machine the
    /// marker directory was empty while eleven agents were running, so every one
    /// of them was listed as a stray job with a Quit button on it.
    func testAgentsAreRecognisedWithoutAMarker() {
        let unmarked = SessionProcessRoot(sessionID: sessionID, shellPID: 37499,
                                          agentName: nil)
        let snapshot = RunningJobs.scan(table: table, roots: [unmarked], uid: 501,
                                        details: details())
        XCTAssertEqual(snapshot.agents.map(\.pgid), [37616],
                       "claude is claude whether or not the shell integration said so")
        XCTAssertEqual(Set(snapshot.work.map(\.pgid)), [15614, 15631])
    }

    /// Claude Code runs its sub-agents as further `claude` processes in groups of
    /// their own. Matching only the first put a Quit button on all the rest.
    func testEverySubAgentGroupCountsAsTheAgent() {
        let withSubAgent = table + [
            entry(15700, 37616, 15700, "2.1.267"),
            entry(15701, 15700, 15700, "2.1.267"),
        ]
        let extra: [pid_t: [String]] = [
            15700: ["/Users/giel/.local/bin/claude", "claude"],
            15701: ["/Users/giel/.local/bin/claude", "claude"],
        ]
        let snapshot = RunningJobs.scan(
            table: withSubAgent, roots: [root], uid: 501,
            details: details(extraArgv: extra))
        XCTAssertEqual(Set(snapshot.agents.map(\.pgid)), [37616, 15700])
        XCTAssertFalse(snapshot.work.contains { $0.pgid == 15700 },
                       "a sub-agent is the agent, not a stray process")
    }

    /// The bug that hid both of a session's dev servers.
    ///
    /// Claude Code's shell tool runs `zsh -c 'source
    /// ~/.claude/shell-snapshots/snapshot-….sh && …'`, so every job an agent
    /// starts carries a mention of `.claude` in its command string. Matching an
    /// agent name anywhere in argv classified both `bun dev` groups as the agent
    /// and dropped them from the list they exist for.
    func testACommandMentioningAnAgentIsNotAnAgent() {
        let snapshotCommand = "source /Users/giel/.claude/shell-snapshots/"
            + "snapshot-zsh-1789042062507-8nxo0e.sh 2>/dev/null || true && bun dev:web"
        let extra: [pid_t: [String]] = [
            15614: ["/bin/zsh", "zsh", "-c", snapshotCommand],
            15631: ["/bin/zsh", "zsh", "-c", snapshotCommand],
        ]
        let snapshot = RunningJobs.scan(table: table, roots: [root], uid: 501,
                                        details: details(extraArgv: extra))
        XCTAssertEqual(Set(snapshot.work.map(\.pgid)), [15614, 15631],
                       "a path in a command string is not the program being run")
        XCTAssertEqual(snapshot.agents.map(\.pgid), [37616])
    }

    func testAgentMatchingLooksAtTheProgramNotTheCommandLine() {
        let names: Set<String> = ["claude", "pi", "aider"]
        XCTAssertTrue(RunningJobs.namesAgent(
            in: ["/Users/giel/.local/bin/claude", "claude"], among: names))
        XCTAssertTrue(RunningJobs.namesAgent(
            in: ["/opt/node", "node", "/x/pi-coding-agent/dist/cli.js"], among: names),
            "a script agent is named by the script, which is argv[1]")
        XCTAssertFalse(RunningJobs.namesAgent(
            in: ["/bin/zsh", "zsh", "-c", "source ~/.claude/x.sh && bun dev"], among: names),
            "the command string is not the program")
        XCTAssertFalse(RunningJobs.namesAgent(
            in: ["/usr/local/bin/bun", "bun", "dev:web"], among: names))
    }

    // MARK: - Shells other than zsh

    /// Wortel ships integration for bash, elvish, fish, nushell and zsh, and a
    /// shell missing from the list costs an unreadable label and an unwanted row.
    func testEveryShippedShellIsRecognised() {
        for shell in ["zsh", "bash", "fish", "elvish", "nu"] {
            XCTAssertTrue(
                RunningJobs.isLoginShell(["/bin/\(shell)", "-\(shell)"]),
                "\(shell) started as a login shell is the session, not a job")
            XCTAssertTrue(
                RunningJobs.isWrapper(["/bin/\(shell)", shell, "-c", "bun dev"]),
                "\(shell) handed a command is scaffolding around that command")
        }
    }

    /// The login shell is found the same way whatever shell it is, because the
    /// dash-prefixed argv[0] is `login`'s convention, not zsh's.
    func testALoginShellOtherThanZshIsStillTheSession() {
        let withFish = [
            entry(37498, 65344, 37498, "login"),
            entry(37499, 37498, 37499, "fish"),
            entry(15614, 37499, 15614, "fish"),
            // A child of the wrapper, which is what a shell actually produces.
            entry(15616, 15614, 15614, "bun"),
        ]
        let argvFish: [pid_t: [String]] = [
            37499: ["/opt/homebrew/bin/fish", "-/opt/homebrew/bin/fish", "-l"],
            15614: ["/opt/homebrew/bin/fish", "fish", "-c", "bun dev:web"],
            15616: ["/usr/local/bin/bun", "bun", "dev:web"],
        ]
        let snapshot = RunningJobs.scan(
            table: withFish,
            roots: [SessionProcessRoot(sessionID: sessionID, shellPID: 37498, agentName: nil)],
            uid: 501, details: details(extraArgv: argvFish))
        XCTAssertEqual(snapshot.work.map(\.pgid), [15614])
        XCTAssertEqual(snapshot.work.first?.label, "bun dev:web",
                       "the label looks past a fish wrapper exactly as it does a zsh one")
    }

    func testCommandWrappersAreLookedThrough() {
        XCTAssertTrue(RunningJobs.isWrapper(["/usr/bin/env", "env", "FOO=1"]))
        XCTAssertTrue(RunningJobs.isWrapper(["/usr/bin/sudo", "sudo", "systemctl"]))
        XCTAssertTrue(RunningJobs.isWrapper(["/usr/bin/nohup", "nohup", "server"]))
        XCTAssertFalse(RunningJobs.isWrapper(["/opt/node", "node", "server.js"]))
    }

    /// A session with an agent and nothing else is a session that is open, not a
    /// machine with something running on it.
    func testAgentsAloneAreNotWork() {
        let quiet = [entry(37499, 37498, 37499, "zsh"), entry(37616, 37499, 37616, "2.1.267")]
        let snapshot = RunningJobs.scan(table: quiet, roots: [root], uid: 501,
                                        details: details())
        XCTAssertFalse(snapshot.hasWork,
                       "the toolbar item would otherwise be there permanently")
        XCTAssertFalse(snapshot.agents.isEmpty, "the agent is still accounted for")
    }

    // MARK: - One group, several jobs

    /// The shape that broke the model, transcribed from the machine.
    ///
    /// `bun dev` fanned out to `dev:web` and `dev:images`, and both trees ended
    /// up in **one** process group (71584), with :3000 in one and :3002 in the
    /// other. Reported as a single job it read as `bun dev:web` at :3000 with
    /// nothing to say that :3002 existed, and its Quit would have stopped both.
    private var sharedGroup: [ProcessEntry] {
        [
            entry(71587, 1, 71584, "bun"),          // dev:web tree
            entry(71591, 71587, 71584, "bun"),
            entry(71613, 71591, 71584, "workerd"),
            entry(71589, 1, 71584, "bun"),          // dev:images tree
            entry(71592, 71589, 71584, "bun"),
            entry(71605, 71592, 71584, "workerd"),
        ]
    }

    private func sharedGroupDetails() -> ProcessDetails {
        let argv: [pid_t: [String]] = [
            71587: ["/usr/local/bin/bun", "bun", "dev:web"],
            71591: ["/usr/local/bin/bun", "bun", "--cwd", "workers/web", "dev"],
            71613: ["/opt/workerd", "workerd", "serve"],
            71589: ["/usr/local/bin/bun", "bun", "dev:images"],
            71592: ["/usr/local/bin/bun", "bun", "--cwd", "workers/images", "dev"],
            71605: ["/opt/workerd", "workerd", "serve"],
        ]
        return ProcessDetails(
            arguments: { argv[$0] ?? [] },
            footprint: { _ in 100_000_000 },
            listeningPorts: { [71613: [3000], 71605: [3002]][$0] ?? [] },
            workingDirectory: { _ in "/Users/giel/dev/gielcobben-2026" })
    }

    func testOneGroupHoldingTwoServersBecomesTwoRows() {
        let snapshot = RunningJobs.scan(
            table: sharedGroup, roots: [], projectRoots: ["/Users/giel/dev"],
            uid: 501, details: sharedGroupDetails())
        XCTAssertEqual(snapshot.orphans.map(\.label).sorted(), ["bun dev:images", "bun dev:web"],
                       "one command starting two servers is two jobs, not one")
        XCTAssertEqual(snapshot.orphans.map(\.primaryPort).sorted { ($0 ?? 0) < ($1 ?? 0) },
                       [3000, 3002],
                       ":3002 was collected and then hidden behind the lower port")
    }

    /// The reason the split matters more than the label: a Quit on a shared
    /// group would have signalled the other server too.
    func testAJobSharingItsGroupDoesNotOwnIt() {
        let snapshot = RunningJobs.scan(
            table: sharedGroup, roots: [], projectRoots: ["/Users/giel/dev"],
            uid: 501, details: sharedGroupDetails())
        XCTAssertTrue(snapshot.orphans.allSatisfy { !$0.ownsGroup },
                      "neither job is the whole group, so neither may kill(-pgid)")
        for job in snapshot.orphans {
            XCTAssertEqual(job.pids.count, 3, "each row covers its own tree only")
        }
    }

    /// A group with one tree still owns it, so the whole-group kill is kept
    /// where it is correct.
    func testASoleJobStillOwnsItsGroup() throws {
        let web = try XCTUnwrap(scan().work.first { $0.pgid == 15614 })
        XCTAssertTrue(web.ownsGroup)
    }

    func testShownPortsCarriesEveryMeaningfulPort() {
        let job = RunningJob(rootPID: 1, pgid: 1, ownsGroup: true, sessionID: nil,
                             label: "x", pids: [1], footprint: 0,
                             ports: [3000, 3002, 9229], startedAt: t0,
                             workingDirectory: nil, isAgent: false)
        XCTAssertEqual(job.shownPorts, [3000, 3002], "the inspector port is still not one you meant")
    }

    // MARK: - The agent

    /// The agent is listed, because it was 409 MB of this session's total and a
    /// sum that skipped it would not match the rows above it. It is never
    /// killable.
    func testAgentIsListedButNeverKillable() throws {
        let agent = try XCTUnwrap(scan().jobs.first { $0.pgid == 37616 })
        XCTAssertTrue(agent.isAgent)
        XCTAssertFalse(agent.isKillable,
                       "quitting the agent is the user's conversation, not a stray server")
        XCTAssertTrue(scan().jobs.filter { $0.pgid != 37616 }.allSatisfy(\.isKillable),
                      "everything that isn't the agent or the shell can be quit")
    }

    // MARK: - Labels

    /// The group leader is `zsh -c source …`, which describes nothing. The label
    /// has to look past it to the first real program.
    func testLabelLooksPastTheShellWrapper() throws {
        let web = try XCTUnwrap(scan().jobs.first { $0.pgid == 15614 })
        XCTAssertEqual(web.label, "bun dev:web",
                       "the leader is scaffolding; the job is what it was told to run")
        let images = try XCTUnwrap(scan().jobs.first { $0.pgid == 15631 })
        XCTAssertEqual(images.label, "bun dev:images")
    }

    /// `p_comm` for the agent is literally the version string it renames itself
    /// to. Labels come from argv or they are nonsense.
    func testLabelIgnoresProcessName() throws {
        let agent = try XCTUnwrap(scan().jobs.first { $0.pgid == 37616 })
        XCTAssertEqual(agent.label, "claude",
                       "p_comm here is \"2.1.267\", which names nothing a person would recognise")
    }

    func testLabelStripsPathsAndLeadingRuntime() {
        XCTAssertEqual(
            RunningJobs.label(forArguments: ["/opt/node", "node", "/a/b/.bin/vite", "dev"]),
            "vite dev", "a runtime plus a script is named for the script")
        XCTAssertEqual(RunningJobs.label(forArguments: ["/opt/node", "node"]), "node",
                       "a bare REPL keeps its own name, because nothing follows it")
        XCTAssertNil(RunningJobs.label(forArguments: []))
    }

    func testLabelIsTruncatedRatherThanAllowedToRunAway() throws {
        let long = ["/bin/x", "x"] + Array(repeating: "argument-that-is-long", count: 6)
        let label = try XCTUnwrap(RunningJobs.label(forArguments: long))
        XCTAssertLessThanOrEqual(label.count, 48, "a row is not a place for a full command line")
    }

    // MARK: - Ports

    /// Eleven of fifteen ports on the real session were the kernel's anonymous
    /// numbers. Showing them buries the one the user typed into a browser.
    func testEphemeralAndDuplicatePortsAreDropped() throws {
        let web = try XCTUnwrap(scan().jobs.first { $0.pgid == 15614 })
        XCTAssertEqual(web.ports, [3000, 9231],
                       "49748 and up are handed out, not chosen")
        XCTAssertEqual(web.primaryPort, 3000,
                       "9231 is node's inspector; :3000 is the one that means something")
    }

    /// A job whose only ports are ephemeral has no port worth showing, which is
    /// exactly the four-day-old orphan that turned out to be serving nothing.
    func testAJobWithOnlyEphemeralPortsShowsNone() {
        XCTAssertEqual(RunningJobs.displayPorts([49749, 49750, 63788]), [])
    }

    // MARK: - Addresses

    /// **`localhost`, never `127.0.0.1`.** Measured against a real vite: it was
    /// listening on `[::1]:3000` and nothing else, so `http://127.0.0.1:3000`
    /// was refused outright while `http://localhost:3000` answered 200. A v4
    /// literal here would break the most common case the feature exists for.
    func testTheAddressIsLocalhostAndNotAnIPv4Literal() throws {
        let web = try XCTUnwrap(scan().work.first { $0.pgid == 15614 })
        XCTAssertEqual(web.localAddress, "localhost:3000")
        XCTAssertEqual(web.localURL?.absoluteString, "http://localhost:3000")
        XCTAssertFalse(web.localAddress?.contains("127.0.0.1") ?? true,
                       "node tooling commonly binds the IPv6 loopback only")
    }

    /// Host and port, not a URL: it has to serve the rows that are not web
    /// servers, where `localhost:6379` is what the client wants.
    func testTheAddressCarriesNoScheme() throws {
        let web = try XCTUnwrap(scan().work.first { $0.pgid == 15614 })
        XCTAssertFalse(web.localAddress?.contains("http") ?? true)
    }

    /// A job with nothing listening has no address, so the row has nothing to
    /// open and says so by having no link.
    func testAJobWithNoPortHasNoAddress() {
        let quiet = RunningJob(rootPID: 10, pgid: 10, ownsGroup: true,
                               sessionID: nil, label: "tsc --watch",
                               pids: [10], footprint: 1_000, ports: [], startedAt: t0,
                               workingDirectory: nil, isAgent: false)
        XCTAssertNil(quiet.localAddress)
        XCTAssertNil(quiet.localURL)
    }

    // MARK: - Footprint

    func testFootprintSumsTheWholeGroup() throws {
        let web = try XCTUnwrap(scan().jobs.first { $0.pgid == 15614 })
        XCTAssertEqual(web.footprint, 2_000_000 + 2_600_000 + 2_700_000 + 572_000_000 + 133_400_000)
    }

    /// The session total includes the agent, so the header matches the rows.
    func testSessionFootprintIncludesTheAgent() {
        let snapshot = scan()
        XCTAssertEqual(snapshot.footprint(for: sessionID),
                       snapshot.jobs.reduce(0) { $0 + $1.footprint })
        XCTAssertGreaterThan(snapshot.footprint(for: sessionID), 408_700_000,
                             "a total that hid the agent would not add up on screen")
    }

    // MARK: - Orphans

    /// The real orphan: a group whose leader died days ago, whose survivors were
    /// reparented to launchd, and which still shares one pgid. Nothing about the
    /// kill path needs to be different for it.
    private var orphanTable: [ProcessEntry] {
        table + [
            entry(38938, 1, 38931, "node", ageSeconds: -346_000),
            entry(38940, 38938, 38931, "node", ageSeconds: -346_000),
            entry(38942, 38940, 38931, "workerd", ageSeconds: -346_000),
        ]
    }

    private func scanWithOrphan(projectRoots: [String], cwd: [pid_t: String],
                                argv: [pid_t: [String]]? = nil) -> RunningJobsSnapshot {
        RunningJobs.scan(table: orphanTable, roots: [root], projectRoots: projectRoots,
                         uid: 501,
                         details: details(cwd: cwd, extraArgv: argv ?? orphanArgv))
    }

    func testAGroupWhoseLeaderIsGoneStillGroups() throws {
        let snapshot = scanWithOrphan(
            projectRoots: ["/Users/giel/Developer/gielcobben-2026"],
            cwd: [38938: "/Users/giel/Developer/gielcobben-2026/workers/images"])
        let orphan = try XCTUnwrap(snapshot.orphans.first)
        XCTAssertEqual(orphan.pgid, 38931, "the group outlives the process that led it")
        XCTAssertEqual(orphan.processCount, 3)
        XCTAssertNil(orphan.sessionID, "its session closed days ago")
        XCTAssertEqual(orphan.label, "wrangler dev")
    }

    /// A process that exits between the table sweep and the argv read has no
    /// arguments to name it. Falling back to `p_comm` is ugly; dropping a row
    /// that is holding 385 MB is worse.
    func testAJobWithUnreadableArgumentsStillGetsARow() throws {
        let snapshot = scanWithOrphan(
            projectRoots: ["/Users/giel/Developer/gielcobben-2026"],
            cwd: [38938: "/Users/giel/Developer/gielcobben-2026/workers/images"],
            argv: [:])
        let orphan = try XCTUnwrap(snapshot.orphans.first,
                                   "an unnameable process is still a process holding memory")
        XCTAssertEqual(orphan.label, "node", "p_comm is the last resort, not the first")
    }

    /// 338 processes on a real machine have ppid 1 under one uid. Without the
    /// cwd filter this feature lists every login agent and XPC service on the
    /// system.
    func testAnOrphanOutsideAKnownProjectIsNotListed() {
        let snapshot = scanWithOrphan(
            projectRoots: ["/Users/giel/Developer/gielcobben-2026"],
            cwd: [38938: "/Library/Application Support/SomeVendor"])
        XCTAssertTrue(snapshot.orphans.isEmpty,
                      "a process Wortel never started is not Wortel's to offer to kill")
    }

    func testNoProjectRootsMeansNoOrphansAtAll() {
        let snapshot = scanWithOrphan(
            projectRoots: [],
            cwd: [38938: "/Users/giel/Developer/gielcobben-2026/workers/images"])
        XCTAssertTrue(snapshot.orphans.isEmpty,
                      "with nothing to match against, claiming a process would be a guess")
    }

    /// A `chrome_crashpad_handler` sitting in a project directory at 2.8 MB is
    /// not a server somebody forgot to stop.
    func testASmallSilentOrphanIsNotWorthMentioning() {
        let tiny = [entry(50100, 1, 50100, "chrome_crashpad")]
        let snapshot = RunningJobs.scan(
            table: table + tiny,
            roots: [root], projectRoots: ["/Users/giel/dev"], uid: 501,
            details: details(cwd: [50100: "/Users/giel/dev/app"],
                             extraArgv: [50100: ["/x/chrome_crashpad", "chrome_crashpad"]]))
        XCTAssertTrue(snapshot.orphans.isEmpty,
                      "no port and nearly no memory means nothing to act on")
    }

    /// Small is fine when it is actually serving something: the real bun script
    /// orphan held 15 MB and :8790.
    func testASmallOrphanHoldingAPortIsStillListed() {
        let serving = [entry(50200, 1, 50200, "bun")]
        let snapshot = RunningJobs.scan(
            table: table + serving,
            roots: [root], projectRoots: ["/Users/giel/dev"], uid: 501,
            details: ProcessDetails(
                arguments: { [50200: ["/x/bun", "bun", "run", "dev:simulator"]][$0] ?? [] },
                footprint: { $0 == 50200 ? 15_000_000 : 0 },
                listeningPorts: { $0 == 50200 ? [8790] : [] },
                workingDirectory: { $0 == 50200 ? "/Users/giel/dev/notify" : nil }))
        XCTAssertEqual(snapshot.orphans.map(\.primaryPort), [8790])
    }

    /// A sibling directory must not match a project root by string prefix.
    func testOrphanAttributionDoesNotMatchASiblingDirectory() {
        let snapshot = scanWithOrphan(
            projectRoots: ["/Users/giel/Developer/wortel"],
            cwd: [38938: "/Users/giel/Developer/wortel-web/workers"])
        XCTAssertTrue(snapshot.orphans.isEmpty,
                      "wortel-web is not inside wortel, however much the prefix suggests it")
    }

    /// A live session's jobs are never also orphans, however the scan is ordered.
    func testLiveJobsAreNotAlsoReportedAsOrphans() {
        let snapshot = scanWithOrphan(
            projectRoots: ["/Users/giel"],
            cwd: [15618: "/Users/giel/dev", 38938: "/Users/giel/Developer/gielcobben-2026"])
        XCTAssertEqual(snapshot.orphans.map(\.pgid), [38931],
                       "only the group with no session above it is an orphan")
    }

    // MARK: - Fail-safe

    func testAnUnreadableTableClaimsNothing() {
        let snapshot = RunningJobs.scan(table: [], roots: [root], details: details())
        XCTAssertTrue(snapshot.isEmpty, "no table means no claim, not an empty machine")
    }

    /// A session whose shell has already exited contributes nothing rather than
    /// dragging in whatever inherited its pid.
    func testASessionWhoseShellIsGoneContributesNothing() {
        let gone = SessionProcessRoot(sessionID: sessionID, shellPID: 999_999, agentName: nil)
        let snapshot = RunningJobs.scan(table: table, roots: [gone], details: details())
        XCTAssertTrue(snapshot.jobs.isEmpty)
    }

    func testExcludedGroupsAreNeverListed() {
        let snapshot = RunningJobs.scan(
            table: table, roots: [root], projectRoots: [], uid: 501,
            excludedPGIDs: [15614], details: details())
        XCTAssertFalse(snapshot.jobs.contains { $0.pgid == 15614 },
                       "Wortel and its keeper must not appear in their own list")
    }

    // MARK: - Close copy

    /// "A process is still running in this session" is equally true of a session
    /// holding one `sleep` and one holding 1.4 GB of dev servers, which is why
    /// it was worth replacing.
    func testCloseSummaryNamesWhatDies() throws {
        let summary = try XCTUnwrap(RunningJobs.closeSummary(for: scan().jobs))
        XCTAssertTrue(summary.contains("bun dev:web (:3000)"),
                      "the biggest thing you are about to lose is named first: \(summary)")
        XCTAssertTrue(summary.contains("claude"),
                      "closing stops the agent too, which is the most important part")
        XCTAssertTrue(summary.contains("8 processes"), "the session shell is not one of them: \(summary)")
    }

    /// No em-dashes in anything a user reads.
    func testCloseSummaryUsesNoDashes() throws {
        let summary = try XCTUnwrap(RunningJobs.closeSummary(for: scan().jobs))
        XCTAssertFalse(summary.contains("—"), summary)
        XCTAssertFalse(summary.contains("–"), summary)
    }

    func testCloseSummaryElidesALongList() throws {
        let summary = try XCTUnwrap(
            RunningJobs.closeSummary(for: scan().jobs, maximumNames: 1))
        XCTAssertTrue(summary.contains("and 2 more"), summary)
    }

    func testCloseSummaryIsNilWhenThereIsNothingToName() {
        XCTAssertNil(RunningJobs.closeSummary(for: []),
                     "the caller keeps its own wording rather than printing an empty sentence")
    }

    /// One process is a process, not 1 processes.
    func testCloseSummaryPluralises() throws {
        let one = RunningJob(rootPID: 10, pgid: 10, ownsGroup: true,
                             sessionID: nil, label: "sleep", pids: [10],
                             footprint: 1_000, ports: [], startedAt: t0,
                             workingDirectory: nil, isAgent: false)
        let summary = try XCTUnwrap(RunningJobs.closeSummary(for: [one]))
        XCTAssertTrue(summary.contains("stops 1 process and"), summary)
    }

    // MARK: - Wrapper detection

    func testWrapperDetection() {
        XCTAssertTrue(RunningJobs.isWrapper(["/bin/zsh", "zsh", "-c", "run something"]))
        XCTAssertTrue(RunningJobs.isWrapper(["/usr/bin/login", "login", "-pf", "giel"]))
        XCTAssertFalse(RunningJobs.isWrapper(["/usr/local/bin/bun", "bun", "dev:web"]))
        XCTAssertFalse(RunningJobs.isWrapper(["/opt/node", "node", "server.js"]))
    }
}
