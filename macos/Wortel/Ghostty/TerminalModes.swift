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
/// **`?2031` is the same bug wearing different clothes.** An agent subscribes
/// to theme changes once, at startup, and from then on trusts the terminal to
/// say when the Mac goes light or dark. A resumed session's terminal never got
/// that subscription, so ghostty stays quiet, and the agent keeps painting the
/// palette it picked hours ago: dark-background diff blocks on a white screen,
/// or a white prompt box on a dark one. Nothing recovers on its own, because
/// the agent has no reason to ask again.
///
/// **No longer what restores a terminal.** Since protocol 2 the keeper keeps
/// each session's terminal, and its snapshot carries every mode. The record
/// stays, fed by the live output (`KeptTerminalFeed`) and kept on disk
/// (`TerminalModeStore`), for the few readers in the app that ask it what a
/// program has on (`docs/terminal-modes.md`), until they ask the keeper.
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
    /// - `2031` theme change notifications: the terminal reports light/dark to
    ///   the program, which is how an agent follows the system appearance.
    /// - `67` backspace sends delete, `1036`/`1039` meta sends escape:
    ///   keyboard shape, set at startup by editors.
    ///
    /// Deliberately **not** `25` (cursor visibility), `12` (cursor blink) or
    /// `2026` (synchronised output): a TUI toggles those every frame, so
    /// recording them would mean writing to disk continuously to restore a
    /// state that is one frame old anyway.
    static let restorable: Set<Int> = [
        1, 9, 67, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016,
        1036, 1039, 1047, 1048, 1049, 2004, 2031,
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

    /// What to write into a terminal to take back what a program switched
    /// on, for a program that is being ended and may not do it itself.
    ///
    /// Claude Code leaves on SIGTERM and tidies up first. Codex has no handler
    /// for any signal: it is simply gone, and the shell is left on the
    /// alternate screen with mouse reporting on, so the prompt is drawn where
    /// it does not belong and every move of the mouse types at it (measured
    /// 2026-11-19, Codex 0.170, SIGTERM, SIGHUP and SIGINT alike).
    ///
    /// Every mode on record as on is turned off, the alternate screen last so
    /// that what is undone before it is undone where it was set. The keyboard
    /// flags are popped on both screens, which keep a stack each; a pop of
    /// nothing does nothing. Then the cursor, which a TUI hides, and the wheel
    /// scrolling a pager (`?1007`, this terminal's default, which Codex turns
    /// off): neither is on record, and both are what a shell expects.
    ///
    /// Written **before** the signal, so the shell's next prompt, which turns
    /// bracketed paste back on for itself, comes after it.
    var undo: [UInt8] {
        let screens: Set<Int> = [1047, 1048, 1049]
        let on = privateModes.filter(\.value).keys.sorted()
        var out = keyboardFlags == nil ? "" : "\u{1B}[<u"
        for mode in on where !screens.contains(mode) { out += "\u{1B}[?\(mode)l" }
        let left = on.filter(screens.contains)
        for mode in left { out += "\u{1B}[?\(mode)l" }
        if keyboardFlags != nil, !left.isEmpty { out += "\u{1B}[<u" }
        if out.isEmpty { return [] }
        return Array((out + "\u{1B}[?25h\u{1B}[?1007h").utf8)
    }

    /// Whether the program asked to be told when the system appearance changes
    /// (`?2031`). The prelude puts the mode back in the *terminal*; this asks a
    /// different question — is anyone on the far side listening — and it is the
    /// one that decides whether anything may be written into the program's
    /// input at all.
    var wantsColorSchemeReports: Bool { privateModes[2031] == true }

    /// Whether the program owns the whole screen and hears a change of light
    /// and dark (`?2031` while on the alternate screen), so it puts every cell
    /// it coloured right by itself when told. Claude Code's fullscreen
    /// renderer does: on the report it repaints each cell in its own colours,
    /// including after a hibernation (measured 2026-11-19, 2.1.329, in a copy
    /// of the app). Its inline renderer does not: what it printed before
    /// keeps the old colours, which is why this needs the alternate screen.
    /// Codex is on the alternate screen but has no `?2031`.
    var repaintsItselfOnSchemeChange: Bool {
        wantsColorSchemeReports && (privateModes[1049] == true || privateModes[1047] == true)
    }

    /// Whether the program has bracketed paste on, so a pasted newline is
    /// text and not Return. False when nobody recorded it (the exec backend
    /// records nothing), which is the safe way to be wrong for a paste.
    var bracketedPaste: Bool { privateModes[2004] == true }

    /// What an agent is known to switch on at startup, and keeps on while it
    /// runs: Claude Code writes `?2004h?2031h?1004h` before anything else.
    static let agentStartupModes: [String: [Int]] = ["claude": [1004, 2004, 2031]]

    /// These modes with what the agent running in the session is known to
    /// have set, whatever was recorded.
    ///
    /// The record misses an agent's startup more often than it should: one
    /// Wortel resumed starts while nobody is attached, and reprinting a long
    /// conversation pushes its first bytes out of the keeper's 512 KB replay
    /// before anyone reads them. 8 Claude sessions out of 9 had no `?2031` on
    /// record (2026-10-15), so a Mac that went light kept them painting dark
    /// diff blocks on a white screen. The agent's marker says it is running
    /// now, which is the better word: it is newer than any record.
    func assuming(agent: String?) -> TerminalModes {
        guard let agent, let modes = Self.agentStartupModes[agent] else { return self }
        var assumed = self
        for mode in modes { assumed.privateModes[mode] = true }
        return assumed
    }

    /// What a terminal sends a program that turned `?2031` on: `CSI ? 997 ; 1 n`
    /// for dark, `; 2 n` for light. The same bytes ghostty writes on a live
    /// appearance change, which is the point — the program cannot tell a
    /// resumed session's catch-up report from the real thing, and shouldn't.
    static func colorSchemeReport(dark: Bool) -> [UInt8] {
        Array("\u{1B}[?997;\(dark ? 1 : 2)n".utf8)
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
/// It reads only the shape `ESC [ <introducer> <parameters> <final>` and
/// ignores everything else, including the text the terminal is actually
/// printing. It is not a terminal: libghostty is, and this must never become a
/// second one.
///
/// **Only sequences with a private introducer** (`?`, `>`, `<`, `=`) are
/// reported, because every mode lives in one. The rest are mostly SGR, the
/// most common sequence a TUI writes, and building a string for each one made
/// the scan of a busy session's output ten times slower than it needs to be.
struct CSIScanner {
    private enum State {
        case text
        case escape
        case parameters
        /// A sequence with no private introducer: waiting for its end.
        case skipping
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
                    if introducer == 0 {
                        state = .skipping
                    } else if parameters.count < Self.maximumParameters {
                        parameters.append(byte)
                    } else {
                        state = .text
                    }
                case 0x40...0x7E:  // the final byte
                    if introducer != 0 {
                        sequence(introducer, String(decoding: parameters, as: UTF8.self), byte)
                    }
                    state = .text
                case 0x1B:
                    state = .escape
                default:
                    state = .text
                }
            case .skipping:
                switch byte {
                case 0x30...0x3B: break
                case 0x1B: state = .escape
                default: state = .text
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
        DataDirectory.file("terminal-modes.json")
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

    /// Take a mode that is on off the record, as though nobody had
    /// mentioned it. One turned off outright stays as it is.
    mutating func forget(mode: Int) {
        if privateModes[mode] == true { privateModes[mode] = nil }
    }

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

    /// Write down what a running agent is known to have switched on, and give
    /// back the record with it.
    ///
    /// `assuming(agent:)` alone was acted on at a reattach (the prelude put the
    /// modes into the new terminal) and then forgotten, so the record and the
    /// terminal disagreed from that moment. A hibernation takes its prelude
    /// from the record: the terminal that session woke with had no `?2031`
    /// and no bracketed paste, and its agent was not sent the appearance
    /// either. What the terminal is told, the record says.
    func assume(agent: String?, in session: UUID) -> TerminalModes {
        lock.lock()
        let before = modes[session] ?? TerminalModes()
        let after = before.assuming(agent: agent)
        let changed = after != before
        if changed { modes[session] = after }
        let schedule = changed && !saveScheduled
        if schedule { saveScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.saveDelay) {
                [weak self] in self?.save()
            }
        }
        return after
    }

    /// The agent in `session` has gone: what it is known to switch on at
    /// startup, and is still on record as on, is taken off the record.
    ///
    /// `assume` writes those modes down for a running agent whether or not
    /// it was seen setting them. One that leaves tidily turns them off
    /// itself and there is nothing here to do. One that was killed, or never
    /// set them (`claude -p`), would otherwise have them on record for good:
    /// every later wake and relaunch put focus reporting into a plain
    /// shell's terminal and wrote a theme report at its prompt. Bracketed
    /// paste is left, because the shell at its prompt has it on itself.
    func forgetStartupModes(of agent: String, in session: UUID) {
        guard let startup = TerminalModes.agentStartupModes[agent] else { return }
        lock.lock()
        guard var state = modes[session] else { lock.unlock(); return }
        let before = state
        for mode in startup where mode != 2004 { state.forget(mode: mode) }
        let changed = state != before
        if changed { modes[session] = state }
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

    /// Forget every terminal but `live`'s: entries for sessions that went away
    /// without a `forget` (a crash, a build from before it was called on every
    /// path). Run once at launch, after the session list is known to be whole.
    func keepOnly(_ live: Set<UUID>) {
        lock.lock()
        let stale = modes.keys.filter { !live.contains($0) }
        for id in stale {
            modes.removeValue(forKey: id)
            scanners.removeValue(forKey: id)
        }
        lock.unlock()
        if !stale.isEmpty { save() }
    }

    func save() {
        lock.lock()
        saveScheduled = false
        let snapshot = modes
        lock.unlock()
        TerminalModeStore.save(snapshot)
    }
}
