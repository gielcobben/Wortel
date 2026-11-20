import Foundation

/// What a program says it is doing, in its own words: one report of the
/// Program Status Protocol (OSC 7501).
///
/// `ESC ] 7501 ; state=blocked:kind=permission:app=codex ESC \`
///
/// This is the one signal about an agent that is not a guess. Everything else
/// Wortel reads (a title spinner, a screen that stopped moving, the words in a
/// notification) is evidence, and every false alarm in `docs/incidents.md`
/// about a dot is one piece of evidence overruling another. A program that
/// sends this is taken at its word, and the guessing stops for it
/// (`docs/agent-signals.md`).
///
/// Spec: https://www.superlogical.com/rex/docs/build/program-status. Codex
/// sends reports unasked; Claude Code and Pi ask first (`ProgramStatusReport
/// .query`) and report only to a terminal that answers.
///
/// A report is about the program itself (the root record) or, with an `id`,
/// about one piece of its work: Claude Code lists its background commands,
/// monitors and remote agents that way. `ProgramRecords` holds them all and
/// says what the session comes to.
struct ProgramStatus: Equatable {
    enum State: String {
        /// At rest, waiting for the next instruction. Also what an
        /// interrupted turn reports: nothing to announce.
        case idle
        case working
        /// Finished a piece of work the user has not seen yet.
        case done
        /// Cannot continue until the user does something (`kind`).
        case blocked
        /// Failed and stopped.
        case error
    }

    /// What a blocked program is waiting for.
    enum Kind: String {
        /// Approval to do something.
        case permission
        /// The user must type or pick an answer.
        case question
        /// A login, token or credential.
        case auth
    }

    var state: State
    /// Only with `.blocked`.
    var kind: Kind?
    /// The program's stable name: `codex`, `claude-code`, `pi`.
    var app: String?
    /// One line from the program about its state, already made safe to show
    /// outside the terminal (`ProgramStatusReport.displayable`).
    var message: String?
    /// Which record: nil for the program itself, else a path naming one piece
    /// of its work (`build/test`). `/` makes a record a child of another.
    var id: String?
    /// A label for a record that is not the root, made safe like `message`.
    var title: String?
}

/// One OSC 7501 sequence, read.
enum ProgramStatusReport: Equatable {
    /// `OSC 7501 ; ? ST`: the program asking whether the terminal speaks the
    /// protocol. The answer is `reply`, and a program that gets none treats
    /// the protocol as unsupported for as long as it runs.
    case query
    /// The root record is now this.
    case status(ProgramStatus)
    /// `state=clear` with no id: every record is gone. The program exited,
    /// was suspended, or handed the terminal to something else.
    case clear
    /// `state=clear` with an id: that record and every record beneath it.
    case clearRecord(String)

    /// What a supporting terminal answers a query with. No `states=` or
    /// `kinds=`: without them the reply means exactly the spec's fixed lists,
    /// which are the ones read here.
    static let reply = Array("\u{1B}]7501;?\u{1B}\\".utf8)

    // The spec's limits. A report that breaks one is discarded whole, so a
    // hostile or broken program cannot make memory grow.
    /// OSC through ST.
    static let maximumSequenceLength = 4096
    static let maximumKeyLength = 16
    static let maximumEncodedMessage = 2732
    static let maximumDecodedMessage = 2048
    static let maximumEncodedTitle = 256
    static let maximumDecodedTitle = 192
    static let maximumAppLength = 32
    static let maximumIDLength = 128
    static let maximumIDSegment = 32
    static let maximumIDDepth = 8

