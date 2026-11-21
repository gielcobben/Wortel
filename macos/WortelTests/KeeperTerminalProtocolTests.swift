import Darwin
import XCTest

/// A session whose terminal the keeper keeps (`KeeperCommand.terminal`),
/// exercised for real: a server on a temporary socket, shells on real ptys.
///
/// What has to hold, because the app's copy of every terminal is built from
/// it: the channel starts with a snapshot and then carries exactly the bytes
/// after it, none missing and none twice, however busy the program is; the
/// keeper never waits for an app that is not reading; and the program gets
/// its answers with no app at all.
final class KeeperTerminalProtocolTests: XCTestCase {
    private var path = ""
    private var server: KeeperServer?
    private var clients: [KeeperClient] = []
    private var descriptors: [Int32] = []

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "kt-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
    }

    override func tearDown() {
        clients.forEach { $0.disconnect() }
        clients = []
        descriptors.forEach { close($0) }
        descriptors = []
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    // MARK: - Harness

    private func startServer() throws {
        let server = KeeperServer(path: path)
        try server.start()
        self.server = server
    }

    private func connect() throws -> KeeperClient {
        let client = KeeperClient(path: path)
        XCTAssertTrue(try client.connect())
        clients.append(client)
        return client
    }

    private func plan(_ script: String) -> KeeperSpawnPlan {
        KeeperSpawnPlan(executable: "/bin/sh", arguments: ["-c", script],
                        environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-ghostty"],
                        workingDirectory: nil)
    }

    private struct Opened {
        let response: KeeperResponse
        let channel: Int32
        let pty: Int32
    }

    private func terminal(_ client: KeeperClient, _ id: String, _ script: String,
                          columns: UInt16 = 80, rows: UInt16 = 24) throws -> Opened {
        let (response, fds) = try client.sendForDescriptors(
            .terminal(session: id, plan: plan(script), columns: columns, rows: rows))
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(fds.count, 2, "a channel and a pty")
        descriptors += fds
        return Opened(response: response, channel: try XCTUnwrap(fds.first), pty: try XCTUnwrap(fds.last))
    }

    /// Read a channel until `done` says so, its end, or the timeout. Returns
    /// the snapshot and the output after it, and whether it ended.
    /// One reader per channel, so a second read of it goes on where the
    /// first stopped.
    private var readers: [Int32: KeeperChannelReader] = [:]
    private var snapshotSeen: Set<Int32> = []

    private func readChannel(_ fd: Int32, timeout: TimeInterval = 10,
                             until done: (Data) -> Bool = { _ in false })
        -> (snapshot: Data?, output: Data, ended: Bool) {
        var reader = readers[fd] ?? KeeperChannelReader()
        defer { readers[fd] = reader }
        var snapshot: Data?
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return (snapshot, output, true) }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue } else { return (snapshot, output, true) } }
            buffer.withUnsafeBufferPointer { raw in
                reader.feed(raw.baseAddress!, count: count) { piece in
                    switch piece {
                    case .snapshot(let data):
                        snapshot = data
                        self.snapshotSeen.insert(fd)
                    case .output(let bytes): output.append(bytes)
                    case .invalid: XCTFail("the channel is not a keeper's")
                    }
                }
            }
            if snapshotSeen.contains(fd), done(output) { return (snapshot, output, false) }
        }
        return (snapshot, output, false)
    }

    private func decode(_ snapshot: Data?) throws -> KeeperTerminal {
        try XCTUnwrap(KeeperTerminal(snapshot: try XCTUnwrap(snapshot), scrollbackBytes: Keeper.scrollbackBytes),
                      "the snapshot does not decode")
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: - The channel

    /// The basics: a snapshot, then the program's output; typing goes in
    /// through the pty the app was given, and comes back on the channel.
    func testChannelStartsWithASnapshotThenCarriesOutputAndTypingWorks() throws {
        try startServer()
        let opened = try terminal(try connect(), "a", "echo READY; read line; echo GOT-$line; sleep 30")
        XCTAssertGreaterThan(opened.response.pid ?? 0, 0)
        let first = readChannel(opened.channel) { self.text($0).contains("READY") }
        XCTAssertNotNil(first.snapshot)
        XCTAssertTrue(text(first.output).contains("READY"))

        _ = write(opened.pty, "ping\n", 5)
        let second = readChannel(opened.channel) { self.text($0).contains("GOT-ping") }
        XCTAssertTrue(text(second.output).contains("GOT-ping"))
    }

    /// **The cut.** Attach, read under a flood, attach again: the first
    /// snapshot plus everything the first channel carried up to its end must
    /// be exactly the terminal the second snapshot shows. A byte lost or
    /// carried twice between the two would show as a difference.
    func testAttachCutIsExact() throws {
        try startServer()
        let client = try connect()
        let script = "i=0; while [ $i -lt 30000 ]; do echo \"line $i of the flood\"; i=$((i+1)); done; sleep 30"
        let first = try terminal(client, "flood", script, columns: 60, rows: 20)

        // Read channel one on another thread, to its end.
        let firstRead = DispatchQueue(label: "first")
        var one: (snapshot: Data?, output: Data, ended: Bool)?
        let done = expectation(description: "first channel ended")
        firstRead.async {
            one = self.readChannel(first.channel, timeout: 20)
            done.fulfill()
        }
        usleep(300_000)                                   // mid-flood
        let second = try terminal(client, "flood", "unused")
        wait(for: [done], timeout: 25)
        let firstChannel = try XCTUnwrap(one)
        XCTAssertTrue(firstChannel.ended, "the first channel ends once the second begins")
        XCTAssertGreaterThan(firstChannel.output.count, 0, "the flood was under way")

        let replayed = try decode(firstChannel.snapshot)
        firstChannel.output.withUnsafeBytes { raw in
            replayed.write(raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count)
        }
        // Until its snapshot is in, not for a fixed time: under the load of
        // the whole suite a fixed 0.2 s read nothing now and then.
        let secondChannel = readChannel(second.channel, timeout: 5) { _ in true }
        let cut = try decode(secondChannel.snapshot)
        XCTAssertEqual(replayed.text(), cut.text(),
                       "snapshot one + channel one is not snapshot two: bytes were lost or repeated")
    }

    /// The same, within one channel: a snapshot asked for while the program
    /// floods (a terminal shown again) must be exactly the first snapshot
    /// plus every output frame between the two.
    func testAResyncIsExactInTheMiddleOfAFlood() throws {
        try startServer()
        let client = try connect()
        let script = "i=0; while [ $i -lt 30000 ]; do echo \"line $i of the flood\"; i=$((i+1)); done; sleep 30"
        let opened = try terminal(client, "flood", script, columns: 60, rows: 20)

        var reader = KeeperChannelReader()
        var snapshots: [Data] = []
        var between = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var asked = false
        let deadline = Date().addingTimeInterval(20)
        while snapshots.count < 2, Date() < deadline {
            var poller = pollfd(fd: opened.channel, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let count = Darwin.read(opened.channel, &buffer, buffer.count)
            guard count > 0 else { break }
            buffer.withUnsafeBufferPointer { raw in
                reader.feed(raw.baseAddress!, count: count) { piece in
                    switch piece {
                    case .snapshot(let data): snapshots.append(data)
                    case .output(let bytes): if snapshots.count == 1 { between.append(bytes) }
                    case .invalid: XCTFail("not a channel")
                    }
                }
            }
            if !asked, between.count > 200_000 {
                asked = true
                XCTAssertTrue(try client.send(.resync(session: "flood")).response.ok)
            }
        }
        XCTAssertEqual(snapshots.count, 2, "the resync's snapshot never came")
        let replayed = try decode(snapshots.first)
        between.withUnsafeBytes { replayed.write($0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        XCTAssertEqual(replayed.text(), try decode(snapshots.last).text(),
                       "snapshot one + the output between is not snapshot two")
    }

    // MARK: - Never waiting on the app

    /// An app that stops reading must not stop the shell: the keeper goes on
    /// reading the pty, and lets that app's channel go once it is too far
    /// behind. The terminal itself misses nothing.
    func testAnAppThatStopsReadingNeverStopsTheShell() throws {
        try startServer()
        let client = try connect()
        // 48 MB of output, more than a channel may hold back, then a marker.
        let script = "head -c 50331648 /dev/zero | tr '\\0' x | fold -w 100; echo; echo FLOOD-DONE; sleep 30"
        let opened = try terminal(client, "busy", script)
        // Never read `opened.channel`. The flood must still finish: the next
        // attach's snapshot shows its end.
        let deadline = Date().addingTimeInterval(60)
        var finished = false
        while Date() < deadline, !finished {
            usleep(250_000)
            let again = try terminal(client, "busy", "unused")
            let read = readChannel(again.channel, timeout: 1)
            finished = (try? decode(read.snapshot))?.text().contains("FLOOD-DONE") ?? false
        }
        XCTAssertTrue(finished, "the shell stalled behind an app that was not reading")
        // And the channel nobody read was let go of rather than held forever.
        var byte: UInt8 = 0
        var ended = false
        let drainUntil = Date().addingTimeInterval(10)
        _ = fcntl(opened.channel, F_SETFL, fcntl(opened.channel, F_GETFL, 0) | O_NONBLOCK)
        while Date() < drainUntil {
            let count = Darwin.read(opened.channel, &byte, 1)
            if count == 0 { ended = true; break }
            if count < 0 { usleep(10_000) }
        }
        XCTAssertTrue(ended, "a channel that fell behind should end")
    }

    /// A shell that writes a flood and ends while its app is not reading:
    /// everything it wrote still reaches the app, then the terminal as it
    /// ended, then the channel's end. The keeper lets go of the channel as
    /// the session ends; what it had queued must not go with it.
    func testAChannelEndingWithOutputQueuedDeliversAllOfIt() throws {
        try startServer()
        let opened = try terminal(try connect(), "brief-flood",
                                  "seq 1 600000 | sed 's/^/line /'; echo LAST-LINE")
        // ~6 MB, more than the socket's buffers hold, so most of it is queued
        // in the keeper; the shell is long gone before anything is read.
        usleep(3_000_000)
        var reader = KeeperChannelReader()
        var output = Data(), snapshots = 0, ended = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !ended {
            var poller = pollfd(fd: opened.channel, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let count = Darwin.read(opened.channel, &buffer, buffer.count)
            if count <= 0 { ended = true; break }
            buffer.withUnsafeBufferPointer { raw in
                reader.feed(raw.baseAddress!, count: count) { piece in
                    switch piece {
                    case .snapshot: snapshots += 1
                    case .output(let bytes): output.append(bytes)
                    case .invalid: XCTFail("not a channel")
                    }
                }
            }
        }
        XCTAssertTrue(ended, "the channel never ended")
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("LAST-LINE"), "the end of the output was lost")
        XCTAssertEqual(snapshots, 2, "the first snapshot and the one as it ended")
    }

    // MARK: - Answers with no app

    /// A program asks the terminal who it is while nobody is attached, and is
    /// answered: the keeper's terminal does it, as Ghostty would.
    func testTheProgramIsAnsweredWithNoAppAttached() throws {
        try startServer()
        let client = try connect()
        // Ask DA1, read the answer up to its final `c`, print what came back.
        let script = "stty raw -echo; printf '\\033[c'; ans=$(dd bs=1 count=12 2>/dev/null); stty sane; echo \"ANSWER:$ans\" | tr '\\033' E; echo ASKED; sleep 30"
        let opened = try terminal(client, "asks", script)
        close(opened.channel)            // no app reading
        descriptors.removeAll { $0 == opened.channel }
        usleep(800_000)
        let again = try terminal(client, "asks", "unused")
        let read = readChannel(again.channel, timeout: 2)
        let screen = try decode(read.snapshot).text() + text(read.output)
        XCTAssertTrue(screen.contains("ASKED"), screen)
        XCTAssertTrue(screen.contains("ANSWER:E[?62;22;52c"), "DA1 not answered: \(screen)")
    }

    /// What Claude Code does at startup: the status question, DA1 behind
    /// it, and "supported" only if the status answer came first. Asked with
    /// no app attached, which is also an agent started while Wortel is closed:
    /// it is answered all the same, so it reports from its first turn.
    func testTheStatusQuestionIsAnsweredBeforeDA1WithNoAppAttached() throws {
        try startServer()
        let client = try connect()
        // The first byte after the ESC that starts the first answer: `]` for
        // OSC 7501, `[` for DA1.
        let script = "stty raw -echo; printf '\\033]7501;?\\033\\\\\\033[c'; first=$(dd bs=1 count=2 2>/dev/null | tail -c 1); stty sane; echo \"FIRST:$first\"; sleep 30"
        let opened = try terminal(client, "agent", script)
        close(opened.channel)
        descriptors.removeAll { $0 == opened.channel }
        usleep(800_000)
        let again = try terminal(client, "agent", "unused")
        let read = readChannel(again.channel, timeout: 2)
        let screen = try decode(read.snapshot).text() + text(read.output)
        XCTAssertTrue(screen.contains("FIRST:]"), "the status question was not answered first: \(screen)")
    }

    // MARK: - Size

    /// A resize reaches the program (SIGWINCH and the new size) and the
    /// keeper's terminal, at one point in the stream.
    func testResizeReachesTheProgramAndTheTerminal() throws {
        try startServer()
        let client = try connect()
        let script = "trap 'echo SIZE-$(stty size)' WINCH; echo READY; while :; do sleep 0.1; done"
        let opened = try terminal(client, "sized", script, columns: 80, rows: 24)
        _ = readChannel(opened.channel) { self.text($0).contains("READY") }
        let (response, _) = try client.send(.resize(session: "sized", columns: 100, rows: 30, cellWidth: 8, cellHeight: 16))
        XCTAssertTrue(response.ok)
        let read = readChannel(opened.channel) { self.text($0).contains("SIZE-30 100") }
        XCTAssertTrue(text(read.output).contains("SIZE-30 100"))
        let again = try terminal(client, "sized", "unused")
        // Until its snapshot is in: a fixed 0.5 s read nothing now and then
        // under the load of the whole suite (2026-11-20).
        let reread = readChannel(again.channel, timeout: 5) { _ in true }
        XCTAssertNotNil(reread.snapshot, "no snapshot on the new channel: ended \(reread.ended), \(reread.output.count) bytes of output, first channel ended \(readChannel(opened.channel, timeout: 0.5).ended)")
        let cut = try decode(reread.snapshot)
        XCTAssertEqual(cut.columns, 100)
        XCTAssertEqual(cut.rows, 30)
    }

    /// The end of the shell is the end of its channel, after its last words.
    func testTheChannelEndsAfterTheShellsLastOutput() throws {
        try startServer()
        let opened = try terminal(try connect(), "short", "echo LAST-WORDS")
        let read = readChannel(opened.channel, timeout: 5)
        XCTAssertTrue(read.ended)
        let screen = try decode(read.snapshot).text() + text(read.output)
        XCTAssertTrue(screen.contains("LAST-WORDS"))
    }
}
