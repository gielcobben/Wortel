import Foundation

/// Reads the start of a session's output channel (`KeeperChannel`): the
/// header, then the snapshot of the keeper's terminal, then the program's
/// output, raw. Reads of a socket end wherever they end, so the snapshot can
/// arrive over many of them and the first output in the same read as its
/// last byte; this puts them back together and in order.
///
/// Pure: the app's pty queue feeds it, and it hands back what it found.
struct KeeperChannelReader {
    enum Piece {
        /// The keeper's terminal as of the cut. Comes once, first.
        case snapshot(Data)
        /// What the program wrote after it, as it came.
        case output(UnsafeBufferPointer<UInt8>)
        /// Not a channel at all: the bytes are dropped, and so is the rest.
        case invalid
    }

    private enum Stage { case header, snapshot(Int), live, broken }
    private var stage = Stage.header
    private var held = Data()

    /// True once the snapshot has been handed over.
    var isLive: Bool { if case .live = stage { return true } else { return false } }

    /// Feed one read. `handle` is called for each piece in order, before this
    /// returns; an `output` piece's bytes are borrowed for the call.
    mutating func feed(_ bytes: UnsafePointer<UInt8>, count: Int, _ handle: (Piece) -> Void) {
        var offset = 0
        while offset < count {
            switch stage {
            case .live:
                handle(.output(UnsafeBufferPointer(start: bytes + offset, count: count - offset)))
                return
            case .broken:
                return
            case .header:
                let take = min(KeeperChannel.headerSize - held.count, count - offset)
                held.append(bytes + offset, count: take)
                offset += take
                guard held.count == KeeperChannel.headerSize else { return }
                // A terminal always encodes to something; an empty snapshot
                // is as broken as a bad header.
                guard let length = KeeperChannel.snapshotLength(header: held), length > 0 else {
                    stage = .broken
                    held = Data()
                    handle(.invalid)
                    return
                }
                held = Data(capacity: length)
                stage = .snapshot(length)
            case .snapshot(let length):
                let take = min(length - held.count, count - offset)
                held.append(bytes + offset, count: take)
                offset += take
                guard held.count == length else { return }
                let snapshot = held
                held = Data()
                stage = .live
                handle(.snapshot(snapshot))
            }
        }
    }
}
