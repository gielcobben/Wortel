import Darwin
import Foundation
import os

/// The app's side of process survival: one connection to the keeper, held open
/// for the whole run.
///
/// Held open deliberately. The connection closing is how the keeper learns the
/// app has gone — quit, crash and `kill -9` all look the same from there — and
/// that is what makes it resume reading the ptys instead of leaving shells
/// blocked on a pty nobody drains. So there is no "detach on quit" code path:
/// quitting *is* the detach, which means it also works for the ways of leaving
/// that don't run any code.
///
/// Session identity is the persisted `Session.id`, which is what makes reattach
/// need no bookkeeping at all: a restored session asks for its own uuid, and if
/// the shell is still running the keeper hands it straight back.
final class KeeperConnection {
    private let client: KeeperClient
    private let binary: String?

    private let socketPath: String

    init(socketPath: String = Keeper.socketPath, binary: String? = KeeperConnection.bundledBinary) {
        self.socketPath = socketPath
        self.client = KeeperClient(path: socketPath)
        self.binary = binary
    }

    /// `Contents/Resources/bin/wortel-keeper`, beside the `wortel` command.
    static var bundledBinary: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("bin/wortel-keeper").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Connect, starting the keeper if it isn't running.
    ///
    /// And check what answered. **This matters from the first release, not from
    /// the first protocol change**: updating the app does not restart the
    /// keeper, so a new Wortel routinely meets a keeper built from the version
    /// you just replaced. Two things can be wrong with it, and they are
    /// answered differently:
    ///
    /// - **Another protocol.** It cannot be talked to, so it is replaced, which
    ///   costs the shells it was holding. That is the lesser evil: refusing to
    ///   talk to it would leave those shells alive and permanently unreachable.
    /// - **Another build, same protocol** (`isOutdated`). It works, but every
    ///   shell it forks runs under an old binary, and macOS judges privacy
    ///   grants (Full Disk Access) by the binary: one keeper survived four
    ///   updates, and its shells could not read what the app could. Replaced
    ///   only while it holds no sessions, because a stale binary is never
    ///   worth a live shell. With sessions it is kept, and said so; it ends by
    ///   itself 30 seconds after it holds nothing with no app connected, so the
    ///   launch after its last session has ended gets a current one.
    @discardableResult
    func connect() -> Bool {
        guard connectStarting() else { return false }
        var ping = (try? client.send(.ping))?.response
        if Self.shouldReplace(afterPing: ping) {
            NSLog("wortel: keeper speaks a different protocol or Ghostty; replacing it")
            KeeperLog.log.notice("""
                keeper \(self.keeperPID ?? -1, privacy: .public) speaks protocol \
                \(ping?.version ?? "?", privacy: .public) with Ghostty \(ping?.ghostty ?? "?", privacy: .public), \
                not \(Keeper.version, privacy: .public) with \(Self.appGhostty ?? "?", privacy: .public); replacing it
                """)
            ping = replaceKeeper()
            guard ping?.version == Keeper.version else { return false }
        } else if let answer = ping, answer.ok, Self.isOutdated(answer, appBuild: Self.appBuild),
                  heldSessions()?.isEmpty == true {
            KeeperLog.log.notice("""
                keeper \(self.keeperPID ?? -1, privacy: .public) is from build \
                \(answer.build ?? "unknown", privacy: .public), not \(Self.appBuild ?? "?", privacy: .public), \
                and holds nothing; replacing it
                """)
            ping = replaceKeeper()
        }
        guard let ping, ping.ok else {
            // Something holds the socket and would not say who it is: busy,
            // wedged or stopped. Every session it holds may still be alive,
            // so this launch goes without it rather than killing them. The
            // next launch asks again.
            NSLog("wortel: keeper did not answer; sessions will not survive a quit this time")
            KeeperLog.log.error("""
                keeper \(self.keeperPID ?? -1, privacy: .public) did not answer a ping; running without it
                """)
            client.disconnect()
            return false
        }
        if Self.isOutdated(ping, appBuild: Self.appBuild) {
            KeeperLog.log.notice("""
                keeper \(self.keeperPID ?? -1, privacy: .public) at \(ping.executable ?? "?", privacy: .public) \
                is from build \(ping.build ?? "unknown", privacy: .public), not \
                \(Self.appBuild ?? "?", privacy: .public); using it, since it holds sessions or was just started
                """)
        }
        KeeperLog.log.notice("connected to keeper \(self.keeperPID ?? -1, privacy: .public)")
        return true
    }


