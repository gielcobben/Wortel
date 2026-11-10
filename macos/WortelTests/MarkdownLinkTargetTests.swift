import XCTest

/// Where a link in a rendered document goes.
///
/// The case that made this a type: a README's links are relative, a relative
/// link has no scheme, and a scheme-less URL handed to LaunchServices is not a
/// no-op but an error dialog (`-50`, "The application can't be opened"). So the
/// interesting assertions here are the ones about links that must *not* reach
/// the system at all.
final class MarkdownLinkTargetTests: XCTestCase {
    private var root: URL!
    /// The document being rendered: `<root>/README.md`.
    private var document: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("macos"),
                                                withIntermediateDirectories: true)
        document = root.appendingPathComponent("README.md")
        try "# Title".write(to: document, atomically: true, encoding: .utf8)
        try "app".write(to: root.appendingPathComponent("macos/CLAUDE.md"),
                        atomically: true, encoding: .utf8)
        try "png".write(to: root.appendingPathComponent("a shot.png"),
                        atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func target(_ link: String) -> MarkdownLinkTarget {
        MarkdownLinkTarget.resolve(URL(string: link)!, in: document)
    }

    // MARK: - What must never reach the system

    func testRelativeFileResolvesAgainstTheDocument() {
        XCTAssertEqual(target("macos/CLAUDE.md"),
                       .file(root.appendingPathComponent("macos/CLAUDE.md").standardizedFileURL))
    }

    /// The link that produced the dialog: a directory, which is a real target
    /// and not a file a preview window could ever show.
    func testDirectoryIsAFolder() {
        XCTAssertEqual(target("macos/"),
                       .folder(root.appendingPathComponent("macos").standardizedFileURL))
    }

    /// An app is a folder to the file system and a program to Finder: a link
    /// to one must never be something a click can run.
    func testAnApplicationBundleIsAPackageNotAFolder() throws {
        let app = root.appendingPathComponent("Tool.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(target("Tool.app"),
                       .package(root.appendingPathComponent("Tool.app").standardizedFileURL))
    }

    /// A symlink is judged by what it points at: one called `docs` that
    /// leads to an app must not be opened as if it were a folder.
    func testASymlinkToAnAppIsAPackage() throws {
        let app = root.appendingPathComponent("Tool.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("docs"),
                                                   withDestinationURL: root.appendingPathComponent("Tool.app"))
        XCTAssertEqual(target("docs"),
                       .package(root.appendingPathComponent("docs").standardizedFileURL))
    }

    /// And a symlink to an ordinary folder is still a folder.
    func testASymlinkToAFolderIsAFolder() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("elsewhere"),
                                                   withDestinationURL: root.appendingPathComponent("macos"))
        XCTAssertEqual(target("elsewhere"),
                       .folder(root.appendingPathComponent("elsewhere").standardizedFileURL))
    }

    func testOtherBundleKindsArePackagesToo() throws {
        for name in ["Pane.prefPane", "Flow.workflow", "Thing.bundle"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
            guard case .package = target(name) else { return XCTFail("\(name) should be a package") }
        }
    }

    /// A link to a file that isn't there is *nothing*, not an error to show the
    /// reader. This is the whole point of the type.
    func testMissingFileIsNothing() {
        XCTAssertEqual(target("docs/missing.md"), .none)
        XCTAssertEqual(target("/nowhere/at/all.md"), .none)
    }

    /// A relative link with no document to be relative to has no meaning.
    func testRelativeLinkNeedsADocument() {
        XCTAssertEqual(MarkdownLinkTarget.resolve(URL(string: "macos/CLAUDE.md")!, in: nil), .none)
    }

    // MARK: - The awkward spellings of a path

    func testFragmentAndQueryAreNotPartOfThePath() {
        XCTAssertEqual(target("macos/CLAUDE.md#build--run"),
                       .file(root.appendingPathComponent("macos/CLAUDE.md").standardizedFileURL))
        XCTAssertEqual(target("macos/CLAUDE.md?plain=1"),
                       .file(root.appendingPathComponent("macos/CLAUDE.md").standardizedFileURL))
    }

    func testPercentEncodingIsDecoded() {
        XCTAssertEqual(target("a%20shot.png"),
                       .file(root.appendingPathComponent("a shot.png").standardizedFileURL))
    }

    func testDotSegmentsAreResolved() {
        XCTAssertEqual(target("./macos/../macos/CLAUDE.md"),
                       .file(root.appendingPathComponent("macos/CLAUDE.md").standardizedFileURL))
    }

    func testFileURLIsCheckedLikeAnyOtherPath() {
        let existing = root.appendingPathComponent("macos/CLAUDE.md")
        XCTAssertEqual(target(existing.absoluteString), .file(existing.standardizedFileURL))
        XCTAssertEqual(target("file:///nowhere/at/all.md"), .none)
    }

    // MARK: - Schemes

    func testWebSchemesAreOpenedAndOthersAreNot() {
        XCTAssertEqual(target("https://ghostty.org"), .web(URL(string: "https://ghostty.org")!))
        XCTAssertEqual(target("mailto:hi@wortel.sh"), .web(URL(string: "mailto:hi@wortel.sh")!))
        // A markdown file is often something an agent just wrote; a click on it
        // is not a way to launch whatever registered a scheme.
        XCTAssertEqual(target("x-custom-app://run"), .none)
        XCTAssertEqual(target("javascript:alert(1)"), .none)
    }

    // MARK: - Anchors

    func testFragmentOnlyLinkIsAHeading() {
        XCTAssertEqual(target("#third-party-code"), .heading("third-party-code"))
        // Slugified on the way in, so a hand-written capitalised anchor still
        // finds its section.
        XCTAssertEqual(target("#Third-Party-Code"), .heading("third-party-code"))
    }

    func testAnchorFindsItsHeading() {
        let blocks = MarkdownParser.parse("""
        # Wortel

        Text.

        ## Third-party code

        More.

        ### The `wortel` command

        Even more.
        """)
        XCTAssertEqual(MarkdownAnchor.blockID(for: "third-party-code", in: blocks), 2)
        // Inline markdown is not part of the anchor: the heading reads "The
        // wortel command", and that is what GitHub slugified.
        XCTAssertEqual(MarkdownAnchor.blockID(for: "the-wortel-command", in: blocks), 4)
        XCTAssertNil(MarkdownAnchor.blockID(for: "nothing-like-this", in: blocks))
    }

    /// Repeated headings are numbered in document order, as GitHub numbers them
    /// — without it every `#options` link in a document of subcommands lands on
    /// the first one.
    func testRepeatedHeadingsAreNumbered() {
        let blocks = MarkdownParser.parse("""
        ## Options

        a

        ## Options

        b
        """)
        XCTAssertEqual(MarkdownAnchor.blockID(for: "options", in: blocks), 0)
        XCTAssertEqual(MarkdownAnchor.blockID(for: "options-1", in: blocks), 2)
    }

    func testSlugDropsPunctuationAndHyphenatesSpaces() {
        XCTAssertEqual(MarkdownAnchor.slug("Build & run"), "build--run")
        XCTAssertEqual(MarkdownAnchor.slug("Status and licence!"), "status-and-licence")
        XCTAssertEqual(MarkdownAnchor.slug("`wortel.conf`"), "wortelconf")
    }

    // MARK: - Images

    func testImageFileIsLocalOnly() {
        XCTAssertEqual(MarkdownLinkTarget.imageFile("a shot.png", in: document),
                       root.appendingPathComponent("a shot.png").standardizedFileURL)
        // Not fetched, so not a file: a remote image is a chip, not a request.
        XCTAssertNil(MarkdownLinkTarget.imageFile("https://img.shields.io/x.svg", in: document))
        XCTAssertNil(MarkdownLinkTarget.imageFile("docs/missing.png", in: document))
    }
}
