import Foundation

/// The terminal modes a program has switched on, so a reattach can say them
/// again.
///
/// **The bug this exists for is a paste that arrives as Enter.** A session
/// survives the app (the keeper holds its shell), but its *terminal* does not:
/// a relaunch builds a new libghostty surface whose modes are all at their
/// defaults, while the program on the far side never restarted and still
/// believes everything it set is set. Nothing tells either side they disagree.
///
/// Bracketed paste is where it hurts. An agent turns on `?2004` at startup, and
/// that is what makes a pasted paragraph arrive as one block: the terminal wraps
/// it in `ESC[200~` … `ESC[201~`, and the agent puts it in its prompt. After a
/// relaunch the terminal no longer thinks the mode is on, so the same paste goes
/// through raw, and every newline in it reads as a separate Enter — one queued
/// message per line, which is exactly what it looked like.
///
/// It was intermittent for a reason worth writing down: the keeper's replay
/// buffer holds the last 512 KB of output, so if the `?2004h` was recent enough
/// to still be in that tail, the replay set the mode again on its way through
/// and the paste behaved. Quiet sessions worked; busy ones did not.
///
/// **This has to live in the app, not the keeper.** While a session is
/// attached the app reads the pty itself and the keeper sees none of those
/// bytes, which is precisely when a program declares its modes. So the app
/// watches the output it is already handling, and writes it down
/// (`TerminalModeStore`) because the process that knows is the one that is
/// about to exit.
struct TerminalModes: Equatable {
    /// The DEC private modes worth restoring, by number.
    ///
    /// An allowlist, and a short one, because a mode replayed into a terminal
    /// that never asked for it is as wrong as a mode lost. Each of these is
    /// sticky (set once, at startup, and left) and its loss is something you
    /// can see:
    ///
    /// - `1` application cursor keys: the arrow keys send `ESC O A` instead of
    ///   `ESC [ A`, so history and menus stop answering them.
    /// - `9`, `1000`, `1002`, `1003`, `1005`, `1006`, `1015`, `1016` mouse
    ///   reporting: without it, clicking in a TUI does nothing.
    /// - `1004` focus reporting, which is how an agent knows to stop animating.
    /// - `1047`, `1048`, `1049` the alternate screen. A program that is in it
    ///   draws over a terminal that thinks it is on the primary screen.
    /// - `2004` bracketed paste: the one above.
    /// - `67` backspace sends delete, `1036`/`1039` meta sends escape:
    ///   keyboard shape, set at startup by editors.
    ///
    /// Deliberately **not** `25` (cursor visibility), `12` (cursor blink) or
    /// `2026` (synchronised output): a TUI toggles those every frame, so
    /// recording them would mean writing to disk continuously to restore a
    /// state that is one frame old anyway.
    static let restorable: Set<Int> = [
        1, 9, 67, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016,
        1036, 1039, 1047, 1048, 1049, 2004,
    ]

    /// Which of those are on, and which were explicitly turned off. A mode
    /// nobody mentioned is absent rather than false: the default is the
    /// terminal's to decide, and saying `ESC[?1l` for a mode no program ever
    /// touched is noise that can only do harm.
    private(set) var privateModes: [Int: Bool] = [:]

    /// The keyboard protocol flags a program asked for (`CSI > flags u`), which
    /// is how Claude Code and Ghostty agree about shift+enter. A lost flag set
    /// turns a newline in the prompt back into a submit, which is the same
    /// class of bug as the paste.
    private(set) var keyboardFlags: UInt8?

    var isEmpty: Bool { privateModes.isEmpty && keyboardFlags == nil }

    /// What to write into a fresh terminal to put it back where the program
    /// believes it is. Ordered so it is stable, and so a diff of two preludes
    /// reads.
    ///
    /// This goes to the *terminal*, before the replay: anything the program did
    /// while nobody was attached is in that replay and must win.
    var prelude: [UInt8] {
        var out = ""
        for mode in privateModes.keys.sorted() {
            guard let on = privateModes[mode] else { continue }
            out += "\u{1B}[?\(mode)\(on ? "h" : "l")"
        }
        if let flags = keyboardFlags {
            out += "\u{1B}[>\(flags)u"
        }
        return Array(out.utf8)
    }

