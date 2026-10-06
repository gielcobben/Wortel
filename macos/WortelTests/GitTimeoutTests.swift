import XCTest

/// A git that talks to a remote can hang for as long as the network does. It
/// must end at its time limit, and take what it started with it: a plain
/// terminate left the fetch's ssh running, adopted by launchd, holding the
/// pipes the call was waiting on.
final class GitTimeoutTests: XCTestCase {
    func testAHungFetchEndsAtItsLimitAndLeavesNothingRunning() async {
        let repo = GitFixture.newRepo("timeout")
        defer { GitFixture.destroy(repo) }
        // An "ssh" that never answers. The odd number is how we find it after.
        let marker = "sleep 37.5"
        let started = Date()
        let result = await GitService.run(
            ["-c", "core.sshCommand=sh -c '\(marker)' --", "fetch", "ssh://example.invalid/x.git"],
            in: repo.path, timeout: 1)
        let took = Date().timeIntervalSince(started)

        XCTAssertFalse(result.ok)
        XCTAssertLessThan(took, 10, "the limit must end the call, not the ssh finishing")
        try? await Task.sleep(for: .milliseconds(300))
        let left = GitFixture.sh("pgrep -f 'slee[p] 37.5' || true", in: repo)
        XCTAssertEqual(left, "", "the transport must not outlive the git that started it")
    }
}
