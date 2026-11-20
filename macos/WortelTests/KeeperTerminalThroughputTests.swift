import Darwin
import XCTest

/// What the keeper keeping the terminal costs on the hottest path a terminal
/// has: a program writing as fast as it can.
///
/// Protocol 1 passed the pty and the keeper did nothing per byte. With the
/// keeper keeping the terminal it reads every byte, parses it into its own
/// terminal and forwards it to the app through a socket. The app's own work
/// is the same either way (it parses the same bytes into its surface), so
/// this measures exactly what is added: the keeper's read, parse and copy,
/// in wall time to the last byte and in CPU.
final class KeeperTerminalThroughputTests: XCTestCase {
    private var path = ""
    private var server: KeeperServer?
    private var file = ""

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "tt-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
        file = NSTemporaryDirectory() + "tt-\(UInt32.random(in: 0..<0xFFFF_FFFF)).txt"
        // 64 MB of the kind of output agents and builds make: text with
        // colour changes, a few wide characters, and long lines that wrap.
        var chunk = ""
        for i in 0..<2000 {
            chunk += "\u{1B}[3\(i % 8)mline \(i)\u{1B}[0m compiling module \(i * 7) of the build ── ok ✓ "
            chunk += String(repeating: "x", count: i % 120) + "\r\n"
        }
        let data = Data(chunk.utf8)
        FileManager.default.createFile(atPath: file, contents: nil)
        let handle = FileHandle(forWritingAtPath: file)!
        var written = 0
        while written < 64 * 1024 * 1024 { handle.write(data); written += data.count }
        try? handle.close()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: file)
        super.tearDown()
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Read until `marker` has gone past, counting bytes.
    private func drain(_ fd: Int32, until marker: [UInt8], timeout: TimeInterval = 60) -> Int {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var tail = [UInt8]()
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { if count < 0 && (errno == EAGAIN || errno == EINTR) { continue } else { break } }
            total += count
            tail = Array((tail + buffer[0..<count]).suffix(64))
            if tail.windowContaining(marker) { break }
        }
        return total
    }

    private func plan() -> KeeperSpawnPlan {
        KeeperSpawnPlan(executable: "/bin/sh", arguments: ["-c", "stty -echo; cat '\(file)'; echo THROUGHPUT-END; sleep 30"],
                        environment: ["PATH": "/usr/bin:/bin"], workingDirectory: nil)
    }

    func testWhatKeepingTheTerminalCosts() throws {
        let server = KeeperServer(path: path)
        try server.start()
        self.server = server
        let client = KeeperClient(path: path)
        XCTAssertTrue(try client.connect())
        let marker = Array("THROUGHPUT-END".utf8)

        func run(_ terminal: Bool, _ id: String) throws -> (mbps: Double, cpuPerMB: Double, bytes: Int) {
            let fd: Int32
            if terminal {
                let (_, fds) = try client.sendForDescriptors(.terminal(session: id, plan: plan(), columns: 160, rows: 48))
                fd = try XCTUnwrap(fds.first)
                fds.dropFirst().forEach { close($0) }
            } else {
                let (_, passed) = try client.send(.open(session: id, plan: plan(), columns: 160, rows: 48))
                fd = try XCTUnwrap(passed)
            }
            defer { close(fd) }
            let cpu = cpuSeconds(), start = Date()
            let bytes = drain(fd, until: marker)
            let seconds = Date().timeIntervalSince(start), used = cpuSeconds() - cpu
            let mb = Double(bytes) / 1_048_576
            return (mb / seconds, used / mb, bytes)
        }

        // Alternated, twice each, so a busy moment lands on both.
        var direct: [(mbps: Double, cpuPerMB: Double, bytes: Int)] = []
        var kept: [(mbps: Double, cpuPerMB: Double, bytes: Int)] = []
        for round in 0..<2 {
            direct.append(try run(false, "direct\(round)"))
            kept.append(try run(true, "kept\(round)"))
        }
        for (name, runs) in [("pty passed (protocol 1)", direct), ("terminal kept", kept)] {
            for r in runs {
                print(String(format: "THROUGHPUT %@: %.0f MB/s, %.2f ms CPU per MB, %d bytes",
                             name, r.mbps, r.cpuPerMB * 1000, r.bytes))
            }
        }
        XCTAssertTrue(kept.allSatisfy { $0.bytes > 60 * 1_048_576 }, "the kept terminal's channel lost output")
    }
}

