import Darwin
import os
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

    /// The plan's `initialInput` is typed by the keeper itself, before the
    /// shell has read a byte, and the keeper then vouches for it on every
    /// attach — which is what lets a relaunch tell "the resume was never
    /// typed" from "it was typed and the agent has since ended".
    func testInitialInputIsTypedByTheKeeperAndVouchedFor() throws {
        try startServer()
        var plan = plan("read line; echo GOT-$line; sleep 30")
        plan.initialInput = "resume-me\n"
        let before = Date().timeIntervalSince1970 - 1
        let first = try connect()
        let (opened, fd) = try first.send(
            .open(session: "a", plan: plan, columns: 80, rows: 24))
        let descriptor = try XCTUnwrap(fd)
        descriptors.append(descriptor)
        XCTAssertEqual(opened.inputDelivered, true)
        XCTAssertGreaterThan(try XCTUnwrap(opened.startedAt), before)
        XCTAssertTrue(read(descriptor, until: "GOT-resume-me").contains("GOT-resume-me"))

        // The app goes away; the next one asks what this shell was given.
        first.disconnect()
        usleep(100_000)
        let (attached, fd2) = try connect().send(.attach(session: "a"))
        if let fd2 { descriptors.append(fd2) }
        XCTAssertTrue(attached.ok, attached.message ?? "")
        XCTAssertEqual(attached.inputDelivered, true)
        XCTAssertEqual(attached.startedAt, opened.startedAt)
    }

    /// A plan without input is the old wire, byte for byte: nothing typed, and
    /// nothing claimed.
    func testNoInitialInputMeansNothingTyped() throws {
        try startServer()
        let (opened, fd) = try connect().send(
            .open(session: "a", plan: plan("echo READY; sleep 30"), columns: 80, rows: 24))
        if let fd { descriptors.append(fd) }
        XCTAssertEqual(opened.inputDelivered, false)
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
        // And says so, or the app takes it for a fresh shell and types a
        // resume into the agent still running in it.
        XCTAssertEqual(second.existing, true)
        XCTAssertNil(first.existing)
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

// MARK: - Handing a pty over

extension KeeperTests {
    /// Read from a pty until `count` bytes have arrived, or give up.
    private func read(_ fd: Int32, bytes count: Int, timeout: TimeInterval = 5) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while data.count < count, Date() < deadline {
            let got = Darwin.read(fd, &buffer, min(buffer.count, count - data.count))
            if got > 0 {
                data.append(contentsOf: buffer[0..<got])
            } else if got < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(5_000)
            } else {
                break
            }
        }
        return data
    }

    /// A new shell's first words, written before the keeper let go of the pty,
    /// arrive in the `open` reply's replay. Read by the keeper and left in its
    /// buffer, they used to be lost from this terminal and replayed, stale, on
    /// the next attach instead.
    func testAShellsFirstOutputIsNeverLostOnOpen() throws {
        try startServer()
        let client = try connect()
        let (opened, fd) = try client.send(
            .open(session: "s", plan: plan("echo FIRST-WORDS; sleep 30"), columns: 80, rows: 24))
        let descriptor = try XCTUnwrap(fd)
        var seen = String(decoding: opened.replay ?? Data(), as: UTF8.self)
        if !seen.contains("FIRST-WORDS") { seen += read(descriptor, until: "FIRST-WORDS") }
        // And nothing more: a second copy would be the same bytes read twice.
        seen += read(descriptor, until: "FIRST-WORDS", timeout: 0.3)
        XCTAssertEqual(seen.components(separatedBy: "FIRST-WORDS").count - 1, 1,
                       "the first output did not arrive exactly once: \(seen.debugDescription)")

        close(descriptor)
        _ = try client.send(.detach(session: "s"))
        let (again, fd2) = try client.send(.attach(session: "s"))
        if let fd2 { descriptors.append(fd2) }
        XCTAssertFalse(String(decoding: again.replay ?? Data(), as: UTF8.self).contains("FIRST-WORDS"),
                       "output from before the open was replayed on the next attach")
    }

    /// **The handover under load.** A shell counting as fast as it can while
    /// detached, then attached: the replay and what the pty gives next must
    /// join without a gap or a repeat. A chunk the keeper read just as the app
    /// attached went missing (it reached the buffer after the replay was
    /// taken), and a keeper read loop that did not notice the pause went on
    /// taking lines from under the app.
    func testAttachingUnderHeavyOutputLosesNothing() throws {
        try startServer()
        let client = try connect()
        let (_, fd) = try client.send(.open(
            session: "count",
            plan: plan("i=0; while [ $i -lt 3000000 ]; do echo L$i; i=$((i+1)); done; sleep 30"),
            columns: 80, rows: 24))
        close(try XCTUnwrap(fd))
        _ = try client.send(.detach(session: "count"))
        usleep(300_000)

        let (attached, again) = try client.send(.attach(session: "count"))
        let reattached = try XCTUnwrap(again)
        descriptors.append(reattached)
        var replay = attached.replay ?? Data()
        if replay.starts(with: ReplayBuffer.resync) { replay = replay.dropFirst(ReplayBuffer.resync.count) }
        let live = read(reattached, bytes: 256 * 1024)

        // The replay's first line may be cut, and so may the last line read.
        let text = String(decoding: replay + live, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        lines.removeLast()
        let numbers = lines.compactMap { $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }
        XCTAssertEqual(numbers.count, lines.count, "a line was torn: \(lines.prefix(3))")
        XCTAssertGreaterThan(numbers.count, 1000, "too little output to say anything")
        for (previous, next) in zip(numbers, numbers.dropFirst()) where next != previous + 1 {
            return XCTFail("output jumped from L\(previous) to L\(next) across the handover")
        }
    }

    /// A shell whose exec fails dies before the keeper has finished starting
    /// it. It still has to be reaped and forgotten, rather than sit as a
    /// zombie that the exit watch, armed a moment too late, never reports.
    func testAShellThatFailsToStartIsForgotten() throws {
        try startServer()
        let client = try connect()
        var dud = plan("")
        dud.executable = "/no/such/shell"
        let (_, fd) = try client.send(.open(session: "dud", plan: dud, columns: 80, rows: 24))
        if let fd { close(fd) }
        var gone = false
        for _ in 0..<40 where !gone {
            usleep(50_000)
            gone = server?.sessionCount == 0
        }
        XCTAssertTrue(gone, "a shell that never started was still held")
    }

    // MARK: - Ending the keeper

    /// The keeper ends only with nothing to keep **and** nobody to keep it for,
    /// decided in one step. An app that had connected but not yet opened a
    /// session was having the keeper stopped under it.
    func testTheKeeperStopsOnlyWhenNothingAndNobodyIsLeft() throws {
        let server = try startServer()
        let first = try connect()
        _ = try first.send(.ping) // answered, so accepted: the connect alone may still be queued
        XCTAssertFalse(server.stopIfIdle(), "stopped with an app connected and nothing opened yet")

        let (_, fd) = try first.send(.open(session: "s", plan: plan("sleep 30"), columns: 80, rows: 24))
        close(try XCTUnwrap(fd))
        first.disconnect()
        usleep(100_000)
        XCTAssertFalse(server.stopIfIdle(), "stopped while holding a shell")

        let second = try connect()
        _ = try second.send(.close(session: "s"))
        second.disconnect()
        usleep(100_000)
        XCTAssertTrue(server.stopIfIdle())
        XCTAssertFalse(server.stopIfIdle(), "stopped twice")
        XCTAssertThrowsError(try WortelCLIClient.connect(to: path), "still listening after it stopped")
    }

    // MARK: - Which keeper

    /// A keeper says which build of the app it came from, read beside its own
    /// binary when it started. Same protocol is not same binary: one keeper
    /// outlived four updates, and its shells ran outside the app's privacy
    /// grants the whole time.
    func testPingSaysWhichBuildTheKeeperIs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kb-\(UInt32.random(in: 0..<0xFFFF_FFFF))")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Wortel.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "4242"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let binary = contents.appendingPathComponent("Resources/bin/wortel-keeper").path

        let server = KeeperServer(path: path, executable: binary)
        try server.start()
        self.server = server
        let (response, _) = try connect().send(.ping)
        XCTAssertEqual(response.build, "4242")
        XCTAssertEqual(response.executable, binary)
        XCTAssertEqual(response.version, Keeper.version)

        XCTAssertNil(KeeperServer.build(ofExecutable: "/usr/bin/true"), "a build read from outside any app")
    }
}

