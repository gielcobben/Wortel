import Foundation

/// What the terminal answers while a reattached session's replay goes through
/// it, and when that stops.
///
/// **The bug this exists for is input nobody typed.** A reattach writes the
/// keeper's replay into a brand-new libghostty surface, and libghostty parses
/// it like any output: every query in there (cursor position `ESC[6n`, device
/// attributes `ESC[c`, the colour queries OSC 10 and 11, XTVERSION, the kitty
/// keyboard query) gets answered, and with a host-managed pty the answer goes
/// straight into the program (`receive_buffer` → `PtyHost.write`). Those
/// queries are old. The program asked them while nobody was attached, gave up
/// waiting, and has moved on; an answer arriving now is read as typed input,
/// which is how `^[[24;1R` or `]11;rgb:…` turned up in an agent's prompt
/// after a relaunch. bb (another agent app) has the same answer: drop what the
/// terminal sends the program while it replays.
///
/// **The window is closed by a marker, not a timer.** libghostty does not
/// write an answer from inside `ghostty_surface_write_buffer`: the parser
/// queues it on the surface's IO thread (`StreamHandler.messageWriter`, Ghostty
/// 1.2), which writes it out a moment later. So the replay having been parsed
/// says nothing about its answers having gone. What does is a query of our own
/// parsed straight after the replay: answers leave that queue in order, so
/// once ours (`sentinel`, a mode request no program makes) comes back, every
/// answer the replay produced has already been through, and nothing after it
/// is muted. A deadline backs it up, should the marker never come back.
///
/// Keystrokes take the same queue and arrive the same way, so they can't be
/// told apart here: a key pressed *while the replay is being parsed* is dropped
/// with the answers. That window is the few milliseconds a surface takes to be
/// built, before it has been on screen to type into, which is why nothing
/// tries harder.
///
/// Three things the terminal sends are let through, because they describe the
/// terminal *now* rather than answer an old question, and the program wants
/// them unasked: a focus report (`ESC[I`/`ESC[O`; re-declaring `?1004` in the
/// mode prelude produces one, and so does the window taking focus), the
/// in-band size report of `?2048`, and the light/dark report of `?2031`, which
/// is the same bytes Wortel sends a resumed agent on purpose
/// (`TerminalModes.colorSchemeReport`).
///
/// Pure, so the keeper (which shares `PtyHost`) and the tests can carry it.
struct ReplayAnswers {
    /// The marker: DECRQM for a private mode no terminal has. Ghostty answers
    /// any mode request, an unknown one with `ESC[?<mode>;0$y`.
    static let sentinelMode = 64_738
    static let sentinel = Array("\u{1B}[?\(sentinelMode)$p".utf8)
    private static let sentinelAnswerPrefix = Array("\u{1B}[?\(sentinelMode);".utf8)

    /// How long the window may stay shut while the replay is still being
    /// written. Generous on purpose: a 512 KB replay full of titles waits on
    /// the main thread's mailbox, and the answers come out as it goes.
    static let writingPatience: UInt64 = 10_000_000_000
    /// How long after the replay is written the marker has to come back. It
    /// takes microseconds; this is only for a marker that never will.
    static let markerPatience: UInt64 = 2_000_000_000
    /// How long after the replay is written the window stays shut when no
    /// marker could be sent (see `endsCleanly`): long enough for the IO thread
    /// to have written out what the parse queued, which is immediate unless
    /// the Mac is in real trouble.
    static let unmarkedPatience: UInt64 = 250_000_000

    /// Uptime, in nanoseconds, past which nothing is muted any more.
    private(set) var deadline: UInt64
    private(set) var isOpen = false
    /// How many writes were dropped, for the log line when the window opens.
    private(set) var dropped = 0

    init(now: UInt64) {
        deadline = now + Self.writingPatience
    }

    /// The replay is written. With a marker sent after it, wait for that;
    /// without one, give the answers a moment to drain and then open.
    mutating func replayWritten(markerSent: Bool, now: UInt64) {
        deadline = now + (markerSent ? Self.markerPatience : Self.unmarkedPatience)
    }

    /// Which part of one write from the terminal goes on to the program: all
    /// of it, none of it (`nil`), or what follows the marker's answer.
    mutating func admit(_ bytes: UnsafeBufferPointer<UInt8>, now: UInt64) -> Range<Int>? {
        if isOpen { return 0..<bytes.count }
        if now >= deadline {
            isOpen = true
            return 0..<bytes.count
        }
        if let end = Self.endOfSentinelAnswer(in: bytes) {
            isOpen = true
            return end..<bytes.count
        }
        if Self.describesTheTerminalNow(bytes) { return 0..<bytes.count }
        dropped += 1
        return nil
    }

