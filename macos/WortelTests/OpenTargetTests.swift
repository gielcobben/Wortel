import XCTest

/// What Open Branch lists for what's typed, and what Return does. The rule
/// is "take me to it": a branch with a place is listed at that place and
/// nowhere else, so Return never makes a second session or worktree for
/// something that already has one.
final class OpenTargetTests: XCTestCase {
    private let fixSession = UUID(), oldSession = UUID()

    private var inputs: OpenTarget.Inputs {
        var inputs = OpenTarget.Inputs()
        inputs.hasRepository = true
        inputs.open = [.init(id: fixSession, name: "Fix login", branch: "fix-login")]
        inputs.archived = [.init(id: oldSession, name: "Old idea", branch: "worktree/old-idea")]
        inputs.notOpen = [.init(path: "/w/shop-toolbar", branch: "giel/toolbar")]
        inputs.main = .init(path: "/w/shop", branch: "main")
        inputs.local = ["main", "fix-login", "worktree/old-idea", "giel/toolbar", "giel/shape-lab", "release"]
        inputs.remote = [("origin", "main"), ("origin", "giel/remote-only"), ("upstream", "giel/remote-only")]
        return inputs
    }

    func testNothingTypedListsWhatHasAPlace() {
        let choices = OpenTarget.choices(for: "", in: inputs)
        XCTAssertEqual(choices.map(\.action), [.goTo(fixSession), .restore(oldSession),
                                               .openWorktree(path: "/w/shop-toolbar")])
    }

    /// Typed in part, a name could still be a new branch, so Create comes
    /// last; typed whole, the place is all there is.
    func testABranchIsListedAtItsPlaceOnly() {
        XCTAssertEqual(OpenTarget.choices(for: "fix", in: inputs).map(\.action),
                       [.goTo(fixSession), .create(branch: "fix")])
        XCTAssertEqual(OpenTarget.choices(for: "fix-login", in: inputs).map(\.action), [.goTo(fixSession)])
        XCTAssertEqual(OpenTarget.choices(for: "worktree/old-idea", in: inputs).map(\.action), [.restore(oldSession)])
        XCTAssertEqual(OpenTarget.choices(for: "giel/toolbar", in: inputs).map(\.action),
                       [.openWorktree(path: "/w/shop-toolbar")])
        XCTAssertEqual(OpenTarget.choices(for: "main", in: inputs).map(\.action), [.mainCheckout(path: "/w/shop")])
    }

    /// Another repository's archived session is listed, so it can be found
    /// from anywhere, but its branch is that repository's: a branch here with
    /// the same name is still offered.
    func testAnotherRepositorysArchivedSessionPlacesNothing() {
        let elsewhere = UUID()
        var inputs = inputs
        inputs.archivedElsewhere = [.init(id: elsewhere, name: "opjetv/Player", branch: "release")]
        XCTAssertEqual(OpenTarget.choices(for: "", in: inputs).map(\.action),
                       [.goTo(fixSession), .restore(oldSession), .restore(elsewhere),
                        .openWorktree(path: "/w/shop-toolbar")])
        XCTAssertEqual(OpenTarget.choices(for: "release", in: inputs).map(\.action),
                       [.restore(elsewhere), .checkOut(branch: "release", remote: nil)])
        XCTAssertEqual(OpenTarget.choices(for: "player", in: inputs).map(\.action),
                       [.restore(elsewhere), .create(branch: "player")])
    }

    func testBranchesThenCreate() {
        let shape = OpenTarget.choices(for: "shape", in: inputs).map(\.action)
        XCTAssertEqual(shape, [.checkOut(branch: "giel/shape-lab", remote: nil), .create(branch: "shape")])
        // A remote-only branch once, from the first remote carrying it.
        XCTAssertEqual(OpenTarget.choices(for: "remote-only", in: inputs).map(\.action),
                       [.checkOut(branch: "giel/remote-only", remote: "origin"), .create(branch: "remote-only")])
        // Typed exactly: no Create for a branch that exists.
        XCTAssertEqual(OpenTarget.choices(for: "release", in: inputs).map(\.action),
                       [.checkOut(branch: "release", remote: nil)])
    }

    func testANameIsMadeIntoABranch() {
        XCTAssertEqual(OpenTarget.choices(for: "Jump to", in: inputs).last?.action, .create(branch: "Jump-to"))
    }

    func testPullRequests() {
        let pr = OpenTarget.choices(for: "#7", in: inputs)
        XCTAssertEqual(pr.first?.action, .pullRequest("#7"))
        XCTAssertFalse(pr.contains { if case .create = $0.action { return true } else { return false } })
        // A bare number is a pull request unless a branch has that name.
        var named = inputs
        named.local.append("42")
        XCTAssertEqual(OpenTarget.choices(for: "42", in: named).first?.action, .checkOut(branch: "42", remote: nil))
        XCTAssertEqual(OpenTarget.choices(for: "42", in: inputs).first?.action, .pullRequest("42"))
    }

    /// Outside a repository there's nothing to check out or make.
    func testNoRepository() {
        var none = OpenTarget.Inputs()
        none.open = [.init(id: fixSession, name: "Fix login", branch: "fix-login")]
        XCTAssertEqual(OpenTarget.choices(for: "anything", in: none), [])
        XCTAssertEqual(OpenTarget.choices(for: "fix", in: none).map(\.action), [.goTo(fixSession)])
    }

    /// A branch starting with what's typed comes before one that only
    /// contains it.
    func testPrefixFirst() {
        var many = inputs
        many.local = ["feature/lab", "lab-notes"]
        let actions = OpenTarget.choices(for: "lab", in: many).map(\.action)
        XCTAssertEqual(actions.prefix(2), [.checkOut(branch: "lab-notes", remote: nil),
                                           .checkOut(branch: "feature/lab", remote: nil)])
    }

    /// `origin/foo` typed or pasted is the remote branch, not a new local one
    /// wearing its name.
    func testARemoteRefTypedIsTheRemoteBranch() {
        let actions = OpenTarget.choices(for: "upstream/giel/remote-only", in: inputs).map(\.action)
        XCTAssertEqual(actions, [.checkOut(branch: "giel/remote-only", remote: "upstream")])
    }

    /// A bare number that's a branch on a remote isn't a pull request.
    func testANumberThatsARemoteBranchIsntAPullRequest() {
        var inputs = self.inputs
        inputs.remote.append(("origin", "4242"))
        XCTAssertFalse(OpenTarget.choices(for: "4242", in: inputs).contains { $0.group == .pullRequest })
    }
}
