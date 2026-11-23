import Foundation
import os

/// The app's end of the `wortel` command: a Unix domain socket that turns one
/// line of JSON into one call into the app.
///
/// Deliberately knows nothing about sessions, windows or previews — it's handed
/// a `handler` and does transport. That's what lets it be tested for real
/// (`WortelCLIServerTests` runs a client against it over an actual socket),
/// because the failures worth catching here are all transport-shaped: a reply
/// that never comes, a connection that hangs the accept loop, a stale socket
/// file after a crash that makes the app look permanently unreachable.
///
/// The reply is asynchronous — `handler` calls back rather than returning —
/// because half of what the CLI asks for is: `new --branch` shells out to git
/// before there's a session to name in the response. Calling back never
/// blocks: the encoding and the write happen on the server's queue.
final class WortelCLIServer: @unchecked Sendable {
    /// Handle one command and call back with the answer. Called on the server's
    /// own queue; the app's implementation hops to the main actor.
    typealias Handler = @Sendable (
        WortelCommand, @escaping @Sendable (WortelResponse) -> Void
    ) -> Void
    /// The same, told who sent the command (`Caller`): `send` and `wait`
    /// need to know which session is asking, and only the kernel can say.
    typealias CallerHandler = @Sendable (
        WortelCommand, Caller, @escaping @Sendable (WortelResponse) -> Void
    ) -> Void

    /// The other end of one connection, as far as the handler needs to know it.
    struct Caller: Sendable {
        /// The process that sent the command, from the kernel; nil if it
        /// wouldn't say.
        let pid: pid_t?
        /// Whether the CLI has gone away (a ^C, a killed script) before its
        /// answer. Only `wortel wait` asks: its answer can be minutes off, and
        /// a wait nobody is waiting on any more would otherwise sit in the app
        /// until its timeout, or forever with none. Valid until the reply is
        /// given, after which the server closes the descriptor it looks at
        /// (on its own queue); don't ask once you've replied.
        let hasHungUp: @Sendable () -> Bool
    }

