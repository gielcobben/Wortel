import Foundation

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
/// before there's a session to name in the response.
final class WortelCLIServer: @unchecked Sendable {
    /// Handle one command and call back with the answer. Called on the server's
    /// own queue; the app's implementation hops to the main actor.
    typealias Handler = @Sendable (
        WortelCommand, @escaping @Sendable (WortelResponse) -> Void
    ) -> Void

    private let path: String
    private let handler: Handler
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
        self.handler = handler
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

        do {
            try bind(socketFD)
        } catch {
            close(socketFD)
            throw error
        }
        guard listen(socketFD, 16) == 0 else {
            let code = errno
            close(socketFD)
            throw WortelCLI.SocketError.failed("listen", errno: code)
        }
        // Ours alone. The socket carries "open this file", "start a shell here"
        // — everything a login session can do — so it is not a thing to leave
        // group- or world-writable on a shared machine.
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
        var timeout = Self.connectionTimeout
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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
        handler(command) { response in
            Self.reply(response, to: client)
        }
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
            guard line.count <= WortelCLI.maximumLineBytes else { return nil }
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
