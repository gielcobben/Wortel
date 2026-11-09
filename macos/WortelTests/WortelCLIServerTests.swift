import XCTest

/// The socket between the `wortel` command and the app, exercised for real: a
/// server on a temporary path, a client connecting to it over an actual Unix
/// socket.
///
/// Worth the setup because every failure mode here is invisible from either end
/// alone. A reply that never comes looks like a hung app. A connection that
/// blocks the accept loop looks like the app "sometimes" ignoring commands. A
/// socket file left behind by a crash makes a perfectly healthy app look
/// permanently unreachable — and the recovery for that one is a *guess* about
/// whether anyone is listening, which is exactly the sort of guess that wants
/// pinning.
final class WortelCLIServerTests: XCTestCase {
    private var path = ""
    private var servers: [WortelCLIServer] = []

    override func setUp() {
        super.setUp()
        // Deliberately short: `sun_path` holds 104 bytes, and the per-user temp
        // directory already spends half of that. A long name here wouldn't fail
        // the tests, it would fail them *sometimes*, on machines with longer
        // temp paths.
        path = NSTemporaryDirectory() + "w-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    /// Start a server that answers with `handler`, and keep it alive for the test.
    @discardableResult
    private func startServer(
        at path: String? = nil,
        handler: @escaping @Sendable (WortelCommand, @escaping @Sendable (WortelResponse) -> Void) -> Void
    ) throws -> WortelCLIServer {
        let server = WortelCLIServer(path: path ?? self.path, handler: handler)
        try server.start()
        servers.append(server)
        return server
    }

    private func send(_ command: WortelCommand) throws -> WortelResponse {
        try WortelCLIClient.send(command, to: path, timeout: 5)
    }

    // MARK: - The round trip

    func testCommandReachesTheAppAndTheAnswerComesBack() throws {
        let seen = Received()
        try startServer { command, reply in
            seen.value = command
            reply(.success("opened", value: "/a/b.txt"))
        }

        let response = try send(.open(path: "/a/b.txt"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "opened")
        XCTAssertEqual(response.value, "/a/b.txt")
        XCTAssertEqual(seen.value, .open(path: "/a/b.txt"))
    }

    /// Every field survives the wire, including the ones that are nil — a
    /// dropped `--branch` would silently give you a session in the wrong place.
    func testEveryCommandSurvivesTheWire() throws {
        let seen = Received()
        try startServer { command, reply in
            seen.value = command
            reply(.success())
        }

        let commands: [WortelCommand] = [
            .open(path: "/a/b.txt"),
            .newSession(cwd: "/a", name: "build", branch: "fix/x", base: "main"),
            .newSession(cwd: nil, name: nil, branch: nil, base: nil),
            .rename(session: UUID().uuidString, name: "build"),
            .notify(session: UUID().uuidString, title: "Done", body: nil),
            .list(caller: UUID().uuidString),
            .list(caller: nil),
            .read(session: "agent two", lines: nil),
            .read(session: "3f2a91c0", lines: 200),
            .send(session: "agent two", text: "line one\nline two", enter: true),
            .send(session: "x", text: "", enter: false),
            .wait(session: "x", text: "DONE", fromStart: true, idle: false, exit: true, timeout: 0),
            .wait(session: "x", text: nil, fromStart: false, idle: true, exit: false, timeout: 30),
            .version,
        ]
        for command in commands {
            XCTAssertTrue(try send(command).ok)
            XCTAssertEqual(seen.value, command)
        }
    }

    /// The handler is told who sent the command, by the kernel. The client
    /// here is this test process, so that's the pid to expect.
    func testTheHandlerIsToldTheCallersPid() throws {
        let caller = CallerBox()
        let server = WortelCLIServer(path: path, callerHandler: { _, from, reply in
            caller.value = from.pid
            reply(.success())
        })
        try server.start()
        servers.append(server)
        XCTAssertTrue(try send(.version).ok)
        XCTAssertEqual(caller.value, getpid())
    }

    private final class CallerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: pid_t?
        var value: pid_t? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// `wortel wait` can be answered minutes later, so the app has to be able
    /// to tell that nobody is waiting any more: a wait for a CLI that was ^C'd
    /// would otherwise sit in the app until its timeout, or forever with none.
    func testTheHandlerCanTellTheCallerHungUp() throws {
        let parked = Parked()
        let server = WortelCLIServer(path: path, callerHandler: { _, from, reply in
            parked.park(from, reply)
        })
        try server.start()
        servers.append(server)

        let socketFD = try WortelCLIClient.connect(to: path)
        var request = try JSONEncoder().encode(WortelCommand.version)
        request.append(0x0A)
        _ = request.withUnsafeBytes { write(socketFD, $0.baseAddress!, $0.count) }
        let caller = try XCTUnwrap(parked.waitForCaller())
        XCTAssertFalse(caller.hasHungUp(), "a caller still waiting for its answer has not hung up")

        close(socketFD)
        let deadline = Date().addingTimeInterval(2)
        while !caller.hasHungUp(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(caller.hasHungUp())
        // And answering it anyway is harmless: no SIGPIPE, which would end
        // the app (and this test process with it).
        parked.reply?(.success())
    }

    /// `read --lines` can answer with a long stretch of scrollback, far past
    /// what a command may be. The reply limit is its own.
    func testALongReplyArrivesWhole() throws {
        let long = String(repeating: "x", count: 1_000_000)
        try startServer { _, reply in reply(.success(value: long)) }
        XCTAssertEqual(try send(.read(session: "x", lines: 100_000)).value?.count, long.count)
    }

    /// The app replies from the main thread, so replying must never wait on
    /// the peer: a CLI suspended with ^Z doesn't read, and a reply bigger
    /// than the socket's buffer written in place froze the whole app. Here
    /// the peer sends its command and then never reads.
    func testReplyingToAPeerThatDoesntReadReturnsAtOnce() throws {
        let parked = Parked()
        let server = WortelCLIServer(path: path, callerHandler: { _, from, reply in
            parked.park(from, reply)
        })
        try server.start()
        servers.append(server)

        let socketFD = try WortelCLIClient.connect(to: path)
        defer { close(socketFD) }
        var request = try JSONEncoder().encode(WortelCommand.read(session: "x", lines: 100_000))
        request.append(0x0A)
        _ = request.withUnsafeBytes { write(socketFD, $0.baseAddress!, $0.count) }
        _ = try XCTUnwrap(parked.waitForCaller())
        let reply = try XCTUnwrap(parked.reply)

        let started = Date()
        reply(.success(value: String(repeating: "x", count: 8_000_000)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "the reply was written on the caller's thread")
        // A second answer is dropped, not written to (and closing) a
        // descriptor that may belong to someone else by now.
        reply(.success())
    }

    /// A failure can carry its own exit status: a `wait` that timed out is not
    /// the same answer as one for a session that doesn't exist.
    func testAFailureCarriesItsStatus() throws {
        try startServer { _, reply in reply(.failure("Timed out.", status: WortelCLI.waitTimedOutStatus)) }
        let response = try send(.wait(session: "x", text: nil, fromStart: false, idle: true, exit: false,
                                      timeout: 1))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.status, 124)
    }

    private final class Parked: @unchecked Sendable {
        private let lock = NSLock()
        private var caller: WortelCLIServer.Caller?
        private(set) var reply: (@Sendable (WortelResponse) -> Void)?

        func park(_ caller: WortelCLIServer.Caller, _ reply: @escaping @Sendable (WortelResponse) -> Void) {
            lock.withLock {
                self.caller = caller
                self.reply = reply
            }
        }

        func waitForCaller() -> WortelCLIServer.Caller? {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let caller = lock.withLock({ caller }) { return caller }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
    }

    /// A failure has to arrive as a failure, not as a closed connection — the
    /// CLI's exit code is the only thing a script can see.
    func testFailuresComeBackAsFailures() throws {
        try startServer { _, reply in reply(.failure("No such file")) }
        let response = try send(.open(path: "/nope"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.message, "No such file")
    }

    /// The app is not required to answer immediately: `new --branch` runs git
    /// first, and the connection has to still be there when the answer arrives.
    func testAnAnswerMayArriveLater() throws {
        try startServer { _, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                reply(.success(value: "late"))
            }
        }
        XCTAssertEqual(try send(.newSession(cwd: "/a", name: nil, branch: "x", base: nil)).value, "late")
    }

    /// The one that would show up as "Wortel sometimes ignores my commands": a
    /// connection whose answer is slow must not hold up the next one.
    func testASlowCommandDoesNotBlockTheNextOne() throws {
        let pending = Pending()
        try startServer { command, reply in
            if case .notify = command {
                pending.hold(reply) // answered only once the second one lands
            } else {
                pending.release()
                reply(.success(value: "second"))
            }
        }

        let slow = expectation(description: "slow command answered")
        DispatchQueue.global().async { [self] in
            let response = try? send(.notify(session: nil, title: "wait", body: nil))
            XCTAssertEqual(response?.value, "first")
            slow.fulfill()
        }
        // Give the slow one time to be accepted and parked in the handler.
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(try send(.open(path: "/a")).value, "second")
        wait(for: [slow], timeout: 5)
    }

    // MARK: - The socket file

    /// A crash leaves the socket file behind. Nothing is listening on it, so the
    /// next launch must take the name over rather than conclude it's taken — the
    /// alternative is an app that never accepts a command again until someone
    /// deletes a file they don't know about.
    func testAStaleSocketFileIsTakenOver() throws {
        FileManager.default.createFile(atPath: path, contents: Data("junk".utf8))
        try startServer { _, reply in reply(.success(value: "alive")) }
        XCTAssertEqual(try send(.open(path: "/a")).value, "alive")
    }

    /// The other half of that rule, and the reason it's proved rather than
    /// assumed: a socket someone *is* listening on is not stale, and a second
    /// copy of the app must not steal the name from the first.
    func testALiveSocketIsNotStolen() throws {
        try startServer { _, reply in reply(.success(value: "first")) }
        XCTAssertThrowsError(try startServer { _, reply in reply(.success(value: "second")) })
        // The original is still the one answering.
        XCTAssertEqual(try send(.open(path: "/a")).value, "first")
    }

    /// Stopping tidies the name up, so the next launch has nothing to reason
    /// about.
    func testStoppingRemovesTheSocket() throws {
        let server = try startServer { _, reply in reply(.success()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Nobody home is its own answer, and the message is the one thing the user
    /// will see: "Wortel isn't running", not a bare errno.
    func testConnectingToNothingSaysTheAppIsntRunning() {
        XCTAssertThrowsError(try send(.open(path: "/a"))) { error in
            XCTAssertEqual("\(error)", "Wortel isn't running.")
        }
    }

    // MARK: - Peers behaving badly

    /// The CLI and the app ship together, but a hand-installed symlink can
    /// outlive its app. A command this version can't parse gets an answer
    /// saying so — a dropped connection would read as "the app is broken".
    func testAnUnparseableCommandIsAnsweredRatherThanDropped() throws {
        try startServer { _, reply in
            XCTFail("the handler must not see a command it couldn't decode")
            reply(.success())
        }
        let response = try sendRaw("{\"verb\":\"teleport\"}\n")
        XCTAssertEqual(response?.ok, false)
    }

    /// A peer that connects and says nothing must not hold a serving slot
    /// forever, and must not stop the next command being answered.
    func testASilentPeerIsDroppedAndTheServerCarriesOn() throws {
        try startServer { _, reply in reply(.success(value: "still here")) }
        let idle = try WortelCLIClient.connect(to: path)
        defer { close(idle) }
        XCTAssertEqual(try send(.open(path: "/a")).value, "still here")
    }

    /// Send bytes the encoder would never produce, and read whatever comes back.
    private func sendRaw(_ text: String) throws -> WortelResponse? {
        let socketFD = try WortelCLIClient.connect(to: path)
        defer { close(socketFD) }
        let bytes = Array(text.utf8)
        XCTAssertEqual(write(socketFD, bytes, bytes.count), bytes.count)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(socketFD, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(
            WortelResponse.self, from: Data(buffer[0..<count]))
    }

    /// The last command a handler saw. A class because the handler is called on
    /// the server's queue and the test reads it from its own.
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WortelCommand?
        var value: WortelCommand? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A reply held back until something else happens.
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var held: (@Sendable (WortelResponse) -> Void)?

        func hold(_ reply: @escaping @Sendable (WortelResponse) -> Void) {
            lock.withLock { held = reply }
        }

        func release() {
            let reply = lock.withLock { () -> (@Sendable (WortelResponse) -> Void)? in
                defer { held = nil }
                return held
            }
            reply?(.success(value: "first"))
        }
    }
}
