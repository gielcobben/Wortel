import Darwin
import XCTest

/// What decides the app's answer to a keeper that is gone or won't talk.
///
/// Each one failed silently on 2026-10-08 or could have: the keeper was killed
/// under a running app and nothing noticed, and a keeper that merely failed to
/// answer a ping would have been killed, shells and all, as if it spoke
/// another protocol.
final class KeeperLossTests: XCTestCase {
    func testOnlyAKeeperNamingAnotherProtocolIsReplaced() {
        // No answer, or a garbled one, says nothing about its sessions.
        XCTAssertFalse(KeeperConnection.shouldReplace(afterPing: nil))
        XCTAssertFalse(KeeperConnection.shouldReplace(afterPing: .failure("busy")))
        XCTAssertFalse(KeeperConnection.shouldReplace(afterPing: .success(version: Keeper.version)))
        XCTAssertTrue(KeeperConnection.shouldReplace(afterPing: .success(version: "0")))
        // Answered, and would not say which protocol: not this one.
        XCTAssertTrue(KeeperConnection.shouldReplace(afterPing: .success()))
    }

    func testAShellIsGoneOnlyOnTheTablesWord() {
        let table = [ProcessEntry(pid: 200, ppid: 1, pgid: 200, uid: 501, name: "zsh", startedAt: Date())]
        XCTAssertFalse(AgentLiveness.shellIsGone(shellPID: 200, table: table))
        XCTAssertTrue(AgentLiveness.shellIsGone(shellPID: 300, table: table))
        // Killed but not finished: still listed, never running anything again.
        // A shell killed with its pty still held open waits like this.
        let ending = [ProcessEntry(pid: 200, ppid: 1, pgid: 200, uid: 501, name: "zsh",
                                   startedAt: Date(), isExiting: true)]
        XCTAssertTrue(AgentLiveness.shellIsGone(shellPID: 200, table: ending))
        // An unreadable table is no claim: a resume held for a shell that is
        // still there would start a second agent beside the first.
        XCTAssertFalse(AgentLiveness.shellIsGone(shellPID: 300, table: []))
    }

    /// The way the keeper went on 2026-10-08: SIGKILL, from outside.
    func testTheWatchSeesAProcessKilled() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let exited = expectation(description: "exit seen")
        let watch = ProcessExitWatch(pid: child.processIdentifier, queue: .global()) { exited.fulfill() }
        kill(child.processIdentifier, SIGKILL)
        wait(for: [exited], timeout: 5)
        withExtendedLifetime(watch) {}
    }

    /// A keeper that died between the connect and the watch being armed. The
    /// kernel never reports an exit that happened before it was asked.
    func testTheWatchFiresForAProcessAlreadyGone() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let exited = expectation(description: "exit seen")
        let watch = ProcessExitWatch(pid: child.processIdentifier, queue: .global()) { exited.fulfill() }
        wait(for: [exited], timeout: 5)
        withExtendedLifetime(watch) {}
    }

    func testTheWatchFiresOnce() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let exited = expectation(description: "exit seen")
        exited.assertForOverFulfill = true
        let watch = ProcessExitWatch(pid: child.processIdentifier, queue: .global()) { exited.fulfill() }
        kill(child.processIdentifier, SIGKILL)
        wait(for: [exited], timeout: 5)
        // Give a second event, if there were one, the time to arrive.
        let settle = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        withExtendedLifetime(watch) {}
    }
}
