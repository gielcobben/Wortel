import Foundation

/// Reads a session's output channel (`KeeperChannel`) back into its frames.
/// Reads of a socket end wherever they end, so a frame can arrive over many
/// of them and several in one; this puts them back together, in order.
///
/// An output frame is handed on as its bytes come, in as many pieces as they
/// came in, never held back for the rest of it: output is the hot path. A
/// snapshot is collected whole, since it is only useful whole.
///
/// Pure: the app's read queue feeds it, and it hands back what it found.
struct KeeperChannelReader {
    enum Piece {
        /// The keeper's terminal as of a point in the stream; what follows is
        /// what came after it.
        case snapshot(Data)
        /// Part of what the program wrote, borrowed for the call.
        case output(UnsafeBufferPointer<UInt8>)
        /// Not a channel at all: the bytes are dropped, and so is the rest.
        case invalid
    }

    private enum Stage {
        case header
        case output(remaining: Int)
        case snapshot(length: Int)
        case broken
    }
    private var stage = Stage.header
    private var held = Data()

    /// Feed one read. `handle` is called for each piece in order, before this
    /// returns.
    mutating func feed(_ bytes: UnsafePointer<UInt8>, count: Int, _ handle: (Piece) -> Void) {
        var offset = 0
        while offset < count {
            switch stage {
            case .broken:
                return
            case .header:
                let take = min(KeeperChannel.headerSize - held.count, count - offset)
                held.append(bytes + offset, count: take)
                offset += take
                guard held.count == KeeperChannel.headerSize else { return }
                guard let (frame, length) = KeeperChannel.parse(header: held) else {
                    stage = .broken
                    held = Data()
                    return handle(.invalid)
                }
                held = Data()
                switch frame {
                case .output: stage = length > 0 ? .output(remaining: length) : .header
                case .snapshot:
                    // A terminal always encodes to something; an empty
                    // snapshot is as broken as a bad header.
                    guard length > 0 else {
                        stage = .broken
                        return handle(.invalid)
                    }
                    held.reserveCapacity(length)
                    stage = .snapshot(length: length)
                }
            case .output(let remaining):
                let take = min(remaining, count - offset)
                handle(.output(UnsafeBufferPointer(start: bytes + offset, count: take)))
                offset += take
                stage = remaining == take ? .header : .output(remaining: remaining - take)
            case .snapshot(let length):
                let take = min(length - held.count, count - offset)
                held.append(bytes + offset, count: take)
                offset += take
                guard held.count == length else { return }
                let snapshot = held
                held = Data()
                stage = .header
                handle(.snapshot(snapshot))
            }
        }
    }
}
