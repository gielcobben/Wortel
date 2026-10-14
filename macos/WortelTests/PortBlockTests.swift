import XCTest

/// A session's ten ports. Every failure here is a collision nobody sees until
/// two dev servers fight over one port: a block handed out twice, a block that
/// moves between launches, or one sitting on a port something else expects.
final class PortBlockTests: XCTestCase {
    private let id = UUID(uuidString: "6F1B7C9E-2D4A-4F3B-9C1E-8A7D5B3E2F10")!

    func testSameSessionAsksForTheSameBlock() {
        let a = PortBlock.allocate(for: id, taken: [], isFree: { _ in true })
        let b = PortBlock.allocate(for: id, taken: [], isFree: { _ in true })
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    /// FNV-1a, not `hashValue`: the first choice must survive a relaunch.
    func testDigestIsFixed() {
        XCTAssertEqual(PortBlock.digest(id), PortBlock.digest(UUID(uuidString: id.uuidString)!))
        XCTAssertNotEqual(PortBlock.digest(id), PortBlock.digest(UUID()))
    }

    func testBlocksAreAlignedAndInRange() throws {
        for _ in 0..<200 {
            let base = try XCTUnwrap(PortBlock.allocate(for: UUID(), taken: [], isFree: { _ in true }))
            XCTAssertTrue(PortBlock.range.contains(base))
            XCTAssertTrue(PortBlock.range.contains(base + PortBlock.size - 1))
            XCTAssertEqual((base - PortBlock.range.lowerBound) % PortBlock.size, 0)
            XCTAssertTrue(PortBlock.avoided.isDisjoint(with: base..<(base + PortBlock.size)))
        }
    }

    func testTakenBlockIsSkipped() throws {
        let first = try XCTUnwrap(PortBlock.allocate(for: id, taken: [], isFree: { _ in true }))
        let second = try XCTUnwrap(PortBlock.allocate(for: id, taken: [first], isFree: { _ in true }))
        XCTAssertNotEqual(first, second)
    }

    /// One busy port is enough to give up the whole block.
    func testBlockWithABusyPortIsSkipped() throws {
        let first = try XCTUnwrap(PortBlock.allocate(for: id, taken: [], isFree: { _ in true }))
        let busy = first + 7
        let second = try XCTUnwrap(PortBlock.allocate(for: id, taken: [], isFree: { $0 != busy }))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse((second..<(second + PortBlock.size)).contains(busy))
    }

    func testBlockContainingAnAvoidedPortIsNeverHandedOut() {
        // Everything but the block holding MongoDB's port is taken.
        let mongoBlock = 27_010
        let taken = Set(stride(from: PortBlock.range.lowerBound, to: PortBlock.range.upperBound,
                               by: PortBlock.size)).subtracting([mongoBlock])
        XCTAssertNil(PortBlock.allocate(for: id, taken: taken, isFree: { _ in true }))
    }

    func testExhaustedRangeGivesNil() {
        XCTAssertNil(PortBlock.allocate(for: id, taken: [], isFree: { _ in false }))
    }

    func testEnvironmentCarriesBothNames() {
        XCTAssertEqual(PortBlock.environment(base: 21_340),
                       ["WORTEL_PORT": "21340", "CONDUCTOR_PORT": "21340"])
        XCTAssertEqual(PortBlock.environment(base: nil), [:])
    }

    /// The probe against a real socket: a port we hold is busy, and once let
    /// go of (with nothing in TIME_WAIT, since nothing connected) it is free.
    func testIsFreeSeesARealListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertFalse(PortBlock.isFree(port))
        close(fd)
        XCTAssertTrue(PortBlock.isFree(port))
    }
}