    mutating func feed(_ bytes: UnsafePointer<UInt8>, count: Int, parser: inout CSIScanner) {
        parser.scan(bytes, count: count) { introducer, parameters, final in
            switch (introducer, final) {
            case (UInt8(ascii: "?"), UInt8(ascii: "h")), (UInt8(ascii: "?"), UInt8(ascii: "l")):
                let on = final == UInt8(ascii: "h")
                // `ESC[?1000;1002;1006h` is one sequence setting three modes.
                for mode in parameters.split(separator: ";").compactMap({ Int($0) })
                where Self.restorable.contains(mode) {
                    privateModes[mode] = on
                }
            case (UInt8(ascii: ">"), UInt8(ascii: "u")):
                // `CSI > u` with no parameter means flags 0, i.e. off.
                let flags = parameters.split(separator: ";").first.flatMap { UInt8($0) }
                keyboardFlags = flags ?? 0
            case (UInt8(ascii: "<"), UInt8(ascii: "u")):
                // A pop. What was pushed underneath is the program's business;
                // all this has to know is that the flags it recorded no longer
                // describe the top of the stack.
                keyboardFlags = nil
            default:
                break
            }
        }
    }

    mutating func feed(_ data: Data, parser: inout CSIScanner) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            feed(base, count: raw.count, parser: &parser)
        }
    }
}

/// Finds CSI sequences in a byte stream that arrives in arbitrary pieces.
///
/// Incremental because a pty read boundary lands wherever it lands: the real
/// stream put `ESC[?2004` at the end of one read and `h` at the start of the
/// next, and a scanner that restarted per chunk would miss exactly the
/// sequences this is here to catch.
///
/// It reads only the shape `ESC [ <introducer?> <parameters> <final>` and
/// ignores everything else, including the text the terminal is actually
/// printing. It is not a terminal: libghostty is, and this must never become a
/// second one.
struct CSIScanner {
    private enum State {
        case text
        case escape
        case parameters
        /// Inside a DCS, APC, PM or SOS string, waiting for its terminator.
        ///
        /// These carry arbitrary bytes, and one of the things they carry is
        /// other terminals' escape sequences: `tmux`'s passthrough wraps a
        /// sequence in a DCS precisely so the terminal in between does *not*
        /// act on it. A scanner that read inside them would record a mode this
        /// terminal was never in.
        case string
        case stringEscape
    }

    private var state: State = .text
    private var introducer: UInt8 = 0
    private var parameters: [UInt8] = []

    /// Longer than any real sequence. A binary file cat'ed to the terminal is
    /// full of bytes that look like the start of one, and without a bound the
    /// parameter buffer would grow for as long as the noise lasted.
    private static let maximumParameters = 32

    mutating func scan(_ bytes: UnsafePointer<UInt8>, count: Int,
                       sequence: (UInt8, String, UInt8) -> Void) {
        for index in 0..<count {
            let byte = bytes[index]
            switch state {
            case .text:
                if byte == 0x1B { state = .escape }
            case .escape:
                switch byte {
                case UInt8(ascii: "["):
                    state = .parameters
                    introducer = 0
                    parameters = []
                case UInt8(ascii: "P"), UInt8(ascii: "X"),
                     UInt8(ascii: "^"), UInt8(ascii: "_"):
                    state = .string
                case 0x1B:
                    state = .escape
                default:
                    // Some other escape sequence, and not one that matters here.
                    state = .text
                }
            case .string:
                // Ends at ST (`ESC \`) or, by common extension, BEL.
                if byte == 0x1B { state = .stringEscape } else if byte == 0x07 { state = .text }
            case .stringEscape:
                // `ESC \` ends it; any other ESC-something inside it does not.
                state = byte == UInt8(ascii: "\\") ? .text : .string
            case .parameters:
                switch byte {
                case UInt8(ascii: "?"), UInt8(ascii: ">"), UInt8(ascii: "<"), UInt8(ascii: "="):
                    // A private introducer, and only in the first position.
                    if parameters.isEmpty, introducer == 0 { introducer = byte } else { state = .text }
                case 0x30...0x3B:  // digits, `:` and `;`
                    if parameters.count < Self.maximumParameters {
                        parameters.append(byte)
                    } else {
                        state = .text
                    }
                case 0x40...0x7E:  // the final byte
                    sequence(introducer, String(decoding: parameters, as: UTF8.self), byte)
                    state = .text
                case 0x1B:
                    state = .escape
                default:
                    state = .text
                }
            }
        }
    }
}

