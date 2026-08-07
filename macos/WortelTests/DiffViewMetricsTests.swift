import AppKit
import XCTest

/// The diff table's geometry. The rows themselves need a window; the numbers
/// they're laid out from do not, and those numbers are where this view goes
/// wrong silently — a row height that disagrees with the font clips text, a
/// gutter measured for two columns leaves a blank stripe when only one is drawn.
final class DiffViewMetricsTests: XCTestCase {
    private func lines(_ texts: [String]) -> [DiffLine] {
        texts.enumerated().map {
            DiffLine(id: $0.offset, kind: .context, text: $0.element,
                     oldLine: $0.offset + 1, newLine: $0.offset + 1, path: "a.swift")
        }
    }

    /// The invariant that broke: `DiffView.rowHeight(forFontSize:)` sizes the
    /// History accordion's inline diffs, and the coordinator sizes the table's
    /// actual rows. Two formulas, one answer required.
    func testCoordinatorRowHeightMatchesTheStaticFormula() {
        for size in [9, 12, 13, 16, 24] as [CGFloat] {
            let coordinator = DiffView.Coordinator()
            coordinator.applyStyle(fontSize: size, gutter: .patch)
            XCTAssertEqual(coordinator.rowHeight, DiffView.rowHeight(forFontSize: size),
                           "row height disagrees at \(size)pt")
        }
    }

    /// Why `makeNSView` applies the style unconditionally rather than through
    /// `setStyle`: a coordinator that has never measured anything is carrying
    /// placeholders, and they are not the right answer for its own default size.
    func testUnmeasuredCoordinatorIsNotAlreadyCorrect() {
        XCTAssertNotEqual(DiffView.Coordinator().rowHeight, DiffView.rowHeight(forFontSize: 12),
                          "if these ever match, this test is the only thing that would notice")
    }

    /// `setStyle` is the reload trigger: it must report a change exactly when
    /// there is one, or ⌘+ moves a number and nothing on screen follows.
    func testSetStyleReportsRealChangesOnly() {
        let coordinator = DiffView.Coordinator()
        coordinator.applyStyle(fontSize: 13, gutter: .patch)
        XCTAssertFalse(coordinator.setStyle(fontSize: 13, gutter: .patch))
        XCTAssertTrue(coordinator.setStyle(fontSize: 14, gutter: .patch), "a size change")
        XCTAssertTrue(coordinator.setStyle(fontSize: 14, gutter: .file), "a gutter change")
        XCTAssertFalse(coordinator.setStyle(fontSize: 14, gutter: .file))
    }

    /// A file is one revision: one column of numbers and no sign column. The
    /// saving is real width, not decoration — it's what stops a preview's source
    /// view starting two columns in from its own margin.
    func testFileGutterIsNarrowerThanAPatchGutter() {
        let content = lines(["let a = 1", "let b = 2"])

        let patch = DiffView.Coordinator()
        patch.applyStyle(fontSize: 13, gutter: .patch)
        _ = patch.update(lines: content, highlights: [:])

        let file = DiffView.Coordinator()
        file.applyStyle(fontSize: 13, gutter: .file)
        _ = file.update(lines: content, highlights: [:])

        XCTAssertLessThan(file.columnWidth, patch.columnWidth)
    }

    /// Column width has to follow the widest line, or long lines are clipped
    /// instead of scrolled to.
    func testColumnWidthGrowsWithTheLongestLine() {
        let short = DiffView.Coordinator()
        short.applyStyle(fontSize: 13, gutter: .file)
        _ = short.update(lines: lines(["ab"]), highlights: [:])

        let long = DiffView.Coordinator()
        long.applyStyle(fontSize: 13, gutter: .file)
        _ = long.update(lines: lines([String(repeating: "x", count: 200)]), highlights: [:])

        XCTAssertGreaterThan(long.columnWidth, short.columnWidth)
    }

    /// A tab is drawn as `tabWidth` spaces, so it has to be *measured* as that
    /// many too — otherwise a tab-indented file reports a column narrower than
    /// what it draws and the last characters fall off the end.
    func testTabsAreMeasuredAsTheyAreDrawn() {
        let tabbed = DiffView.Coordinator()
        tabbed.applyStyle(fontSize: 13, gutter: .file)
        _ = tabbed.update(lines: lines(["\tx"]), highlights: [:])

        let spaced = DiffView.Coordinator()
        spaced.applyStyle(fontSize: 13, gutter: .file)
        _ = spaced.update(
            lines: lines([String(repeating: " ", count: DiffLineCellView.tabWidth) + "x"]),
            highlights: [:])

        XCTAssertEqual(tabbed.columnWidth, spaced.columnWidth)
    }

    /// Reload semantics: new content reloads and returns to the top; the same
    /// content arriving again (a sibling diff loading, a re-render) must not,
    /// or the History accordion reloads every mounted table on every load.
    func testUpdateOnlyReloadsWhenSomethingChanged() {
        let coordinator = DiffView.Coordinator()
        coordinator.applyStyle(fontSize: 13, gutter: .patch)
        let content = lines(["a", "b"])

        var result = coordinator.update(lines: content, highlights: [:])
        XCTAssertTrue(result.reload)
        XCTAssertTrue(result.scrollToTop, "a new file starts at the top")

        result = coordinator.update(lines: content, highlights: [:])
        XCTAssertFalse(result.reload, "the same lines are not a reason to reload")

        result = coordinator.update(lines: content, highlights: [0: [
            HighlightSpan(range: NSRange(location: 0, length: 1), token: .keyword),
        ]])
        XCTAssertTrue(result.reload, "colour arriving late recolours in place")
        XCTAssertFalse(result.scrollToTop, "…without yanking the reader back to the top")
    }
}
