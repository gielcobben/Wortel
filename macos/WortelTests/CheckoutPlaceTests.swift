import XCTest

/// What the git panel calls a checkout. After a placeholder branch is renamed
/// for the work, a worktree's folder still reads `worktree-brave-river-1a2f`:
/// naming places by folder put that on the chip, in the lists and in Bring
/// Here's messages, where the session you know it by belongs.
final class CheckoutPlaceTests: XCTestCase {
    private let wt = "/w/repo/worktree-brave-river-1a2f"

    func testTheSessionThatLivesThereWins() {
        let name = CheckoutPlace.sessionName(
            at: wt,
            live: [
                .init(home: nil, visiting: wt, name: "Just looking"),
                .init(home: wt, visiting: "/elsewhere", name: "Fix login"),
            ],
            archived: [.init(checkout: wt, name: "Old")])
        XCTAssertEqual(name, "Fix login")
    }

    func testThenOneStandingInIt() {
        let name = CheckoutPlace.sessionName(
            at: wt,
            live: [.init(home: "/other", visiting: nil, name: "A"), .init(home: nil, visiting: wt, name: "B")],
            archived: [.init(checkout: wt, name: "Old")])
        XCTAssertEqual(name, "B")
    }

    func testThenOneArchivedThere() {
        let name = CheckoutPlace.sessionName(
            at: wt, live: [.init(home: "/other", visiting: nil, name: "A")],
            archived: [.init(checkout: "/x", name: "X"), .init(checkout: wt, name: "Waiting")])
        XCTAssertEqual(name, "Waiting")
    }

    func testNoSession() {
        XCTAssertNil(CheckoutPlace.sessionName(at: wt, live: [], archived: []))
    }

    func testTitleFallsFromSessionToBranchToFolder() {
        XCTAssertEqual(CheckoutPlace.title(path: wt, sessionName: "Fix login", branch: "worktree/fix-login",
                                           isPrimary: false), "Fix login")
        XCTAssertEqual(CheckoutPlace.title(path: wt, sessionName: nil, branch: "worktree/fix-login",
                                           isPrimary: false), "worktree/fix-login")
        XCTAssertEqual(CheckoutPlace.title(path: wt, sessionName: "", branch: nil, isPrimary: false),
                       "worktree-brave-river-1a2f")
    }

    /// The repository's own folder is named for the repository, and its
    /// branch is already on the chip beside it.
    func testTheMainFolderKeepsItsName() {
        XCTAssertEqual(CheckoutPlace.title(path: "/w/repo", sessionName: nil, branch: "main", isPrimary: true),
                       "repo")
    }
}
