import Darwin
import Foundation

/// The app's end of the keeper: one connection, held open for as long as the app
/// runs.
///
/// Held open on purpose. The connection closing is how the keeper learns the app
/// is gone — a quit, a crash and a `kill -9` all look the same from there — and
/// that is what makes it resume reading the ptys instead of leaving shells to
/// block on a pty nobody drains.
final class KeeperClient {
    private(set) var socket: Int32 = -1
    private let path: String
    private let replyTimeout: TimeInterval

    init(path: String = Keeper.socketPath, replyTimeout: TimeInterval = 5) {
        self.path = path
        self.replyTimeout = replyTimeout
    }

    deinit { disconnect() }

    var isConnected: Bool { socket >= 0 && !isOutOfStep }

    /// Connect to a running keeper, or start one and connect to that.
    ///
    /// `launch` is how the keeper gets spawned; it is a closure so the app can
    /// pass its own bundled binary and tests can pass whatever they like.
    @discardableResult
    func connect(startingWith launch: (() throws -> Void)? = nil,
                 timeout: TimeInterval = 5) throws -> Bool {
        if isConnected { return true }
        if let existing = try? WortelCLIClient.connect(to: path) {
            socket = existing
            applyTimeout()
            return true
        }
        guard let launch else { return false }
        try launch()

        // The keeper has to bind before we can connect, and how long that takes
        // is a process spawn — poll rather than guess a sleep.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let started = try? WortelCLIClient.connect(to: path) {
                socket = started
                applyTimeout()
                return true
            }
            usleep(20_000)
        }
        return false
    }

    /// Bound how long a reply may take.
    ///
    /// Not paranoia: the app asks for a session on the **main thread**, while a
    /// surface is being created, so a keeper that wedged — a bug, a stopped
    /// process, a full socket — would freeze the window rather than the
    /// feature. A timeout turns that into a session that falls back to forking
    /// locally, which is a bad day rather than a hung app.
    private func applyTimeout() {
        guard socket >= 0 else { return }
        var deadline = timeval(
            tv_sec: Int(replyTimeout),
            tv_usec: Int32((replyTimeout - replyTimeout.rounded(.down)) * 1e6))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Which process is on the other end of this connection.
    ///
    /// A syscall on a socket we already hold, which is the point: it runs no
    /// other code, so it is safe from inside a lazy initialiser on the main
    /// thread. The obvious alternative — shelling out to `pgrep` — pumps the
    /// run loop and re-entered surface creation.
    func peerProcessID() -> pid_t? {
        guard socket >= 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
            return nil
        }
        return pid
    }

    /// Close the connection. The next `connect` starts a new one, which is in
    /// step again: nothing is owed on a socket that has never been sent on.
    func disconnect() {
        guard socket >= 0 else { return }
        close(socket)
        socket = -1
        isOutOfStep = false
    }

    /// Send a command and read the reply.
    ///
    /// The returned descriptor is **owned by the caller**. For `open` and
    /// `attach` it is the pty, and dropping it without closing leaks a
    /// descriptor for the life of the app.
    ///
    /// **A failure leaves the connection unusable, on purpose.** Replies carry
    /// no request id, so once one is missed (a timeout, half a line) the next
    /// reply read would be the late answer to the previous request, and an
    /// `attach` could be handed another session's pty: typing into one agent
    /// would land in another. The socket stays open rather than closed,
    /// because closing it tells the keeper the app is gone, and it would start
    /// reading the ptys this app is still reading.
    @discardableResult
    func send(_ command: KeeperCommand) throws -> (response: KeeperResponse, descriptor: Int32?) {
        guard socket >= 0, !isOutOfStep else { throw WortelCLI.SocketError.notRunning }
        do {
            var data = try JSONEncoder().encode(command)
            data.append(0x0A)
            try FileDescriptorChannel.send(data, descriptor: nil, over: socket)

            guard let (line, descriptor) = try FileDescriptorChannel.receiveLine(from: socket) else {
                throw WortelCLI.SocketError.notRunning
            }
            guard let response = try? JSONDecoder().decode(KeeperResponse.self, from: line) else {
                if let descriptor { close(descriptor) }
                throw WortelCLI.SocketError.badResponse
            }
            return (response, descriptor)
        } catch {
            isOutOfStep = true
            KeeperLog.log.error("""
                keeper \(command.verb, privacy: .public) failed (\(String(describing: error), privacy: .public)); \
                not using this connection again
                """)
            throw error
        }
    }

    /// See `send`. New terminals then start without the keeper; the ones
    /// already attached carry on.
    private(set) var isOutOfStep = false
}
