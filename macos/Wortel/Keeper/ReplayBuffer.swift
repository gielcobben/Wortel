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
///
/// **A ring once full.** It grows like an array up to `limit`, and from then on
/// new bytes overwrite the oldest in place. It used to trim with
/// `removeFirst`, which moves every remaining byte: once full, every read from
/// a busy detached session copied half a megabyte to make room for a few
/// hundred bytes.
///
/// **What it drops, it reads first.** A program declares its terminal modes
/// once, at startup, and the cut takes that startup with it: Codex resumed
/// while nobody was attached turns on the alternate screen, the mouse and the
/// keyboard protocol, then reprints a long conversation, and reattached, the
/// terminal had none of them, so scrolling and selecting in Codex did nothing.
/// So the modes set in the dropped bytes go in front of the replay
/// (`TerminalModes`), and the tail, being newer, still wins.
struct ReplayBuffer {
    /// Grows to `limit`, then wraps: the oldest byte is at `head`.
    private var storage: [UInt8] = []
    private var head = 0
    /// Bytes dropped off the front since the last `take`. The difference
    /// between "you have everything" and "you have the tail", which is also
    /// what decides whether a replay needs `resync` in front of it.
    private(set) var dropped = 0
    /// The modes set in the bytes dropped since the last `take`, read in the
    /// order they were written.
    private var droppedModes = TerminalModes()
    private var droppedScanner = CSIScanner()

    let limit: Int

    /// Put in front of a replay whose start was dropped.
    ///
    /// The cut falls wherever the limit did, so the first byte kept can be the
    /// middle of an escape sequence, and the terminal would read the rest of it
    /// as text or as a different sequence. CAN abandons a sequence in progress
    /// (and does nothing outside one), and the SGR reset clears a colour or
    /// style whose start was cut off and would otherwise bleed over the screen.
    static let resync = Data("\u{18}\u{1b}[0m".utf8)

    init(limit: Int = Keeper.replayLimit) {
        self.limit = max(0, limit)
    }

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    mutating func append(_ incoming: UnsafePointer<UInt8>, count: Int) {
        guard limit > 0, count > 0 else { return }
        // A single write larger than the whole buffer: keep only its tail, and
        // don't bother appending the part that is about to be dropped.
        if count >= limit {
            noteDropped(oldestFirst: storage.count)
            noteDropped(incoming, count: count - limit)
            dropped += storage.count + (count - limit)
            storage = Array(UnsafeBufferPointer(start: incoming + (count - limit), count: limit))
            head = 0
            return
        }
        let filling = min(count, limit - storage.count)
        storage.append(contentsOf: UnsafeBufferPointer(start: incoming, count: filling))
        overwriteOldest(with: incoming + filling, count: count - filling)
    }

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            append(base, count: raw.count)
        }
    }

    /// What is held, oldest first, without letting go of it: the tail a
    /// keeper that keeps the terminal gives each app that attaches, for what
    /// the program said about itself (`ProgramStatusWatch`). Never written
    /// into a terminal, so a cut start needs no resync in front of it.
    func copy() -> Data {
        guard !storage.isEmpty else { return Data() }
        var data = Data(capacity: storage.count)
        data.append(contentsOf: storage[head...])
        data.append(contentsOf: storage[..<head])
        return data
    }

    /// Hand everything over and start again. Taking rather than copying is the
    /// point: once it has been replayed it must not be replayed twice, which is
    /// how a reattach loop would duplicate a screenful of output.
    mutating func take() -> Data {
        defer {
            storage = []
            head = 0
            dropped = 0
            droppedModes = TerminalModes()
            droppedScanner = CSIScanner()
        }
        guard !storage.isEmpty else { return Data() }
        let modes = dropped > 0 ? droppedModes.prelude : []
        var data = Data(capacity: modes.count + storage.count + Self.resync.count)
        if dropped > 0 {
            data.append(contentsOf: modes)
            data.append(Self.resync)
        }
        data.append(contentsOf: storage[head...])
        data.append(contentsOf: storage[..<head])
        return data
    }

    /// Write `count` bytes over the oldest ones, in at most two copies. Only
    /// once full, so `storage.count == limit`, and `count < limit`.
    private mutating func overwriteOldest(with incoming: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        noteDropped(oldestFirst: count)
        let limit = self.limit
        let head = self.head
        storage.withUnsafeMutableBufferPointer { ring in
            guard let base = ring.baseAddress else { return }
            let first = min(count, limit - head)
            (base + head).update(from: incoming, count: first)
            base.update(from: incoming + first, count: count - first)
        }
        self.head = (head + count) % limit
        dropped += count
    }

    private mutating func noteDropped(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        droppedModes.feed(bytes, count: count, parser: &droppedScanner)
    }

    /// Read the `count` oldest bytes, about to be dropped, in the order they
    /// were written: from `head`, wrapping.
    private mutating func noteDropped(oldestFirst count: Int) {
        guard count > 0 else { return }
        // Moved out and back so reading the ring isn't an access to `self`
        // overlapping the one that updates them.
        var modes = TerminalModes()
        var scanner = CSIScanner()
        swap(&modes, &droppedModes)
        swap(&scanner, &droppedScanner)
        let head = self.head
        storage.withUnsafeBufferPointer { ring in
            guard let base = ring.baseAddress else { return }
            let first = min(count, ring.count - head)
            modes.feed(base + head, count: first, parser: &scanner)
            if count > first { modes.feed(base, count: count - first, parser: &scanner) }
        }
        swap(&modes, &droppedModes)
        swap(&scanner, &droppedScanner)
    }
}
