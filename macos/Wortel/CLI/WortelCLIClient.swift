import Foundation

/// The `wortel` binary's end: connect, send one line, read one line, hang up.
///
/// Blocking on purpose. This runs in a process whose entire job is one round
/// trip to a socket on the same machine, and a shell is already waiting on it —
/// an async client here would buy nothing and cost a run loop.
enum WortelCLIClient {
    /// Send `command` and wait for the app's answer.
    static func send(
        _ command: WortelCommand, to path: String = WortelCLI.socketPath,
        timeout: TimeInterval = 10
    ) throws -> WortelResponse {
        let socketFD = try connect(to: path)
        defer { close(socketFD) }

        // A bound on the whole exchange, because the app can be busy in ways the
        // CLI can't see (a modal sheet, a git command on a cold monorepo) and a
        // command line that never returns is worse than one that says so.
        var deadline = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        var request = try JSONEncoder().encode(command)
        request.append(0x0A)
        try write(request, to: socketFD)

        guard let line = readLine(from: socketFD) else { throw WortelCLI.SocketError.badResponse }
        guard let response = try? JSONDecoder().decode(WortelResponse.self, from: line) else {
            throw WortelCLI.SocketError.badResponse
        }
        return response
    }

    /// Connect to the socket at `path`, or say the app isn't running.
    ///
    /// Both "no such file" and "connection refused" mean the same thing to
    /// someone at a prompt — nothing is listening — and they're the two ways a
    /// quit app presents: the socket gone, or the file left behind by a crash.
    static func connect(to path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw WortelCLI.SocketError.failed("socket", errno: errno) }
        // **Close-on-exec, or the connection outlives the process that made it.**
        // Wortel forks constantly — every `git` read, and every shell the keeper
        // starts — and a descriptor without this is inherited by all of them and
        // survives their exec. The far end then never sees the connection close,
        // so the keeper cannot tell that the app has gone and leaves sessions
        // marked attached with nobody reading them. It cost an hour to find,
        // because the symptom is a session that is alive and unreachable.
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
        // **And no SIGPIPE.** Writing to a socket whose far end has gone raises
        // it, and its default is to end the process. The app does not ignore
        // it, so a keeper that died between two requests would have taken the
        // whole app with it instead of failing one `send`.
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = try WortelCLI.address(for: path)
        guard WortelCLI.withSockaddr(&address, { Darwin.connect(socketFD, $0, $1) }) == 0 else {
            let failure = errno
            close(socketFD)
            if failure == ENOENT || failure == ECONNREFUSED {
                throw WortelCLI.SocketError.notRunning
            }
            throw WortelCLI.SocketError.failed("connect", errno: failure)
        }
        return socketFD
    }

    private static func write(_ data: Data, to socketFD: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(socketFD, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else {
                    throw WortelCLI.SocketError.failed("write", errno: errno)
                }
                offset += written
            }
        }
    }

    private static func readLine(from socketFD: Int32) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            guard count > 0 else { return line.isEmpty ? nil : line }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[0..<newline])
                return line
            }
            line.append(contentsOf: buffer[0..<count])
            guard line.count <= WortelCLI.maximumLineBytes else { return nil }
        }
    }
}
