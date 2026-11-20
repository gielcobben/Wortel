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
/// - A shell that dies with the app that opened it is the feature not working.
/// - A descriptor that arrives unnoticed is a leak that shows up hours later.
/// - An app that dies without a word must leave its sessions to the next one.
///
/// What the channel carries (the snapshot, the cut, the flood, the answers) is
/// `KeeperTerminalProtocolTests`.
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
    private func startServer() throws -> KeeperServer {
        let server = KeeperServer(path: path)
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

    private func plan(_ script: String, input: String? = nil) -> KeeperSpawnPlan {
        KeeperSpawnPlan(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-ghostty"],
            workingDirectory: nil, initialInput: input)
    }

    private struct Opened {
        let response: KeeperResponse
        let channel: Int32
        let pty: Int32
    }

    /// Open or attach `id`; `track: false` leaves closing the descriptors to
    /// the caller (an app that goes away closes them itself).
    private func terminal(_ client: KeeperClient, _ id: String, _ plan: KeeperSpawnPlan,
                          track: Bool = true) throws -> Opened? {
        let (response, fds) = try client.sendForDescriptors(
            .terminal(session: id, plan: plan, columns: 80, rows: 24))
        guard response.ok, fds.count == 2 else {
            fds.forEach { close($0) }
            return nil
        }
        if track { descriptors += fds }
        return Opened(response: response, channel: fds[0], pty: fds[1])
    }

    /// Everything a channel shows, its snapshot's text then its output, until
    /// `marker` appears or the time is up.
    private func read(_ fd: Int32, until marker: String, timeout: TimeInterval = 5) -> String {
        var reader = KeeperChannelReader()
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !text.contains(marker) {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            buffer.withUnsafeBufferPointer { raw in
                reader.feed(raw.baseAddress!, count: count) { piece in
                    switch piece {
                    case .snapshot(let data):
                        text += KeeperTerminal(snapshot: data, scrollbackBytes: Keeper.scrollbackBytes)?.text() ?? ""
                    case .output(let bytes): text += String(decoding: bytes, as: UTF8.self)
                    case .invalid: break
                    }
                }
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

    /// The plan's `initialInput` is typed by the keeper itself, before the
    /// shell has read a byte, and the keeper then vouches for it on every
    /// attach: which is what lets a relaunch tell "the resume was never
    /// typed" from "it was typed and the agent has since ended".
    func testInitialInputIsTypedByTheKeeperAndVouchedFor() throws {
        try startServer()
        let before = Date().timeIntervalSince1970 - 1
        let first = try connect()
        let opened = try XCTUnwrap(try terminal(first, "a", plan("read line; echo GOT-$line; sleep 30",
                                                                   input: "resume-me\n")))
        XCTAssertEqual(opened.response.inputDelivered, true)
        XCTAssertGreaterThan(try XCTUnwrap(opened.response.startedAt), before)
        XCTAssertTrue(read(opened.channel, until: "GOT-resume-me").contains("GOT-resume-me"))

        // The app goes away; the next one asks what this shell was given.
        first.disconnect()
        usleep(100_000)
        let attached = try XCTUnwrap(try terminal(try connect(), "a", plan("unused", input: "not typed\n")))
        XCTAssertEqual(attached.response.existing, true)
        XCTAssertEqual(attached.response.inputDelivered, true)
        XCTAssertEqual(attached.response.startedAt, opened.response.startedAt)
    }

    /// A plan without input: nothing typed, and nothing claimed.
    func testNoInitialInputMeansNothingTyped() throws {
        try startServer()
        let opened = try XCTUnwrap(try terminal(try connect(), "a", plan("echo READY; sleep 30")))
        XCTAssertEqual(opened.response.inputDelivered, false)
    }

    // MARK: - Surviving

    /// **The whole feature, in one test.** Open a session, drop the connection
    /// the way a quitting app does, and the shell is still there, with the same
    /// pid, for a completely new client to pick up, with what it wrote meanwhile.
    func testAShellOutlivesTheClientThatOpenedIt() throws {
        try startServer()
        let first = try connect()
        let opened = try XCTUnwrap(try terminal(first, "s", plan("echo ALIVE; sleep 0.5; echo WHILE-AWAY; sleep 60"),
                                                track: false))
        let pid = try XCTUnwrap(opened.response.pid)
        XCTAssertTrue(read(opened.channel, until: "ALIVE").contains("ALIVE"))

        // The app quits: connection gone, descriptors gone, nothing said.
        close(opened.channel)
        close(opened.pty)
        first.disconnect()
        usleep(800_000)
        XCTAssertEqual(kill(pid, 0), 0, "the shell died with its client")

        // A new launch attaches to work already in progress, and sees what it
        // missed in its snapshot.
        let again = try XCTUnwrap(try terminal(try connect(), "s", plan("unused")))
        XCTAssertEqual(again.response.pid, pid, "attached to a different shell")
        XCTAssertTrue(read(again.channel, until: "WHILE-AWAY").contains("WHILE-AWAY"))
        _ = write(again.pty, "echo SECOND\n", 12)
        XCTAssertTrue(read(again.channel, until: "SECOND").contains("SECOND"))
    }

    /// An agent is not the shell: it is a child of it, several processes deep.
    /// Surviving the app has to mean the whole tree survives.
    func testAProcessTreeInsideTheShellSurvivesToo() throws {
        try startServer()
        let client = try connect()
        let opened = try XCTUnwrap(try terminal(
            client, "agent", plan("sh -c 'echo CHILD-$$; exec sleep 120' & echo SHELL-$$; wait"), track: false))
        let shellPID = try XCTUnwrap(opened.response.pid)
        var text = read(opened.channel, until: "SHELL-")
        let deadline = Date().addingTimeInterval(5)
        while text.range(of: #"CHILD-\d+\s"#, options: .regularExpression) == nil, Date() < deadline {
            text += read(opened.channel, until: "\n", timeout: 0.5)
        }
        let childPID = try XCTUnwrap(
            text.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("CHILD-") }
                .flatMap { pid_t($0.dropFirst("CHILD-".count).trimmingCharacters(in: .whitespaces)) },
            "could not find the child's pid in \(text.debugDescription)")
        XCTAssertNotEqual(childPID, shellPID, "the test did not actually nest anything")

        close(opened.channel)
        close(opened.pty)
        client.disconnect()
        usleep(300_000)
        XCTAssertEqual(kill(shellPID, 0), 0, "the shell died with its client")
        XCTAssertEqual(kill(childPID, 0), 0, "the agent inside the shell died with the client")
        XCTAssertNotNil(try terminal(try connect(), "agent", plan("unused")))
    }

    // MARK: - One app at a time

    /// A session's channel belongs to one app; a second is refused rather
    /// than given a copy that the first does not know about.
    func testASecondClientCannotTakeAnAttachedSession() throws {
        try startServer()
        XCTAssertNotNil(try terminal(try connect(), "s", plan("sleep 30")))
        XCTAssertNil(try terminal(try connect(), "s", plan("sleep 30")), "two apps were given one session")
    }

    /// But once the holder goes, the next one gets it.
    func testTheSessionIsAvailableAgainAfterTheHolderDisconnects() throws {
        try startServer()
        let first = try connect()
        XCTAssertNotNil(try terminal(first, "s", plan("sleep 30")))
        first.disconnect()
        usleep(200_000)
        XCTAssertNotNil(try terminal(try connect(), "s", plan("sleep 30")))
    }

    // MARK: - Housekeeping

    /// Opening a session that is already running is an attach, not a second
    /// shell: what makes a relaunch idempotent.
    func testOpeningAnExistingSessionAttachesInstead() throws {
        try startServer()
        let client = try connect()
        let first = try XCTUnwrap(try terminal(client, "s", plan("sleep 30")))
        let second = try XCTUnwrap(try terminal(client, "s", plan("sleep 30")))
        XCTAssertEqual(second.response.pid, first.response.pid, "a second shell was forked for one session")
        XCTAssertEqual(server?.sessionCount, 1)
        // And says so, or the app takes it for a fresh shell and types a
        // resume into the agent still running in it.
        XCTAssertEqual(second.response.existing, true)
        XCTAssertNil(first.response.existing)
    }

    func testListReportsWhatIsRunning() throws {
        try startServer()
        let first = try connect()
        for id in ["a", "b"] { XCTAssertNotNil(try terminal(first, id, plan("sleep 30"))) }
        first.disconnect()
        usleep(200_000)
        let (response, _) = try connect().send(.list)
        XCTAssertEqual(response.sessions?.map(\.session), ["a", "b"])
        XCTAssertEqual(response.sessions?.allSatisfy { !$0.attached }, true)
    }

    /// Closing is the one thing that is allowed to end a shell.
    func testCloseEndsTheShell() throws {
        try startServer()
        let client = try connect()
        let opened = try XCTUnwrap(try terminal(client, "s", plan("sleep 60")))
        let pid = try XCTUnwrap(opened.response.pid)
        _ = try client.send(.close(session: "s"))
        var alive = true
        for _ in 0..<50 where alive {
            usleep(100_000)
            alive = kill(pid, 0) == 0
        }
        XCTAssertFalse(alive, "the shell survived being closed")
        XCTAssertEqual(server?.sessionCount, 0)
    }

    // MARK: - Ending for a resume

    /// A stand-in shell: it handles the hangup rather than dying of it, as
    /// an interactive shell waiting on a job does, runs an "agent" that does
    /// die of it, and once that ends does what zsh does on its way out: its
    /// last prompt removes the agent's marker, and it saves its history
    /// (`cleaned`). The agent prints its pid. (A handler, not `trap ''`: an
    /// ignored signal is inherited and cannot be undone in a child.)
    private func shellWithAgent(marker: URL, cleaned: String, underLogin: Bool) -> KeeperSpawnPlan {
        let script = "trap 'true' HUP; sh -c 'echo AGENT-$$; exec sleep 60'; rm -f '\(marker.path)'; echo cleaned > '\(cleaned)'"
        guard underLogin else { return plan(script) }
        return KeeperSpawnPlan(
            executable: "/usr/bin/login", arguments: ["-flp", NSUserName(), "/bin/sh", "-c", script],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-ghostty"],
            workingDirectory: nil, initialInput: nil)
    }

    /// What a keeper ending leaves behind: whether the shell ended its own
    /// way (`cleaned`), whether the agent's marker is there, as it was, and
    /// whether the agent ended too.
    private func endKeeper(forResume: Bool, underLogin: Bool) throws
        -> (cleaned: Bool, marker: Data?, agentEnded: Bool, written: Data) {
        let markers = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markers) }
        let session = UUID().uuidString
        let marker = markers.appendingPathComponent(session)
        let written = Data("agent=claude\nargv=claude\nshellpid=1\n".utf8)
        try written.write(to: marker)
        let cleaned = markers.appendingPathComponent("cleaned").path

        let server = KeeperServer(path: path, agentMarkers: markers)
        try server.start()
        self.server = server
        let client = try connect()
        let opened = try XCTUnwrap(try terminal(
            client, session, shellWithAgent(marker: marker, cleaned: cleaned, underLogin: underLogin)))
        let said = read(opened.channel, until: "AGENT-")
        let agent = try XCTUnwrap(said.range(of: #"AGENT-(\d+)"#, options: .regularExpression)
            .flatMap { pid_t(said[$0].dropFirst(6)) }, said)
        usleep(200_000)
        server.stop(endingShellsForResume: forResume)
        self.server = nil
        var agentAlive = true
        for _ in 0..<30 where agentAlive {
            usleep(100_000)
            agentAlive = kill(agent, 0) == 0
        }
        usleep(300_000)
        return (FileManager.default.fileExists(atPath: cleaned), try? Data(contentsOf: marker), !agentAlive, written)
    }

    /// The control: a session closed politely hangs up, its agent ends, and
    /// its shell's last prompt removes the marker. Right for a session someone
    /// closed, and what lost every agent at an update.
    func testAPoliteStopLetsTheShellRemoveItsAgentsMarker() throws {
        let ended = try endKeeper(forResume: false, underLogin: false)
        XCTAssertTrue(ended.agentEnded)
        XCTAssertTrue(ended.cleaned, "the stand-in shell never ran its last prompt; this test proves nothing")
        XCTAssertNil(ended.marker)
    }

    /// A keeper ending on a signal (an update replacing it, a logout) hangs
    /// its shells up all the same, so each ends its own way (history saved,
    /// jobs told), and then puts back the markers their last prompts removed:
    /// the agents are resumed.
    func testEndingForAResumeKeepsTheMarkerAndLetsTheShellEndItsOwnWay() throws {
        let ended = try endKeeper(forResume: true, underLogin: false)
        XCTAssertTrue(ended.agentEnded, "the agent outlived its keeper")
        XCTAssertTrue(ended.cleaned, "the shell was not let end its own way: its history would be lost")
        XCTAssertEqual(ended.marker, ended.written, "the agent's marker is not back as it was")
    }

    /// The same under `/usr/bin/login`, which is how every session runs.
    func testEndingForAResumeUnderLogin() throws {
        let ended = try endKeeper(forResume: true, underLogin: true)
        XCTAssertTrue(ended.agentEnded, "the agent outlived its keeper")
        XCTAssertTrue(ended.cleaned, "the shell under login was not let end its own way")
        XCTAssertEqual(ended.marker, ended.written, "the agent's marker is not back as it was")
    }

    /// Never over a marker that is there: one written since is newer. Only
    /// markers are held, not the exit log or a marker being written.
    func testAHeldMarkerIsPutBackOnlyWhereItIsGone() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = UUID().uuidString, rewritten = UUID().uuidString
        try Data("old-gone".utf8).write(to: dir.appendingPathComponent(gone))
        try Data("old".utf8).write(to: dir.appendingPathComponent(rewritten))
        try Data("log".utf8).write(to: dir.appendingPathComponent("exits.log"))
        let hold = AgentMarkerHold(in: dir)
        XCTAssertEqual(hold.count, 2)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(gone))
        try Data("new".utf8).write(to: dir.appendingPathComponent(rewritten))
        XCTAssertEqual(hold.restore(), 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(gone)), Data("old-gone".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(rewritten)), Data("new".utf8))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, [gone, rewritten, "exits.log"].sorted(), "a staging file was left behind")
    }

    /// Where the hold looks is where the shell integration writes and the
    /// app reads.
    func testTheHoldReadsTheMarkersTheAppReads() {
        XCTAssertEqual(AgentMarkerHold.directory.standardizedFileURL, AgentResumeStore.directory.standardizedFileURL)
    }

    /// A keeper already listening must not be displaced by a second one: that
    /// would orphan every shell the first is holding.
    func testASecondKeeperWillNotTakeTheSocket() throws {
        try startServer()
        let second = KeeperServer(path: path)
        XCTAssertThrowsError(try second.start())
        second.stop()
    }

    /// A shell that exits is over, and the session goes with it. Kept, the
    /// next launch would attach to a terminal over a dead process.
    func testASessionThatExitsIsForgotten() throws {
        try startServer()
        let client = try connect()
        XCTAssertNotNil(try terminal(client, "brief", plan("sleep 0.2; exit 0")))
        client.disconnect()
        var gone = false
        for _ in 0..<40 where !gone {
            usleep(100_000)
            gone = server?.sessionCount == 0
        }
        XCTAssertTrue(gone, "an exited session was still being held")
    }

    /// A shell whose exec fails dies before the keeper has finished starting
    /// it. It still has to be reaped and forgotten, rather than sit as a
    /// zombie that the exit watch, armed a moment too late, never reports.
    func testAShellThatFailsToStartIsForgotten() throws {
        try startServer()
        var dud = plan("")
        dud.executable = "/no/such/shell"
        _ = try terminal(try connect(), "dud", dud)
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

        XCTAssertNotNil(try terminal(first, "s", plan("sleep 30")))
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

// MARK: - The app's end

extension KeeperTests {
    /// The app's host for a fresh session running `script`: reading its
    /// channel, typing into its pty.
    private func appHost(running script: String) throws -> PtyHost {
        let opened = try XCTUnwrap(try terminal(try connect(), UUID().uuidString, plan(script), track: false))
        let pty = PtyHost(channel: opened.channel, typing: opened.pty)
        pty.onOutput = { _, _ in }
        return pty
    }

    /// A shell that ends is news to the app only through its channel ending:
    /// the keeper reaps it, and libghostty spawned nothing. Without this the
    /// terminal simply stopped.
    func testTheAppHearsWhenItsShellIsGone() throws {
        try startServer()
        let pty = try appHost(running: "echo bye; exit 0")
        let hungUp = expectation(description: "hung up")
        hungUp.assertForOverFulfill = true
        pty.onHangup = { hungUp.fulfill() }
        pty.beginReading()
        wait(for: [hungUp], timeout: 5)
    }

    /// Letting go of a session (the app quitting, a shell being restarted) is
    /// not the shell ending, and must not be reported as if it were.
    func testALetGoSessionSaysNothing() throws {
        try startServer()
        let pty = try appHost(running: "sleep 0.3; exit 0")
        let hungUp = expectation(description: "hung up")
        hungUp.isInverted = true
        pty.onHangup = { hungUp.fulfill() }
        pty.beginReading()
        pty.release()
        wait(for: [hungUp], timeout: 1)
    }
}
