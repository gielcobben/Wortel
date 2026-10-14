import XCTest

/// What counts as a pull request in a field meant for branch names, and which
/// remote a URL means. A misread checks out the wrong code, or turns a branch
/// someone named `123` into a pull request.
final class PullRequestRefTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(PullRequestRef.parse("#123")?.number, 123)
        XCTAssertEqual(PullRequestRef.parse(" 42 ")?.number, 42)
        XCTAssertNil(PullRequestRef.parse("0"))
        XCTAssertNil(PullRequestRef.parse("#"))
        XCTAssertNil(PullRequestRef.parse("12a"))
        XCTAssertNil(PullRequestRef.parse("fix/123"))
        XCTAssertNil(PullRequestRef.parse("-1"))
    }

    /// A bare number is a branch when a branch has that name; `#` always means
    /// a pull request.
    func testBareNumberYieldsToABranch() {
        XCTAssertNil(PullRequestRef.parse("123", allowsBareNumber: false))
        XCTAssertEqual(PullRequestRef.parse("#123", allowsBareNumber: false)?.number, 123)
    }

    func testGitHubURL() throws {
        let pr = try XCTUnwrap(PullRequestRef.parse("https://github.com/Owner/Repo/pull/7/files"))
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.host, "github.com")
        XCTAssertEqual(pr.path, "Owner/Repo")
        XCTAssertEqual(pr.forge, .github)
        XCTAssertEqual(pr.ref(remoteURL: nil), "refs/pull/7/head")
        XCTAssertEqual(pr.branch, "worktree/pr-7")
    }

    func testGitLabURL() throws {
        let pr = try XCTUnwrap(PullRequestRef.parse("https://gitlab.com/group/sub/repo/-/merge_requests/9/diffs"))
        XCTAssertEqual(pr.number, 9)
        XCTAssertEqual(pr.path, "group/sub/repo")
        XCTAssertEqual(pr.forge, .gitlab)
        XCTAssertEqual(pr.ref(remoteURL: nil), "refs/merge-requests/9/head")
    }

    func testNotAPullRequestURL() {
        XCTAssertNil(PullRequestRef.parse("https://github.com/o/r/issues/7"))
        XCTAssertNil(PullRequestRef.parse("https://github.com/o/r"))
        XCTAssertNil(PullRequestRef.parse("ftp://github.com/o/r/pull/7"))
    }

    /// A number alone decides the ref by the remote it's fetched from.
    func testRefFollowsTheRemote() throws {
        let pr = try XCTUnwrap(PullRequestRef.parse("#5"))
        XCTAssertEqual(pr.ref(remoteURL: "git@github.com:o/r.git"), "refs/pull/5/head")
        XCTAssertEqual(pr.ref(remoteURL: "git@gitlab.example.com:o/r.git"), "refs/merge-requests/5/head")
    }

    func testURLMatchesItsRemoteWhateverTheTransport() throws {
        let pr = try XCTUnwrap(PullRequestRef.parse("https://github.com/owner/repo/pull/3"))
        for remote in ["git@github.com:owner/repo.git", "ssh://git@github.com/owner/repo",
                       "https://github.com/Owner/Repo.git", "https://github.com/owner/repo/"] {
            XCTAssertTrue(pr.matches(remoteURL: remote), remote)
        }
        for remote in ["git@github.com:someone/repo.git", "git@gitlab.com:owner/repo.git",
                       "https://github.com/owner/repo-fork.git"] {
            XCTAssertFalse(pr.matches(remoteURL: remote), remote)
        }
    }
}
