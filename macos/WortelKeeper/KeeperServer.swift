import Darwin
import Foundation

/// The process that holds the ptys, so the shells stop being the app's children.
///
/// Small on purpose. It knows nothing about terminals, sessions, git or
/// rendering — it forks what it is told to fork, hands the descriptor to
/// whoever attaches, and keeps reading when nobody does. Every decision about
/// *what* to run was already made by the app (see `ShellSpawn`) and arrives here
/// as data, which is what keeps this process small enough to trust with
/// outliving everything else.
///
/// The one invariant it enforces is the one the design rests on: **only one
/// process reads a pty at a time.** Attached, the app reads the descriptor
/// directly and the keeper's read source is suspended; detached, the keeper
/// drains into a bounded replay buffer so the shell never blocks on a full pty.
final class KeeperServer: @unchecked Sendable {
    private final class Session {
        let id: String
        let pty: PtyHost
        var buffer: ReplayBuffer
        /// The connection currently reading this session, if any. Keyed by
        /// descriptor because that is what a connection *is* here, and because
        /// it makes "the app died" and "the app detached" the same code path.
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
        /// Where the app's copy of the terminal is fed from, while one is
        /// attached through `terminal`. Read queue only.
        var channel: KeeperOutputChannel?
        /// Set when a `attach` (protocol 1) handed the app the pty itself:
        /// from then on the keeper is not reading, and its terminal falls
        /// behind for good.
        var terminalStale = false
        /// Answers to the program go out here, never on the read queue: a
        /// program that is not reading its input would otherwise stop the
        /// keeper reading its output, and each would wait on the other.
        let replies: DispatchQueue

        init(id: String, pty: PtyHost, limit: Int, columns: UInt16, rows: UInt16, replays: Bool) {
            self.id = id
            self.pty = pty
            // Opened for the keeper to keep its terminal, the buffer is only a
            // tail for what the program said about itself, never a replay, so
            // it reads nothing of what it drops (`readsDroppedModes`).
            self.buffer = ReplayBuffer(limit: limit, readsDroppedModes: replays)
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
    private var descriptor: Int32 = -1
    private var liveConnections = 0
    /// Set by `stopIfIdle` as it decides to go. `open` refuses from then on,
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
    }

    func stop() {
        listener?.cancel()
        listener = nil
        descriptor = -1
        state.sync {
            for session in sessions.values { session.pty.stop() }
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
            // **The survival path.** A client that quits, crashes or is killed
            // never sends `detach` — so the connection closing has to mean the
            // same thing, or the pty would go unread, fill, and block the shell
            // that was supposed to survive.
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
                           build: build, executable: executable), to: client)

        case .open(let id, let plan, let columns, let rows):
            open(id: id, plan: plan, columns: columns, rows: rows, from: client)

        case .attach(let id):
            attach(id: id, from: client)

        case .detach(let id):
            state.sync {
                guard let session = sessions[id], session.attachedTo == client else { return }
                resume(session)
            }
            reply(.success(), to: client)

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
                                       buffered: $0.buffer.count)
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
        // As `open`: one step under `state`, fork included.
        let admission: Admission = state.sync {
            if let session = sessions[id] {
                if let holder = session.attachedTo, holder != client {
                    return .refused("session is attached elsewhere")
                }
                guard session.terminal != nil, !session.terminalStale else {
                    return .refused("this session's terminal was not kept")
                }
                session.attachedTo = client
                return .attached(session, existing: true)
            }
            guard !stopping else { return .refused("this keeper is shutting down") }
            guard let session = startSession(id: id, plan: plan, columns: columns, rows: rows, replays: false),
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

        let (tail, delivered) = state.sync { (session.buffer.copy(), session.inputDelivered) }
        reply(.success(pid: session.pty.pid, replay: tail.isEmpty ? nil : tail,
                       existing: existing ? true : nil, inputDelivered: delivered,
                       startedAt: session.startedAt.timeIntervalSince1970),
              descriptors: [pair.appEnd, pty], to: client)
        close(pair.appEnd)
        close(pty)
    }

    private func open(
        id: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16, from client: Int32
    ) {
        enum Admission { case refused(String), opened(Session), existing(Session) }
        // One step under `state`, fork included: two opens for one id cannot
        // both fork, a shell that exits at once cannot be reaped before it is
        // in the table, and `stopIfIdle` cannot decide in between.
        let admission: Admission = state.sync {
            if let session = sessions[id] {
                // Opening one that already exists is an attach. That is not a
                // convenience: it is what makes a relaunch idempotent, so an
                // app that restores its session list doesn't fork a second
                // shell for a session that never stopped running.
                guard claim(session, for: client) else { return .refused("session is attached elsewhere") }
                return .existing(session)
            }
            guard !stopping else { return .refused("this keeper is shutting down") }
            guard let session = startSession(id: id, plan: plan, columns: columns, rows: rows) else {
                return .refused("could not start \(plan.executable)")
            }
            sessions[id] = session
            // Handed straight over: the caller opened it in order to use it.
            _ = claim(session, for: client)
            return .opened(session)
        }

        switch admission {
        case .refused(let reason):
            reply(.failure(reason), to: client)
        case .existing(let session):
            // Says so, because the plan was not used: whatever `initialInput`
            // asked for was not typed, and the app must not take this for a
            // fresh shell and type a resume into a live agent.
            send(handOver(session), existing: true, to: client)
        case .opened(let session):
            typeInitialInput(of: plan, into: session)
            send(handOver(session), to: client)
        }
    }

