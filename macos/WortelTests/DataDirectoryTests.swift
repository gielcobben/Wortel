import XCTest

/// Which data folder a build uses. A wrong answer is a Debug build from a
/// fresh clone adopting the installed app's sessions, or replacing its keeper
/// and ending every shell in it; or, the other way, the maintainer's daily
/// build opening on an empty folder.
final class DataDirectoryTests: XCTestCase {
    private let support = "/Users/someone/Library/Application Support"
    private var marker: String { support + "/Wortel/" + DataDirectory.shareMarker }

    private func resolve(_ environment: String? = nil, debug: Bool, shared: Bool = false,
                         cwd: String = "/tmp/here") -> String? {
        let marker = marker
        return DataDirectory.resolve(environment: environment, debugBuild: debug,
                                     applicationSupport: support, currentDirectory: cwd,
                                     fileExists: { shared && $0 == marker })
    }

    func testReleaseUsesTheUsualFolder() {
        XCTAssertNil(resolve(debug: false))
        XCTAssertNil(resolve(debug: false, shared: true))
    }

    func testDebugKeepsToItsOwnFolderByDefault() {
        XCTAssertEqual(resolve(debug: true), support + "/Wortel Dev")
    }

    func testDebugSharesTheUsualFolderWhenThisMacSaysSo() {
        XCTAssertNil(resolve(debug: true, shared: true))
    }

    /// Test copies set it, and it has to win over both rules, or a copy run
    /// on the maintainer's Mac lands on the real folder.
    func testTheVariableAlwaysWins() {
        for debug in [false, true] {
            for shared in [false, true] {
                XCTAssertEqual(resolve("/tmp/wt", debug: debug, shared: shared), "/tmp/wt")
            }
        }
    }

    func testTheVariableIsMadeAbsolute() {
        XCTAssertEqual(resolve("data", debug: true, cwd: "/tmp/here"), "/tmp/here/data")
        XCTAssertEqual(resolve("/tmp/a/../b/", debug: false), "/tmp/b")
        XCTAssertEqual(resolve("~/wt", debug: false), NSHomeDirectory() + "/wt")
    }

    func testAnEmptyVariableIsNoVariable() {
        XCTAssertEqual(resolve("", debug: true), support + "/Wortel Dev")
        XCTAssertNil(resolve("", debug: false))
    }

    /// `scripts/debug-bundle-id.sh` looks for the same file by name.
    func testTheMarkerNameMatchesTheBuildScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/debug-bundle-id.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("Application Support/Wortel/" + DataDirectory.shareMarker))
    }
}
