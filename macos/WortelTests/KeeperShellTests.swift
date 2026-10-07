import XCTest

/// What the keeper's pid actually is, and what counts as "idle" under it.
///
/// The keeper reports the pid it forked, and `ShellSpawn` makes that
/// `/usr/bin/login`, which stays the shell's parent for the whole session:
///
///     wortel-keeper → login → zsh → claude
///
/// Asking login for its children always finds the shell, so an "is anything
/// running?" check made against the keeper's pid could never say no. The keeper
/// tests spawn `/bin/sh` directly, with no login in between, which is how this
/// went unnoticed. These tables are shaped like a real session's.
final class KeeperShellTests: XCTestCase {
    private func entry(_ pid: pid_t, _ ppid: pid_t, _ name: String) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, pgid: pid, uid: 501, name: name,
                     startedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    func testTheShellUnderLoginIsFound() {
        let table = [entry(100, 1, "wortel-keeper"), entry(200, 100, "login"),
                     entry(300, 200, "zsh"), entry(400, 300, "claude")]
        XCTAssertEqual(ProcessTable.shell(of: 200, in: table), 300)
    }

    func testAShellForkedDirectlyIsItsOwnShell() {
        let table = [entry(100, 1, "wortel-keeper"), entry(300, 100, "zsh")]
        XCTAssertEqual(ProcessTable.shell(of: 300, in: table), 300)
    }

    /// The incident's nine sessions: login, a shell, and nothing under it.
    func testAShellAtAPromptHasNoWork() {
        let table = [entry(200, 100, "login"), entry(300, 200, "zsh")]
        let shell = ProcessTable.shell(of: 200, in: table)
        XCTAssertTrue(ProcessTable.work(under: shell, in: table).isEmpty)
        // Against login itself the same session looks busy, which was the bug.
        XCTAssertFalse(ProcessTable.work(under: 200, in: table).isEmpty)
    }

    func testAnAgentUnderTheShellIsWork() {
        let table = [entry(200, 100, "login"), entry(300, 200, "zsh"),
                     entry(400, 300, "claude")]
        let shell = ProcessTable.shell(of: 200, in: table)
        XCTAssertEqual(ProcessTable.work(under: shell, in: table).map(\.name), ["claude"])
    }

    /// `exec claude` replaces the shell: login's child is then the agent, and
    /// "nothing under it" would type a resume into the agent's own input. The
    /// resume check only proceeds when the process under login is a shell.
    func testAnExecdAgentIsNotAShell() {
        let table = [entry(200, 100, "login"), entry(300, 200, "claude")]
        let shell = ProcessTable.shell(of: 200, in: table)
        XCTAssertEqual(shell, 300)
        XCTAssertFalse(ProcessTable.isShell("claude"))
        XCTAssertTrue(ProcessTable.isShell("zsh"))
        XCTAssertTrue(ProcessTable.isShell("-zsh"))
    }

    /// powerlevel10k keeps `gitstatusd` and forked copies of the shell under
    /// an idle prompt; neither is work.
    func testPromptHelpersAreNotWork() {
        let table = [entry(200, 100, "login"), entry(300, 200, "zsh"),
                     entry(310, 300, "gitstatusd-darwin-arm64"), entry(320, 300, "zsh")]
        let shell = ProcessTable.shell(of: 200, in: table)
        XCTAssertTrue(ProcessTable.work(under: shell, in: table).isEmpty)
    }
}
