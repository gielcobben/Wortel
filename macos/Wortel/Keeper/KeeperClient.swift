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

    init(path: String = Keeper.socketPath) {
        self.path = path
    }

    deinit { disconnect() }

    var isConnected: Bool { socket >= 0 }

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
                return true
            }
            usleep(20_000)
        }
        return false
    }

    func disconnect() {
        guard socket >= 0 else { return }
        close(socket)
        socket = -1
    }

    /// Send a command and read the reply.
    ///
    /// The returned descriptor is **owned by the caller**. For `open` and
    /// `attach` it is the pty, and dropping it without closing leaks a
    /// descriptor for the life of the app.
    @discardableResult
    func send(_ command: KeeperCommand) throws -> (response: KeeperResponse, descriptor: Int32?) {
        guard socket >= 0 else { throw WortelCLI.SocketError.notRunning }
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
    }
}
