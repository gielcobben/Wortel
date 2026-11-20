import Darwin
import Foundation

/// Sending an open file descriptor to another process, over a Unix socket.
///
/// This is what lets the keeper own a pty while the app reads it. The
/// alternative — the keeper reading and forwarding every byte — would put a
/// copy, a context switch and a wakeup on the hottest path in a terminal. With
/// `SCM_RIGHTS` the app ends up holding the *same open file description*, so
/// reading it is exactly as fast as reading a pty it opened itself, and the
/// keeper's own copy is what keeps the pty alive after the app lets go.
///
/// The mechanics fail quietly, which is why they live in one place and are
/// tested over a real socket pair: a message carrying only ancillary data may be
/// dropped, a control buffer that is short truncates silently, and a descriptor
/// that arrives unnoticed is a leak that surfaces hours later as an app that
/// cannot open files.
enum FileDescriptorChannel {
    // Darwin's CMSG_* are function-like macros, and Swift imports none of them.
    // Reimplemented from <sys/socket.h>. The alignment is **32-bit, not
    // pointer-sized** — using MemoryLayout<Int>.alignment here builds a control
    // message the kernel quietly ignores, and the descriptor simply never
    // arrives.
    private static let alignBytes = MemoryLayout<UInt32>.size - 1
    private static func align(_ value: Int) -> Int { (value + alignBytes) & ~alignBytes }
    private static var headerSize: Int { align(MemoryLayout<cmsghdr>.size) }
    /// The most descriptors one message carries: a session's output channel
    /// and its pty.
    static let maximumDescriptors = 2
    private static func payloadSize(_ count: Int) -> Int { MemoryLayout<Int32>.size * count }
    private static var controlSpace: Int { headerSize + align(payloadSize(maximumDescriptors)) }
    private static func controlLength(_ count: Int) -> Int { headerSize + payloadSize(count) }
    private static func controlData(_ control: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        control.advanced(by: headerSize)
    }

    /// Send `line` (a newline-terminated JSON reply) and, optionally, a
    /// descriptor alongside it.
    ///
    /// There is always at least one real byte on the wire because a `sendmsg`
    /// carrying only ancillary data is allowed to be dropped. Here that byte is
    /// the JSON we were sending anyway.
    static func send(_ line: Data, descriptor: Int32?, over socket: Int32) throws {
        try send(line, descriptors: descriptor.map { [$0] } ?? [], over: socket)
    }

    /// `send(_:descriptor:over:)` with up to `maximumDescriptors` of them, in
    /// one message, received in the same order.
    static func send(_ line: Data, descriptors: [Int32], over socket: Int32) throws {
        precondition(descriptors.count <= maximumDescriptors, "too many descriptors for one message")
        var bytes = [UInt8](line)
        if bytes.isEmpty { bytes = [0x0A] }

        let control = UnsafeMutableRawPointer.allocate(
            byteCount: controlSpace, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, controlSpace)

        try bytes.withUnsafeMutableBufferPointer { buffer in
            var iov = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            try withUnsafeMutablePointer(to: &iov) { iovPointer in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                if !descriptors.isEmpty {
                    message.msg_control = control
                    message.msg_controllen = socklen_t(headerSize + align(payloadSize(descriptors.count)))
                    let header = control.assumingMemoryBound(to: cmsghdr.self)
                    header.pointee.cmsg_level = SOL_SOCKET
                    header.pointee.cmsg_type = SCM_RIGHTS
                    header.pointee.cmsg_len = socklen_t(controlLength(descriptors.count))
                    descriptors.withUnsafeBytes { raw in
                        _ = memcpy(controlData(control), raw.baseAddress!, raw.count)
                    }
                }
                // The descriptor rides on the first segment only. A reply with
                // a replay can be larger than the socket buffer, so the rest
                // goes out as plain bytes, which the reader takes in bulk.
                var offset = 0
                while offset < buffer.count {
                    iovPointer.pointee.iov_base = UnsafeMutableRawPointer(buffer.baseAddress! + offset)
                    iovPointer.pointee.iov_len = buffer.count - offset
                    let sent = sendmsg(socket, &message, 0)
                    if sent < 0 {
                        if errno == EINTR { continue }
                        throw ChannelError.failed("sendmsg", errno)
                    }
                    offset += sent
                    message.msg_control = nil
                    message.msg_controllen = 0
                }
            }
        }
    }

