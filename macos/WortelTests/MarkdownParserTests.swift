import XCTest

/// The markdown block parser is a line-based structure pass (not a full
/// CommonMark engine), so the risk isn't spec purity — it's a rule quietly
/// eating or mis-classifying a line. These pin the structure it produces:
/// headings, the two list families, task checkboxes, coalesced quotes, rules,
/// fenced code, and GitHub tables, plus the boundaries between them.
final class MarkdownParserTests: XCTestCase {

    // MARK: - Headings

    func testHeadingLevels() {
        let blocks = MarkdownParser.parse("# One\n## Two\n###### Six")
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1), .heading(level: 2), .heading(level: 6),
        ])
        XCTAssertEqual(blocks.map(\.text), ["One", "Two", "Six"])
    }

    func testSevenHashesIsNotAHeading() {
        // Only 1–6 hashes are a heading; more is prose.
        let blocks = MarkdownParser.parse("####### too many")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let blocks = MarkdownParser.parse("#nospace")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    // MARK: - Paragraphs

    func testConsecutiveLinesCoalesceBlankLineSplits() {
        let blocks = MarkdownParser.parse("line one\nline two\n\nsecond para")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].text, "line one\nline two")
        XCTAssertEqual(blocks[1].text, "second para")
    }

    // MARK: - Lists

    func testBulletMarkersAndIndent() {
        let blocks = MarkdownParser.parse("- a\n* b\n+ c\n  - nested")
        XCTAssertEqual(blocks.map(\.kind), [
            .bullet(indent: 0), .bullet(indent: 0), .bullet(indent: 0), .bullet(indent: 1),
        ])
        XCTAssertEqual(blocks.map(\.text), ["a", "b", "c", "nested"])
    }

    func testOrderedMarkers() {
        let blocks = MarkdownParser.parse("1. first\n2) second")
        XCTAssertEqual(blocks.map(\.kind), [
            .ordered(indent: 0, marker: "1."), .ordered(indent: 0, marker: "2)"),
        ])
        XCTAssertEqual(blocks.map(\.text), ["first", "second"])
    }

    // MARK: - Task lists

    func testTaskCheckboxes() {
        let blocks = MarkdownParser.parse("- [ ] open\n- [x] done\n- [X] also done\n- plain")
        XCTAssertEqual(blocks.map(\.kind), [
            .task(indent: 0, checked: false),
            .task(indent: 0, checked: true),
            .task(indent: 0, checked: true),
            .bullet(indent: 0),
        ])
        XCTAssertEqual(blocks.map(\.text), ["open", "done", "also done", "plain"])
    }

    func testMalformedCheckboxIsAPlainBullet() {
        // `[y]` isn't a valid mark; it stays a normal bullet, text intact.
        let blocks = MarkdownParser.parse("- [y] nope\n- [] empty")
        XCTAssertEqual(blocks.map(\.kind), [.bullet(indent: 0), .bullet(indent: 0)])
        XCTAssertEqual(blocks.map(\.text), ["[y] nope", "[] empty"])
    }

    // MARK: - Quotes

    func testQuoteLinesCoalesce() {
        let blocks = MarkdownParser.parse("> one\n> two\n\nafter")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .quote)
        XCTAssertEqual(blocks[0].text, "one\ntwo")
        XCTAssertEqual(blocks[1].kind, .paragraph)
    }

    // MARK: - Rules

    func testHorizontalRules() {
        let blocks = MarkdownParser.parse("---\n***\n___\n- - -")
        XCTAssertEqual(blocks.map(\.kind), [.rule, .rule, .rule, .rule])
    }

    // MARK: - Fenced code

    func testFencedCodeCapturesLanguageAndBody() {
        let source = "```swift\nlet x = 1\nlet y = 2\n```"
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[0].text, "let x = 1\nlet y = 2")
    }

    func testFenceWithoutLanguage() {
        let blocks = MarkdownParser.parse("```\nplain\n```")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: nil)])
        XCTAssertEqual(blocks[0].text, "plain")
    }

    func testUnterminatedFenceSwallowsRest() {
        // A fence being typed still renders as code, not as literal backticks.
        let blocks = MarkdownParser.parse("text\n```py\nunclosed")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code(language: "py")])
        XCTAssertEqual(blocks[1].text, "unclosed")
    }

    func testHashInsideCodeIsNotAHeading() {
        let blocks = MarkdownParser.parse("```\n# not a heading\n```")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: nil)])
        XCTAssertEqual(blocks[0].text, "# not a heading")
    }

    // MARK: - Tables

    func testTableWithEdgePipes() {
        let source = """
        | A | B |
        | - | - |
        | 1 | 2 |
        | 3 | 4 |
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .table(header: ["A", "B"], rows: [["1", "2"], ["3", "4"]]))
    }

    func testTableWithoutEdgePipesAndAlignment() {
        let source = """
        Name | Score
        :--- | ---:
        Ada  | 100
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .table(header: ["Name", "Score"], rows: [["Ada", "100"]]))
    }

    func testPipeLineWithoutSeparatorIsNotATable() {
        // A pipe in prose with no `---|---` beneath it stays a paragraph.
        let blocks = MarkdownParser.parse("a | b is just prose")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    // MARK: - Mixed document ordering

    func testBlockOrderAndSequentialIDs() {
        let source = """
        # Title

        Intro paragraph.

        - item

        ```
        code
        ```
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1), .paragraph, .bullet(indent: 0), .code(language: nil),
        ])
        XCTAssertEqual(blocks.map(\.id), Array(0..<blocks.count))
    }
}
