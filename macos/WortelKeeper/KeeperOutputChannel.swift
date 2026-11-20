import Darwin
import Foundation

/// The keeper's end of one session's output channel: what the app's terminal
/// is fed from (`KeeperCommand.terminal`, `KeeperChannel`).
///
/// **Nothing here may make the pty's read loop wait.** The keeper is the one
/// reader of the pty, and a reader that blocks on the app is a shell that
/// blocks on the app: an app beach-balling on its main thread, or stopped in
/// a debugger, would freeze every agent. So the socket is non-blocking, what
/// it will not take now is queued in memory and written when it drains, and
/// the queue is bounded (`limit`). An app that falls that far behind loses
/// its channel (`send` returns false) and attaches again, which costs it a
/// snapshot and nothing else: the keeper's terminal never missed a byte.
///
/// Used on the session's read queue only, like the terminal it carries.
final class KeeperOutputChannel {
    /// Queued for an app that is not reading. Far beyond a flood any app
    /// keeps up with (`cat` of a large file runs at hundreds of MB/s through
    /// a socket), and a bound on the memory a stalled app costs the keeper.
    static let limit = 32 * 1024 * 1024
    /// The kernel's own buffering for the socket, both ways: room for a
    /// burst without waking anyone.
    static let socketBuffer: Int32 = 1024 * 1024

    private let descriptor: Int32
    private let queue: DispatchQueue
    private var pending: [Data] = []
    private var pendingOffset = 0
    private var pendingBytes = 0
    private var writer: DispatchSourceWrite?
    private var writerRunning = false
    /// Set by `finish`: close once everything queued has been written.
    private var finishing = false
    private(set) var isClosed = false

    /// A connected pair: the keeper's end, wrapped here, and the app's end,
    /// handed over by the caller. nil when the system has no sockets to give.
    static func makePair(queue: DispatchQueue) -> (channel: KeeperOutputChannel, appEnd: Int32)? {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { return nil }
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            var size = socketBuffer
            setsockopt(end, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(end, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        // An app that has gone makes a write fail, not raise SIGPIPE.
        var on: Int32 = 1
        setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(ends[0], F_SETFL, fcntl(ends[0], F_GETFL, 0) | O_NONBLOCK)
        // The app only reads its end; it closes it to say it has gone.
        shutdown(ends[1], SHUT_WR)
        return (KeeperOutputChannel(descriptor: ends[0], queue: queue), ends[1])
    }

    private init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
    }

    deinit {
        if !isClosed { closeNow() }
    }

    /// Send raw bytes, or queue what the socket will not take now. False when the
    /// channel is closed or the app has fallen `limit` behind; the channel is
    /// closed then, and the caller lets go of it.
    @discardableResult
    private func sendRaw(_ bytes: UnsafeRawPointer, count: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, !finishing else { return false }
        guard count > 0 else { return true }
        var offset = 0
        if pending.isEmpty {
            while offset < count {
                let written = Darwin.write(descriptor, bytes + offset, count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && errno == EAGAIN {
                    break
                } else {
                    closeNow() // the app has gone
                    return false
                }
            }
            if offset == count { return true }
        }
        guard pendingBytes + (count - offset) <= Self.limit else {
            let behind = pendingBytes + count - offset
            KeeperLog.log.error("an app fell \(behind, privacy: .public) bytes behind a session's output; closing its channel")
            closeNow()
            return false
        }
        pending.append(Data(bytes: bytes + offset, count: count - offset))
        pendingBytes += count - offset
        startWriter()
        return true
    }

    /// Send one frame (`KeeperChannel`): its header and its payload, in one
    /// `writev` while the socket has room, so a read of the pty costs one
    /// system call here and no copy. What does not go now is queued, as by
    /// `send`, and the same bound applies.
    @discardableResult
    func send(_ frame: KeeperChannel.Frame, _ payload: UnsafeRawPointer, count: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, !finishing else { return false }
        var header = KeeperChannel.header(frame, length: count)
        guard pending.isEmpty else {
            return header.withUnsafeBytes { sendRaw($0.baseAddress!, count: $0.count) }
                && sendRaw(payload, count: count)
        }
        let total = header.count + count
        var written = 0
        header.withUnsafeMutableBytes { head in
            var vectors = [iovec(iov_base: head.baseAddress, iov_len: head.count),
                           iovec(iov_base: UnsafeMutableRawPointer(mutating: payload), iov_len: count)]
            while true {
                let result = writev(descriptor, &vectors, Int32(vectors.count))
                if result >= 0 { written = result; return }
                if errno == EINTR { continue }
                written = errno == EAGAIN ? 0 : -1
                return
            }
        }
        if written < 0 {
            closeNow() // the app has gone
            return false
        }
        if written == total { return true }
        // Queue the rest: what is left of the header, then of the payload.
        if written < header.count {
            let rest = header.count - written
            let ok = header.withUnsafeBytes { sendRaw($0.baseAddress! + written, count: rest) }
            return ok && sendRaw(payload, count: count)
        }
        return sendRaw(payload + (written - header.count), count: total - written)
    }

    @discardableResult
    func send(_ frame: KeeperChannel.Frame, _ data: Data) -> Bool {
        guard !data.isEmpty else {
            var nothing: UInt8 = 0
            return withUnsafeBytes(of: &nothing) { send(frame, $0.baseAddress!, count: 0) }
        }
        return data.withUnsafeBytes { send(frame, $0.baseAddress!, count: $0.count) }
    }

    /// How long a finished channel waits for its app to take what is queued.
    static let finishPatience: TimeInterval = 10

    /// Close once everything queued has reached the app: the end of this
    /// channel's part of the stream, as when a new channel takes over. An app
    /// that does not take it within `finishPatience` is not reading at all,
    /// and the channel closes anyway rather than hold the memory.
    func finish() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        guard !pending.isEmpty else { return closeNow() }
        finishing = true
        queue.asyncAfter(deadline: .now() + Self.finishPatience) { [weak self] in self?.closeNow() }
    }

    /// Close now, dropping whatever is queued.
    func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        pending = []
        pendingBytes = 0
        if let writer {
            // A suspended source cannot be cancelled; resume it first.
            if !writerRunning { writer.resume() }
            writer.cancel() // its cancel handler closes the descriptor
            self.writer = nil
        } else {
            close(descriptor)
        }
    }

    // MARK: - Draining

    private func startWriter() {
        if writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            let fd = descriptor
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { close(fd) }
            writer = source
        }
        if !writerRunning {
            writerRunning = true
            writer?.resume()
        }
    }

    private func drain() {
        while let first = pending.first {
            let remaining = first.count - pendingOffset
            let written = first.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress! + pendingOffset, remaining)
            }
            if written > 0 {
                pendingBytes -= written
                if written == remaining {
                    pending.removeFirst()
                    pendingOffset = 0
                } else {
                    pendingOffset += written
                }
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                return
            } else {
                closeNow()
                return
            }
        }
        // Everything is out: stop asking until there is more.
        if writerRunning {
            writerRunning = false
            writer?.suspend()
        }
        if finishing { closeNow() }
    }
}
