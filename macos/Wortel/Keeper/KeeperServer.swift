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
        var exited = false

        init(id: String, pty: PtyHost, limit: Int) {
            self.id = id
            self.pty = pty
            self.buffer = ReplayBuffer(limit: limit)
        }
    }

    private let path: String
    private let replayLimit: Int
    /// Guards the session table. Everything that touches `sessions` hops here,
    /// including the pty read callbacks, which arrive on their own queues.
    private let state = DispatchQueue(label: "sh.wortel.keeper.state")
    private let accepts = DispatchQueue(label: "sh.wortel.keeper.accept")
    private let connections = DispatchQueue(label: "sh.wortel.keeper.conn", attributes: .concurrent)
    private var sessions: [String: Session] = [:]
    private var listener: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private var liveConnections = 0

    /// Called when nothing is left to keep — no sessions, no clients. A keeper
    /// that lingers with nothing to hold is just a leaked process.
    var onIdle: (() -> Void)?

    init(path: String = Keeper.socketPath, replayLimit: Int = Keeper.replayLimit) {
        self.path = path
        self.replayLimit = replayLimit
    }

    deinit { stop() }

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
            guard let (line, extra) = try? FileDescriptorChannel.receiveLine(from: client) else {
                return
            }
            if let extra { close(extra) } // clients never send us descriptors
            guard !line.isEmpty else { continue }
            guard let command = try? JSONDecoder().decode(KeeperCommand.self, from: line) else {
                reply(.failure("this keeper does not understand that command"), to: client)
                continue
            }
            handle(command, from: client)
        }
    }

    private func reply(_ response: KeeperResponse, descriptor: Int32? = nil, to client: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? FileDescriptorChannel.send(data, descriptor: descriptor, over: client)
    }

    // MARK: - Commands

    private func handle(_ command: KeeperCommand, from client: Int32) {
        switch command {
        case .ping:
            reply(.success(message: "wortel-keeper", version: Keeper.version), to: client)

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
        }
    }

    private func open(
        id: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16, from client: Int32
    ) {
        if let existing: Session = state.sync(execute: { sessions[id] }) {
            // Opening one that already exists is an attach. That is not a
            // convenience: it is what makes a relaunch idempotent, so an app
            // that restores its session list doesn't fork a second shell for a
            // session that never stopped running.
            _ = existing
            return attach(id: id, from: client)
        }

        let pty = PtyHost()
        let session = Session(id: id, pty: pty, limit: replayLimit)
        pty.onOutput = { [weak self, weak session] bytes, count in
            // Only ever called while detached — attached, the source is
            // suspended and the app is reading the descriptor itself.
            guard let self, let session else { return }
            self.state.sync { session.buffer.append(bytes, count: count) }
        }
        pty.onExit = { [weak self, weak session] _, _ in
            guard let self, let session else { return }
            session.exited = true
            // **Forget it.** A session whose shell has exited is over, and
            // keeping the entry means the next `attach` hands back a pty whose
            // far end is closed — a terminal that opens onto a dead process and
            // says nothing about it. Dropping it makes the next launch fork a
            // fresh shell, which is what the exec backend has always done when
            // a shell exits. Any client still attached has its own descriptor
            // and sees the EOF itself.
            self.state.sync {
                guard self.sessions[session.id] === session else { return }
                self.sessions.removeValue(forKey: session.id)
            }
            session.pty.stop()
        }

        guard pty.start(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, workingDirectory: plan.workingDirectory,
            columns: max(columns, 1), rows: max(rows, 1))
        else {
            return reply(.failure("could not start \(plan.executable)"), to: client)
        }

        state.sync {
            sessions[id] = session
            // Hand it straight over: the caller opened it in order to use it.
            session.attachedTo = client
            session.pty.pauseReading()
        }
        reply(.success(pid: pty.pid), descriptor: pty.master, to: client)
    }

    private func attach(id: String, from client: Int32) {
        var descriptor: Int32 = -1
        var replay = Data()
        var pid: Int32 = -1

        enum Outcome { case ok, missing, busy }
        let outcome: Outcome = state.sync {
            guard let session = sessions[id] else { return .missing }
            // Someone else is reading it. Refusing beats two readers splitting
            // the byte stream, which corrupts intermittently and cannot be
            // reproduced on demand.
            if let holder = session.attachedTo, holder != client { return .busy }
            session.pty.pauseReading()
            session.attachedTo = client
            replay = session.buffer.take()
            descriptor = session.pty.master
            pid = session.pty.pid
            return .ok
        }

        // Told apart deliberately: "gone" and "someone else has it" look
        // identical from the app and need completely different fixes.
        switch outcome {
        case .missing: return reply(.failure("no such session"), to: client)
        case .busy: return reply(.failure("session is attached elsewhere"), to: client)
        case .ok: break
        }
        guard descriptor >= 0 else {
            return reply(.failure("session has no pty"), to: client)
        }
        reply(.success(pid: pid, replay: replay.isEmpty ? nil : replay),
              descriptor: descriptor, to: client)
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
            }
        }
    }
}
