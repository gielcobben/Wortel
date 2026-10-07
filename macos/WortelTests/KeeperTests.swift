import Darwin
import XCTest

/// The keeper, exercised for real: a server on a temporary socket, actual ptys
/// with actual shells on them, and descriptors passed between processes.
///
/// Worth every bit of the setup, because this is the one component whose whole
/// purpose is to still be correct after the app is gone, and each failure mode
/// is invisible from either side alone:
///
/// - Two readers on one pty split the byte stream. The corruption is
///   intermittent and cannot be reproduced on demand.
/// - A descriptor that arrives unnoticed is a leak that shows up hours later.
/// - A client that dies without detaching leaves a shell blocked on a pty
///   nobody drains — the exact opposite of surviving.
final class KeeperTests: XCTestCase {
    private var path = ""
    private var server: KeeperServer?
    private var clients: [KeeperClient] = []
    private var descriptors: [Int32] = []

    override func setUp() {
        super.setUp()
        // Short: sun_path is 104 bytes and the temp directory spends half.
        path = NSTemporaryDirectory() + "k-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
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

    @discardableResult
    private func startServer(replayLimit: Int = 64 * 1024) throws -> KeeperServer {
        let server = KeeperServer(path: path, replayLimit: replayLimit)
        try server.start()
        self.server = server
        return server
    }

    private func connect() throws -> KeeperClient {
        let client = KeeperClient(path: path)
        XCTAssertTrue(try client.connect())
        clients.append(client)
        return client
    }

    /// A shell that announces itself and then waits, so the test can tell it is
    /// alive without racing its startup.
    private func plan(_ script: String) -> KeeperSpawnPlan {
        KeeperSpawnPlan(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-ghostty"],
            workingDirectory: nil)
    }

    /// Read from a pty until `marker` shows up, or give up.
    @discardableResult
    private func read(_ fd: Int32, until marker: String, timeout: TimeInterval = 5) -> String {
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                text += String(decoding: buffer[0..<count], as: UTF8.self)
                if text.contains(marker) { return text }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(20_000)
            } else {
                break
            }
        }
        return text
    }

    // MARK: - The basics

    func testPingAnswersWithItsVersion() throws {
        try startServer()
        let (response, _) = try connect().send(.ping)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.version, Keeper.version)
    }

    /// The core move: the keeper forks the shell, and hands us the pty itself
    /// rather than a stream of copies of what it read.
    func testOpenReturnsAWorkingPty() throws {
        try startServer()
        let (response, fd) = try connect().send(
            .open(session: "a", plan: plan("echo READY; sleep 30"), columns: 80, rows: 24))
        XCTAssertTrue(response.ok, response.message ?? "")
        let descriptor = try XCTUnwrap(fd)
        descriptors.append(descriptor)
        XCTAssertGreaterThan(try XCTUnwrap(response.pid), 0)
        XCTAssertTrue(read(descriptor, until: "READY").contains("READY"))
    }

    /// Input has to flow the other way through the same descriptor, or the
    /// terminal is a read-only view of a shell you cannot type at.
    func testThePassedDescriptorTakesInput() throws {
        try startServer()
        let (_, fd) = try connect().send(
            .open(session: "a", plan: plan("read line; echo GOT-$line; sleep 30"),
                  columns: 80, rows: 24))
        let descriptor = try XCTUnwrap(fd)
        descriptors.append(descriptor)
        _ = write(descriptor, "ping\n", 5)
        XCTAssertTrue(read(descriptor, until: "GOT-ping").contains("GOT-ping"))
    }

    // MARK: - Surviving

    /// **The whole feature, in one test.** Open a session, drop the connection
    /// the way a quitting app does, and the shell is still there — with the same
    /// pid — for a completely new client to pick up.
    func testAShellOutlivesTheClientThatOpenedIt() throws {
        try startServer()
        let first = try connect()
        let (opened, fd) = try first.send(
            .open(session: "s", plan: plan("echo ALIVE; sleep 60"), columns: 80, rows: 24))
        let descriptor = try XCTUnwrap(fd)
        let pid = try XCTUnwrap(opened.pid)
        XCTAssertTrue(read(descriptor, until: "ALIVE").contains("ALIVE"))

        // The app quits: connection gone, descriptor gone, no detach sent.
        close(descriptor)
        first.disconnect()
        usleep(200_000)

        XCTAssertEqual(kill(pid, 0), 0, "the shell died with its client")

        // A new launch attaches to work already in progress.
        let second = try connect()
        let (attached, again) = try second.send(.attach(session: "s"))
        XCTAssertTrue(attached.ok, attached.message ?? "")
        XCTAssertEqual(attached.pid, pid, "attached to a different shell")
        let reattached = try XCTUnwrap(again)
        descriptors.append(reattached)
        _ = write(reattached, "echo SECOND\n", 12)
        XCTAssertTrue(read(reattached, until: "SECOND").contains("SECOND"))
    }

    /// What the shell said while nobody was listening has to be there when you
    /// come back — otherwise reattaching shows a blank screen and the work looks
    /// lost even though it isn't.
    func testOutputProducedWhileDetachedIsReplayed() throws {
        try startServer()
        let client = try connect()
        let (_, fd) = try client.send(
            .open(session: "s", plan: plan("echo FIRST; sleep 0.3; echo WHILE-AWAY; sleep 30"),
                  columns: 80, rows: 24))
        let descriptor = try XCTUnwrap(fd)
        XCTAssertTrue(read(descriptor, until: "FIRST").contains("FIRST"))

        // Detach before the second line is printed.
        _ = try client.send(.detach(session: "s"))
        close(descriptor)
        usleep(600_000)

        let (attached, again) = try client.send(.attach(session: "s"))
        let reattached = try XCTUnwrap(again)
        descriptors.append(reattached)
        let replay = String(decoding: attached.replay ?? Data(), as: UTF8.self)
        XCTAssertTrue(replay.contains("WHILE-AWAY"),
                      "missed output was not replayed; got \(replay.debugDescription)")
    }

    /// Replay is handed over, not copied: attaching twice must not show the same
    /// screenful again.
    func testReplayIsNotDeliveredTwice() throws {
        try startServer()
        let client = try connect()
        let (_, fd) = try client.send(
            .open(session: "s", plan: plan("sleep 0.2; echo ONCE; sleep 30"),
                  columns: 80, rows: 24))
        close(try XCTUnwrap(fd))
        _ = try client.send(.detach(session: "s"))
        usleep(500_000)

        let (first, fd1) = try client.send(.attach(session: "s"))
        if let fd1 { descriptors.append(fd1) }
        XCTAssertTrue(String(decoding: first.replay ?? Data(), as: UTF8.self).contains("ONCE"))

        _ = try client.send(.detach(session: "s"))
        let (second, fd2) = try client.send(.attach(session: "s"))
        if let fd2 { descriptors.append(fd2) }
        XCTAssertFalse(String(decoding: second.replay ?? Data(), as: UTF8.self).contains("ONCE"),
                       "the same output was replayed twice")
    }

    // MARK: - One reader at a time

    /// The invariant the whole design rests on. Two readers would split the byte
    /// stream between them, and the corruption would be intermittent and
    /// unreproducible — so a second attach is refused outright.
    func testASecondClientCannotStealAnAttachedSession() throws {
        try startServer()
        let first = try connect()
        let (_, fd) = try first.send(
            .open(session: "s", plan: plan("sleep 30"), columns: 80, rows: 24))
        descriptors.append(try XCTUnwrap(fd))

        let second = try connect()
        let (response, stolen) = try second.send(.attach(session: "s"))
        if let stolen { close(stolen) }
        XCTAssertFalse(response.ok, "two clients were allowed to read one pty")
    }

    /// But once the holder lets go, the next client gets it.
    func testTheSessionIsAvailableAgainAfterTheHolderDisconnects() throws {
        try startServer()
        let first = try connect()
        let (_, fd) = try first.send(
            .open(session: "s", plan: plan("sleep 30"), columns: 80, rows: 24))
        close(try XCTUnwrap(fd))
        first.disconnect()
        usleep(200_000)

        let (response, again) = try connect().send(.attach(session: "s"))
        if let again { descriptors.append(again) }
        XCTAssertTrue(response.ok, response.message ?? "")
    }

    // MARK: - Housekeeping

    /// Opening a session that is already running is an attach, not a second
    /// shell. This is what makes a relaunch idempotent: an app restoring its
    /// session list must not fork a duplicate for every session that never died.
    func testOpeningAnExistingSessionAttachesInstead() throws {
        try startServer()
        let client = try connect()
        let (first, fd1) = try client.send(
            .open(session: "s", plan: plan("sleep 30"), columns: 80, rows: 24))
        close(try XCTUnwrap(fd1))
        _ = try client.send(.detach(session: "s"))

        let (second, fd2) = try client.send(
            .open(session: "s", plan: plan("sleep 30"), columns: 80, rows: 24))
        if let fd2 { descriptors.append(fd2) }
        XCTAssertEqual(second.pid, first.pid, "a second shell was forked for one session")
        XCTAssertEqual(server?.sessionCount, 1)
    }

    func testListReportsWhatIsRunning() throws {
        try startServer()
        let client = try connect()
        for id in ["a", "b"] {
            let (_, fd) = try client.send(
                .open(session: id, plan: plan("sleep 30"), columns: 80, rows: 24))
            close(try XCTUnwrap(fd))
            _ = try client.send(.detach(session: id))
        }
        let (response, _) = try client.send(.list)
        XCTAssertEqual(response.sessions?.map(\.session), ["a", "b"])
        XCTAssertEqual(response.sessions?.allSatisfy { !$0.attached }, true)
    }

    /// Closing is the one thing that is allowed to end a shell.
    func testCloseEndsTheShell() throws {
        try startServer()
        let client = try connect()
        let (opened, fd) = try client.send(
            .open(session: "s", plan: plan("sleep 60"), columns: 80, rows: 24))
        close(try XCTUnwrap(fd))
        let pid = try XCTUnwrap(opened.pid)

        _ = try client.send(.close(session: "s"))
        var alive = true
        for _ in 0..<50 where alive {
            usleep(100_000)
            alive = kill(pid, 0) == 0
        }
        XCTAssertFalse(alive, "the shell survived being closed")
        XCTAssertEqual(server?.sessionCount, 0)
    }

    func testAttachingToNothingFails() throws {
        try startServer()
        let (response, fd) = try connect().send(.attach(session: "nope"))
        if let fd { close(fd) }
        XCTAssertFalse(response.ok)
    }

    /// A keeper already listening must not be displaced by a second one — that
    /// would orphan every shell the first is holding.
    func testASecondKeeperWillNotTakeTheSocket() throws {
        try startServer()
        let second = KeeperServer(path: path)
        XCTAssertThrowsError(try second.start())
        second.stop()
    }
}

