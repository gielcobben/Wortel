import Darwin
import XCTest

/// The claim the whole feature is sold on, tested against a **real agent**
/// rather than a stand-in.
///
/// Everything else about survival has been checked with `sleep` and nested
/// `sh` — the right way to pin the mechanism, and not the same as knowing that
/// Claude Code specifically comes back. A real agent is a Node process behind a
/// full-screen TUI: it holds the alternate screen buffer, redraws on SIGWINCH,
/// and reacts to focus reporting. Any of those could behave differently across
/// a detach and reattach, and none of it shows up in a test that runs `sleep`.
///
/// Skipped when the agent isn't installed, so this stays honest on a machine
/// that doesn't have one rather than quietly passing.
final class KeeperAgentTests: XCTestCase {
    private var path = ""
    private var server: KeeperServer?
    private var clients: [KeeperClient] = []
    private var descriptors: [Int32] = []
    private var openedSessions: [String] = []

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "a-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
    }

    override func tearDown() {
        // Close sessions before tearing the server down: these are real agents,
        // and leaving one running after the test would be a stray Node process
        // holding a pty for the rest of the day.
        if let client = clients.first(where: { $0.isConnected }) {
            for id in openedSessions { _ = try? client.send(.close(session: id)) }
        }
        clients.forEach { $0.disconnect() }
        descriptors.forEach { close($0) }
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    private func connect() throws -> KeeperClient {
        let client = KeeperClient(path: path)
        XCTAssertTrue(try client.connect())
        clients.append(client)
        return client
    }

    private func drain(_ fd: Int32, until marker: String? = nil,
                       seconds: TimeInterval = 20) -> String {
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // The channel blocks; never wait on it past the deadline.
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                text += String(decoding: buffer[0..<count], as: UTF8.self)
                if let marker, text.contains(marker) { return text }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(50_000)
            } else {
                break
            }
        }
        return text
    }

    /// What a pid is actually running, for telling an agent from a shell.
    private func command(of pid: pid_t) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return "" }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every descendant of the shell, which is where an agent actually lives.
    private func descendants(of root: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid=,ppid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()

        var children: [pid_t: [pid_t]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").compactMap { pid_t($0) }
            guard parts.count == 2 else { continue }
            children[parts[1], default: []].append(parts[0])
        }
        var found: [pid_t] = []
        var queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    func testClaudeCodeSurvivesTheAppDisappearing() throws {
        try checkAgentSurvives(named: "claude",
                               at: "/Users/me/.local/bin/claude")
    }

    /// A second agent, because "it works with Claude" and "it works with agents"
    /// are different claims, and this one is a different TUI.
    func testPiSurvivesTheAppDisappearing() throws {
        try checkAgentSurvives(
            named: "pi",
            at: "/Users/me/.local/share/fnm/node-versions/v24.14.0/installation/bin/pi")
    }

    private func checkAgentSurvives(named name: String, at agent: String) throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: agent),
                          "\(name) is not installed here")

        let server = KeeperServer(path: path)
        try server.start()
        self.server = server

        let first = try connect()
        openedSessions.append("agent")
        // A login shell running the agent, the way a session does.
        let (opened, fds) = try first.sendForDescriptors(.terminal(
            session: "agent",
            plan: KeeperSpawnPlan(
                executable: "/bin/zsh",
                arguments: ["-lc", "\(agent) 2>&1"],
                environment: [
                    "PATH": "/Users/me/.local/bin:"
                        + "/Users/me/.local/share/fnm/node-versions/v24.14.0/installation/bin:"
                        + "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": NSHomeDirectory(),
                    "TERM": "xterm-256color",
                ],
                workingDirectory: NSTemporaryDirectory()),
            columns: 120, rows: 40))
        XCTAssertTrue(opened.ok, opened.message ?? "")
        XCTAssertEqual(fds.count, 2)
        let descriptor = try XCTUnwrap(fds.first)
        fds.dropFirst().forEach { close($0) }
        let shellPID = try XCTUnwrap(opened.pid)

        // Wait for it to actually draw something — a TUI, not a prompt.
        let firstScreen = drain(descriptor, until: "\u{1B}[", seconds: 30)
        XCTAssertFalse(firstScreen.isEmpty, "the agent produced no output at all")

        // Find the agent. It is usually *not* a child: `zsh -lc <one command>`
        // execs it directly, so the pty's own child becomes the agent and the
        // shell is gone. Both shapes are normal, so look at the whole tree
        // including the root and identify it by what it is running.
        var tree: [pid_t] = []
        var agentPIDs: [pid_t] = []
        for _ in 0..<60 where agentPIDs.isEmpty {
            usleep(250_000)
            tree = [shellPID] + descendants(of: shellPID)
            agentPIDs = tree.filter { command(of: $0).contains(name) }
        }
        XCTAssertFalse(
            agentPIDs.isEmpty,
            "no \(name) process in the session; tree was \(tree.map { "\($0):\(command(of: $0))" })")

        // The app vanishes: descriptors closed, connection dropped, nothing said.
        close(descriptor)
        first.disconnect()
        usleep(500_000)

        XCTAssertEqual(kill(shellPID, 0), 0, "the shell died with the app")
        for pid in agentPIDs {
            XCTAssertEqual(kill(pid, 0), 0, "an agent process died with the app (pid \(pid))")
        }

        // A new launch picks it up.
        let second = try connect()
        let (attached, again) = try second.sendForDescriptors(.terminal(
            session: "agent", plan: KeeperSpawnPlan(executable: "/usr/bin/false", arguments: [],
                                                    environment: [:], workingDirectory: nil),
            columns: 120, rows: 40))
        XCTAssertTrue(attached.ok, attached.message ?? "")
        XCTAssertEqual(attached.existing, true)
        XCTAssertEqual(attached.pid, shellPID, "attached to a different shell")
        XCTAssertEqual(again.count, 2)
        descriptors += again
        let reattached = try XCTUnwrap(again.first)
        // What it drew while nobody was attached is in the snapshot.
        _ = drain(reattached, seconds: 1)

        // And it is still a live terminal: a resize makes any TUI redraw, which
        // is the cheapest way to ask "are you still there" without typing
        // anything into someone's agent.
        _ = try second.send(.resize(session: "agent", columns: 121, rows: 41, cellWidth: 8, cellHeight: 16))
        let afterResize = drain(reattached, until: "\u{1B}[", seconds: 15)
        XCTAssertFalse(afterResize.isEmpty,
                       "the agent stopped responding after reattach — it did not redraw")

        // Still the same processes, not a restarted agent.
        for pid in agentPIDs {
            XCTAssertEqual(kill(pid, 0), 0, "an agent process died during reattach")
        }
    }
}
