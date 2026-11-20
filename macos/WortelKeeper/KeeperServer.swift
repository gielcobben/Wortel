import Darwin
import Foundation

/// The process that holds the ptys, and each session's terminal, so the
/// shells stop being the app's children and their terminals stop being the
/// app's to lose.
///
/// It forks what it is told to fork (every decision about *what* to run was
/// made by the app, `ShellSpawn`, and arrives as data), reads every pty
/// itself, always, into a terminal per session (`KeeperTerminal`), answers
/// what programs ask of a terminal, and forwards the output to the app over
/// a channel per session (`KeeperOutputChannel`). It knows nothing about
/// sessions, git or rendering.
///
/// It is the one reader of every pty. Nothing in its read loop waits on the
/// app: an app that stops reading loses its channel, never the shell its
/// output.
final class KeeperServer: @unchecked Sendable {
    private final class Session {
        let id: String
        let pty: PtyHost
        /// The latest output, for an app that attaches to read what the
        /// program said about itself (`OutputTail`). Under `state`.
        var tail: OutputTail
        /// The connection this session's channel belongs to, if any. Keyed by
        /// descriptor because that is what a connection *is* here, and because
        /// it makes "the app quit" and "the app crashed" the same code path.
        var attachedTo: Int32?
        /// When the shell was forked, and whether the plan's `initialInput`
        /// went into its pty. Reported on every attach, so an app that comes
        /// back can tell a resume that was never typed from one whose agent
        /// has since ended. See `KeeperSpawnPlan.initialInput`.
        let startedAt = Date()
        var inputDelivered = false

        /// The session's terminal: every byte the program wrote, parsed at
        /// the size its pty had (`KeeperTerminal`). **Touched on the pty's
        /// read queue only**, in stream order. nil only if libghostty-vt
        /// could not make one.
        let terminal: KeeperTerminal?
        /// Where the app's copy of the terminal is fed from, while an app is
        /// attached. Read queue only.
        var channel: KeeperOutputChannel?
        /// The terminal's activity (`KeeperTerminal.activity`) as of the last
        /// look, and the one it was compressed at. Read queue only.
        var seenActivity: UInt64?
        var compressedActivity: UInt64?
        /// Answers to the program go out here, never on the read queue: a
        /// program that is not reading its input would otherwise stop the
        /// keeper reading its output, and each would wait on the other.
        let replies: DispatchQueue

        init(id: String, pty: PtyHost, limit: Int, columns: UInt16, rows: UInt16) {
            self.id = id
            self.pty = pty
            self.tail = OutputTail(limit: limit)
            self.terminal = KeeperTerminal(columns: columns, rows: rows, scrollbackBytes: Keeper.scrollbackBytes)
            self.replies = DispatchQueue(label: "sh.wortel.keeper.replies", qos: .userInitiated)
        }
    }

    private let path: String
    private let replayLimit: Int
    /// Which keeper this is, for `ping`. See `KeeperResponse.build`.
    private let executable: String?
    let build: String?
    /// Guards the session table. Everything that touches `sessions` hops here,
    /// including the pty read callbacks, which arrive on their own queues.
    private let state = DispatchQueue(label: "sh.wortel.keeper.state")
    private let accepts = DispatchQueue(label: "sh.wortel.keeper.accept")
    private let connections = DispatchQueue(label: "sh.wortel.keeper.conn", attributes: .concurrent)
    private var sessions: [String: Session] = [:]
    private var listener: DispatchSourceRead?
    /// Compresses the scrollback of terminals that have gone quiet
    /// (`compressQuietTerminals`).
    private var compression: DispatchSourceTimer?
    /// How often terminals are looked at for compression: one quiet for a
    /// whole interval is compressed.
    static let compressionInterval: TimeInterval = 15
    private var descriptor: Int32 = -1
    private var liveConnections = 0
    /// Set by `stopIfIdle` as it decides to go. `terminal` refuses from then on,
    /// so no shell is forked into a keeper that is about to hang it up.
    private var stopping = false
    /// What the app shows terminals in, last it said (`appearance`). Given to
    /// every terminal, those opened later included. Under `state`.
    private var appearance: KeeperAppearance?

    /// Called when nothing is left to keep — no sessions, no clients. A keeper
    /// that lingers with nothing to hold is just a leaked process. A hint, not
    /// a decision: by the time anyone acts on it an app may have connected, so
    /// the decision is `stopIfIdle`'s.
    var onIdle: (() -> Void)?

