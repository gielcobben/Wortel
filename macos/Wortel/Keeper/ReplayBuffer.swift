import Foundation

/// What you missed while nothing was attached.
///
/// A bounded, oldest-first byte buffer. When it overflows it drops from the
/// **front**, because the useful end of a terminal's output is the end: if an
/// agent produced 40MB while you were away, what you want on reattach is how it
/// finished, not how it started.
///
/// Deliberately not scrollback. It only fills while a session is detached, so
/// it answers one question — "what happened while I was gone" — and a session
/// that is attached the whole time never allocates anything at all.
struct ReplayBuffer: Equatable {
    private(set) var bytes: [UInt8] = []
    /// Bytes dropped off the front. Not shown anywhere yet, but the count is the
    /// difference between "you have everything" and "you have the tail", and a
    /// replay that silently omits the start would be indistinguishable from one
    /// that didn't.
    private(set) var dropped = 0

    let limit: Int

    init(limit: Int = Keeper.replayLimit) {
        self.limit = max(0, limit)
    }

    var isEmpty: Bool { bytes.isEmpty }
    var count: Int { bytes.count }

    mutating func append(_ incoming: UnsafePointer<UInt8>, count: Int) {
        guard limit > 0, count > 0 else { return }
        // A single write larger than the whole buffer: keep only its tail, and
        // don't bother appending the part that is about to be dropped.
        if count >= limit {
            dropped += bytes.count + (count - limit)
            bytes = Array(UnsafeBufferPointer(start: incoming + (count - limit), count: limit))
            return
        }
        bytes.append(contentsOf: UnsafeBufferPointer(start: incoming, count: count))
        if bytes.count > limit {
            let excess = bytes.count - limit
            bytes.removeFirst(excess)
            dropped += excess
        }
    }

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            append(base, count: raw.count)
        }
    }

    /// Hand everything over and start again. Taking rather than copying is the
    /// point: once it has been replayed it must not be replayed twice, which is
    /// how a reattach loop would duplicate a screenful of output.
    mutating func take() -> Data {
        defer {
            bytes = []
            dropped = 0
        }
        return Data(bytes)
    }
}
