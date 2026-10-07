import Darwin
import Foundation
import ServiceManagement

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
        guard let (response, _) = try? client.send(.ping), response.ok,
              response.version == Keeper.version
        else {
            NSLog("wortel: keeper speaks a different protocol; replacing it")
            replaceMismatchedKeeper()
            return connectStarting()
                && (try? client.send(.ping))?.response.version == Keeper.version
        }
        return true
    }

    /// Set by `launch` when launchd took the job, so a keeper that then never
    /// binds can be started the other way.
    private var startedViaLaunchd = false

    /// Connect, starting the keeper if needed — and if launchd said it started
    /// one that never bound the socket (a job launchd still thought was
    /// running, a bundle program that failed to exec), start one directly
    /// rather than run the whole launch without a keeper. The first wait is
    /// short: binding takes milliseconds, and this blocks surface creation.
    private func connectStarting() -> Bool {
        startedViaLaunchd = false
        if (try? client.connect(startingWith: { try self.launch() }, timeout: 2)) == true {
            return true
        }
        guard startedViaLaunchd else { return false }
        NSLog("wortel: launchd started no keeper that answered; starting it directly")
        return (try? client.connect(startingWith: { try self.spawn() })) == true
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

    /// Start the keeper: as launchd's process when it can be, ours when not.
    ///
    /// launchd first, and not for tidiness. A process the app spawns stays in
    /// the app's coalition however many `setsid`s it does, and macOS 27's Dock
    /// reads that as the app "Running in Background" once it has quit, with a
    /// "Stop Running in Background" item that force-quits whatever is left.
    /// On 2026-10-07 what was left was the keeper, and with it every shell
    /// and every agent. Registered through `SMAppService` the keeper is
    /// launchd's, with a coalition of its own, and shows under Wortel in
    /// Login Items ("Allow in the Background") where stopping it is a
    /// deliberate act rather than a menu item next to Quit.
    ///
    /// Spawning it directly stays as the fallback: for a `WORTEL_DATA_DIR`
    /// instance (launchd knows one keeper per label, and it would be the real
    /// one), and for a user who switched the background item off.
    private func launch() throws {
        if launchViaLaunchd() {
            startedViaLaunchd = true
            return
        }
        try spawn()
    }

    /// Only the copy in an Applications folder registers the job. launchd
    /// knows one `sh.wortel.keeper`, and it belongs to whichever bundle
    /// registered it last: a Debug build from DerivedData registering it would
    /// leave the installed app starting that build's keeper, failing the
    /// version check, killing it, and starting it again. Every other copy
    /// spawns its keeper directly, as before.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications"
            || path == (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
    }

    /// The job's plist, in `Contents/Library/LaunchAgents`.
    static let launchdPlist = "sh.wortel.keeper.plist"
    static let launchdLabel = "sh.wortel.keeper"

    private func launchViaLaunchd() -> Bool {
        guard DataDirectory.custom == nil, Self.isInstalledCopy else { return false }
        let service = SMAppService.agent(plistName: Self.launchdPlist)
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                NSLog("wortel: keeper not registered with launchd (%@); starting it directly",
                      String(describing: error))
                return false
            }
        }
        guard service.status == .enabled else {
            NSLog("wortel: keeper not allowed in the background (status %ld); starting it directly",
                  service.status.rawValue)
            return false
        }
        // Not run at load, so registering starts nothing: ask launchd for it.
        // The app then polls for the socket as it always has.
        return kickstart()
    }

    /// `launchctl kickstart -k gui/<uid>/sh.wortel.keeper`. Spawned and reaped
    /// here rather than through `Process`, whose wait pumps the run loop; see
    /// `replaceMismatchedKeeper` for what that re-entered. launchctl itself
    /// returns in milliseconds.
    ///
    /// `-k` because this only runs when no keeper answered on the socket: an
    /// instance launchd still counts as running is then one that is wedged or
    /// was just killed by `replaceMismatchedKeeper`, and a plain kickstart of a
    /// running job does nothing at all.
    private func kickstart() -> Bool {
        let target = "gui/\(getuid())/\(Self.launchdLabel)"
        var argv: [UnsafeMutablePointer<CChar>?] =
            ["/bin/launchctl", "kickstart", "-k", target].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/launchctl", nil, nil, &argv, environ) == 0 else {
            return false
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
        if code != 0 {
            NSLog("wortel: launchctl kickstart %@ failed (%d); starting the keeper directly",
                  target, code)
        }
        return code == 0
    }

    /// Start the keeper as a process of our own.
    ///
    /// `POSIX_SPAWN_SETSID` puts the keeper in a new session, so it is not in
    /// the app's process group and does not receive the signals the app
    /// receives. A keeper that died with its parent would be an elaborate way
    /// to change nothing. What this cannot do is leave the app's coalition,
    /// which is why launchd is tried first.
    private func spawn() throws {
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
