import Darwin
import XCTest

/// The two pieces the keeper is built from, tested apart from it: the buffer
/// that holds what you missed, and the descriptor passing that makes the whole
/// design affordable.
final class KeeperPartsTests: XCTestCase {

    // MARK: - ReplayBuffer

    private func append(_ text: String, to buffer: inout ReplayBuffer) {
        buffer.append(Data(text.utf8))
    }

    /// What `take` hands back for a replay whose start was dropped.
    private func cut(_ text: String) -> String {
        String(decoding: ReplayBuffer.resync + Data(text.utf8), as: UTF8.self)
    }

    func testItKeepsWhatFits() {
        var buffer = ReplayBuffer(limit: 64)
        append("hello", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), "hello")
    }

    /// **Drops the oldest, not the newest.** The useful end of a terminal's
    /// output is the end: if an agent produced 40MB overnight, what you want on
    /// reattach is how it finished.
    func testOverflowDropsFromTheFront() {
        var buffer = ReplayBuffer(limit: 8)
        append("0123456789ab", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), cut("456789ab"))
    }

    func testOverflowAcrossSeveralWrites() {
        var buffer = ReplayBuffer(limit: 6)
        append("abcd", to: &buffer)
        append("efgh", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), cut("cdefgh"))
    }

    /// A single write bigger than the whole buffer is the `cat` of a large file
    /// case, and it must not allocate the whole thing to then throw it away.
    func testAWriteLargerThanTheBufferKeepsOnlyItsTail() {
        var buffer = ReplayBuffer(limit: 4)
        append("abcdefghij", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), cut("ghij"))
        XCTAssertEqual(buffer.count, 0)
    }

    /// Taking empties it. Replaying the same screenful twice is what a reattach
    /// loop would do otherwise.
    func testTakingEmptiesIt() {
        var buffer = ReplayBuffer(limit: 64)
        append("once", to: &buffer)
        XCTAssertFalse(buffer.take().isEmpty)
        XCTAssertTrue(buffer.take().isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    /// The dropped count is the difference between "you have everything" and
    /// "you have the tail" — a replay that silently omits the start looks
    /// exactly like one that didn't.
    func testItRecordsWhatItThrewAway() {
        var buffer = ReplayBuffer(limit: 4)
        append("abcdef", to: &buffer)
        XCTAssertEqual(buffer.dropped, 2)
    }

    func testAZeroLimitKeepsNothingRatherThanCrashing() {
        var buffer = ReplayBuffer(limit: 0)
        append("anything", to: &buffer)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertTrue(buffer.take().isEmpty)
    }

    /// The ring has to be indistinguishable from the plain "keep the last
    /// `limit` bytes" it replaced, wherever the writes happen to fall against
    /// the wrap: short ones, ones that straddle it, ones that fill it exactly.
    func testTheRingKeepsExactlyTheTailOverManyWrites() {
        var generator = SystemRandomNumberGenerator()
        for limit in [1, 7, 64, 1000] {
            var buffer = ReplayBuffer(limit: limit)
            var everything: [UInt8] = []
            for round in 0..<300 {
                let size = Int.random(in: 1...(limit * 2), using: &generator)
                let chunk = (0..<size).map { UInt8(truncatingIfNeeded: round &* 31 &+ $0) }
                chunk.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: size) }
                everything += chunk
                XCTAssertEqual(buffer.count, min(everything.count, limit))
            }
            let expected = ReplayBuffer.resync + Data(everything.suffix(limit))
            XCTAssertEqual(buffer.dropped, everything.count - limit)
            XCTAssertEqual(buffer.take(), expected, "limit \(limit)")
        }
    }

    /// Nothing dropped, nothing put in front: a replay that is all there needs
    /// no resync, and the bytes go to the terminal exactly as the shell wrote
    /// them.
    func testOnlyACutReplayStartsWithTheResync() {
        var buffer = ReplayBuffer(limit: 8)
        append("12345678", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), "12345678")
        append("123456789", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), cut("23456789"))
        // And a take starts a new round: what was dropped before it is not
        // counted against what comes after.
        append("abc", to: &buffer)
        XCTAssertEqual(String(decoding: buffer.take(), as: UTF8.self), "abc")
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