    /// Whether a keeper that answered a ping came from another build of the
    /// app. One too old to report its build counts as outdated: the field is
    /// newer than every keeper that lacks it. An app that cannot name its own
    /// build has nothing to compare with, and calls nothing outdated.
    static func isOutdated(_ ping: KeeperResponse, appBuild: String?) -> Bool {
        guard let appBuild else { return false }
        return ping.build != appBuild
    }

    /// This app's build, which a keeper from the same bundle reports as its own.
    static var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Whether a keeper should be killed and replaced, judged by its answer to
    /// a ping.
    ///
    /// Only a keeper that answered and named another protocol. Killing one
    /// costs every shell it holds, so "it didn't answer" is not reason enough:
    /// a reply that timed out or came back garbled says nothing about its
    /// sessions. Until 2026-10-08 any failed ping counted as a mismatch.
    ///
    /// **Or another Ghostty.** The snapshots the app restores its terminals
    /// from are only readable by a Ghostty of the same commit, so a keeper of
    /// another one is as unusable as one of another protocol: an update that
    /// moves Ghostty replaces it, which ends its shells once, agents resumed
    /// (`docs/decisions.md`, 2026-11-20). Judged only when both say which
    /// commit they are: an app that cannot tell kills nothing for it.
    static func shouldReplace(afterPing response: KeeperResponse?, appGhostty: String? = appGhostty) -> Bool {
        guard let response, response.ok else { return false }
        if response.version != Keeper.version { return true }
        if let appGhostty, let keeper = response.ghostty, keeper != appGhostty { return true }
        return false
    }

    /// The Ghostty commit this app's GhosttyKit was built from, set at launch
    /// by `GhosttyRuntime` (this file is also the tests', which have no
    /// GhosttyKit). nil until then, or when it does not say.
    nonisolated(unsafe) static var appGhostty: String?

    /// The keeper process, as the kernel names the other end of the socket.
    var keeperPID: pid_t? { client.peerProcessID() }

    private var exitWatch: ProcessExitWatch?

    /// Call `handler` on the main queue, once, when the keeper process ends.
    ///
    /// It is not supposed to end while the app runs, so this is the moment
    /// every shell it held may have gone with it. On 2026-10-08 that happened,
    /// killed from outside, and the app noticed nothing for seven minutes: the
    /// terminals just stopped. The process rather than the socket, because
    /// `send` reads that socket on demand and a second reader would take a
    /// reply meant for it.
    func watchForExit(_ handler: @escaping (pid_t) -> Void) {
        guard exitWatch == nil, let pid = keeperPID, pid > 1 else { return }
        exitWatch = ProcessExitWatch(pid: pid) { handler(pid) }
    }

    /// Connect, starting the keeper if it isn't running.
    private func connectStarting() -> Bool {
        (try? client.connect(startingWith: { try self.launch() })) == true
    }