    /// Read the body of an OSC 7501 (what comes after `7501;`). nil for a
    /// report the spec says to ignore or discard.
    static func parse(_ body: [UInt8]) -> ProgramStatusReport? {
        guard let text = String(bytes: body, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // A query is `?` alone. A reply (the terminal's side) carries pairs
        // after it and is never something a program sends, but reading it as
        // a query would have two terminals asking each other for ever.
        if trimmed == "?" { return .query }
        if trimmed.hasPrefix("?") { return nil }

        var pairs: [String: String] = [:]
        for pair in trimmed.split(separator: ":", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // A limit broken discards the report whole; a malformed pair is
            // only skipped, and the rest still read.
            guard key.utf8.count <= maximumKeyLength else { return nil }
            guard !key.isEmpty, key.utf8.allSatisfy({ (0x61...0x7A).contains($0) }),
                  value.utf8.allSatisfy(isValueByte) else {
                // Except an id: skipped, its report would land on the root,
                // and `state=clear:id=a b` would clear everything.
                if key == "id" { return nil }
                continue
            }
            pairs[key] = value // a repeated key: the last one wins
        }
        if let app = pairs["app"], app.utf8.count > maximumAppLength { return nil }

        // Free text is checked before anything is applied: bad base64 or a
        // control character discards the whole report.
        var message: String?
        if let encoded = pairs["msg"] {
            guard let decoded = decode(encoded, maximumEncoded: maximumEncodedMessage,
                                       maximumDecoded: maximumDecodedMessage) else { return nil }
            message = displayable(decoded)
        }
        var title: String?
        if let encoded = pairs["title"] {
            guard let decoded = decode(encoded, maximumEncoded: maximumEncodedTitle,
                                       maximumDecoded: maximumDecodedTitle) else { return nil }
            title = displayable(decoded)
        }

        // An id that is no valid id ignores the report: falling back to the
        // root would let a malformed one overwrite it.
        let id = pairs["id"]
        if let id, !isRecordID(id) { return nil }
        guard let stateName = pairs["state"] else { return nil }
        if stateName == "clear" { return id.map(ProgramStatusReport.clearRecord) ?? .clear }
        // An unrecognised state ignores the whole report, so one added later
        // never turns into `idle` here.
        guard let state = ProgramStatus.State(rawValue: stateName) else { return nil }

        var status = ProgramStatus(state: state)
        status.id = id
        if id != nil, let title, !title.isEmpty { status.title = title }
        if state == .blocked { status.kind = pairs["kind"].flatMap(ProgramStatus.Kind.init(rawValue:)) }
        // Outside its own character set an app name is absent, not an error.
        if let app = pairs["app"], !app.isEmpty, app.utf8.allSatisfy(isAppByte) { status.app = app }
        if let message, !message.isEmpty { status.message = message }
        return .status(status)
    }

    /// `[A-Za-z0-9_.,+/=-]`: the value set leaves out `:` and `;`, so nothing
    /// in a report needs escaping.
    private static func isValueByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x5F, 0x2E, 0x2C, 0x2B, 0x2F, 0x3D, 0x2D: return true // _ . , + / = -
        default: return false
        }
    }

    /// `segment ("/" segment)*`, each segment `[A-Za-z0-9_.+-]{1,32}`, at most
    /// eight deep and 128 bytes.
    private static func isRecordID(_ id: String) -> Bool {
        guard id.utf8.count <= maximumIDLength else { return false }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        return segments.count <= maximumIDDepth && segments.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= maximumIDSegment && $0.utf8.allSatisfy(isAppByte)
        }
    }

    /// `[A-Za-z0-9_.+-]`, narrower than a value.
    private static func isAppByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x5F, 0x2E, 0x2B, 0x2D: return true // _ . + -
        default: return false
        }
    }

    /// Standard base64 of UTF-8, padding optional. nil when it is too long,
    /// does not decode, or holds a control character.
    private static func decode(_ encoded: String, maximumEncoded: Int, maximumDecoded: Int) -> String? {
        guard encoded.utf8.count <= maximumEncoded else { return nil }
        var padded = encoded
        while padded.utf8.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded), data.count <= maximumDecoded,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F: return nil
            default: continue
            }
        }
        return text
    }

    /// A program's words on their way out of the terminal's grid, into a
    /// banner: without the characters that turn text around or hide in it.
    /// The text is from whatever is running in the terminal, which is not
    /// always what the user thinks is running there.
    static func displayable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, // zero width, and the direction marks
                 0x202A...0x202E, // embeddings and overrides
                 0x2060...0x2069, // word joiner, invisible operators, isolates
                 0xFEFF:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

extension ProgramStatusReport {
    /// For the log: which record, its state and why it is blocked, and
    /// whether it came with words. Never the words themselves, nor a
    /// record's title: those are the user's work, and nothing else in the
    /// log spells that out either.
    var logDescription: String {
        switch self {
        case .query: return "query"
        case .clear: return "clear"
        case .clearRecord(let id): return "clear record=\(id)"
        case .status(let status):
            var text = status.state.rawValue
            if let kind = status.kind { text += "/\(kind.rawValue)" }
            if let app = status.app { text += " app=\(app)" }
            if let id = status.id { text += " record=\(id)" }
            if status.message != nil { text += " +msg" }
            return text
        }
    }
}

/// Everything a terminal's program has reported: the record for the program
/// itself and one for each piece of work it named, as the spec has a terminal
/// hold them.
///
/// Pure. `effective` is the one question the rest of Wortel asks of it.
struct ProgramRecords: Equatable {
    /// How many records besides the root are kept. The spec asks for at
    /// least 64; past it the one updated longest ago makes room.
    static let maximumChildren = 64

