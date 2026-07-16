import XCTest

/// `%D` is a stable, documented format, so these run against fixed input rather
/// than a live repo — each string below is what `git log --decorate=full`
/// actually prints for that situation.
///
/// The reason this parser is worth pinning at all: it exists only because the
/// *short* decoration is ambiguous, and a regression would be silent. Every
/// case here is one that short names get wrong.
final class GitRefTests: XCTestCase {
    func testHeadArrowMarksTheCurrentBranch() {
        let refs = GitRef.parse(decoration: "HEAD -> refs/heads/main")
        XCTAssertEqual(refs, [GitRef(name: "main", kind: .localBranch, isHead: true)])
    }

    /// The whole reason for `--decorate=full`. Short decoration prints "main" and
    /// "origin/main", and nothing in either string says which is remote — a
    /// slash can't be the test, because a local branch is very often "feature/x".
    func testSlashesDoNotDecideRemoteness() {
        let refs = GitRef.parse(
            decoration: "HEAD -> refs/heads/feature/login, refs/remotes/origin/main")
        XCTAssertEqual(refs, [
            GitRef(name: "feature/login", kind: .localBranch, isHead: true),
            GitRef(name: "origin/main", kind: .remoteBranch, isHead: false),
        ])
    }

    /// Note the "tag: " marker: git keeps it even under --decorate=full, so a tag
    /// arrives as "tag: refs/tags/v1.2" rather than the bare refname the other
    /// kinds get. Dropping the marker is what a naive prefix check gets wrong —
    /// and it did, until GitBranchServiceTests caught it against real git.
    func testTagsAndBranchesTogether() {
        let refs = GitRef.parse(
            decoration: "HEAD -> refs/heads/main, tag: refs/tags/v1.2, refs/remotes/origin/main")
        XCTAssertEqual(refs.map(\.kind), [.localBranch, .tag, .remoteBranch])
        XCTAssertEqual(refs.map(\.name), ["main", "v1.2", "origin/main"])
    }

    /// A detached HEAD decorates as a bare "HEAD" with no arrow.
    func testDetachedHead() {
        let refs = GitRef.parse(decoration: "HEAD, tag: refs/tags/v1.0")
        XCTAssertEqual(refs.first, GitRef(name: "HEAD", kind: .detachedHead, isHead: true))
        XCTAssertEqual(refs.last, GitRef(name: "v1.0", kind: .tag, isHead: false))
    }

    /// origin/HEAD is a symref to the remote's default branch, so it rides along
    /// on every origin/main and would draw a second chip meaning the same thing.
    func testRemoteHeadSymrefIsDropped() {
        let refs = GitRef.parse(
            decoration: "refs/remotes/origin/main, refs/remotes/origin/HEAD")
        XCTAssertEqual(refs, [GitRef(name: "origin/main", kind: .remoteBranch, isHead: false)])
    }

    /// The overwhelmingly common case: no decoration at all.
    func testUndecoratedCommit() {
        XCTAssertTrue(GitRef.parse(decoration: "").isEmpty)
    }

    /// A commit that is HEAD but whose branch is checked out elsewhere still
    /// decorates other branches pointing at it — only the arrow one is HEAD.
    func testOnlyTheArrowRefIsHead() {
        let refs = GitRef.parse(
            decoration: "HEAD -> refs/heads/main, refs/heads/release")
        XCTAssertEqual(refs.filter(\.isHead).map(\.name), ["main"])
        XCTAssertEqual(refs.last, GitRef(name: "release", kind: .localBranch, isHead: false))
    }

    /// Refs outside heads/remotes/tags (notes, stash, pull refs) aren't branches
    /// and have no business as chips.
    func testUnknownRefNamespacesAreIgnored() {
        let refs = GitRef.parse(
            decoration: "refs/notes/commits, refs/stash, refs/heads/main")
        XCTAssertEqual(refs, [GitRef(name: "main", kind: .localBranch, isHead: false)])
    }

    /// An annotated tag on the checked-out commit decorates with the arrow *and*
    /// the marker: HEAD points at the branch, the tag rides along beside it.
    func testTagOnHeadCommit() {
        let refs = GitRef.parse(decoration: "HEAD -> refs/heads/main, tag: refs/tags/v2.0")
        XCTAssertEqual(refs.filter(\.isHead).map(\.name), ["main"])
        XCTAssertEqual(refs.last, GitRef(name: "v2.0", kind: .tag, isHead: false))
    }

    /// "origin/feature/x" → "feature/x": only the remote name comes off.
    func testLocalNameForRemoteStripsOnlyTheRemote() {
        XCTAssertEqual(GitService.localName(forRemote: "origin/main"), "main")
        XCTAssertEqual(GitService.localName(forRemote: "origin/feature/x"), "feature/x")
        XCTAssertEqual(GitService.localName(forRemote: "main"), "main")
    }
}
