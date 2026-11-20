import Foundation

/// The last `limit` bytes a session's program wrote **while no app had a
/// channel to it**, kept by the keeper beside its terminal and taken by the
/// next app that attaches, which reads it for what the program said about
/// itself meanwhile (`ProgramStatusWatch`: an agent's working and done, a
/// notification). Only what that app has not heard: a report it already
/// acted on before it quit, read again, would be raised twice. Never written
/// into a terminal, whose snapshot has all of it. A ring: the oldest go
/// first, in at most two copies a write.
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

    /// Everything held, oldest first, and empty after.
    mutating func take() -> Data {
        defer {
            storage = []
            head = 0
        }
        return copy()
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