    /// A new session with its shell running, or nil if it could not be forked.
    /// Called on `state`.
    private func startSession(
        id: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16, replays: Bool = true
    ) -> Session? {
        let pty = PtyHost()
        let session = Session(id: id, pty: pty, limit: replayLimit,
                              columns: max(columns, 1), rows: max(rows, 1), replays: replays)
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
            // Then the app's copy, if one is attached. Then the tail kept for
            // what the program said about itself (`buffer`).
            guard let self, let session else { return }
            session.terminal?.write(bytes, count: count)
            if let channel = session.channel, !channel.send(.output, bytes, count: count) {
                session.channel = nil
            }
            self.state.sync { session.buffer.append(bytes, count: count) }
        }
        pty.onExit = { [weak self, weak session] _, _ in
            guard let self, let session else { return }
            // **Forget it.** A session whose shell has exited is over, and
            // keeping the entry means the next `attach` hands back a pty whose
            // far end is closed — a terminal that opens onto a dead process and
            // says nothing about it. Dropping it makes the next launch fork a
            // fresh shell, which is what the exec backend has always done when
            // a shell exits. Any client still attached has its own descriptor
            // and sees the EOF itself.
            let empty: Bool = self.state.sync {
                guard self.sessions[session.id] === session else { return false }
                self.sessions.removeValue(forKey: session.id)
                return self.liveConnections == 0 && self.sessions.isEmpty
            }
            // The shell's last words (an exit message, a final prompt) are
            // still in the pty; they reach the terminal and the app's copy
            // before the channel ends, and its end is how the app hears.
            session.pty.readWhatIsLeft()
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

    private func attach(id: String, from client: Int32) {
        enum Claim { case claimed(Session), missing, busy }
        let outcome: Claim = state.sync {
            guard let session = sessions[id] else { return .missing }
            return claim(session, for: client) ? .claimed(session) : .busy
        }

        // Told apart deliberately: "gone" and "someone else has it" look
        // identical from the app and need completely different fixes.
        switch outcome {
        case .missing: reply(.failure("no such session"), to: client)
        case .busy: reply(.failure("session is attached elsewhere"), to: client)
        case .claimed(let session): send(handOver(session), to: client)
        }
    }

    /// Make `client` the session's one reader and stop the keeper's own
    /// reading, or say no because another client has it. Called on `state`.
    ///
    /// Refusing beats two readers splitting the byte stream, which corrupts
    /// intermittently and cannot be reproduced on demand.
    private func claim(_ session: Session, for client: Int32) -> Bool {
        if let holder = session.attachedTo, holder != client { return false }
        session.attachedTo = client
        session.pty.pauseReading()
        // The app reads the pty itself from here: the keeper's terminal
        // misses what it reads, so it is not offered again.
        session.terminalStale = true
        return true
    }

    /// What a client is given for a session it has just claimed.
    private struct Handover {
        let descriptor: Int32
        let replay: Data
        let pid: Int32
        let inputDelivered: Bool
        let startedAt: Date
    }

    /// Everything the keeper read before the claim, and a descriptor of the
    /// client's own. nil when the pty has already closed under it (the shell
    /// ended).
    ///
    /// The order is the fix for a lost chunk. The claim paused the keeper's
    /// reading, but a read already under way finishes regardless, and appends
    /// under `state`. So the wait for it happens here, **outside** `state` (it
    /// may be waiting for exactly that), and only then is the buffer taken: the
    /// chunk lands in this replay rather than after it, where it turned up
    /// stale on the next attach and out of order on this one.
    private func handOver(_ session: Session) -> Handover? {
        session.pty.finishReadInFlight()
        return state.sync {
            guard let descriptor = session.pty.duplicateMaster() else { return nil }
            return Handover(descriptor: descriptor, replay: session.buffer.take(),
                            pid: session.pty.pid, inputDelivered: session.inputDelivered,
                            startedAt: session.startedAt)
        }
    }

    /// Reply with the handover, then close the keeper's copy of the descriptor:
    /// the kernel has given the client one of its own by then.
    private func send(_ handover: Handover?, existing: Bool = false, to client: Int32) {
        guard let handover else { return reply(.failure("session has no pty"), to: client) }
        defer { close(handover.descriptor) }
        reply(.success(pid: handover.pid,
                       replay: handover.replay.isEmpty ? nil : handover.replay,
                       existing: existing ? true : nil,
                       inputDelivered: handover.inputDelivered,
                       startedAt: handover.startedAt.timeIntervalSince1970),
              descriptor: handover.descriptor, to: client)
    }

    /// Resume the keeper's own reading. Called on detach and on disconnect.
    private func resume(_ session: Session) {
        session.attachedTo = nil
        session.pty.resumeReading()
    }

    private func detachEverything(heldBy client: Int32) {
        state.sync {
            for session in sessions.values where session.attachedTo == client {
                resume(session)
                // The app has gone, so has whatever reads the channel.
                session.pty.enqueue { [weak session] in
                    session?.channel?.closeNow()
                    session?.channel = nil
                }
            }
        }
    }
}
