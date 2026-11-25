import XCTest

/// A ⌘-clicked path in a terminal. The case that made `TerminalLink` a type:
/// `docs/decisions.md.`, written by an agent relative to the repository and
/// matched with the sentence's full stop, opened nothing.
final class TerminalLinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-terminal-links-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("macos/docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tool.app/Contents/MacOS"),
                               withIntermediateDirectories: true)
        for file in ["docs/decisions.md", "macos/docs/agent-signals.md", "macos/App.swift", "a b.md"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ relative: String) -> URL {
        root.appendingPathComponent(relative).standardizedFileURL
    }

    private func resolve(_ link: String, from folder: String = "") -> TerminalLink.Target? {
        let base = folder.isEmpty ? root.path : root.appendingPathComponent(folder).path
        return TerminalLink.resolve(link, bases: TerminalLink.bases([base]))
    }

    // MARK: - Path or web link

    // MARK: - Other links

    /// 2026.47.4: no web link opened, in Pi first (its links are OSC 8),
    /// because libghostty stopped opening them itself.
    func testWebAndMailLinksOpen() {
        for link in ["https://wortel.sh", "http://example.com/a?b=c#d", "HTTPS://Example.com",
                     "mailto:a@b.c"] {
            XCTAssertEqual(TerminalLink.external(link), .open(URL(string: link)!), link)
        }
    }

    func testOtherSchemesAsk() {
        for link in ["vscode://file/a", "tel:0612345678", "ssh://host", "x-man-page://ls"] {
            XCTAssertEqual(TerminalLink.external(link), .ask(URL(string: link)!), link)
        }
    }

    func testMalformedOrHiddenLinksAreRefused() {
        for link in ["https:relative", "http://", "mailto:", "file:///tmp/nothing-here",
                     "https://wortel.sh/\u{202E}gpj.exe", "https://a.com\u{200B}.b.com",
                     "https://wortel.sh/\na", "no scheme", ""] {
            XCTAssertEqual(TerminalLink.external(link), .refuse, link)
        }
    }

    func testWebLinksAndOtherSchemesAreNotPaths() {
        for link in ["https://wortel.sh", "http://localhost:3000", "mailto:a@b.c", "tel:0612345678",
                     "ssh://host", "vscode://file/a", "x-man-page://ls"] {
            XCTAssertFalse(TerminalLink.isPath(link), link)
        }
    }

    func testPathsAreOurs() {
        for link in ["docs/decisions.md", "/etc/hosts", "~/x", "./a", "README.md:12",
                     "macos/App.swift:42:7", "file:///tmp/a.md", "FILE:///tmp/a.md"] {
            XCTAssertTrue(TerminalLink.isPath(link), link)
        }
    }

    // MARK: - Resolving

    func testTheScreenshotsTwoLinks() {
        XCTAssertEqual(resolve("macos/docs/agent-signals.md")?.url, path("macos/docs/agent-signals.md"))
        XCTAssertEqual(resolve("docs/decisions.md.")?.url, path("docs/decisions.md"))
        XCTAssertEqual(resolve("docs/decisions.md.")?.kind, .markdown)
    }

    /// The shell is in `macos/`, the agent named the file from the repo root.
    func testFallsBackToTheRepositoryRoot() {
        XCTAssertEqual(resolve("docs/decisions.md", from: "macos")?.url, path("docs/decisions.md"))
    }

    /// The nearer folder wins when both have the file.
    func testTheTerminalsOwnFolderComesFirst() {
        XCTAssertEqual(resolve("docs/agent-signals.md", from: "macos")?.url,
                       path("macos/docs/agent-signals.md"))
    }

    func testLocationSuffixesBecomeALine() {
        XCTAssertEqual(resolve("macos/App.swift:42"), .init(url: path("macos/App.swift"), kind: .file, line: 42))
        XCTAssertEqual(resolve("macos/App.swift:42:7")?.line, 42)
        XCTAssertEqual(resolve("macos/App.swift:42:7.")?.line, 42)
        XCTAssertEqual(resolve("docs/decisions.md#L12")?.line, 12)
        XCTAssertEqual(resolve("docs/decisions.md#L12-L20")?.line, 12)
    }

    func testSentencePunctuationIsTakenOff() {
        for link in ["docs/decisions.md,", "docs/decisions.md;", "docs/decisions.md!",
                     "docs/decisions.md**", "docs/decisions.md)."] {
            XCTAssertEqual(resolve(link)?.url, path("docs/decisions.md"), link)
        }
    }

    func testDiffPrefixes() {
        XCTAssertEqual(resolve("b/macos/App.swift")?.url, path("macos/App.swift"))
        XCTAssertEqual(resolve("a/docs/decisions.md")?.url, path("docs/decisions.md"))
    }

    func testAbsoluteAndFileURLs() {
        XCTAssertEqual(resolve(path("docs/decisions.md").path)?.url, path("docs/decisions.md"))
        XCTAssertEqual(resolve(path("a b.md").absoluteString)?.url, path("a b.md"))
        XCTAssertEqual(resolve(path("docs/decisions.md").absoluteString + "#L3")?.line, 3)
    }

    func testFoldersAndPackages() {
        XCTAssertEqual(resolve("macos/docs")?.kind, .folder)
        XCTAssertEqual(resolve("Tool.app")?.kind, .package)
    }

    /// The agent was in `macos/`, the shell in the repo root.
    func testOneFolderDownWhenOnlyOneHasIt() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("macos/scripts"),
                                                withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("macos/scripts/try.sh"), atomically: true, encoding: .utf8)
        XCTAssertEqual(resolve("scripts/try.sh")?.url, path("macos/scripts/try.sh"))

        try FileManager.default.createDirectory(at: root.appendingPathComponent("web/scripts"),
                                                withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("web/scripts/try.sh"), atomically: true, encoding: .utf8)
        XCTAssertNil(resolve("scripts/try.sh"), "two folders have it: no guess")
    }

    func testNothingThereIsNil() {
        XCTAssertNil(resolve("docs/missing.md"))
        XCTAssertNil(resolve("/no/such/file.md"))
    }

    /// 2026.47.4 on macOS 15.5: a ⌘-click in a terminal outside any
    /// repository climbed past `/` for ever. The walk ends at the disk.
    func testOutsideARepositoryTheWalkEndsAtTheDisk() throws {
        let loose = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-no-repo-" + UUID().uuidString + "/.scratch/game-v1")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: loose.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(TerminalLink.repositoryRoot(of: loose.path))
        XCTAssertNil(TerminalLink.repositoryRoot(of: "/"))
        let folder = loose.deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertEqual(TerminalLink.resolve(".scratch/game-v1/,", bases: TerminalLink.bases([folder]))?.kind, .folder)
    }

    func testBasesAddTheRepositoryWithoutRepeats() {
        let macos = root.appendingPathComponent("macos").path
        XCTAssertEqual(TerminalLink.bases([macos, nil, macos]), [macos, root.path])
    }

    // MARK: - Servers on this Mac

    func testLocalServers() {
        for link in ["http://localhost:3000", "https://localhost:5173/a", "http://127.0.0.1:8080",
                     "http://[::1]:4000", "http://0.0.0.0:3000", "http://app.localhost:1355"] {
            XCTAssertNotNil(TerminalLink.localServer(link), link)
        }
        for link in ["https://wortel.sh", "http://localhost.example.com", "ftp://localhost",
                     "http://127.example.com", "http://127.0.0.1.example.com",
                     "docs/decisions.md"] {
            XCTAssertNil(TerminalLink.localServer(link), link)
        }
    }
}