    /// Where the marker's answer ends in `bytes`, if it is in there.
    static func endOfSentinelAnswer(in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        let prefix = sentinelAnswerPrefix
        guard bytes.count >= prefix.count + 3 else { return nil }
        var start = 0
        while start + prefix.count <= bytes.count {
            if bytes[start] == 0x1B, zip(prefix, bytes[start..<start + prefix.count]).allSatisfy({ $0 == $1 }) {
                // `<code>$y` after the prefix.
                var index = start + prefix.count
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "$"),
                   bytes[index + 1] == UInt8(ascii: "y") {
                    return index + 2
                }
            }
            start += 1
        }
        return nil
    }

    /// A focus report, a `?2048` size report or a `?2031` light/dark report,
    /// and nothing else.
    static func describesTheTerminalNow(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let text = Array(bytes)
        if text == [0x1B, 0x5B, 0x49] || text == [0x1B, 0x5B, 0x4F] { return true } // ESC[I, ESC[O
        if text == Array("\u{1B}[?997;1n".utf8) || text == Array("\u{1B}[?997;2n".utf8) { return true }
        // ESC [ 4 8 ; <digits and ;> t
        let sizePrefix = Array("\u{1B}[48;".utf8)
        if text.count > sizePrefix.count + 1, Array(text.prefix(sizePrefix.count)) == sizePrefix,
           text.last == UInt8(ascii: "t") {
            return text[sizePrefix.count..<(text.count - 1)].allSatisfy {
                (0x30...0x39).contains($0) || $0 == UInt8(ascii: ";")
            }
        }
        return false
    }

    /// Whether `replay` stops between sequences, so the marker can follow it
    /// without landing inside one.
    ///
    /// The replay and the live output are one stream cut in two: the keeper
    /// stopped reading wherever the program had got to, and the app reads on
    /// from there. A program drawing at that moment can leave the replay
    /// mid-sequence, with the rest arriving in the first live read. Written
    /// into that gap, the marker's `ESC` would cut the sequence short (an
    /// escape aborts whatever the parser is in), and its tail would then be
    /// printed as text. So the marker goes only after a replay that ends
    /// cleanly; otherwise the window closes on the short deadline instead.
    ///
    /// Reads the last escape in the tail and nothing more. It is not a
    /// terminal, only enough of one to know when it is unsure, and unsure
    /// counts as not clean. What it can't see is a string the last escape is
    /// *inside*: a tmux passthrough (`ESC P tmux; … ESC ESC [ … h`) cut off
    /// after an escaped sequence reads as clean. Rare enough at the very end
    /// of a replay to leave.
    static func endsCleanly(_ replay: Data) -> Bool {
        guard let last = replay.last else { return true }
        // A UTF-8 character cut short: a lead byte without all its
        // continuation bytes.
        var continuation = 0
        for byte in replay.suffix(4).reversed() {
            if byte & 0xC0 == 0x80 { continuation += 1; continue }
            let needs = byte & 0xE0 == 0xC0 ? 1 : byte & 0xF0 == 0xE0 ? 2 : byte & 0xF8 == 0xF0 ? 3 : 0
            if needs > continuation { return false }
            break
        }
        if last == 0x1B { return false }
        let tail = replay.suffix(4096)
        guard let escape = tail.lastIndex(of: 0x1B) else { return true }
        let after = tail[tail.index(after: escape)...]
        guard let kind = after.first else { return false }
        let rest = after.dropFirst()
        switch kind {
        case UInt8(ascii: "\\"):
            // ST: the end of a string, and so of the last sequence.
            return true
        case UInt8(ascii: "["):
            // CSI: complete once its final byte has come.
            return rest.contains { (0x40...0x7E).contains($0) }
        case UInt8(ascii: "]"):
            // OSC: an unterminated one ends at BEL, or at the ST this would
            // have found as the last escape.
            return rest.contains(0x07)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            // DCS, SOS, PM, APC: only ST ends them, and that would have been
            // the last escape.
            return false
        default:
            // `ESC <intermediates> <final>`: `ESC 7`, `ESC ( B`.
            if (0x30...0x7E).contains(kind) { return true }
            return rest.contains { (0x30...0x7E).contains($0) }
        }
    }
}