    private let path: String
    private let handler: CallerHandler
    /// Accept on one queue, serve on another: a connection whose peer stops
    /// reading must not stop the app from accepting the next one.
    private let acceptQueue = DispatchQueue(label: "sh.wortel.cli.accept")
    private let serveQueue = DispatchQueue(
        label: "sh.wortel.cli.serve", attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1

    /// How long a connection may take to send its line, and to take its reply.
    /// A CLI on the same machine takes microseconds; this only bounds a peer
    /// that has wandered off.
    private static let connectionTimeout = timeval(tv_sec: 5, tv_usec: 0)

    init(path: String = WortelCLI.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = { command, _, reply in handler(command, reply) }
    }

    init(path: String = WortelCLI.socketPath, callerHandler: @escaping CallerHandler) {
        self.path = path
        self.handler = callerHandler
    }

    deinit { stopListening() }

    // MARK: - Lifecycle

    func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw WortelCLI.SocketError.failed("socket", errno: errno)
        }
        // Every surface's shell is spawned by this process, and without this
        // each one would inherit the listening socket: the app could then quit
        // and the socket stay open in a dozen shells, so the *next* launch finds
        // a live peer and refuses to bind.
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)

        // Ours alone, from the moment it has a name. The socket carries "open
        // this file", "start a shell here" — everything a login session can
        // do — so it is not a thing to leave group- or world-writable on a
        // shared machine. `bind` creates the file with the umask's mode, and a
        // chmod after it leaves a moment when another user with write access
        // could connect; a Unix socket can't be fchmod'ed before it is bound.
        // So the umask is narrowed around the bind instead. It is
        // process-wide: a file another thread creates in those microseconds
        // comes out owner-only, which costs nothing in a per-user app. The
        // chmod stays, for a socket bound under a different mask. Each
        // connection is also checked for its user (`isOwnUser`), which holds
        // whatever the file's mode is.
        let mask = umask(0o077)
        do {
            try bind(socketFD)
            umask(mask)
        } catch {
            umask(mask)
            close(socketFD)
            throw error
        }
        guard listen(socketFD, 16) == 0 else {
            let code = errno
            close(socketFD)
            throw WortelCLI.SocketError.failed("listen", errno: code)
        }
        chmod(path, 0o600)

        descriptor = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptOne(on: socketFD) }
        source.setCancelHandler { close(socketFD) }
        self.source = source
        source.resume()
    }

    func stop() {
        stopListening()
        // The socket file outlives the process that made it, so a launch that
        // doesn't tidy up leaves the next one a stale name to reason about.
        try? FileManager.default.removeItem(atPath: path)
    }

    private func stopListening() {
        source?.cancel() // the cancel handler closes the descriptor
        source = nil
        descriptor = -1
    }

    /// Bind, dealing with the socket file a previous run left behind.
    ///
    /// A Unix socket's name is a file, and a crash (or a kill -9) leaves it
    /// there. Deleting it unconditionally would be wrong — that's how two
    /// running copies would each steal the name from the other — so the stale
    /// case is *proved* rather than assumed: if nothing answers a connect, no
    /// one is listening, and the file is a leftover.
    private func bind(_ socketFD: Int32) throws {
        var address = try WortelCLI.address(for: path)
        if WortelCLI.withSockaddr(&address, { Darwin.bind(socketFD, $0, $1) }) == 0 { return }
        let failure = errno
        guard failure == EADDRINUSE else {
            throw WortelCLI.SocketError.failed("bind", errno: failure)
        }
        guard !isSomeoneListening() else {
            throw WortelCLI.SocketError.failed("bind", errno: EADDRINUSE)
        }
        unlink(path)
        guard WortelCLI.withSockaddr(&address, { Darwin.bind(socketFD, $0, $1) }) == 0 else {
            throw WortelCLI.SocketError.failed("bind", errno: errno)
        }
    }

    private func isSomeoneListening() -> Bool {
        guard let probe = try? WortelCLIClient.connect(to: path) else { return false }
        close(probe)
        return true
    }

    // MARK: - Serving

    private func acceptOne(on socketFD: Int32) {
        let client = accept(socketFD, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        guard Self.isOwnUser(client) else {
            close(client)
            return
        }
        var timeout = Self.connectionTimeout
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // **No SIGPIPE.** A reply written to a CLI that has gone raises it,
        // and its default ends the process, which here is the app. A reply
        // used to follow its command within milliseconds; `wortel wait`
        // answers minutes later, to a caller that may have been ^C'd.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        serveQueue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        guard let line = Self.readLine(from: client) else {
            close(client)
            return
        }
        guard let command = try? JSONDecoder().decode(WortelCommand.self, from: line) else {
            // A version skew, most likely: an older app and a newer CLI. Saying
            // so beats the silence of a dropped connection, which reads as "the
            // app is broken" rather than "these two don't match".
            Self.reply(.failure("This Wortel doesn't understand that command."), to: client)
            return
        }
        let caller = Caller(pid: Self.peerPID(of: client), hasHungUp: { Self.hasHungUp(client) })
        let answered = OSAllocatedUnfairLock(initialState: false)
        handler(command, caller) { [serveQueue] response in
            // Once: the reply closes the descriptor, and a second one would
            // close whatever the number had been handed to since.
            guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
            // **Never written where it was given.** The app replies from the
            // main thread, and a write blocks for as long as the peer doesn't
            // read: a CLI suspended with ^Z, or piped into something stuck,
            // with a `read --lines` answer of up to 16 MB in front of it.
            // Written there, that froze the whole app, terminals included,
            // for up to the send timeout per chunk. One reply per connection,
            // so the connection's order is its own; the queue is concurrent
            // so one stuck peer holds up no one else's answer.
            serveQueue.async { Self.reply(response, to: client) }
        }
    }

    /// The pid of the process on the other end, from the kernel rather than
    /// from anything the peer says about itself.
    /// Whether the process at the other end of `client` runs as this user.
    /// Anyone else, or a peer the kernel can't name, is hung up on unread:
    /// the socket's mode already says so, and this says it again for a
    /// socket file whose mode was changed, or a folder that let someone in.
    static func isOwnUser(_ client: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(client, &uid, &gid) == 0 && uid == geteuid()
    }

    private static func peerPID(of client: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Whether the peer has closed its end. The CLI sends one line and then
    /// only reads, so anything readable now is the end of the stream.
    private static func hasHungUp(_ client: Int32) -> Bool {
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    /// Read up to the first newline. Returns nil if the peer goes away, sends
    /// nothing in time, or sends more than a command could plausibly be.
    private static func readLine(from client: Int32) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[0..<newline])
                return line
            }
            line.append(contentsOf: buffer[0..<count])
            guard line.count <= WortelCLI.maximumRequestBytes else { return nil }
        }
    }

    private static func reply(_ response: WortelResponse, to client: Int32) {
        defer { close(client) }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(client, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
