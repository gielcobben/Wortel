import XCTest

/// The app's reading of a session's channel (`KeeperChannel`): frames that a
/// socket hands over in whatever pieces it likes. A frame put back together
/// wrong is a terminal restored from half a snapshot, or output written into
/// one at the wrong point.
final class KeeperChannelReaderTests: XCTestCase {
    private enum Seen: Equatable { case snapshot(Data), output(Data), invalid }

    private func frame(_ type: KeeperChannel.Frame, _ payload: [UInt8]) -> [UInt8] {
        KeeperChannel.header(type, length: payload.count) + payload
    }

    /// Feed `bytes` in pieces of `size`, merging consecutive output pieces.
    private func read(_ bytes: [UInt8], in size: Int) -> [Seen] {
        var reader = KeeperChannelReader()
        var seen: [Seen] = []
        var offset = 0
        while offset < bytes.count {
            let piece = Array(bytes[offset..<min(offset + size, bytes.count)])
            piece.withUnsafeBufferPointer { raw in
                reader.feed(raw.baseAddress!, count: raw.count) { found in
                    switch found {
                    case .snapshot(let data): seen.append(.snapshot(data))
                    case .output(let out):
                        if case .output(let before) = seen.last {
                            seen[seen.count - 1] = .output(before + Data(out))
                        } else {
                            seen.append(.output(Data(out)))
                        }
                    case .invalid: seen.append(.invalid)
                    }
                }
            }
            offset += size
        }
        return seen
    }

    func testFramesComeBackWholeHoweverTheyAreCut() {
        let snapshot = (0..<300).map { UInt8($0 % 251) }
        let second = (0..<40).map { UInt8($0) }
        let stream = frame(.snapshot, snapshot) + frame(.output, Array("hello ".utf8))
            + frame(.output, Array("world".utf8)) + frame(.snapshot, second) + frame(.output, Array("after".utf8))
        let want: [Seen] = [.snapshot(Data(snapshot)), .output(Data("hello world".utf8)),
                            .snapshot(Data(second)), .output(Data("after".utf8))]
        for size in 1...stream.count {
            XCTAssertEqual(read(stream, in: size), want, "cut into pieces of \(size)")
        }
    }

    func testAnEmptyOutputFrameIsNothing() {
        let stream = frame(.snapshot, [1, 2, 3]) + frame(.output, []) + frame(.output, [65])
        XCTAssertEqual(read(stream, in: 4), [.snapshot(Data([1, 2, 3])), .output(Data([65]))])
    }

    /// Something that is not a keeper's channel is said once and dropped.
    func testWhatIsNotAChannelIsDropped() {
        XCTAssertEqual(read(Array("not a channel at all".utf8), in: 3), [.invalid])
        XCTAssertEqual(read(frame(.snapshot, []) + frame(.output, [1]), in: 2), [.invalid])
    }
}
