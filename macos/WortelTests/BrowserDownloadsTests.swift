import XCTest

/// Where a download's bytes go, and what is ever removed. The failures here
/// lose files quietly: a row says Done over a file that is gone, or a
/// truncated file sits in Downloads under its real name.
final class BrowserDownloadsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-downloads-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: file(name), atomically: false, encoding: .utf8)
    }

    private func read(_ name: String) -> String? { try? String(contentsOf: file(name), encoding: .utf8) }

    /// Two downloads of one name, the first's file not made yet by WebKit.
    /// Both were given `report.zip`; WebKit failed the second, and its
    /// cleanup deleted the first's file while its row said Done.
    func testTwoDownloadsOfOneNameNeverShareAFile() throws {
        let first = BrowserDownloadName.free("report.zip", in: folder, held: [])
        XCTAssertEqual(first, "report.zip")
        let second = BrowserDownloadName.free("report.zip", in: folder, held: [first])
        XCTAssertEqual(second, "report 2.zip", "a running download holds its name")

        // The first is written; the second fails and is cleaned up.
        try write("the first's data", to: BrowserDownloadName.partial(first))
        BrowserDownloadName.removePartial(file(BrowserDownloadName.partial(second)))
        let done = try XCTUnwrap(BrowserDownloadName.finish(file(BrowserDownloadName.partial(first)),
                                                            as: first, held: []))
        XCTAssertEqual(done.lastPathComponent, "report.zip")
        XCTAssertEqual(read("report.zip"), "the first's data")
    }

    /// A `.download` left by a quit or a crash keeps its name taken.
    func testALeftoverPartialKeepsItsNameTaken() throws {
        try write("half", to: "report.zip.download")
        XCTAssertEqual(BrowserDownloadName.free("report.zip", in: folder, held: []), "report 2.zip")
    }

    /// Until it has finished, a download is not under its real name.
    func testAFinishedDownloadTakesItsName() throws {
        try write("whole", to: "notes.txt.download")
        let done = try XCTUnwrap(BrowserDownloadName.finish(file("notes.txt.download"), as: "notes.txt", held: []))
        XCTAssertEqual(done, file("notes.txt"))
        XCTAssertEqual(read("notes.txt"), "whole")
        XCTAssertNil(read("notes.txt.download"))
    }

    /// The name was taken while it downloaded: numbered, never replaced.
    func testFinishingNeverReplacesAFile() throws {
        try write("someone else's", to: "notes.txt")
        try write("whole", to: "notes.txt.download")
        let done = try XCTUnwrap(BrowserDownloadName.finish(file("notes.txt.download"), as: "notes.txt",
                                                            held: ["notes 2.txt"]))
        XCTAssertEqual(done.lastPathComponent, "notes 3.txt", "past the file and the running download")
        XCTAssertEqual(read("notes.txt"), "someone else's")
        XCTAssertEqual(read("notes 3.txt"), "whole")
    }

    /// A failed or stopped download removes its `.download`, and only that.
    func testOnlyAPartialFileIsEverRemoved() throws {
        try write("whole", to: "report.zip")
        try write("half", to: "report.zip.download")
        BrowserDownloadName.removePartial(file("report.zip"))
        XCTAssertEqual(read("report.zip"), "whole")
        BrowserDownloadName.removePartial(file("report.zip.download"))
        XCTAssertNil(read("report.zip.download"))
    }
}