    /// Read one newline-terminated line, and pick up a descriptor if one came
    /// with it. Returns nil at end of stream.
    ///
    /// **The caller owns any descriptor returned and must close it.** This is
    /// the one place in the codebase where a return value is a resource.
    ///
    /// Every read takes the ancillary data with it, and none reads past the
    /// newline: on a stream socket a descriptor arrives with the byte it was
    /// attached to, so a read spanning two lines could hand it to the wrong
    /// one. Each read first peeks at what is waiting, then takes exactly up to
    /// the end of the line. A line used to be read a byte at a time, which for
    /// a full replay (700 KB of base64) was 700,000 syscalls on the main
    /// thread, about half a second per restored session.
    /// One line and what came with it. `descriptor` is the first of them.
    struct Received {
        var line: Data
        var descriptors: [Int32]
        var descriptor: Int32? { descriptors.first }
    }

    static func receiveLine(from socket: Int32) throws -> Received? {
        var line = Data()
        var descriptors: [Int32] = []
        func closeAll() { descriptors.forEach { close($0) } }

        let control = UnsafeMutableRawPointer.allocate(
            byteCount: controlSpace, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            // How much of what's waiting belongs to this line.
            let peeked = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, MSG_PEEK) }
            if peeked < 0 {
                if errno == EINTR { continue }
                closeAll()
                throw ChannelError.failed("recv", errno)
            }
            if peeked == 0 {
                if line.isEmpty, descriptors.isEmpty { return nil }
                return Received(line: line, descriptors: descriptors)
            }
            let newline = chunk[0..<peeked].firstIndex(of: 0x0A)
            let wanted = newline.map { $0 + 1 } ?? peeked

            memset(control, 0, controlSpace)
            let received: Int = chunk.withUnsafeMutableBytes { raw -> Int in
                var iov = iovec(iov_base: raw.baseAddress, iov_len: wanted)
                return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                    var message = msghdr()
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    message.msg_control = control
                    message.msg_controllen = socklen_t(controlSpace)
                    let count = recvmsg(socket, &message, 0)
                    if count > 0, message.msg_controllen >= socklen_t(controlLength(1)) {
                        let header = control.assumingMemoryBound(to: cmsghdr.self)
                        if header.pointee.cmsg_level == SOL_SOCKET,
                           header.pointee.cmsg_type == SCM_RIGHTS {
                            let carried = (Int(header.pointee.cmsg_len) - headerSize) / MemoryLayout<Int32>.size
                            var incoming = [Int32](repeating: -1, count: carried)
                            incoming.withUnsafeMutableBytes { raw in
                                _ = memcpy(raw.baseAddress!, controlData(control), raw.count)
                            }
                            // They ride on a line's first piece only. More on
                            // a later piece are a protocol error, and leaking
                            // them is worse than dropping them.
                            let valid = incoming.filter { $0 >= 0 }
                            if descriptors.isEmpty { descriptors = valid } else { valid.forEach { close($0) } }
                        }
                    }
                    return count
                }
            }

            if received < 0 {
                if errno == EINTR { continue }
                closeAll()
                throw ChannelError.failed("recvmsg", errno)
            }
            if received == 0 {
                if line.isEmpty, descriptors.isEmpty { return nil }
                return Received(line: line, descriptors: descriptors)
            }
            if received > 0, chunk[received - 1] == 0x0A {
                line.append(contentsOf: chunk[0..<(received - 1)])
                return Received(line: line, descriptors: descriptors)
            }
            line.append(contentsOf: chunk[0..<received])
            if line.count > Keeper.maximumLineBytes {
                closeAll()
                throw ChannelError.failed("line too long", EMSGSIZE)
            }
        }
    }

    enum ChannelError: Error, CustomStringConvertible {
        case failed(String, Int32)

        var description: String {
            switch self {
            case .failed(let what, let code):
                return "\(what): \(String(cString: strerror(code)))"
            }
        }
    }
}
