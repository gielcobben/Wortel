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

    // MARK: - Front matter

    func testFrontMatterIsYAMLCode() {
        let source = "---\nname: Wortel\ncolors:\n  page: \"#fff\"\n---\n\n# Title\n\nbody"
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.map(\.kind), [.code(language: "yaml"), .heading(level: 1), .paragraph])
        XCTAssertEqual(blocks[0].text, "name: Wortel\ncolors:\n  page: \"#fff\"")
        // Lines still match the source: the YAML starts on 2, the heading on 7.
        XCTAssertEqual(blocks.map(\.line), [2, 7, 9])
    }

    func testFrontMatterMayCloseWithDots() {
        let blocks = MarkdownParser.parse("---\ntitle: x\n...\ntext")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: "yaml"), .paragraph])
        XCTAssertEqual(blocks[1].line, 4)
    }

    func testUnclosedLeadingRuleIsStillARule() {
        let blocks = MarkdownParser.parse("---\ntext")
        XCTAssertEqual(blocks.map(\.kind), [.rule, .paragraph])
    }

    func testRuleLaterInTheFileIsNotFrontMatter() {
        let blocks = MarkdownParser.parse("intro\n\n---\nkey: value\n---")
        XCTAssertFalse(blocks.contains { $0.kind == .code(language: "yaml") })
    }

    /// A leading rule followed by a title, prose or a blank line is a rule,
    /// even with another `---` further down.
    func testLeadingRuleThenMarkdownIsNotFrontMatter() {
        XCTAssertEqual(MarkdownParser.parse("---\n# Title\n\nintro\n\n---\nmore").map(\.kind),
                       [.rule, .heading(level: 1), .paragraph, .rule, .paragraph])
        XCTAssertEqual(MarkdownParser.parse("---\nTitle\n---").map(\.kind),
                       [.rule, .heading(level: 2)])
        XCTAssertEqual(MarkdownParser.parse("---\n\nSome paragraph.\n\n---").map(\.kind),
                       [.rule, .paragraph, .rule])
        XCTAssertEqual(MarkdownParser.parse("---\n---\n# Title").map(\.kind),
                       [.rule, .rule, .heading(level: 1)])
    }

    func testIndentedDashesInsideFrontMatterDoNotCloseIt() {
        let blocks = MarkdownParser.parse("---\ndescription: |\n  ---\n  more\nkey: v\n---\nbody")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: "yaml"), .paragraph])
        XCTAssertEqual(blocks[0].text, "description: |\n  ---\n  more\nkey: v")
    }

    func testFenceStopsTheSearchForAClose() {
        let blocks = MarkdownParser.parse("---\nkey: v\n```\n---\n```\n# Rest")
        XCTAssertEqual(blocks.last?.kind, .heading(level: 1))
        XCTAssertFalse(blocks.contains { $0.kind == .code(language: "yaml") })
    }

    func testCRLFAndBOMFilesParse() {
        let blocks = MarkdownParser.parse("\u{FEFF}---\r\nname: x\r\n---\r\n# Title\r\nbody")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: "yaml"), .heading(level: 1), .paragraph])
        XCTAssertEqual(blocks[0].text, "name: x")
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

    // MARK: - Images

    /// A screenshot on its own line is a picture, not a paragraph that happens
    /// to mention one. Everything the renderer needs to draw it — and to decide
    /// it *can't* — is in the block.
    func testImageOnItsOwnLineIsAnImageBlock() {
        let blocks = MarkdownParser.parse("![The window](web/public/screenshot.png)")
        XCTAssertEqual(blocks.map(\.kind),
                       [.images([MarkdownImage(source: "web/public/screenshot.png",
                                               alt: "The window", link: nil)])])
    }

    /// A badge is an image inside a link, and a row of them is one paragraph.
    func testBadgeRowIsOneImageBlock() {
        let blocks = MarkdownParser.parse(
            "[![CI](https://img.shields.io/ci.svg)](https://ci.example) ![v](v.png)")
        XCTAssertEqual(blocks.map(\.kind), [
            .images([
                MarkdownImage(source: "https://img.shields.io/ci.svg", alt: "CI",
                              link: "https://ci.example"),
                MarkdownImage(source: "v.png", alt: "v", link: nil),
            ]),
        ])
    }

    func testImageTitleIsNotPartOfTheSource() {
        let blocks = MarkdownParser.parse(#"![alt](shot.png "A title")"#)
        XCTAssertEqual(blocks.map(\.kind),
                       [.images([MarkdownImage(source: "shot.png", alt: "alt", link: nil)])])
    }

    /// A picture *inside* a sentence stays where it is: breaking a paragraph
    /// into three views to seat a 16px badge mid-line is worse than the alt
    /// text the author already wrote.
    func testImageInASentenceIsStillAParagraph() {
        let blocks = MarkdownParser.parse("Built with ![love](love.png) by hand.")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    func testLinkThatIsNotAnImageIsStillAParagraph() {
        XCTAssertEqual(MarkdownParser.parse("[download](https://wortel.sh)").map(\.kind),
                       [.paragraph])
    }

    // MARK: - Images written as HTML

    /// A README's screenshot is as often HTML as Markdown, and `<picture>` is
    /// the only way to give a light one and a dark one. To a parser that only
    /// reads Markdown it is a paragraph of angle brackets, which renders as
    /// nothing anybody wants to look at.
    func testPictureElementIsAnImageBlock() {
        let blocks = MarkdownParser.parse("""
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset=".github/assets/hero-dark.png">
          <img alt="The Wortel window" src=".github/assets/hero-light.png">
        </picture>
        """)
        XCTAssertEqual(blocks.map(\.kind), [
            .images([MarkdownImage(source: ".github/assets/hero-light.png",
                                   alt: "The Wortel window",
                                   link: nil,
                                   darkSource: ".github/assets/hero-dark.png")]),
        ])
    }

    /// The wrappers people put around a picture — centring, a link, a line break
    /// — are not text, so they don't stop the block being a picture.
    func testWrappedImageIsStillAnImageBlock() {
        let blocks = MarkdownParser.parse(
            #"<p align="center"><a href="https://wortel.sh"><img src="logo.png" width=64 /></a></p>"#)
        XCTAssertEqual(blocks.map(\.kind), [
            .images([MarkdownImage(source: "logo.png", alt: "", link: "https://wortel.sh")]),
        ])
    }

    /// But an `<img>` in a sentence is a sentence.
    func testHTMLImageWithProseIsStillAParagraph() {
        XCTAssertEqual(MarkdownParser.parse(#"<img src="a.png"> a caption"#).map(\.kind),
                       [.paragraph])
    }

    func testHTMLWithoutAnImageIsNotAnImageBlock() {
        XCTAssertEqual(MarkdownParser.parse(#"<div align="center"></div>"#).map(\.kind),
                       [.paragraph])
    }
}
