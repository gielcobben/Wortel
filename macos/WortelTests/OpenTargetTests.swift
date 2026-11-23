import XCTest

/// What ⌘P lists besides the open sessions: archived sessions and worktrees
/// nobody's in, and only once something is typed.
final class OpenTargetTests: XCTestCase {
    private let oldSession = UUID(), otherSession = UUID()

    private var inputs: OpenTarget.Inputs {
        var inputs = OpenTarget.Inputs()
        inputs.archived = [.init(id: oldSession, name: "Old idea", branch: "worktree/old-idea"),
                           .init(id: otherSession, name: "Blog/Draft post", branch: nil)]
        inputs.notOpen = [.init(path: "/w/shop-toolbar", branch: "me/toolbar", repository: "~/work/shop"),
                          .init(path: "/w/detached-head", branch: nil),
                          .init(path: "/w/blog-toolbar", branch: "me/toolbar", repository: "~/blog")]
        return inputs
    }

    /// Nothing typed is the recent sessions, with nothing put away under them.
    func testNothingTypedListsNothing() {
        XCTAssertEqual(OpenTarget.choices(for: "", in: inputs), [])
        XCTAssertEqual(OpenTarget.choices(for: "   ", in: inputs), [])
    }

    func testArchivedByNameOrBranch() {
        XCTAssertEqual(OpenTarget.choices(for: "old", in: inputs).map(\.action), [.restore(oldSession)])
        XCTAssertEqual(OpenTarget.choices(for: "worktree/old", in: inputs).map(\.action), [.restore(oldSession)])
        XCTAssertEqual(OpenTarget.choices(for: "DRAFT", in: inputs).map(\.action), [.restore(otherSession)])
    }

    /// A worktree is named for its branch, or its folder when it has none.
    func testNotOpenByBranchOrPath() {
        XCTAssertEqual(OpenTarget.choices(for: "toolbar", in: inputs).map(\.action),
                       [.openWorktree(path: "/w/shop-toolbar"), .openWorktree(path: "/w/blog-toolbar")])
        let detached = OpenTarget.choices(for: "detached", in: inputs)
        XCTAssertEqual(detached.map(\.title), ["detached-head"])
        XCTAssertEqual(detached.map(\.group), [.notOpen])
    }

    /// Two repositories with a worktree on the same branch: told apart by
    /// the repository beside the name, which can be typed too.
    func testNotOpenSaysWhichRepository() {
        let both = OpenTarget.choices(for: "me/toolbar", in: inputs)
        XCTAssertEqual(both.map(\.title), ["me/toolbar", "me/toolbar"])
        XCTAssertEqual(both.map(\.detail), ["~/work/shop", "~/blog"])
        XCTAssertEqual(OpenTarget.choices(for: "blog toolbar", in: inputs).map(\.action),
                       [.openWorktree(path: "/w/blog-toolbar")])
    }

    /// Every word has to match, in any order, archived before not open.
    func testEveryWordMatches() {
        XCTAssertEqual(OpenTarget.choices(for: "idea old", in: inputs).map(\.action), [.restore(oldSession)])
        XCTAssertEqual(OpenTarget.choices(for: "old toolbar", in: inputs), [])
        XCTAssertEqual(OpenTarget.choices(for: "o", in: inputs).map(\.group), [.archived, .archived, .notOpen, .notOpen])
    }
}
