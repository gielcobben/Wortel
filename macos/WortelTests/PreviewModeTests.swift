import XCTest

/// Which mode a preview window opens on is decided once and then left alone, so
/// getting it wrong is not a glitch you can click past — it's the wrong view of
/// the file every time you open that kind of file. It's also the only part of
/// the preview that can be checked without a window around it.
final class PreviewModeTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/repo/\(name)")
    }

    // MARK: What a file can be shown as

    func testMarkdownCanBeRendered() {
        for name in ["README.md", "notes.markdown", "a.MD"] {
            XCTAssertTrue(
                PreviewMode.available(for: url(name), hasDiffSource: false).contains(.rendered),
                "\(name) should offer Rendered")
        }
    }

    func testOnlyMarkdownCanBeRendered() {
        for name in ["main.swift", "app.ts", "Makefile", "notes.md.bak"] {
            XCTAssertFalse(
                PreviewMode.available(for: url(name), hasDiffSource: false).contains(.rendered),
                "\(name) should not offer Rendered")
        }
    }

    /// Outside a repo there is no diff to ask for, so the mode isn't offered —
    /// a segment that can only ever say "nothing here" is worse than no segment.
    func testDiffIsOfferedOnlyWhereThereIsOne() {
        XCTAssertFalse(PreviewMode.available(for: url("a.swift"), hasDiffSource: false).contains(.diff))
        XCTAssertTrue(PreviewMode.available(for: url("a.swift"), hasDiffSource: true).contains(.diff))
    }

    func testSourceIsAlwaysAvailable() {
        XCTAssertTrue(PreviewMode.available(for: url("a.swift"), hasDiffSource: false).contains(.source))
        XCTAssertTrue(PreviewMode.available(for: url("README.md"), hasDiffSource: true).contains(.source))
    }

    /// One mode is not a choice, and the window hides the control entirely in
    /// that case — so "how many modes" is load-bearing, not cosmetic.
    func testAPlainFileOutsideARepoHasNothingToChoose() {
        XCTAssertEqual(PreviewMode.available(for: url("a.swift"), hasDiffSource: false), [.source])
    }

    // MARK: What it opens on

    func testMarkdownOpensRendered() {
        XCTAssertEqual(
            PreviewMode.inferred(for: url("README.md"), hasChanges: false, hasDiffSource: false),
            .rendered)
    }

    /// Even when it's changed: you opened a document, and the rendered view is
    /// what you meant by that. The diff is one segment away.
    func testMarkdownOpensRenderedEvenWhenChanged() {
        XCTAssertEqual(
            PreviewMode.inferred(for: url("README.md"), hasChanges: true, hasDiffSource: true),
            .rendered)
    }

    /// The reason you reach for a file an agent just touched is almost always
    /// what it did to it.
    func testAChangedFileOpensOnItsDiff() {
        XCTAssertEqual(
            PreviewMode.inferred(for: url("main.swift"), hasChanges: true, hasDiffSource: true),
            .diff)
    }

    func testAnUnchangedFileOpensOnSource() {
        XCTAssertEqual(
            PreviewMode.inferred(for: url("main.swift"), hasChanges: false, hasDiffSource: true),
            .source)
    }

    /// "Has changes" is not enough on its own — without a diff source there is
    /// nothing to show, and opening on an empty Diff would be the worst of both.
    func testChangedButWithNoDiffSourceOpensOnSource() {
        XCTAssertEqual(
            PreviewMode.inferred(for: url("main.swift"), hasChanges: true, hasDiffSource: false),
            .source)
    }

    /// Whatever it opens on has to be a mode it actually offers.
    func testInferredModeIsAlwaysAvailable() {
        for name in ["README.md", "main.swift", "data.json"] {
            for hasChanges in [true, false] {
                for hasDiff in [true, false] {
                    let inferred = PreviewMode.inferred(
                        for: url(name), hasChanges: hasChanges, hasDiffSource: hasDiff)
                    XCTAssertTrue(
                        PreviewMode.available(for: url(name), hasDiffSource: hasDiff).contains(inferred),
                        "\(name) changes=\(hasChanges) diff=\(hasDiff) opened on an unavailable mode")
                }
            }
        }
    }
}
