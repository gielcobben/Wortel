import XCTest

/// When a page shown from a file is loaded again. The failures here are
/// silent ones: a watch that went deaf after the first save looks exactly
/// like a file nobody is touching.
@MainActor
final class BrowserPageWatchTests: XCTestCase {
    private var folder: URL!
    private var watch: BrowserPageWatch!
    private var changes = 0

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-pagewatch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watch = BrowserPageWatch()
        changes = 0
        watch.onChange = { [unowned self] in self.changes += 1 }
    }

    override func tearDown() async throws {
        watch.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func path(_ name: String) -> String { folder.appendingPathComponent(name).path }

    private func write(_ text: String, to name: String, atomically: Bool = false) throws {
        try text.write(toFile: path(name), atomically: atomically, encoding: .utf8)
    }

    /// Long enough for the settle delay and the hop from the watch's queue.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(700))
    }

    func testAWriteInPlaceReloads() async throws {
        try write("<p>one</p>", to: "index.html")
        watch.watch(page: path("index.html"), resources: [])
        try await settle()
        XCTAssertEqual(changes, 0, "nothing changed yet")
        try write("<p>one, and more</p>", to: "index.html")
        try await settle()
        XCTAssertEqual(changes, 1)
    }

    /// An agent's save: a temporary file renamed over the page. The old
    /// inode's watch goes deaf, so the second save is the one that proves
    /// the watch was made again.
    func testASaveByRenameReloadsEveryTime() async throws {
        try write("<p>one</p>", to: "index.html")
        watch.watch(page: path("index.html"), resources: [])
        try write("<p>two, renamed over</p>", to: "index.html", atomically: true)
        try await settle()
        XCTAssertEqual(changes, 1)
        try write("<p>three, renamed over again</p>", to: "index.html", atomically: true)
        try await settle()
        XCTAssertEqual(changes, 2)
        try write("<p>four, in place this time</p>", to: "index.html")
        try await settle()
        XCTAssertEqual(changes, 3)
    }

    /// A burst of writes is one reload.
    func testABurstIsOneReload() async throws {
        try write("0", to: "index.html")
        watch.watch(page: path("index.html"), resources: [])
        for round in 1...5 {
            try write(String(repeating: "x", count: round), to: "index.html")
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
        XCTAssertEqual(changes, 1)
    }

    func testAFileThePageLoadedReloadsIt() async throws {
        try write("<link rel=stylesheet href=style.css>", to: "index.html")
        try write("body{}", to: "style.css")
        watch.watch(page: path("index.html"), resources: [path("style.css")])
        try write("body{color:red}", to: "style.css", atomically: true)
        try await settle()
        XCTAssertEqual(changes, 1)
    }

    /// The folder's watch fires for every file in it. Only the page's count.
    func testAnotherFileInTheFolderDoesNot() async throws {
        try write("<p>one</p>", to: "index.html")
        watch.watch(page: path("index.html"), resources: [])
        try write("notes", to: "unrelated.txt", atomically: true)
        try write("more", to: "also-unrelated.txt")
        try await settle()
        XCTAssertEqual(changes, 0)
    }

    /// Deleted: the page stays as it was. Back: it loads again.
    func testAFileThatGoesAndComesBack() async throws {
        try write("<p>one</p>", to: "index.html")
        watch.watch(page: path("index.html"), resources: [])
        try FileManager.default.removeItem(atPath: path("index.html"))
        try await settle()
        XCTAssertEqual(changes, 0, "gone is not a change to show")
        try write("<p>back</p>", to: "index.html")
        try await settle()
        XCTAssertEqual(changes, 1)
    }

    /// A page that wasn't there when its tab was restored loads when it is.
    func testAFileThatWasNeverThereAppears() async throws {
        watch.watch(page: path("later.html"), resources: [])
        try await settle()
        try write("<p>here now</p>", to: "later.html")
        try await settle()
        XCTAssertEqual(changes, 1)
    }

    func testOnlySoManyLoadedFilesAreWatched() async throws {
        let many = (0..<100).map { path("asset-\($0).js") }
        watch.watch(page: path("index.html"), resources: many)
        XCTAssertEqual(watch.watchedFiles.count, BrowserPageWatch.maxResources + 1)
        XCTAssertTrue(watch.watchedFiles.contains(path("index.html")))
        // The next page: what the last one loaded is let go.
        watch.watch(page: path("other.html"), resources: [])
        XCTAssertEqual(watch.watchedFiles, [path("other.html")])
    }
}