extension KeeperTests {
    /// **The case the feature is for.** An agent is not the shell — it is a
    /// child of it, several processes deep by the time it is doing anything. So
    /// surviving the app has to mean the whole tree survives, not just the login
    /// shell that happens to be at the top of it.
    func testAProcessTreeInsideTheShellSurvivesToo() throws {
        try startServer()
        let client = try connect()
        // A shell, with a long-lived child inside it that announces its own pid
        // — which is what `claude` or `pi` looks like from out here.
        let (opened, fd) = try client.send(.open(
            session: "agent",
            plan: plan("sh -c 'echo CHILD-$$; exec sleep 120' & echo SHELL-$$; wait"),
            columns: 80, rows: 24))
        let descriptor = try XCTUnwrap(fd)
        let shellPID = try XCTUnwrap(opened.pid)

        // Both lines, in either order: the child is started in the background,
        // so its line can land after the shell's, and stopping at "SHELL-"
        // alone made this fail now and then under load.
        var text = read(descriptor, until: "SHELL-")
        let deadline = Date().addingTimeInterval(5)
        while text.range(of: #"CHILD-\d+\s"#, options: .regularExpression) == nil, Date() < deadline {
            text += read(descriptor, until: "\n", timeout: 0.5)
        }
        let childPID = try XCTUnwrap(
            text.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("CHILD-") }
                .flatMap { pid_t($0.dropFirst("CHILD-".count).trimmingCharacters(in: .whitespaces)) },
            "could not find the child's pid in \(text.debugDescription)")
        XCTAssertNotEqual(childPID, shellPID, "the test did not actually nest anything")

