import Darwin
import XCTest

/// Does routing a pty through the keeper cost anything to read?
///
/// The design's whole justification is that it does not: the keeper passes the
/// descriptor rather than the bytes, so while a session is attached the app
/// reads the same open file description it would have read anyway. That is a
/// claim about the hottest path in a terminal, so it is measured rather than
/// asserted — Wortel's pitch is Ghostty-class throughput, and a regression here
/// would be the one that matters.
final class KeeperThroughputTests: XCTestCase {
    private var path = ""
    private var server: KeeperServer?

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "t-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    /// Read a descriptor until it ends, returning bytes and seconds.
    private func drain(_ fd: Int32, timeout: TimeInterval = 30) -> (bytes: Int, seconds: Double) {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                total += count
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(200)
            } else {
                break
            }
        }
        return (total, Date().timeIntervalSince(start))
    }

    /// ~8MB of output, which is enough to swamp any per-call overhead.
    private var script: String {
        "for i in $(seq 1 2000); do " +
        "printf '%s\\n' 'wortel throughput measurement line, long enough to be realistic ---------'; " +
        "done; " +
        "for i in $(seq 1 40); do cat /usr/share/dict/words 2>/dev/null || true; done"
    }

    func testAPassedDescriptorReadsAsFastAsALocalOne() throws {
        // Local: a pty this process forked, the way the app does today.
        let local = PtyHost()
        local.onOutput = { _, _ in } // the source is only there to be paused
        XCTAssertTrue(local.start(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: nil,
            columns: 200, rows: 50))
        local.pauseReading() // read it ourselves, as the app would
        let direct = drain(local.master)
        local.stop()

        // Through the keeper: the descriptor crossed a process boundary.
        let server = KeeperServer(path: path)
        try server.start()
        self.server = server
        let client = KeeperClient(path: path)
        XCTAssertTrue(try client.connect())
        let (_, fd) = try client.send(.open(
            session: "t",
            plan: KeeperSpawnPlan(executable: "/bin/sh", arguments: ["-c", script],
                                  environment: ["PATH": "/usr/bin:/bin"],
                                  workingDirectory: nil),
            columns: 200, rows: 50))
        let passed = try XCTUnwrap(fd)
        let viaKeeper = drain(passed)
        close(passed)
        client.disconnect()

        let directRate = Double(direct.bytes) / direct.seconds / 1_048_576
        let keeperRate = Double(viaKeeper.bytes) / viaKeeper.seconds / 1_048_576
        print(String(format: "THROUGHPUT direct %.1f MB/s (%d bytes), keeper %.1f MB/s (%d bytes)",
                     directRate, direct.bytes, keeperRate, viaKeeper.bytes))

        XCTAssertGreaterThan(direct.bytes, 500_000, "the local pty produced too little to compare")
        XCTAssertGreaterThan(viaKeeper.bytes, 500_000, "the keeper's pty produced too little")
        // Deliberately loose. The point is that passing the descriptor is not a
        // *category* change — no per-byte copy, no round trip — not that two
        // runs on a busy machine land on the same number.
        XCTAssertGreaterThan(keeperRate, directRate / 2,
                             "reading a passed descriptor got materially slower")
    }
}