    private(set) var root: ProgramStatus?
    private(set) var children: [String: ProgramStatus] = [:]
    /// The root said `done` while a piece of its work was still unfinished,
    /// and that work has not all ended since: the turn is held open
    /// (`standing`). Set only by the `done` itself, so work listed after a
    /// turn was over changes nothing.
    private(set) var finishHeld = false
    /// Child ids, least recently updated first.
    private var order: [String] = []

    init(root: ProgramStatus? = nil) {
        self.root = root
    }

    /// The child records, least recently updated first.
    var childrenInOrder: [ProgramStatus] { order.compactMap { children[$0] } }

    /// Take a report in. Each one replaces its record completely. A `clear`
    /// of everything is the caller's to act on: the program has gone.
    mutating func apply(_ report: ProgramStatusReport) {
        switch report {
        case .query:
            break
        case .clear:
            root = nil
            children = [:]
            order = []
            finishHeld = false
        case .clearRecord(let id):
            let beneath = id + "/"
            order.removeAll { $0 == id || $0.hasPrefix(beneath) }
            children = children.filter { $0.key != id && !$0.key.hasPrefix(beneath) }
            if !hasUnfinishedWork { finishHeld = false }
        case .status(let status):
            guard let id = status.id else {
                root = status
                finishHeld = status.state == .done && hasUnfinishedWork
                return
            }
            children[id] = status
            order.removeAll { $0 == id }
            order.append(id)
            if order.count > Self.maximumChildren { children[order.removeFirst()] = nil }
            if !hasUnfinishedWork { finishHeld = false }
        }
    }

    /// What the program is waiting on the user for, if anything: its own
    /// record when that is `blocked`, else a piece of its work that is. A
    /// blocked piece is the program waiting on the user whatever the root says
    /// meanwhile ("both are true, and the terminal decides which to show"):
    /// Claude Code's root reads `done` while a remote agent it started waits
    /// for an answer.
    ///
    /// Kept apart from the root on purpose. The root says whether the program
    /// is working or has finished; this says whether it wants an answer. One
    /// changing must not look like the other changing: a question answered
    /// while the root reads `done` is not a second finished turn.
    var block: ProgramStatus? {
        if let root, root.state == .blocked { return root }
        // The first by id, so which one is shown does not move as others
        // report.
        guard let waiting = children.values.filter({ $0.state == .blocked })
            .min(by: { ($0.id ?? "") < ($1.id ?? "") }) else { return nil }
        let words = [waiting.title, waiting.message].compactMap { $0 }.joined(separator: ": ")
        return ProgramStatus(state: .blocked, kind: waiting.kind, app: waiting.app ?? root?.app,
                             message: words.isEmpty ? nil : words)
    }

    /// Whether the program is at work, as the person is shown it: its own
    /// record, except that one at rest (`done` or `idle`) with a piece of its
    /// work still `working` is working. Claude Code ends a turn with `done`
    /// while a background command, a monitor or a remote agent it started is
    /// still going, and when that ends it carries on by itself; its root
    /// says `working` for that wait only sometimes. So the turn is not over,
    /// and the row keeps its spinner until everything is done
    /// (2026-11-20, chosen by the person: busy until all done, even for a
    /// monitor that runs for hours). Only a `done` holds, and only with work
    /// unfinished at that moment (`finishHeld`): `idle` is a stop (Esc), and
    /// work listed after a turn was announced does not take the
    /// announcement back. `blocked` and `error` stand as they are: they are
    /// news.
    var standing: ProgramStatus? {
        guard let root, root.state == .done, finishHeld, hasUnfinishedWork else { return root }
        return ProgramStatus(state: .working, app: root.app)
    }

    /// A piece of work still going, or waiting on the person: a background
    /// agent that asked a question carries on once answered.
    var hasUnfinishedWork: Bool {
        children.values.contains { $0.state == .working || $0.state == .blocked }
    }

    /// What the session comes to, in one status: blocked if anything in it
    /// is, else whether it is at work (`standing`).
    var effective: ProgramStatus? { block ?? standing }

    /// What the program said of itself, and what it waits on the person for:
    /// what is kept across a relaunch (`PersistedSession.reportedState`).
    /// Not `standing`: the pieces of work are not kept, so a turn held open
    /// by them would be restored working with nothing left to end it.
    var said: ProgramStatus? { block ?? root }
}

/// Something a program said to its terminal that Wortel acts on.
enum ProgramSignal: Equatable {
    /// What it is doing (OSC 7501).
    case status(ProgramStatusReport)
    /// A notification of its own (OSC 9 with text, 777, 99).
    case notification(TerminalNotification)
}