    /// Stop the keeper on the other end, clear its socket so a new one can
    /// bind, start one from this bundle, and return its answer to a ping (nil
    /// if it gave none). For a keeper that speaks another protocol, or one from
    /// another build that holds no sessions.
    ///
    /// The pid comes from the **socket itself** (`LOCAL_PEERPID`), not from
    /// `pgrep`. That is not a micro-optimisation: this runs during surface
    /// creation on the main thread, and `Process.waitUntilExit()` pumps the run
    /// loop — which let SwiftUI re-enter, create another surface, and re-enter
    /// this very lazy initialiser. libdispatch calls that "trying to lock
    /// recursively" and traps. Asking the kernel who is on the other end of a
    /// socket we already hold is a syscall that cannot run anyone else's code.
    ///
    /// SIGTERM, then SIGKILL: a keeper old enough to speak a different protocol
    /// is also old enough to have bugs we have since fixed — one build ignored
    /// SIGTERM outright. Politeness cannot be a precondition for recovering
    /// from a bad old version, since that is the version least likely to
    /// cooperate. Killing it closes its ptys, which hangs its shells up rather
    /// than orphaning them.
    private func replaceKeeper() -> KeeperResponse? {
        let pid = client.peerProcessID()
        client.disconnect()
        if let pid, pid > 1 {
            kill(pid, SIGTERM)
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(20_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(atPath: Keeper.socketPath)
        guard connectStarting() else { return nil }
        return (try? client.send(.ping))?.response
    }

    /// The sessions the keeper holds, or nil if it would not say. Not `running`,
    /// whose empty answer on a failure is fine for what it is used for and
    /// fatal here: "no sessions" is what makes replacing a keeper safe.
    private func heldSessions() -> [KeeperSessionState]? {
        guard client.isConnected, let (response, _) = try? client.send(.list),
              response.ok else { return nil }
        return response.sessions ?? []
    }

    /// Start the keeper as a process of its own.
    ///
    /// `POSIX_SPAWN_SETSID` puts the keeper in a new session, so it is not in
    /// the app's process group and does not receive the signals the app
    /// receives. A keeper that died with its parent would be an elaborate way
    /// to change nothing.
    ///
    /// **It inherits nothing it was not given.** `POSIX_SPAWN_CLOEXEC_DEFAULT`
    /// closes every descriptor the app has open, and stdio is `/dev/null`. A
    /// keeper outlives the app by days, and every descriptor it inherited
    /// lived as long: the app's sockets and files, and the stdout of whatever
    /// launched the app (a terminal, Xcode), held open long after they were
    /// gone. Every shell it forked inherited them in turn.
    ///
    /// **Without disclaiming responsibility, deliberately.** macOS counts the
    /// keeper as Wortel's responsible child, and that is what makes its shells
    /// run under Wortel's privacy grants (Full Disk Access and the rest). A
    /// disclaimed keeper would ask for each grant again, as itself.
    ///
    /// **Not a launchd agent, deliberately.** Tried and removed on 2026-10-07.
    /// Registered through `SMAppService`, the keeper was launchd's process and
    /// outlived the app as before, but macOS 27's Dock still marked Wortel
    /// "Running in Background" after a quit, now because the keeper was the
    /// app's registered background item, so "Stop Running in Background" was
    /// still offered next to Quit, which is how that day's sessions were lost.
    /// It also costs a "Background Items Added" notice after every update.
    ///
    /// **Nor an app of its own.** Also tried the same day: "Wortel Keeper", a
    /// background-only app in Contents/Helpers opened through LaunchServices.
    /// It ran as its own app, with launchd as its parent, survived the quit and
    /// was not throttled. The Dock still marked Wortel "Running in Background"
    /// right after the quit, and it added a nested app to sign and notarize.
    ///
    /// So the answer to a killed keeper is recovery instead: the next launch
    /// resumes every agent into its own conversation, verified by killing the
    /// keeper under a full set of sessions.
    private func launch() throws {
        guard let binary else { throw WortelCLI.SocketError.notRunning }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(binary), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary, &actions, &attributes, &argv, environ)
        guard result == 0 else {
            throw WortelCLI.SocketError.failed("spawning the keeper", errno: result)
        }
    }

    /// What the app gets back for a session: its terminal's channel, its pty
    /// to type into, and what the program said about itself lately.
    struct Attachment {
        let session: UUID
        /// The session's output channel from the keeper's terminal
        /// (`KeeperChannel`): a snapshot, then every byte after it.
        let descriptor: Int32
        /// The pty, for typing into and asking who is in the foreground. Never
        /// read: the keeper is its one reader.
        let typingDescriptor: Int32
        let pid: Int32
        /// What the program wrote while no app was attached, for what it said
        /// about itself meanwhile (`ProgramStatusWatch`). Never written into a
        /// terminal: the snapshot has all of it.
        let replay: Data
        /// True when this attached to a shell that was already running — i.e.
        /// the session survived, which is the whole feature.
        let resumed: Bool
        /// Whether the keeper typed the plan's `initialInput` into this shell
        /// when it forked it. False from a keeper too old to say.
        let inputDelivered: Bool
        /// When the keeper forked the shell. nil from a keeper too old to say.
        let startedAt: Date?

        /// Whether this survived shell should have its agent resumed: the
        /// caller has a resume for it (an agent was running at the last quit),
        /// and the shell is back at a prompt with nothing under it.
        ///
        /// Each condition rules out a way to start a second agent. The shell
        /// must be older than a startup: the keeper types a resume into a new
        /// shell before it has read anything, and one still in its rc files
        /// has that text waiting and will run it in a moment. The process under
        /// login must be a shell: after `exec claude` it is the agent, and the
        /// resume would be typed into its input. And it must have nothing but
        /// its prompt's helpers under it, by the process table's word rather
        /// than a marker file's; an unreadable table is no claim at all.
        ///
        /// It covers an agent started by hand as much as one Wortel resumed:
        /// either way it was running at quit, and the shell outlived it. What
        /// this cannot tell is *why* the agent ended; that is the exit log's.
        func resumeIsOwed(now: Date = Date(), table: () -> [ProcessEntry]) -> Bool {
            guard resumed, let startedAt, pid > 0,
                  now.timeIntervalSince(startedAt) > 10 else { return false }
            let snapshot = table()
            // `pid` is login; the agent hangs off the shell under it.
            let shell = ProcessTable.shell(of: pid, in: snapshot)
            guard let entry = snapshot.first(where: { $0.pid == shell }),
                  ProcessTable.isShell(entry.name) else { return false }
            return ProcessTable.work(under: shell, in: snapshot).isEmpty
        }
    }

    /// The session's terminal from the keeper: the one it already keeps if
    /// the session survived, a new session with a new shell otherwise. One
    /// call for both, which is what makes a relaunch idempotent: restoring
    /// the session list never forks a second shell for one still running.
    func attachOrOpen(
        session: UUID, plan: ShellSpawn.Plan, workingDirectory: String?,
        initialInput: String? = nil, columns: UInt16, rows: UInt16
    ) -> Attachment? {
        guard client.isConnected else { return nil }
        let id = session.uuidString
        let keeperPlan = KeeperSpawnPlan(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, workingDirectory: workingDirectory,
            initialInput: initialInput)
        guard let (response, descriptors) = try? client.sendForDescriptors(
            .terminal(session: id, plan: keeperPlan, columns: columns, rows: rows)) else { return nil }
        guard response.ok, descriptors.count == 2 else {
            descriptors.forEach { Darwin.close($0) }
            let reason = response.message ?? "no reason"
            KeeperLog.log.error("keeper would not give session \(id, privacy: .public) its terminal: \(reason, privacy: .public)")
            return nil
        }
        // `existing`: nothing was forked and nothing typed, so a resume must
        // not be taken for a fresh shell's and typed into a live agent.
        return Attachment(session: session, descriptor: descriptors[0], typingDescriptor: descriptors[1],
                          pid: response.pid ?? -1,
                          replay: response.replay ?? Data(), resumed: response.existing ?? false,
                          inputDelivered: response.inputDelivered ?? false,
                          startedAt: response.startedAt.map(Date.init(timeIntervalSince1970:)))
    }

    /// End a session for good — the user closed it, so the shell goes too.
    /// Distinct from the app quitting, which must leave it running.
    ///
    /// Over a connection of its own once the main one is out of step (see
    /// `KeeperClient.send`): otherwise a closed session's shell and agent
    /// would run on in the keeper with nobody reading them, and come back at
    /// the next launch. The keeper closes a session whoever asks.
    func close(session: UUID) {
        let command = KeeperCommand.close(session: session.uuidString)
        if client.isConnected {
            _ = try? client.send(command)
            return
        }
        let once = KeeperClient(path: socketPath)
        guard (try? once.connect()) == true else { return }
        _ = try? once.send(command)
        once.disconnect()
    }

    // MARK: - Terminals the keeper keeps

    /// The session's pty and the keeper's terminal for it take this size.
    /// Main thread, like every request on this connection.
    func resize(session: UUID, columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard client.isConnected else { return }
        _ = try? client.send(.resize(session: session.uuidString, columns: columns, rows: rows,
                                     cellWidth: cellWidth, cellHeight: cellHeight))
    }

    /// A snapshot of the session's terminal down its channel, for a surface
    /// shown again (`KeeperCommand.resync`).
    func resync(session: UUID) {
        guard client.isConnected else { return }
        _ = try? client.send(.resync(session: session.uuidString))
    }

    /// Write into a session's terminal as though its program had
    /// (`KeeperCommand.inject`).
    func inject(session: UUID, _ bytes: [UInt8]) {
        guard client.isConnected, !bytes.isEmpty else { return }
        _ = try? client.send(.inject(session: session.uuidString, bytes: Data(bytes)))
    }

    /// What terminals are shown in, for the keeper to answer programs with.
    func setAppearance(_ appearance: KeeperAppearance) {
        guard client.isConnected else { return }
        _ = try? client.send(.appearance(appearance))
    }

    /// Whether each DEC private mode is set in the keeper's terminal for the
    /// session, or nil when it could not say.
    func modes(session: UUID, _ modes: [UInt16]) -> [Bool]? {
        guard client.isConnected,
              let (response, _) = try? client.send(.modes(session: session.uuidString, modes: modes)),
              response.ok, let set = response.modes, set.count == modes.count
        else { return nil }
        return set
    }

    /// Sessions the keeper is still holding. Used to tell whether anything
    /// survived before deciding what to say about it.
    func running() -> [KeeperSessionState] {
        guard client.isConnected,
              let (response, _) = try? client.send(.list) else { return [] }
        return response.sessions ?? []
    }
}
