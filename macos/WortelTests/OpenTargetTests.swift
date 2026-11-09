import XCTest

/// What ⌘P lists besides the open sessions: archived sessions and worktrees
/// nobody's in, and only once something is typed.
final class OpenTargetTests: XCTestCase {
    private let oldSession = UUID(), otherSession = UUID()

    private var inputs: OpenTarget.Inputs {
        var inputs = OpenTarget.Inputs()
        inputs.archived = [.init(id: oldSession, name: "Old idea", branch: "worktree/old-idea"),
                           .init(id: otherSession, name: "Blog/Draft post", branch: nil)]
        inputs.notOpen = [.init(path: "/w/shop-toolbar", branch: "giel/toolbar"),
                          .init(path: "/w/detached-head", branch: nil)]
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
                       [.openWorktree(path: "/w/shop-toolbar")])
        let detached = OpenTarget.choices(for: "detached", in: inputs)
        XCTAssertEqual(detached.map(\.title), ["detached-head"])
        XCTAssertEqual(detached.map(\.group), [.notOpen])
    }

    /// Every word has to match, in any order, archived before not open.
    func testEveryWordMatches() {
        XCTAssertEqual(OpenTarget.choices(for: "idea old", in: inputs).map(\.action), [.restore(oldSession)])
        XCTAssertEqual(OpenTarget.choices(for: "old toolbar", in: inputs), [])
        XCTAssertEqual(OpenTarget.choices(for: "o", in: inputs).map(\.group), [.archived, .archived, .notOpen])
    }
}
