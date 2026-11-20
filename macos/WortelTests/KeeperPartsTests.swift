import Darwin
import XCTest

/// Pieces the keeper is built from, tested apart from it: the tail of a
/// session's output, and the descriptor passing that hands the app its
/// channel and its pty.
final class KeeperPartsTests: XCTestCase {

    // MARK: - OutputTail

    private func append(_ text: String, to tail: inout OutputTail) {
        Array(text.utf8).withUnsafeBufferPointer { tail.append($0.baseAddress!, count: $0.count) }
    }

    private func text(_ tail: OutputTail) -> String { String(decoding: tail.copy(), as: UTF8.self) }

    func testItKeepsWhatFits() {
        var tail = OutputTail(limit: 64)
        append("hello", to: &tail)
        XCTAssertEqual(text(tail), "hello")
    }

    /// **Drops the oldest, not the newest.** What a program said about itself
    /// last is what an app that attaches needs to read.
    func testOverflowDropsFromTheFront() {
        var tail = OutputTail(limit: 8)
        append("0123456789ab", to: &tail)
        XCTAssertEqual(text(tail), "456789ab")
    }

    func testOverflowAcrossSeveralWrites() {
        var tail = OutputTail(limit: 6)
        append("abcd", to: &tail)
        append("efgh", to: &tail)
        XCTAssertEqual(text(tail), "cdefgh")
    }

    /// A copy leaves it as it was: every app that attaches reads the same.
    func testCopyingLeavesItWhole() {
        var tail = OutputTail(limit: 64)
        append("twice", to: &tail)
        XCTAssertEqual(text(tail), "twice")
        XCTAssertEqual(text(tail), "twice")
    }

    func testAZeroLimitKeepsNothingRatherThanCrashing() {
        var tail = OutputTail(limit: 0)
        append("anything", to: &tail)
        XCTAssertTrue(tail.isEmpty)
        XCTAssertTrue(tail.copy().isEmpty)
    }

    /// The ring has to be indistinguishable from "keep the last `limit`
    /// bytes", wherever the writes fall against the wrap: short ones, ones
    /// that straddle it, ones larger than all of it.
    func testTheRingKeepsExactlyTheTailOverManyWrites() {
        var generator = SystemRandomNumberGenerator()
        for limit in [1, 7, 64, 1000] {
            var tail = OutputTail(limit: limit)
            var everything: [UInt8] = []
            for round in 0..<300 {
                let size = Int.random(in: 1...(limit * 2), using: &generator)
                let chunk = (0..<size).map { UInt8(truncatingIfNeeded: round &* 31 &+ $0) }
                chunk.withUnsafeBufferPointer { tail.append($0.baseAddress!, count: size) }
                everything += chunk
                XCTAssertEqual(tail.count, min(everything.count, limit))
            }
            XCTAssertEqual(tail.copy(), Data(everything.suffix(limit)), "limit \(limit)")
        }
    }

    // MARK: - Passing a descriptor

    /// Over a real socket pair, with a real pty on the other end — because the
    /// mechanics fail quietly and only an actual descriptor proves otherwise.
    func testADescriptorSurvivesTheCrossing() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }

        // A pipe stands in for the pty: same question, less setup.
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[0]) }

        try FileDescriptorChannel.send(Data("{\"ok\":true}\n".utf8),
                                       descriptor: ends[0], over: pair[0])
        let received = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(String(decoding: received.line, as: UTF8.self), "{\"ok\":true}")

        let passed = try XCTUnwrap(received.descriptor)
        defer { close(passed) }
        XCTAssertNotEqual(passed, ends[0], "the same number, so nothing actually crossed")

        // The proof: writing the original end is readable through the passed one.
        _ = write(ends[1], "through", 7)
        close(ends[1])
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(passed, &buffer, buffer.count)
        XCTAssertEqual(String(decoding: buffer[0..<max(0, count)], as: UTF8.self), "through")
    }

    /// A session's channel and its pty cross in one message, in order.
    func testTwoDescriptorsCrossTogetherInOrder() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        var first: [Int32] = [0, 0], second: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&first), 0)
        XCTAssertEqual(pipe(&second), 0)
        defer { [first[0], first[1], second[0], second[1]].forEach { close($0) } }

        try FileDescriptorChannel.send(Data("two\n".utf8), descriptors: [first[0], second[0]], over: pair[0])
        let received = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(received.descriptors.count, 2)
        defer { received.descriptors.forEach { close($0) } }
        _ = write(first[1], "one", 3)
        _ = write(second[1], "two", 3)
        var buffer = [UInt8](repeating: 0, count: 8)
        var n = read(received.descriptors[0], &buffer, 8)
        XCTAssertEqual(String(decoding: buffer[0..<max(0, n)], as: UTF8.self), "one")
        n = read(received.descriptors[1], &buffer, 8)
        XCTAssertEqual(String(decoding: buffer[0..<max(0, n)], as: UTF8.self), "two")
    }

    /// Most messages carry no descriptor, and must not invent one.
    func testALineWithoutADescriptorArrivesAlone() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }

        try FileDescriptorChannel.send(Data("plain\n".utf8), descriptor: nil, over: pair[0])
        let received = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(String(decoding: received.line, as: UTF8.self), "plain")
        XCTAssertNil(received.descriptor)
    }

    /// Two messages back to back must not hand the first one's descriptor to the
    /// second — the reason the reader never reads past a newline.
    func testDescriptorsStayWithTheirOwnMessage() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }

        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[0]); close(ends[1]) }

        try FileDescriptorChannel.send(Data("first\n".utf8), descriptor: ends[0], over: pair[0])
        try FileDescriptorChannel.send(Data("second\n".utf8), descriptor: nil, over: pair[0])

        let first = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(String(decoding: first.line, as: UTF8.self), "first")
        let passed = try XCTUnwrap(first.descriptor)
        close(passed)

        let second = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(String(decoding: second.line, as: UTF8.self), "second")
        XCTAssertNil(second.descriptor, "a descriptor leaked onto the next message")
    }

    /// A full replay is a line far larger than the socket's buffer, so it
    /// crosses in many pieces while the reader is already taking them. The
    /// descriptor rides on the first piece only and must arrive once, with
    /// the whole line, and the next line must start clean after it.
    func testALargeLineArrivesWholeWithItsDescriptor() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[0]); close(ends[1]) }

        let large = Data((0..<700_000).map { UInt8(ascii: "a") + UInt8($0 % 26) })
        let sender = pair[0], carried = ends[0]
        let sent = expectation(description: "sent")
        DispatchQueue.global().async {
            try? FileDescriptorChannel.send(large + Data("\n".utf8), descriptor: carried, over: sender)
            try? FileDescriptorChannel.send(Data("after\n".utf8), descriptor: nil, over: sender)
            sent.fulfill()
        }

        let first = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(first.line, large)
        let passed = try XCTUnwrap(first.descriptor, "the descriptor did not come with the line")
        close(passed)
        let second = try XCTUnwrap(FileDescriptorChannel.receiveLine(from: pair[1]))
        XCTAssertEqual(String(decoding: second.line, as: UTF8.self), "after")
        XCTAssertNil(second.descriptor)
        wait(for: [sent], timeout: 5)
    }

    /// End of stream is nil, not an empty line that a caller might act on.
    func testAClosedPeerReadsAsNothing() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        close(pair[0])
        XCTAssertNil(try FileDescriptorChannel.receiveLine(from: pair[1]))
    }
}
