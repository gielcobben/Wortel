import XCTest

/// ⌘P's ranking: the first row is the whole feature.
final class SessionSwitcherMatchTests: XCTestCase {
    private typealias C = SessionSwitcherMatch.Candidate

    private let wortel = C(id: UUID(), name: "Wortel app design and UX improvements", folder: "Wortel",
                           branch: nil, path: "~/Developer/wortel")
    private let emdash = C(id: UUID(), name: "EmDash site build", folder: "slimmersmullen",
                           branch: nil, path: "~/Developer/slimmersmullen")
    private let market = C(id: UUID(), name: "add-pre-post-market-prices", folder: "networth",
                           branch: "worktree/pre-post", path: "~/.wortel/worktrees/networth/pre-post")
    private let run = C(id: UUID(), name: "Run locally", folder: "GFPC",
                        branch: nil, path: "~/Developer/gielcobben-2026")

    private var all: [C] { [wortel, emdash, market, run] }

    private func first(_ query: String, recent: [UUID] = [], current: UUID? = nil) -> C? {
        SessionSwitcherMatch.rank(query, all, recent: recent, current: current).first
    }

    func testTheStartOfTheNameWins() {
        XCTAssertEqual(first("em"), emdash)
        XCTAssertEqual(first("run"), run)
    }

    /// A word inside the name beats the same letters anywhere else.
    func testAWordInTheNameBeatsTheFolderAndPath() {
        XCTAssertEqual(first("site"), emdash)
        XCTAssertEqual(first("market"), market)
    }

    func testFolderBranchAndPathFindSessionsToo() {
        XCTAssertEqual(first("slimmer"), emdash, "the folder")
        XCTAssertEqual(first("pre-post"), market)
        XCTAssertEqual(first("gielcobben"), run, "the path")
    }

    /// Every word has to match somewhere; together they narrow.
    func testEveryWordMustMatch() {
        XCTAssertEqual(SessionSwitcherMatch.rank("wortel design", all, recent: [], current: nil), [wortel])
        XCTAssertTrue(SessionSwitcherMatch.rank("wortel emdash", all, recent: [], current: nil).isEmpty)
    }

    func testLettersInOrderAreALastResort() {
        XCTAssertEqual(first("wadu"), wortel)
        XCTAssertNil(first("zzz"))
    }

    /// Nothing typed: most recently used first, the one you're in last, so
    /// ⌘P then Return goes back where you were.
    func testEmptyQueryIsMostRecentFirstWithTheCurrentLast() {
        let ranked = SessionSwitcherMatch.rank("", all, recent: [run.id, emdash.id], current: run.id)
        XCTAssertEqual(ranked.first, emdash)
        XCTAssertEqual(ranked.last, run)
        XCTAssertEqual(ranked.count, all.count)
    }

    /// Two equally good matches: the more recently used first.
    func testTiesGoToTheMostRecent() {
        let a = C(id: UUID(), name: "api server", folder: nil, branch: nil, path: "~/a")
        let b = C(id: UUID(), name: "api client", folder: nil, branch: nil, path: "~/b")
        let ranked = SessionSwitcherMatch.rank("api", [a, b], recent: [b.id, a.id], current: nil)
        XCTAssertEqual(ranked, [b, a])
    }
}