/// Each session's modes, on disk, because the process that knows them is the
/// one that is quitting.
///
/// Small, rewritten only when something changes, and unreadable or missing is
/// simply "nothing to restore" — the state it had before this existed.
enum TerminalModeStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wortel/terminal-modes.json")
    }

    /// One session's record. Modes are a `[String: Bool]` because JSON keys are
    /// strings; the numbers are what the terminal calls them.
    struct Record: Codable, Equatable {
        var modes: [String: Bool]
        var keyboardFlags: UInt8?
    }

    static func encode(_ modes: [UUID: TerminalModes]) -> Data? {
        var records: [String: Record] = [:]
        for (session, state) in modes where !state.isEmpty {
            records[session.uuidString] = Record(
                modes: Dictionary(uniqueKeysWithValues:
                    state.privateModesForStorage.map { (String($0.key), $0.value) }),
                keyboardFlags: state.keyboardFlags)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(records)
    }

    static func decode(_ data: Data) -> [UUID: TerminalModes] {
        guard let records = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        var result: [UUID: TerminalModes] = [:]
        for (key, record) in records {
            guard let session = UUID(uuidString: key) else { continue }
            var modes = TerminalModes()
            for (mode, on) in record.modes {
                guard let number = Int(mode) else { continue }
                modes.restore(mode: number, on: on)
            }
            modes.restore(keyboardFlags: record.keyboardFlags)
            if !modes.isEmpty { result[session] = modes }
        }
        return result
    }

    static func load() -> [UUID: TerminalModes] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return decode(data)
    }

    /// Best-effort. A failure here costs a paste its brackets after the *next*
    /// relaunch, which is the behaviour this whole file replaces, and never a
    /// session.
    static func save(_ modes: [UUID: TerminalModes]) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = encode(modes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension TerminalModes {
    /// The modes as stored: only the restorable ones, which is all `feed` keeps
    /// anyway, and exposed separately so the store isn't reaching into the
    /// parser's private state.
    var privateModesForStorage: [Int: Bool] { privateModes }

    mutating func restore(mode: Int, on: Bool) {
        guard Self.restorable.contains(mode) else { return }
        privateModes[mode] = on
    }

    mutating func restore(keyboardFlags flags: UInt8?) {
        keyboardFlags = flags
    }
}

/// What every session's terminal has been told, kept current and written down.
///
/// Fed from the pty read thread, read on the main thread when a surface is
/// built, so everything here is behind a lock. The write to disk is debounced:
/// the modes this tracks are set at a program's startup and then left alone, so
/// in practice it is one small write when an agent launches and nothing at all
/// for the rest of the session.
final class TerminalModeRecorder: @unchecked Sendable {
    static let shared = TerminalModeRecorder()

    /// Long enough that a program declaring six modes in a row writes once.
    static let saveDelay: TimeInterval = 2

    private let lock = NSLock()
    private var modes: [UUID: TerminalModes]
    private var scanners: [UUID: CSIScanner] = [:]
    private var saveScheduled = false

    init(modes: [UUID: TerminalModes] = TerminalModeStore.load()) {
        self.modes = modes
    }

    func modes(for session: UUID) -> TerminalModes {
        lock.lock()
        defer { lock.unlock() }
        return modes[session] ?? TerminalModes()
    }

    /// Watch output on its way to the terminal.
    func feed(session: UUID, bytes: UnsafePointer<UInt8>, count: Int) {
        lock.lock()
        var state = modes[session] ?? TerminalModes()
        var scanner = scanners[session] ?? CSIScanner()
        state.feed(bytes, count: count, parser: &scanner)
        scanners[session] = scanner
        let changed = state != modes[session]
        modes[session] = state
        let schedule = changed && !saveScheduled
        if schedule { saveScheduled = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.saveDelay) {
            [weak self] in self?.save()
        }
    }

    func feed(session: UUID, replay: Data) {
        replay.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            feed(session: session, bytes: base, count: raw.count)
        }
    }

    /// The session is closed, and so its terminal's state is nobody's. Without
    /// this the file grows by one entry per session ever opened.
    func forget(session: UUID) {
        lock.lock()
        modes.removeValue(forKey: session)
        scanners.removeValue(forKey: session)
        lock.unlock()
        save()
    }

    func save() {
        lock.lock()
        saveScheduled = false
        let snapshot = modes
        lock.unlock()
        TerminalModeStore.save(snapshot)
    }
}