extension KeeperTerminalThroughputTests {
    /// A key's round trip: typed into the pty, echoed by the program, back
    /// to the app. Keys go straight to the pty either way; the echo now comes
    /// through the keeper. 2000 trips each, alternated in blocks.
    func testWhatKeepingTheTerminalCostsAKeystroke() throws {
        let server = KeeperServer(path: path)
        try server.start()
        self.server = server
        let client = KeeperClient(path: path)
        XCTAssertTrue(try client.connect())
        let echo = KeeperSpawnPlan(executable: "/bin/sh", arguments: ["-c", "stty raw -echo; exec cat"],
                                   environment: ["PATH": "/usr/bin:/bin"], workingDirectory: nil)

        func waitReadable(_ fd: Int32) { var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0); _ = poll(&p, 1, 1000) }

        func trips(terminal: Bool, id: String, count: Int) throws -> [Double] {
            var readFD: Int32 = -1, writeFD: Int32 = -1
            if terminal {
                let (_, fds) = try client.sendForDescriptors(.terminal(session: id, plan: echo, columns: 80, rows: 24))
                readFD = fds[0]; writeFD = fds[1]
            } else {
                let (_, fd) = try client.send(.open(session: id, plan: echo, columns: 80, rows: 24))
                readFD = try XCTUnwrap(fd); writeFD = readFD
            }
            defer { close(readFD); if writeFD != readFD { close(writeFD) } }
            var reader = KeeperChannelReader()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            // Let the shell settle, and take the snapshot off the channel.
            usleep(300_000)
            while true {
                var p = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 50) > 0 else { break }
                let n = read(readFD, &buffer, buffer.count)
                if n <= 0 { break }
                if terminal { buffer.withUnsafeBufferPointer { b in reader.feed(b.baseAddress!, count: n) { _ in } } }
            }
            var samples: [Double] = []
            var key: UInt8 = 0x61
            for _ in 0..<count {
                var got = false
                let start = DispatchTime.now().uptimeNanoseconds
                _ = write(writeFD, &key, 1)
                while !got {
                    waitReadable(readFD)
                    let n = read(readFD, &buffer, buffer.count)
                    guard n > 0 else { continue }
                    if terminal {
                        buffer.withUnsafeBufferPointer { b in
                            reader.feed(b.baseAddress!, count: n) { piece in if case .output = piece { got = true } }
                        }
                    } else { got = true }
                }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
            }
            return samples.sorted()
        }

        var direct: [Double] = [], kept: [Double] = []
        for round in 0..<4 {
            direct += try trips(terminal: false, id: "d\(round)", count: 500)
            kept += try trips(terminal: true, id: "k\(round)", count: 500)
        }
        direct.sort(); kept.sort()
        func at(_ a: [Double], _ q: Double) -> Double { a[min(a.count - 1, Int(Double(a.count) * q))] }
        print(String(format: "KEYSTROKE pty passed: median %.0f µs, p99 %.0f µs; terminal kept: median %.0f µs, p99 %.0f µs",
                     at(direct, 0.5), at(direct, 0.99), at(kept, 0.5), at(kept, 0.99)))
        XCTAssertEqual(kept.count, 2000)
    }
}

private extension Array where Element == UInt8 {
    func windowContaining(_ needle: [UInt8]) -> Bool {
        guard count >= needle.count else { return false }
        for start in 0...(count - needle.count) where self[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}
