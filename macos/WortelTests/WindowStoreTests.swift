import XCTest

/// Which window each session opens in at launch, and which windows come back
/// (`WindowStore.assign`), plus the file `windows.json` round trip. The case
/// that matters most is the one nobody chose: a `sessions.json` written by an
/// older build, which knows nothing of windows and drops `windowID` on save.
/// Everything must then land in one window, and nothing may be left out.
final class WindowStoreTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private let one = UUID(), two = UUID(), three = UUID()

    func testSessionsGoToTheirOwnWindows() {
        let result = WindowStore.assign(
            sessions: [(one, a), (two, b), (three, a)], windows: [a, b])
        XCTAssertEqual(result.windows, [a, b])
        XCTAssertEqual(result.owner[one], a)
        XCTAssertEqual(result.owner[two], b)
        XCTAssertEqual(result.owner[three], a)
    }

    /// An older build's file: no session names a window. All of them go to
    /// the first, and the windows left with none are not brought back.
    func testAnOlderFileLandsInTheFirstWindow() {
        let result = WindowStore.assign(
            sessions: [(one, nil), (two, nil)], windows: [a, b])
        XCTAssertEqual(result.windows, [a])
        XCTAssertEqual(result.owner[one], a)
        XCTAssertEqual(result.owner[two], a)
    }

    /// A window that `windows.json` no longer lists (the file lost, or a
    /// newer build's) is the first one's.
    func testAnUnknownWindowIsTheFirst() {
        let result = WindowStore.assign(sessions: [(one, c), (two, b)], windows: [a, b])
        XCTAssertEqual(result.owner[one], a)
        XCTAssertEqual(result.owner[two], b)
        XCTAssertEqual(result.windows, [a, b])
    }

    /// The first window is kept even with nothing in it: there is always a
    /// window. Any other without a session is dropped.
    func testOnlyTheFirstWindowMayBeEmpty() {
        let result = WindowStore.assign(sessions: [(one, b)], windows: [a, b, c])
        XCTAssertEqual(result.windows, [a, b])
        XCTAssertEqual(result.owner[one], b)
    }

    /// No `windows.json` at all (the first launch of this build): one window.
    func testNoSavedWindowsMakesOne() {
        let result = WindowStore.assign(sessions: [(one, a)], windows: [])
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.owner[one], result.windows[0])
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = [PersistedWindow(id: a, frame: "10 20 1100 700 0 0 1512 944 ", selected: one),
                     PersistedWindow(id: b, frame: nil, selected: nil)]
        WindowStore.save(saved, to: url)
        XCTAssertEqual(WindowStore.load(from: url), saved)
    }

    func testAMissingFileIsNoWindows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json")
        XCTAssertEqual(WindowStore.load(from: url), [])
    }

    /// `windowID` is read back, and a file without it reads as nil.
    func testPersistedSessionCarriesItsWindow() throws {
        let id = UUID()
        let with = try JSONDecoder().decode(
            PersistedSession.self, from: Data(#"{"id":"\#(UUID())","windowID":"\#(id)"}"#.utf8))
        XCTAssertEqual(with.windowID, id)
        let without = try JSONDecoder().decode(
            PersistedSession.self, from: Data(#"{"id":"\#(UUID())"}"#.utf8))
        XCTAssertNil(without.windowID)
    }
}
