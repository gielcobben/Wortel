import XCTest

/// 2026.47.4 on macOS 15.5: a walk up the folders that waited for the parent
/// of `/` to be `/` never ended. These hold on any macOS, which is the point:
/// the walk ends because each step is shorter, not because of Foundation.
final class PathWalkTests: XCTestCase {
    func testAnAbsolutePathEndsAtTheDisk() {
        XCTAssertEqual(PathWalk.upward(from: "/Users/someone/.scratch/game-v1"),
                       ["/Users/someone/.scratch/game-v1", "/Users/someone/.scratch",
                        "/Users/someone", "/Users", "/"])
    }

    func testTheDiskIsOneStep() {
        XCTAssertEqual(PathWalk.upward(from: "/"), ["/"])
    }

    func testARelativePathEndsAtItsFirstFolder() {
        XCTAssertEqual(PathWalk.upward(from: "macos/docs/x"), ["macos/docs/x", "macos/docs", "macos"])
    }

    func testEmptyAndOddPathsEnd() {
        XCTAssertEqual(PathWalk.upward(from: ""), [])
        // Whatever these mean, each walk is no longer than its string.
        for path in ["/a/", "//", "/..", "/../../..", "../..", "./", "~", "a//b///"] {
            let walk = PathWalk.upward(from: path)
            XCTAssertLessThanOrEqual(walk.count, path.count, path)
            XCTAssertEqual(walk.first, path, path)
        }
    }
}
