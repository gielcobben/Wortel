import XCTest

/// A ⌘-clicked link an agent broke over several rows. Every row here is one
/// an agent drew at 60 columns (Claude Code 2.1.331, recorded 2026-11-24):
/// its renderer wraps its own text with a real line break and an indent, so
/// libghostty only ever saw the clicked row, and half a path opened nothing.
final class TerminalLinkWrapTests: XCTestCase {
    private var root: URL!
    private let longFile = "macos/Wortel/Ghostty/GhosttyRuntimeSomethingVeryLongName/TerminalLinkResolution.swift"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-terminal-wrap-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for file in [longFile, "docs/decisions.md", "macos/App.swift"] {
            let url = root.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A click on `rows[row]`, on the first character of `text` there, moved
    /// on by `offset`.
    private func click(_ rows: [String], row: Int, on text: String, offset: Int = 0,
                       columns: Int = 60) -> TerminalLinkClick {
        let line = rows[row]
        let range = line.range(of: text)!
        let index = line.distance(from: line.startIndex, to: range.lowerBound) + offset
        return TerminalLinkClick(rows: rows, row: row, index: index, columns: columns)
    }

    /// What the app opens for a click on a path: the first join that exists.
    private func openedPath(_ click: TerminalLinkClick) -> TerminalLink.Target? {
        let bases = TerminalLink.bases([root.path])
        return TerminalLink.wrappedPaths(click).lazy
            .compactMap { TerminalLink.resolve($0, bases: bases) }.first
    }

    private func file(_ relative: String) -> URL {
        root.appendingPathComponent(relative).standardizedFileURL
    }

    // MARK: - Paths

    /// The shape that made this: broken mid-word, the rest indented under
    /// the text, a `:42` after it. The first row has no dot, so libghostty
    /// found no link there at all; the second's half existed nowhere.
    func testClaudesBrokenPathOpensFromEitherRow() {
        let rows = [
            "     Edit macos/Wortel/Ghostty/GhosttyRuntimeSomethingVeryLo",
            "     ngName/TerminalLinkResolution.swift:42 next.",
        ]
        for c in [click(rows, row: 0, on: "macos"), click(rows, row: 0, on: "VeryLo", offset: 5),
                  click(rows, row: 1, on: "ngName"), click(rows, row: 1, on: ":42")] {
            let target = openedPath(c)
            XCTAssertEqual(target?.url, file(longFile))
            XCTAssertEqual(target?.line, 42)
        }
    }

    /// Broken just after a `/`: the first row alone is a folder that exists,
    /// and the file is what was meant.
    func testBrokenAfterASlashOpensTheFileNotTheFolder() {
        let rows = ["  ⎿  Read docs/", "     decisions.md for the reason"]
        XCTAssertEqual(openedPath(click(rows, row: 0, on: "docs"))?.url, file("docs/decisions.md"))
        XCTAssertEqual(openedPath(click(rows, row: 1, on: "decisions"))?.url, file("docs/decisions.md"))
    }

    func testThreeRowsFromAnyOfThem() {
        let rows = [
            "⏺ Edit macos/Wortel/Ghostty/",
            "       GhosttyRuntimeSomethingVeryLongName/",
            "       TerminalLinkResolution.swift",
        ]
        for row in 0..<3 {
            let text = ["macos", "Ghostty", "Terminal"][row]
            XCTAssertEqual(openedPath(click(rows, row: row, on: text))?.url, file(longFile), "row \(row)")
        }
    }

    /// A whole path with the sentence going on below it: the join doesn't
    /// exist, so nothing here, and libghostty's own match is opened.
    func testAJoinThatDoesNotExistOpensNothingHere() {
        let rows = ["  Read docs/decisions.md", "  and then the rest of it"]
        XCTAssertNil(openedPath(click(rows, row: 0, on: "docs")))
    }

    func testTwoPathsOnNeighbouringRowsStayApart() {
        let rows = ["  docs/decisions.md", "  macos/App.swift"]
        XCTAssertNil(openedPath(click(rows, row: 0, on: "docs")))
        XCTAssertNil(openedPath(click(rows, row: 1, on: "macos")))
    }

    /// A row that ends mid-sentence is not a path's first half.
    func testTextAroundIsNotTakenIn() {
        let rows = ["  ⏺ Done.", "  docs/decisions.md is where it went"]
        XCTAssertEqual(TerminalLink.wrappedPaths(click(rows, row: 1, on: "docs")),
                       ["Done.docs/decisions.md"])
        XCTAssertNil(openedPath(click(rows, row: 1, on: "docs")))
        XCTAssertEqual(TerminalLink.wrappedPaths(click(rows, row: 1, on: " is", offset: 1)), [])
    }

    func testAClickOffTheTextIsNothing() {
        let rows = ["     Edit macos/Wortel/Ghostty/GhosttyRuntimeSomethingVeryLo"]
        XCTAssertEqual(TerminalLink.wrappedPaths(click(rows, row: 0, on: " macos")), [])
        XCTAssertEqual(TerminalLink.wrappedPaths(
            TerminalLinkClick(rows: rows, row: 0, index: 500, columns: 60)), [])
    }

    // MARK: - Web addresses

    private let address =
        "https://github.com/manaflow-ai/cmux/issues/8583?query=long-url-that-wraps-across-two-lines-in-tool-output&x=1234567890"

    /// Claude Code's approval box: `│` down the left, the command inside it.
    func testApprovalBox() {
        let rows = [
            " │ curl -sI \"https://github.com/manaflow-ai/cmux/issues/858",
            " │ 3?query=long-url-that-wraps-across-two-lines-in-tool-out",
            " │ put&x=1234567890\"",
        ]
        for c in [click(rows, row: 0, on: "github"), click(rows, row: 1, on: "query"),
                  click(rows, row: 2, on: "1234")] {
            XCTAssertEqual(TerminalLink.wrappedURL(c), address)
        }
    }

    /// Its tool-call header, the address broken at a `?` and the call's
    /// closing bracket after it.
    func testToolCallHeader() {
        let rows = [
            "⏺ Bash(echo https://github.com/manaflow-ai/cmux/issues/8583?",
            "      query=long-url-that-wraps-across-two-lines-in-tool-out",
            "      put&x=1234567890)",
        ]
        for c in [click(rows, row: 0, on: "https"), click(rows, row: 1, on: "wraps"),
                  click(rows, row: 2, on: "put")] {
            XCTAssertEqual(TerminalLink.wrappedURL(c), address)
        }
    }

    /// The echo of your own prompt, broken mid-word.
    func testYourOwnPrompt() {
        let rows = [
            "❯ Use the Bash tool to run: curl -sI https://github.com/man",
            "  aflow-ai/cmux/issues/8583?query=long-url-that-wraps-acros",
            "  s-two-lines-in-tool-output&x=1234567890",
        ]
        XCTAssertEqual(TerminalLink.wrappedURL(click(rows, row: 1, on: "aflow")), address)
        // The words before the address are not part of it.
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 0, on: "curl")))
    }

    /// cmux's open bug (#24990): broken inside a `%XX`, after a hex digit.
    func testBrokenInsideAPercentEscape() {
        let rows = [
            "  https://fa.wikipedia.org/wiki/%D8%B1%D8%A7%D8%AA_%D8%B",
            "  2%D8%A8%D8%A7%D9%86",
        ]
        XCTAssertEqual(TerminalLink.wrappedURL(click(rows, row: 1, on: "2%", columns: 58)),
                       "https://fa.wikipedia.org/wiki/%D8%B1%D8%A7%D8%AA_%D8%B2%D8%A8%D8%A7%D9%86")
    }

    /// Short rows were not wrapped: a list of addresses stays a list, and
    /// git's `remote:` line after a link is not glued on.
    func testShortRowsAreNotJoined() {
        let list = ["  https://a.example/x", "  https://b.example/y", "  more"]
        XCTAssertNil(TerminalLink.wrappedURL(click(list, row: 0, on: "https")))
        XCTAssertNil(TerminalLink.wrappedURL(click(list, row: 1, on: "https")))
        let push = ["remote:   https://github.com/o/r/pull/new/some-branch", "remote:"]
        XCTAssertNil(TerminalLink.wrappedURL(click(push, row: 0, on: "https", columns: 120)))
    }

    /// A whole address that only ends late in its row, short of where an
    /// agent breaks one: the next row's word is not glued on, from either.
    func testAnAddressEndingLateInARowIsNotContinued() {
        let rows = ["     remote:   https://github.com/u/r/pull/new/some-long-branch-name",
                    "     remote:"]
        XCTAssertEqual(rows[0].count, 68)
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 0, on: "https", columns: 80)))
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 1, on: "remote", columns: 80)))
    }

    /// A full row of addresses, one after another: each its own.
    func testANewAddressIsNotGluedOn() {
        let rows = [
            "  https://github.com/manaflow-ai/cmux/issues/8583?query=abc",
            "  https://github.com/manaflow-ai/cmux/issues/9866",
        ]
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 0, on: "https")))
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 1, on: "https")))
    }

    /// A comma ending a full row is a list going on.
    func testACommaEndsIt() {
        let rows = [
            "  see https://github.com/manaflow-ai/cmux/issues/8583?q=ab,",
            "  then the next thing",
        ]
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 0, on: "https")))
    }

    /// An address on one row is libghostty's to match, as before.
    func testAnUnbrokenAddressIsLeftAlone() {
        let rows = ["  see https://wortel.sh for it"]
        XCTAssertNil(TerminalLink.wrappedURL(click(rows, row: 0, on: "wortel")))
    }
}