        // The app goes away without warning.
        close(descriptor)
        client.disconnect()
        usleep(300_000)

        XCTAssertEqual(kill(shellPID, 0), 0, "the shell died with its client")
        XCTAssertEqual(kill(childPID, 0), 0, "the agent inside the shell died with the client")

        // And it is still reachable afterwards.
        let (attached, again) = try connect().send(.attach(session: "agent"))
        XCTAssertTrue(attached.ok, attached.message ?? "")
        if let again { descriptors.append(again) }
    }

    /// A shell that exits while nobody is attached is over, and the session has
    /// to go with it. Keeping the entry means the next launch attaches to a pty
    /// whose far end is closed — a terminal opening onto a dead process, saying
    /// nothing about it.
    func testASessionThatExitsWhileDetachedIsForgotten() throws {
        try startServer()
        let client = try connect()
        let (_, fd) = try client.send(
            .open(session: "brief", plan: plan("sleep 0.2; exit 0"), columns: 80, rows: 24))
        close(try XCTUnwrap(fd))
        _ = try client.send(.detach(session: "brief"))

        var gone = false
        for _ in 0..<40 where !gone {
            usleep(100_000)
            gone = server?.sessionCount == 0
        }
        XCTAssertTrue(gone, "an exited session was still being held")

        // And attaching to it now says so, rather than handing over a dead pty.
        let (response, again) = try client.send(.attach(session: "brief"))
        if let again { close(again) }
        XCTAssertFalse(response.ok)
    }
}
