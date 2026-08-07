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
        // A source newline is a *soft* break: the paragraph re-flows to the width
        // it's read at. Keeping it would break the line where the author's editor
        // wrapped, which in a wide window is a ragged column down the left.
        XCTAssertEqual(blocks[0].text, "line one line two")
        XCTAssertEqual(blocks[1].text, "second para")
    }

    func testTwoTrailingSpacesIsAHardBreak() {
        let blocks = MarkdownParser.parse("line one  \nline two")
        XCTAssertEqual(blocks[0].text, "line one\nline two")
    }

    func testTrailingBackslashIsAHardBreak() {
        let blocks = MarkdownParser.parse("line one\\\nline two")
        XCTAssertEqual(blocks[0].text, "line one\nline two")
    }

    func testSetextHeadings() {
        let blocks = MarkdownParser.parse("Title\n=====\n\nSection\n---\n\nbody")
        XCTAssertEqual(blocks.map(\.kind),
                       [.heading(level: 1), .heading(level: 2), .paragraph])
        XCTAssertEqual(blocks.map(\.text), ["Title", "Section", "body"])
    }

    func testRuleWithNoParagraphAboveIsStillARule() {
        // `---` is a thematic break *and* a setext underline; only a paragraph
        // directly above it makes it the latter.
        let blocks = MarkdownParser.parse("# Head\n\n---\n\nbody")
        XCTAssertEqual(blocks.map(\.kind), [.heading(level: 1), .rule, .paragraph])
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
        // A quote is prose too, so its lines re-flow like a paragraph's.
        XCTAssertEqual(blocks[0].text, "one two")
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

    // MARK: - Source lines

    /// Every block knows the line it starts on, which is what lets a preview
    /// window keep your place when you switch from the rendered document to the
    /// source and back. It's the only coordinate the two views share.
    func testBlocksCarryTheirSourceLine() {
        let source = """
        # Title

        A paragraph.

        - one
        - two

        ## Section

        Another paragraph.
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1), .paragraph, .bullet(indent: 0), .bullet(indent: 0),
            .heading(level: 2), .paragraph,
        ])
        XCTAssertEqual(blocks.map(\.line), [1, 3, 5, 6, 8, 10])
    }

    /// A fence's *content* starts on the line after the fence — the line the
    /// reader would land on if they switched to the source.
    func testCodeBlockLineIsItsFirstLineOfCode() {
        let source = """
        intro

        ```swift
        let a = 1
        ```

        after
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code(language: "swift"), .paragraph])
        XCTAssertEqual(blocks.map(\.line), [1, 4, 7])
    }

    func testQuotesTablesAndRulesCarryTheirLine() {
        let source = """
        > quoted

        ---

        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.map(\.line), [1, 3, 5])
    }

    /// A soft-wrapped paragraph reports where it *began*, not where it ended —
    /// otherwise switching modes lands you below the text you were reading.
    func testWrappedParagraphReportsItsFirstLine() {
        let blocks = MarkdownParser.parse("# T\n\nline one\nline two\nline three\n\nnext")
        XCTAssertEqual(blocks.map(\.line), [1, 3, 7])
    }

    // MARK: - Continuation and separation

    /// A line indented under a list item continues it — CommonMark's lazy
    /// continuation. Read as its own block it renders as a paragraph back at the
    /// left margin, outdented from the list it belongs to, which is the one place
    /// in a document text visibly does not belong.
    func testIndentedLineContinuesItsListItem() {
        let blocks = MarkdownParser.parse("""
        - a long item that wraps in the source
          and continues on this line
        - a second item
        """)
        XCTAssertEqual(blocks.map(\.kind), [.bullet(indent: 0), .bullet(indent: 0)])
        XCTAssertEqual(blocks[0].text, "a long item that wraps in the source and continues on this line")
        XCTAssertEqual(blocks[1].text, "a second item")
    }

    /// …but an indented line that is itself a list item is a nested item, not a
    /// continuation.
    func testIndentedListItemIsStillAListItem() {
        let blocks = MarkdownParser.parse("- outer\n  - inner")
        XCTAssertEqual(blocks.map(\.kind), [.bullet(indent: 0), .bullet(indent: 1)])
    }

    /// Two lists separated by a blank line are two lists. The blank line is the
    /// only thing that says so, so the parser has to carry it — the view spaces
    /// them apart from this.
    func testBlankLineBetweenListsIsRecorded() {
        let blocks = MarkdownParser.parse("- one\n- two\n\n- three\n- four")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.map(\.afterBlank), [false, false, true, false])
    }

    func testFirstBlockIsNotMarkedAfterBlank() {
        XCTAssertEqual(MarkdownParser.parse("intro\n\n- one").map(\.afterBlank), [false, true])
    }
}
