import XCTest

/// What a preview window is allowed to do to a file it did not write.
///
/// `PreviewDocument.read` runs against files an agent is actively rewriting, on
/// whatever volume the session happens to be in, and every one of its rules
/// fails *quietly* when it's wrong: a cap applied a line too late still pulls
/// the file into memory, a phantom last line shifts every line number under it,
/// a missed NUL renders a binary as mojibake. None of that needs a window, so
/// all of it is pinned here.
final class PreviewDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private func write(_ contents: String, to name: String = "file.swift") -> URL {
        let url = directory.appendingPathComponent(name)
        try! contents.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func write(_ data: Data, to name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    /// Unwrap the text case, failing the test rather than crashing it.
    private func text(
        _ result: PreviewDocument.LoadResult, file: StaticString = #filePath, line: UInt = #line
    ) -> (lines: [DiffLine], blocks: [MarkdownBlock], truncated: Bool)? {
        guard case .text(let lines, let blocks, _, let truncated) = result else {
            XCTFail("expected text, got \(result)", file: file, line: line)
            return nil
        }
        return (lines, blocks, truncated)
    }

    // MARK: - Lines

    /// A trailing newline *ends* the last line; it does not begin an empty one.
    /// Get this wrong and every file gains a blank row, which also makes the
    /// line count — and so the gutter width — disagree with every other tool.
    func testTrailingNewlineIsNotAnExtraLine() async {
        let withNewline = await PreviewDocument.read(
            write("one\ntwo\n"), ifNewerThan: nil, parseMarkdown: false)
        XCTAssertEqual(text(withNewline)?.lines.map(\.text), ["one", "two"])

        let without = await PreviewDocument.read(
            write("one\ntwo", to: "b.swift"), ifNewerThan: nil, parseMarkdown: false)
        XCTAssertEqual(text(without)?.lines.map(\.text), ["one", "two"])
    }

    func testBlankLinesInsideAFileSurvive() async {
        let result = await PreviewDocument.read(
            write("one\n\nthree\n"), ifNewerThan: nil, parseMarkdown: false)
        XCTAssertEqual(text(result)?.lines.map(\.text), ["one", "", "three"])
    }

    func testEmptyFileHasNoLines() async {
        let result = await PreviewDocument.read(write(""), ifNewerThan: nil, parseMarkdown: false)
        XCTAssertEqual(text(result)?.lines.count, 0)
    }

    /// Source is rendered as an all-context diff, so these three fields are what
    /// the view actually draws from. `path` in particular is load-bearing and
    /// invisible: it is the *only* thing that tells the highlighter which
    /// grammar to use, and a whole file has no hunk header to carry it. When it
    /// was missing, every preview rendered in plain grey and nothing failed.
    func testEveryLineIsContextNumberedFromOneAndCarriesItsPath() async {
        let url = write("let a = 1\nlet b = 2\n")
        let result = await PreviewDocument.read(url, ifNewerThan: nil, parseMarkdown: false)
        guard let lines = text(result)?.lines else { return }
        XCTAssertEqual(lines.map(\.kind), [.context, .context])
        XCTAssertEqual(lines.map(\.oldLine), [1, 2])
        XCTAssertEqual(lines.map(\.newLine), [1, 2])
        XCTAssertEqual(lines.map(\.path), [url.path, url.path])
    }

    // MARK: - Caps

    func testLineCountIsCappedAndSaysSo() async {
        let long = (1...(PreviewDocument.maxLines + 500)).map(String.init).joined(separator: "\n")
        let result = await PreviewDocument.read(
            write(long, to: "long.txt"), ifNewerThan: nil, parseMarkdown: false)
        guard let value = text(result) else { return }
        XCTAssertEqual(value.lines.count, PreviewDocument.maxLines)
        XCTAssertTrue(value.truncated, "a truncated view that doesn't say so reads as the whole file")
    }

    func testFileAtTheLineCapIsNotMarkedTruncated() async {
        let exact = (1...PreviewDocument.maxLines).map(String.init).joined(separator: "\n")
        let result = await PreviewDocument.read(
            write(exact, to: "exact.txt"), ifNewerThan: nil, parseMarkdown: false)
        guard let value = text(result) else { return }
        XCTAssertEqual(value.lines.count, PreviewDocument.maxLines)
        XCTAssertFalse(value.truncated)
    }

    /// The byte cap has to be applied *before* the read, not after: checking it
    /// afterwards still allocates the whole file first, so a stray 2GB log costs
    /// 2GB on its way to being rejected. The content here is all printable, so
    /// only the size can be what rejects it.
    func testOversizeFileIsRejectedWithoutBeingText() async {
        let big = Data(repeating: UInt8(ascii: "a"), count: PreviewDocument.maxBytes + 1)
        let result = await PreviewDocument.read(
            write(big, to: "huge.log"), ifNewerThan: nil, parseMarkdown: false)
        guard case .binary = result else {
            return XCTFail("a file over the byte cap must not be read as text, got \(result)")
        }
    }

    // MARK: - Not text

    /// The same test git uses: a NUL early in the file. It answers the only
    /// question the window has — can this be shown as lines?
    func testNulByteMakesItBinary() async {
        var data = Data("PNG".utf8)
        data.append(0)
        data.append(Data("more".utf8))
        let result = await PreviewDocument.read(
            write(data, to: "image.png"), ifNewerThan: nil, parseMarkdown: false)
        guard case .binary = result else { return XCTFail("expected binary, got \(result)") }
    }

    func testInvalidUTF8IsBinaryRatherThanMojibake() async {
        // Lone continuation bytes: no NUL, so only the decode can reject them.
        let result = await PreviewDocument.read(
            write(Data([0x41, 0xC3, 0x28, 0xA9, 0xFF]), to: "weird.bin"),
            ifNewerThan: nil, parseMarkdown: false)
        guard case .binary = result else { return XCTFail("expected binary, got \(result)") }
    }

    func testMissingFile() async {
        let result = await PreviewDocument.read(
            directory.appendingPathComponent("nope.swift"), ifNewerThan: nil, parseMarkdown: false)
        guard case .missing = result else { return XCTFail("expected missing, got \(result)") }
    }

    // MARK: - Doing no work

    /// The directory this file sits in fires constantly while an agent works in
    /// it. An unmoved modification date has to cost a stat, not a read, a decode
    /// and a markdown parse.
    func testUnchangedModificationDateSkipsTheRead() async {
        let url = write("one\n")
        let first = await PreviewDocument.read(url, ifNewerThan: nil, parseMarkdown: false)
        guard case .text(_, _, let modified, _) = first else { return XCTFail("expected text") }
        let again = await PreviewDocument.read(url, ifNewerThan: modified, parseMarkdown: false)
        guard case .unchanged = again else { return XCTFail("expected unchanged, got \(again)") }
    }

    func testMarkdownIsOnlyParsedWhenAsked() async {
        let source = "# Title\n\nbody\n"
        let plain = await PreviewDocument.read(
            write(source, to: "README.md"), ifNewerThan: nil, parseMarkdown: false)
        XCTAssertEqual(text(plain)?.blocks.count, 0)

        let parsed = await PreviewDocument.read(
            write(source, to: "OTHER.md"), ifNewerThan: nil, parseMarkdown: true)
        XCTAssertEqual(text(parsed)?.blocks.map(\.kind), [.heading(level: 1), .paragraph])
    }
}
