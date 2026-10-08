import Darwin
import Foundation

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

    init(socketPath: String = Keeper.socketPath, binary: String? = KeeperConnection.bundledBinary) {
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
    /// you just replaced. Without this, the day the wire changes is the day
    /// sessions break in a way nobody can reproduce on a clean machine.
    ///
    /// A mismatch is resolved by replacing it, which costs the shells it was
    /// holding. That is the lesser evil: refusing to talk to it would leave
    /// those shells alive and permanently unreachable, whereas an app update has
    /// always meant losing your sessions anyway. It only ever happens on an
    /// update, and only once.
    @discardableResult
    func connect() -> Bool {
        guard connectStarting() else { return false }
        let ping = (try? client.send(.ping))?.response
        guard !Self.shouldReplace(afterPing: ping) else {
            NSLog("wortel: keeper speaks a different protocol; replacing it")
            KeeperLog.log.notice("""
                keeper \(self.keeperPID ?? -1, privacy: .public) speaks protocol \
                \(ping?.version ?? "?", privacy: .public), not \(Keeper.version, privacy: .public); replacing it
                """)
            replaceMismatchedKeeper()
            return connectStarting()
                && (try? client.send(.ping))?.response.version == Keeper.version
        }
        guard ping?.ok == true else {
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
        KeeperLog.log.notice("connected to keeper \(self.keeperPID ?? -1, privacy: .public)")
        return true
    }

    /// Whether a keeper should be killed and replaced, judged by its answer to
    /// a ping.
    ///
    /// Only a keeper that answered and named another protocol. Killing one
    /// costs every shell it holds, so "it didn't answer" is not reason enough:
    /// a reply that timed out or came back garbled says nothing about its
    /// sessions. Until 2026-10-08 any failed ping counted as a mismatch.
    static func shouldReplace(afterPing response: KeeperResponse?) -> Bool {
        guard let response, response.ok else { return false }
        return response.version != Keeper.version
    }

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

    /// Stop a keeper we cannot talk to, and clear its socket so a new one can
    /// bind.
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
    private func replaceMismatchedKeeper() {
        let pid = client.peerProcessID()
        client.disconnect()
        if let pid, pid > 1 {
            kill(pid, SIGTERM)
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(20_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(atPath: Keeper.socketPath)
    }

    /// Start the keeper as a process of its own.
    ///
    /// `POSIX_SPAWN_SETSID` puts the keeper in a new session, so it is not in
    /// the app's process group and does not receive the signals the app
    /// receives. A keeper that died with its parent would be an elaborate way
    /// to change nothing.
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(binary), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary, nil, &attributes, &argv, environ)
        guard result == 0 else {
            throw WortelCLI.SocketError.failed("spawning the keeper", errno: result)
        }
    }

    /// What the app gets back for a session: a pty to read, and whatever
    /// happened while it wasn't watching.
    struct Attachment {
        let session: UUID
        let descriptor: Int32
        let pid: Int32
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

    /// Get a pty for `session`: the one it already has if it survived, a new one
    /// otherwise.
    ///
    /// One call for both, because the keeper's `open` already means "attach if
    /// it exists". That is what makes a relaunch idempotent — restoring a
    /// session list must not fork a second shell for every session that never
    /// stopped running.
    func attachOrOpen(
        session: UUID, plan: ShellSpawn.Plan, workingDirectory: String?,
        initialInput: String? = nil, columns: UInt16, rows: UInt16
    ) -> Attachment? {
        guard client.isConnected else { return nil }
        let id = session.uuidString

        // Ask to attach first purely so we can *tell* whether it survived —
        // `open` would do both, but silently, and "your agent is still running"
        // is worth knowing.
        if let (response, descriptor) = try? client.send(.attach(session: id)),
           response.ok, let descriptor {
            return Attachment(session: session, descriptor: descriptor,
                              pid: response.pid ?? -1,
                              replay: response.replay ?? Data(), resumed: true,
                              inputDelivered: response.inputDelivered ?? false,
                              startedAt: response.startedAt.map(Date.init(timeIntervalSince1970:)))
        }

        let keeperPlan = KeeperSpawnPlan(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, workingDirectory: workingDirectory,
            initialInput: initialInput)
        guard let (response, descriptor) = try? client.send(
            .open(session: id, plan: keeperPlan, columns: columns, rows: rows)),
            response.ok, let descriptor
        else { return nil }
        return Attachment(session: session, descriptor: descriptor,
                          pid: response.pid ?? -1,
                          replay: response.replay ?? Data(), resumed: false,
                          inputDelivered: response.inputDelivered ?? false,
                          startedAt: response.startedAt.map(Date.init(timeIntervalSince1970:)))
    }

    /// End a session for good — the user closed it, so the shell goes too.
    /// Distinct from the app quitting, which must leave it running.
    func close(session: UUID) {
        guard client.isConnected else { return }
        _ = try? client.send(.close(session: session.uuidString))
    }

    /// Sessions the keeper is still holding. Used to tell whether anything
    /// survived before deciding what to say about it.
    func running() -> [KeeperSessionState] {
        guard client.isConnected,
              let (response, _) = try? client.send(.list) else { return [] }
        return response.sessions ?? []
    }
}
