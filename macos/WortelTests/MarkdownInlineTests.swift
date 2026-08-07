import XCTest

/// Inline markdown: the intents the renderer styles from.
///
/// Everything here fails by looking like ordinary prose rather than by throwing
/// — a code span that loses its intent is text in a slightly different font, a
/// bare URL that isn't linkified is blue-looking text that does nothing — which
/// is exactly why it's pinned away from the view that draws it.
final class MarkdownInlineTests: XCTestCase {
    private func intents(_ markdown: String, for text: String) -> InlinePresentationIntent? {
        let parsed = MarkdownInline.parse(markdown)
        for run in parsed.runs where String(parsed[run.range].characters) == text {
            return run.inlinePresentationIntent
        }
        return nil
    }

    func testCodeSpanKeepsItsIntent() {
        XCTAssertEqual(intents("Run `git status` now.", for: "git status"), .code)
    }

    func testEmphasisAndStrong() {
        XCTAssertEqual(intents("A **bold** word.", for: "bold"), .stronglyEmphasized)
        XCTAssertEqual(intents("An *italic* word.", for: "italic"), .emphasized)
    }

    /// The syntax itself is consumed — a renderer that shows `**` is showing the
    /// source, not the document.
    func testMarkersAreNotInTheText() {
        let parsed = MarkdownInline.parse("A **bold** word and `code`.")
        let plain = String(parsed.characters)
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertEqual(plain, "A bold word and code.")
    }

    func testExplicitLinks() {
        let parsed = MarkdownInline.parse("See [the docs](https://wortel.sh/docs).")
        let range = parsed.range(of: "the docs")!
        XCTAssertEqual(parsed[range].link, URL(string: "https://wortel.sh/docs"))
    }

    /// Foundation's inline parser doesn't linkify bare URLs; agents write them
    /// constantly, and an unclickable URL in a rendered document reads as a bug.
    func testBareURLsAreLinkified() {
        let parsed = MarkdownInline.parse("Docs live at https://wortel.sh today.")
        let range = parsed.range(of: "https://wortel.sh")!
        XCTAssertEqual(parsed[range].link, URL(string: "https://wortel.sh"))
    }

    /// An explicit link's own URL wins — linkification must not overwrite it
    /// when the visible text happens to be a URL too.
    func testExplicitLinkSurvivesLinkification() {
        let parsed = MarkdownInline.parse("[https://wortel.sh](https://wortel.sh/docs)")
        let range = parsed.range(of: "https://wortel.sh")!
        XCTAssertEqual(parsed[range].link, URL(string: "https://wortel.sh/docs"))
    }

    /// Whitespace is preserved on purpose: the block parser has already decided
    /// where the breaks are (see `joinSoftWrapped`), and re-flowing here would
    /// undo that.
    func testWhitespaceIsPreserved() {
        XCTAssertEqual(String(MarkdownInline.parse("two  spaces").characters), "two  spaces")
    }

    /// Half-written markdown is normal — a file is being typed, or an agent is
    /// mid-write. It must render as text rather than throwing away the line.
    func testUnterminatedSyntaxStillRenders() {
        XCTAssertTrue(String(MarkdownInline.parse("an **unfinished bold").characters)
            .contains("unfinished bold"))
    }
}