// MARK: - Pausing a pty

extension KeeperTests {
    /// The primitive the handover rests on, made deterministic: a read that
    /// has its bytes but not yet the keeper's lock (held here by a semaphore)
    /// when the pause comes. `finishReadInFlight` has to wait it out, so its
    /// bytes are in the buffer before the replay is taken, and nothing at all
    /// may be read after it.
    func testAPauseWaitsOutTheReadInFlight() throws {
        let pty = PtyHost()
        defer { pty.stop() }
        let reading = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        // Counted once each read has handed its bytes over, as the keeper's
        // append does once it has the lock.
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        pty.onOutput = { _, _ in
            if delivered.withLock({ $0 }) == 0 {
                reading.signal()
                proceed.wait()
            }
            delivered.withLock { $0 += 1 }
        }
        XCTAssertTrue(pty.start(executable: "/usr/bin/yes", arguments: [], environment: [:],
                                workingDirectory: nil, columns: 80, rows: 24))
        XCTAssertEqual(reading.wait(timeout: .now() + 5), .success, "nothing was read")

        pty.pauseReading()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { proceed.signal() }
        pty.finishReadInFlight()
        let afterHandover = delivered.withLock { $0 }
        XCTAssertEqual(afterHandover, 1, "the handover did not wait for the read in flight")
        usleep(200_000)
        XCTAssertEqual(delivered.withLock { $0 }, afterHandover, "the keeper read on after the pause")
    }
}

// MARK: - The app's end of a pty

extension KeeperTests {
    /// Adopt the pty of a fresh keeper session running `script`.
    private func adoptedPty(running script: String) throws -> PtyHost {
        let (_, fd) = try connect().send(
            .open(session: UUID().uuidString, plan: plan(script), columns: 80, rows: 24))
        let pty = PtyHost(adopting: try XCTUnwrap(fd))
        pty.onOutput = { _, _ in }
        return pty
    }

    /// A keeper-hosted shell that ends is news to the app only through its pty
    /// hanging up: the keeper reaps it, and libghostty spawned nothing. Without
    /// this the terminal simply stopped.
    func testAnAdoptedPtySaysWhenItsShellIsGone() throws {
        try startServer()
        let pty = try adoptedPty(running: "echo bye; exit 0")
        let hungUp = expectation(description: "hung up")
        hungUp.assertForOverFulfill = true
        pty.onHangup = { hungUp.fulfill() }
        pty.beginReading()
        wait(for: [hungUp], timeout: 5)
    }

    /// Letting go of a pty (the app quitting, a shell being restarted) is not
    /// the shell ending, and must not be reported as if it were.
    func testAReleasedPtySaysNothing() throws {
        try startServer()
        let pty = try adoptedPty(running: "sleep 0.3; exit 0")
        let hungUp = expectation(description: "hung up")
        hungUp.isInverted = true
        pty.onHangup = { hungUp.fulfill() }
        pty.beginReading()
        pty.release()
        wait(for: [hungUp], timeout: 1)
    }
}