/// Hears what a program says in a terminal's output as it goes past, in
/// whatever pieces it arrives: its status reports, and its notifications.
///
/// The output is on its way to libghostty, so nothing is taken out: this only
/// listens. libghostty ignores a status report, and Wortel ignores what
/// libghostty makes of a notification (`TerminalNotificationReader` has why).
/// It runs on every read of every pty, `cat` of a large file included, so
/// outside a sequence it does nothing but look for the next ESC, and inside
/// one it gives up at the first byte that shows it is none of these.
///
/// `ESC ]`, a number and `;` start a match, wherever they turn up. Inside
/// another OSC or a DCS string an ESC ends that string, in a terminal as
/// here, so there is no state of the surrounding stream worth tracking.
///
/// Not thread-safe: one per terminal, fed on that terminal's pty queue.
struct ProgramSignalScanner {
    /// The sequences listened for, and the longest body each may have. A
    /// status report's limit is the spec's, on the whole sequence; a
    /// notification's is libghostty's, which drops a longer one.
    private static let limits: [Int: Int] = [
        7501: ProgramStatusReport.maximumSequenceLength - 9, // less `ESC ] 7501 ;` and `ESC \`
        9: 2048, 99: 2048, 777: 2048,
    ]

    private enum State {
        /// Looking for an ESC.
        case ground
        /// After ESC: `]` opens an OSC, anything else is not ours.
        case escape
        /// The OSC's number, up to its `;`.
        case number
        /// The body of one of ours.
        case body
    }

    private var state = State.ground
    private var number = 0
    private var digits = 0
    private var limit = 0
    private var body: [UInt8] = []
    /// ESC seen inside a body: the next byte says whether it was the string
    /// terminator (`ESC \`).
    private var pendingEscape = false
    /// The body outgrew its limit: read to its end, and dropped there.
    private var overflowed = false
    private var notifications = TerminalNotificationReader()

    /// Read `bytes` and return what was said in them, in order.
    mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> [ProgramSignal] {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return [] }
        var heard: [ProgramSignal] = []
        var index = 0
        let count = bytes.count
        while index < count {
            if state == .ground {
                // The whole cost for output that says nothing.
                guard let found = memchr(base + index, 0x1B, count - index) else { break }
                index = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + 1
                state = .escape
                continue
            }
            let byte = bytes[index]
            index += 1
            switch state {
            case .ground:
                break
            case .escape:
                if byte == 0x5D { // ]
                    state = .number
                    number = 0
                    digits = 0
                } else {
                    restart(at: byte)
                }
            case .number:
                if (0x30...0x39).contains(byte), digits < 4 {
                    number = number * 10 + Int(byte - 0x30)
                    digits += 1
                } else if byte == 0x3B, digits > 0, let limit = Self.limits[number] { // ;
                    self.limit = limit
                    state = .body
                    body.removeAll(keepingCapacity: true)
                    overflowed = false
                    pendingEscape = false
                } else {
                    // Another OSC, or none: not ours to read.
                    restart(at: byte)
                }
            case .body:
                if let signal = bodyByte(byte) { heard.append(signal) }
            }
        }
        return heard
    }

    /// Not one of ours after all. An ESC may still be the start of one.
    private mutating func restart(at byte: UInt8) {
        state = byte == 0x1B ? .escape : .ground
    }

    private mutating func bodyByte(_ byte: UInt8) -> ProgramSignal? {
        if pendingEscape {
            pendingEscape = false
            if byte == 0x5C { return finish() }
            // ESC not followed by `\`: the sequence is cut off, and this
            // ESC starts whatever comes next.
            if byte == 0x5D {
                state = .number
                number = 0
                digits = 0
            } else {
                restart(at: byte)
            }
            return nil
        }
        switch byte {
        case 0x07:
            return finish()
        case 0x1B:
            pendingEscape = true
        case 0x18, 0x1A: // CAN, SUB: cancelled
            state = .ground
        default:
            if body.count < limit { body.append(byte) } else { overflowed = true }
        }
        return nil
    }

    private mutating func finish() -> ProgramSignal? {
        state = .ground
        defer { body.removeAll(keepingCapacity: true) }
        guard !overflowed else { return nil }
        if number == 7501 { return ProgramStatusReport.parse(body).map(ProgramSignal.status) }
        guard let text = String(bytes: body, encoding: .utf8) else { return nil }
        return notifications.read(number: number, text: text).map(ProgramSignal.notification)
    }
}
