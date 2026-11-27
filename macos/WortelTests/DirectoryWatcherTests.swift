import XCTest

/// The file tree updates because one of these is watching each open directory,
/// and the way that goes wrong is silent: a watch that has died reports nothing,
/// which is indistinguishable from a directory where nothing is happening. So
/// the two facts the tree's refresh actually leans on are pinned here.
final class DirectoryWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The ordinary case: something appears in a watched directory.
    func testReportsAnEntryAppearing() {
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = DirectoryWatcher(path: root.path) { _ in fired.fulfill() }
        XCTAssertNotNil(watcher)

        FileManager.default.createFile(atPath: root.appendingPathComponent("a.txt").path,
                                       contents: Data("hi".utf8))
        wait(for: [fired], timeout: 5)
    }

    /// The case the tree's correctness hangs on. A vnode watch is on an inode,
    /// not a path — so a directory that is deleted and recreated (a branch
    /// switch, `rm -rf dist`, an agent rebuilding a folder) leaves this watching
    /// something unreachable, and every later write to that path is invisible.
    /// It has to *say so*, because that report is the only chance the model gets
    /// to put a live watch back; without it the subtree quietly stops updating
    /// for the rest of the session.
    func testReportsItsOwnDirectoryVanishing() {
        let vanished = expectation(description: "reported as vanished")
        vanished.assertForOverFulfill = false
        let watcher = DirectoryWatcher(path: root.path) { gone in
            if gone { vanished.fulfill() }
        }
        XCTAssertNotNil(watcher)

        try? FileManager.default.removeItem(at: root)
        wait(for: [vanished], timeout: 5)

        // Put it back so tearDown has something to clean up.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `open` on a FIFO waits for a writer, and on a serial port for a
    /// carrier, for ever (measured 2026-11-27). A browser tab watches paths a
    /// page names, on the main thread, so only a file or a directory is
    /// watched. Run off the test's thread so a regression fails, not hangs.
    func testRefusesAFIFOAndADeviceWithoutWaiting() {
        let fifo = root.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o644), 0)
        let returned = expectation(description: "returned")
        DispatchQueue.global().async {
            let pipe = DirectoryWatcher(path: fifo) { _ in }
            let device = DirectoryWatcher(path: "/dev/null") { _ in }
            XCTAssertNil(pipe)
            XCTAssertNil(device)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 5)
        XCTAssertTrue(DirectoryWatcher.isWatchable(root.path))
        let file = root.appendingPathComponent("a.txt").path
        FileManager.default.createFile(atPath: file, contents: Data())
        XCTAssertTrue(DirectoryWatcher.isWatchable(file))
    }
}
