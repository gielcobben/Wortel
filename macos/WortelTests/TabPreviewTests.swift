import XCTest

/// What a tab's hover card previews: a terminal's screen is mostly blank
/// rows under the prompt, and a file can be anything.
final class TabPreviewTests: XCTestCase {
    private func text(_ preview: TabPreview?) -> String? {
        guard case .text(let text)? = preview else { return nil }
        return text
    }

    /// The prompt sits at the top of a mostly empty screen: the blank rows
    /// under it aren't the preview.
    func testATerminalPreviewDropsTheBlankRowsUnderThePrompt() {
        let screen = "$ ls\nREADME.md  macos   \n$ \n\n\n\n"
        XCTAssertEqual(text(.terminal(screen)), "$ ls\nREADME.md  macos\n$")
    }

    func testATerminalPreviewIsItsLastLines() {
        let screen = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let lines = text(.terminal(screen, lines: 3))?.split(separator: "\n")
        XCTAssertEqual(lines, ["line 38", "line 39", "line 40"])
    }

    func testABlankTerminalHasNoPreview() {
        XCTAssertNil(TabPreview.terminal("\n\n   \n"))
        XCTAssertNil(TabPreview.terminal(nil))
    }

    func testAFilePreviewIsItsTop() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).md")
        try "# Title\n\tindented\nthird\nfourth\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(text(.file(at: url.path, lines: 2)), "# Title\n  indented")
    }

    func testABinaryFileHasNoPreview() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(TabPreview.file(at: url.path))
        XCTAssertNil(TabPreview.file(at: "/nonexistent/\(UUID())"))
    }
}