    /// `executable` is this keeper's own binary. Its build is read **now**, as
    /// the keeper starts: an app update replaces the bundle on disk under a
    /// running keeper, and reading it later would report the new build for a
    /// process still running the old one.
    init(path: String = Keeper.socketPath, replayLimit: Int = Keeper.replayLimit,
         executable: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path) {
        self.path = path
        self.replayLimit = replayLimit
        self.executable = executable
        self.build = executable.flatMap(Self.build(ofExecutable:))
    }

    deinit { stop() }

    /// The `CFBundleVersion` of the app a keeper binary ships in, or nil when it
    /// isn't in one. The binary lives at `Wortel.app/Contents/Resources/bin/`,
    /// so the app's Info.plist is two directories up.
    static func build(ofExecutable executable: String) -> String? {
        let plist = URL(fileURLWithPath: executable)
            .deletingLastPathComponent()      // bin
            .deletingLastPathComponent()      // Resources
            .deletingLastPathComponent()      // Contents
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    // MARK: - Lifecycle

    func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw WortelCLI.SocketError.failed("socket", errno: errno) }
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)

        var address = try WortelCLI.address(for: path)
        if WortelCLI.withSockaddr(&address, { Darwin.bind(socketFD, $0, $1) }) != 0 {
            let failure = errno
            guard failure == EADDRINUSE, !isSomeoneListening() else {
                close(socketFD)
                throw WortelCLI.SocketError.failed("bind", errno: failure)
            }
            // Proved stale — nothing answered a connect. Same rule as the CLI
            // socket: never delete a name someone might still be using.
            unlink(path)
            guard WortelCLI.withSockaddr(&address, { Darwin.bind(socketFD, $0, $1) }) == 0 else {
                close(socketFD)
                throw WortelCLI.SocketError.failed("bind", errno: errno)
            }
        }
        guard listen(socketFD, 8) == 0 else {
            let code = errno
            close(socketFD)
            throw WortelCLI.SocketError.failed("listen", errno: code)
        }
        chmod(path, 0o600)

        descriptor = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: accepts)
        source.setEventHandler { [weak self] in self?.acceptOne(on: socketFD) }
        source.setCancelHandler { close(socketFD) }
        listener = source
        source.resume()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sh.wortel.keeper.compress", qos: .utility))
        timer.schedule(deadline: .now() + Self.compressionInterval, repeating: Self.compressionInterval,
                       leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.compressQuietTerminals() }
        compression = timer
        timer.resume()
    }

    /// Compress the scrollback of every terminal that has done nothing since
    /// the last look. Memory is most of what a terminal costs the keeper (a
    /// full scrollback is its limit, 10 MB), and what nobody is scrolling
    /// through compresses to a fraction (libghostty-vt measured 70 to 90%).
    /// A page is decompressed when it is next read or written, so this is
    /// invisible but for the memory. In bounded steps, on each session's read
    /// queue between two reads, so a session that wakes up waits for at most
    /// one step.
    private func compressQuietTerminals() {
        let all = state.sync { Array(sessions.values) }
        for session in all {
            session.pty.enqueue { [weak session] in
                guard let session, let terminal = session.terminal else { return }
                let activity = terminal.activity
                defer { session.seenActivity = activity }
                guard activity == session.seenActivity, activity != session.compressedActivity else { return }
                var steps = 0
                while terminal.compressStep() {
                    steps += 1
                    // Not all of a huge scrollback in one turn of the queue.
                    if steps >= 256 { return }
                }
                session.compressedActivity = terminal.activity
            }
        }
    }

    /// Stop, ending every session. `endingShellsForResume`: the keeper is
    /// ending on a signal (an update replacing it, a logout), not because
    /// anyone closed these sessions, so their agents are to be resumed
    /// (`PtyHost.endShellForResume`). Otherwise each is hung up, as a session
    /// someone closed is.
    func stop(endingShellsForResume: Bool = false) {
        compression?.cancel()
        compression = nil
        listener?.cancel()
        listener = nil
        descriptor = -1
        state.sync {
            for session in sessions.values {
                if endingShellsForResume { session.pty.endForResume() } else { session.pty.stop() }
            }
            sessions = [:]
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Stop, if there is nothing to keep and nobody to keep it for. Returns
    /// whether it did.
    ///
    /// One step under `state`, because both halves of the question can change
    /// between asking and acting: an app that has connected but not opened
    /// anything yet holds no session, and was having the keeper stopped under
    /// it; and an `open` landing just after "no sessions" forked a shell that
    /// the stop then hung up.
    func stopIfIdle() -> Bool {
        let idle: Bool = state.sync {
            guard !stopping, liveConnections == 0, sessions.isEmpty else { return false }
            stopping = true
            return true
        }
        if idle { stop() }
        return idle
    }

    /// Sessions still running, for tests and for `list`.
    var sessionCount: Int { state.sync { sessions.count } }

    private func isSomeoneListening() -> Bool {
        guard let probe = try? WortelCLIClient.connect(to: path) else { return false }
        close(probe)
        return true
    }

    // MARK: - Connections

    private func acceptOne(on socketFD: Int32) {
        let client = accept(socketFD, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // A reply to an app that has just gone must fail, not raise SIGPIPE:
        // the keeper ignores it, but this server also runs inside the tests.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        state.sync { liveConnections += 1 }
        connections.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        defer {
            // **The survival path.** An app that quits, crashes or is killed
            // says nothing first: the connection closing is how the keeper
            // hears it, and it lets go of that app's channels.
            detachEverything(heldBy: client)
            close(client)
            let empty: Bool = state.sync {
                liveConnections -= 1
                return liveConnections == 0 && sessions.isEmpty
            }
            if empty { onIdle?() }
        }

        while true {
            guard let received = try? FileDescriptorChannel.receiveLine(from: client) else {
                return
            }
            received.descriptors.forEach { close($0) } // clients never send us descriptors
            let line = received.line
            guard !line.isEmpty else { continue }
            guard let command = try? JSONDecoder().decode(KeeperCommand.self, from: line) else {
                reply(.failure("this keeper does not understand that command"), to: client)
                continue
            }
            handle(command, from: client)
        }
    }

    private func reply(_ response: KeeperResponse, descriptor: Int32? = nil, to client: Int32) {
        reply(response, descriptors: descriptor.map { [$0] } ?? [], to: client)
    }

    private func reply(_ response: KeeperResponse, descriptors: [Int32], to client: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? FileDescriptorChannel.send(data, descriptors: descriptors, over: client)
    }

    // MARK: - Commands

    private func handle(_ command: KeeperCommand, from client: Int32) {
        switch command {
        case .ping:
            reply(.success(message: "wortel-keeper", version: Keeper.version,
                           build: build, executable: executable,
                           ghostty: KeeperTerminal.ghosttyCommit), to: client)

        case .close(let id):
            let found: Bool = state.sync {
                guard let session = sessions.removeValue(forKey: id) else { return false }
                session.pty.stop()
                return true
            }
            reply(found ? .success() : .failure("no such session"), to: client)

        case .list:
            let states: [KeeperSessionState] = state.sync {
                sessions.values.map {
                    KeeperSessionState(session: $0.id, pid: $0.pty.pid,
                                       attached: $0.attachedTo != nil,
                                       buffered: $0.tail.count)
                }.sorted { $0.session < $1.session }
            }
            reply(.success(sessions: states), to: client)

        case .terminal(let id, let plan, let columns, let rows):
            attachTerminal(id: id, plan: plan, columns: columns, rows: rows, from: client)

        case .resize(let id, let columns, let rows, let cellWidth, let cellHeight):
            guard let session = state.sync(execute: { sessions[id] }) else {
                return reply(.failure("no such session"), to: client)
            }
            // Between two reads: what the program wrote before is parsed at
            // the old size, what it writes after the SIGWINCH at the new one.
            session.pty.enqueue { [weak session] in
                guard let session else { return }
                let columns = max(columns, 1), rows = max(rows, 1)
                // The size it has: nothing to tell anyone. A relaunched app
                // tells every terminal its size, and a program asked for
                // in-band reports (`?2048`) would get one per relaunch.
                if let terminal = session.terminal, terminal.columns == columns, terminal.rows == rows,
                   terminal.cellWidth == cellWidth, terminal.cellHeight == cellHeight { return }
                KeeperLog.log.debug("session \(session.id, privacy: .public) resized to \(columns)x\(rows)")
                session.pty.setWindowSize(
                    columns: columns, rows: rows,
                    widthPx: UInt32(columns) &* cellWidth, heightPx: UInt32(rows) &* cellHeight)
                session.terminal?.resize(columns: columns, rows: rows,
                                         cellWidth: cellWidth, cellHeight: cellHeight)
            }
            reply(.success(), to: client)

        case .appearance(let new):
            let all: [Session] = state.sync {
                appearance = new
                return Array(sessions.values)
            }
            for session in all {
                session.pty.enqueue { [weak session] in session?.terminal?.setAppearance(new) }
            }
            reply(.success(), to: client)

        case .resync(let id):
            guard let session = state.sync(execute: { sessions[id] }) else {
                return reply(.failure("no such session"), to: client)
            }
            // Between two reads, like the first: the channel goes on with
            // exactly what the program wrote after it.
            session.pty.enqueue { [weak session] in
                guard let session, let channel = session.channel, let terminal = session.terminal else { return }
                guard let snapshot = terminal.snapshot() else {
                    return KeeperLog.log.error("session \(session.id, privacy: .public): its terminal would not snapshot")
                }
                if !channel.send(.snapshot, snapshot) { session.channel = nil }
            }
            reply(.success(), to: client)

        case .inject(let id, let bytes):
            guard let session = state.sync(execute: { sessions[id] }) else {
                return reply(.failure("no such session"), to: client)
            }
            // Through the same road the pty's output takes, so the terminal,
            // the app's copy and the status tail all hear it, in order.
            session.pty.enqueue { [weak session] in
                guard let session, !bytes.isEmpty else { return }
                bytes.withUnsafeBytes { raw in
                    session.pty.onOutput?(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
                }
            }
            reply(.success(), to: client)

        case .modes(let id, let modes):
            guard let session = state.sync(execute: { sessions[id] }), let terminal = session.terminal else {
                return reply(.failure("no such session"), to: client)
            }
            let set = session.pty.onReadQueue { modes.map { terminal.mode($0) } }
            reply(.success(modes: set), to: client)
        }
    }

    /// `KeeperCommand.terminal`: open the session or find it, and give the
    /// app a channel that starts with a snapshot of its terminal and goes on
    /// with every byte after it, and the pty to type into.
    private func attachTerminal(
        id: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16, from client: Int32
    ) {
        enum Admission { case refused(String), attached(Session, existing: Bool) }
        // One step under `state`, fork included: two for one id cannot both
        // fork, a shell that exits at once cannot be reaped before it is in
        // the table, and `stopIfIdle` cannot decide in between.
        let admission: Admission = state.sync {
            if let session = sessions[id] {
                // An existing one is attached to: what makes a relaunch
                // idempotent, so restoring a session list never forks a
                // second shell for a session that never stopped.
                if let holder = session.attachedTo, holder != client {
                    return .refused("session is attached elsewhere")
                }
                guard session.terminal != nil else { return .refused("this session has no terminal") }
                session.attachedTo = client
                return .attached(session, existing: true)
            }
            guard !stopping else { return .refused("this keeper is shutting down") }
            guard let session = startSession(id: id, plan: plan, columns: columns, rows: rows),
                  session.terminal != nil else {
                return .refused("could not start \(plan.executable)")
            }
            sessions[id] = session
            session.attachedTo = client
            return .attached(session, existing: false)
        }

        guard case .attached(let session, let existing) = admission else {
            if case .refused(let reason) = admission { reply(.failure(reason), to: client) }
            return
        }
        if !existing { typeInitialInput(of: plan, into: session) }

        guard let pair = KeeperOutputChannel.makePair(queue: session.pty.readQueue) else {
            return reply(.failure("no socket for the session's output"), to: client)
        }
        guard let pty = session.pty.duplicateMaster() else {
            close(pair.appEnd)
            pair.channel.closeNow()
            return reply(.failure("session has no pty"), to: client)
        }

        // **The cut.** Between two reads, on the read queue: the previous
        // channel gets everything up to here and then ends, the snapshot is
        // the terminal as of here, and the new channel carries every byte
        // after it. Nothing is lost or seen twice between the two.
        let channel = pair.channel
        session.pty.enqueue { [weak session] in
            guard let session, let terminal = session.terminal else { return channel.closeNow() }
            session.channel?.finish()
            session.channel = nil
            guard let snapshot = terminal.snapshot() else {
                KeeperLog.log.error("session \(session.id, privacy: .public): its terminal would not snapshot")
                return channel.closeNow()
            }
            guard channel.send(.snapshot, snapshot) else { return }
            session.channel = channel
        }

        let (tail, delivered) = state.sync { (session.tail.take(), session.inputDelivered) }
        reply(.success(pid: session.pty.pid, replay: tail.isEmpty ? nil : tail,
                       existing: existing ? true : nil, inputDelivered: delivered,
                       startedAt: session.startedAt.timeIntervalSince1970),
              descriptors: [pair.appEnd, pty], to: client)
        close(pair.appEnd)
        close(pty)
    }

    /// A new session with its shell running, or nil if it could not be forked.
    /// Called on `state`.
    private func startSession(
        id: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16
    ) -> Session? {
        let pty = PtyHost()
        let session = Session(id: id, pty: pty, limit: replayLimit,
                              columns: max(columns, 1), rows: max(rows, 1))
        // Answers the terminal gives the program, copied out of the callback
        // and written off the read queue (see `Session.replies`).
        session.terminal?.reply = { [weak pty, replies = session.replies] bytes, count in
            let answer = Data(bytes: bytes, count: count)
            replies.async {
                answer.withUnsafeBytes { raw in
                    guard let pty, let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    pty.write(base, count: raw.count)
                }
            }
        }
        if let appearance {
            pty.enqueue { [weak session] in session?.terminal?.setAppearance(appearance) }
        }
        pty.onOutput = { [weak self, weak session] bytes, count in
            // The read queue. The terminal first: it is the session's record.
            // Then the app's copy, if one is attached; if none, the tail.
            guard let self, let session else { return }
            session.terminal?.write(bytes, count: count)
            if let channel = session.channel, channel.send(.output, bytes, count: count) { return }
            // No app is reading (or the one that was just lost its channel):
            // kept for the next one to hear what the program said meanwhile.
            session.channel = nil
            self.state.sync { session.tail.append(bytes, count: count) }
        }
        pty.onExit = { [weak self, weak session] _, _ in
            guard let self, let session else { return }
            // **Forget it.** A session whose shell has exited is over, and
            // keeping the entry means the next attach hands back a pty whose
            // far end is closed — a terminal that opens onto a dead process and
            // says nothing about it. Dropping it makes the next launch fork a
            // fresh shell, which is what the exec backend has always done when
            // a shell exits. An app attached hears it as its channel's end.
            let empty: Bool = self.state.sync {
                guard self.sessions[session.id] === session else { return false }
                self.sessions.removeValue(forKey: session.id)
                return self.liveConnections == 0 && self.sessions.isEmpty
            }
            // The shell's last words (an exit message, a final prompt) are
            // still in the pty; they reach the terminal and the app's copy
            // before the channel ends, and its end is how the app hears.
            session.pty.readWhatIsLeft()
            // And the terminal as it ended, for an app whose copy of it has
            // no surface: there will be no session to ask once this is over.
            if let channel = session.channel, let final = session.terminal?.snapshot() {
                channel.send(.snapshot, final)
            }
            session.channel?.finish()
            session.channel = nil
            session.pty.stop()
            // The other way to run out of things to keep: the app quit with
            // shells alive and the last of them has now ended. Checked only on
            // a connection closing, this left a keeper holding nothing running
            // until the next launch happened to connect and disconnect.
            if empty { self.onIdle?() }
        }

        guard pty.start(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, workingDirectory: plan.workingDirectory,
            columns: max(columns, 1), rows: max(rows, 1))
        else { return nil }
        return session
    }

    /// What the app wants run first, typed before the shell has read a byte:
    /// it waits in the pty's input buffer until the prompt. Done here and not
    /// by the app so the keeper can vouch for it later. Outside `state`,
    /// because a write to a full pty waits.
    private func typeInitialInput(of plan: KeeperSpawnPlan, into session: Session) {
        guard let input = plan.initialInput, !input.isEmpty else { return }
        let bytes = Array(input.utf8)
        bytes.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            session.pty.write(base, count: raw.count)
        }
        state.sync { session.inputDelivered = true }
    }

    /// The app has gone, by a quit, a crash or a `kill -9`, all of which are
    /// the connection closing: so has whatever read its channels. The keeper
    /// reads on, as it always does.
    private func detachEverything(heldBy client: Int32) {
        state.sync {
            for session in sessions.values where session.attachedTo == client {
                session.attachedTo = nil
                session.pty.enqueue { [weak session] in
                    session?.channel?.closeNow()
                    session?.channel = nil
                }
            }
        }
    }
}
