import Foundation

/// The last `limit` bytes a session's program wrote, kept by the keeper beside
/// its terminal. An app that attaches reads it for what the program said
/// about itself lately (`ProgramStatusWatch`: an agent's working and done, a
/// notification); it is never written into a terminal, whose snapshot has all
/// of it. A ring: the oldest go first, in at most two copies a write.
struct OutputTail {
    let limit: Int
    private var storage: [UInt8] = []
    /// Where the oldest byte is, once full.
    private var head = 0

    init(limit: Int = Keeper.replayLimit) {
        self.limit = max(0, limit)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ incoming: UnsafePointer<UInt8>, count: Int) {
        guard limit > 0, count > 0 else { return }
        // Larger than the whole tail: only its own end is kept.
        if count >= limit {
            storage = Array(UnsafeBufferPointer(start: incoming + (count - limit), count: limit))
            head = 0
            return
        }
        let filling = min(count, limit - storage.count)
        storage.append(contentsOf: UnsafeBufferPointer(start: incoming, count: filling))
        let rest = count - filling
        guard rest > 0 else { return }
        // Full: write over the oldest.
        let head = self.head, limit = self.limit
        storage.withUnsafeMutableBufferPointer { ring in
            let first = min(rest, limit - head)
            (ring.baseAddress! + head).update(from: incoming + filling, count: first)
            ring.baseAddress!.update(from: incoming + filling + first, count: rest - first)
        }
        self.head = (head + rest) % limit
    }

    /// What is held, oldest first.
    func copy() -> Data {
        guard !storage.isEmpty else { return Data() }
        var data = Data(capacity: storage.count)
        data.append(contentsOf: storage[head...])
        data.append(contentsOf: storage[..<head])
        return data
    }
}
