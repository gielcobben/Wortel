import Foundation

/// The signals a terminal raises, read straight off a session's output while
/// it has no terminal to raise them (a hibernated one, `SurfaceView.hibernate`).
///
/// Everything the sidebar knows about a session's work arrives as a libghostty
/// action: the title (and with it an agent's spinner), the cwd, a bell, OSC
/// 9;4 progress, OSC 133 command ends, desktop notifications. With no surface
/// nothing parses the output, so a hibernated agent that finished its turn
/// would sit there "working" until somebody looked. This reads the same
/// sequences, the same way, and raises the same callbacks.
///
/// **It also takes them out.** The output is kept for the terminal that comes
/// back, and written into it then; a signal left in would be raised a second
/// time, late, by that terminal: the same "needs you" twice, a turn announced
/// as ended after you had already read it. So `scan` hands back the bytes
/// without the signals in them. Nothing else is removed, and what it doesn't
/// recognise passes through untouched.
///
/// Mirrors libghostty's parser for these sequences only, with its limits:
/// - OSC 0 and 2 set the title (1 is the icon name, ignored); a title that is
///   not UTF-8, or longer than `maximumLength`, is ignored.
/// - OSC 7 reports the cwd: `file://` or `kitty-shell-cwd://`, from this host.
/// - BEL outside a sequence rings the bell. Inside one it ends the sequence.
/// - OSC 9;4;state is progress. OSC 9 with any other ConEmu subcommand is
///   ignored, and OSC 9 with plain text is a notification with no title.
/// - OSC 777;notify;title;body, and kitty's OSC 99, are notifications.
/// - OSC 133;C starts a command and 133;D[;exit] ends it, with how long it ran.
///   Only D is taken out: the other prompt marks raise nothing and the
///   terminal needs them.
///
/// Not thread-safe: one per session, fed on that session's pty queue.
struct SignalScanner {
    enum Signal: Equatable {
        case title(String)
        case pwd(String)
        case bell
        case progress(active: Bool, errored: Bool)
        case commandFinished(exitCode: Int, durationNs: UInt64)
        case notification(title: String, body: String)
    }

    /// The longest OSC body kept. libghostty drops longer ones.
    static let maximumLength = 2048

    private enum State {
        case ground
        /// After ESC, deciding what kind of sequence this is.
        case escape
        /// Inside an OSC whose number is still being read (`body`).
        case oscNumber
        /// Inside an OSC that is a signal: kept, and taken out of the output.
        case oscSignal
        /// Inside an OSC that is not: passed through as it comes.
        case oscPassing
        /// Inside a DCS, APC, PM or SOS string: passed through; a BEL in
        /// there is not a bell.
        case string
    }

    private var state = State.ground
    /// ESC seen inside an OSC or string: the next byte decides whether it
    /// was the string terminator (`ESC \`).
    private var pendingEscape = false
    private var body: [UInt8] = []
    private var overflowed = false
    private var number: Int?
    private var commandStartedAt: UInt64?
    /// Reads the notification sequences, as the terminal's listener does
    /// (`TerminalNotificationReader`): one set of rules for both.
    private var notifications = TerminalNotificationReader()

    private static let signalNumbers: Set<Int> = [0, 1, 2, 7, 9, 99, 133, 777]

    /// Read `bytes`, return the signals in them in order, and append to
    /// `output` everything that is not a signal. `now` is a monotonic time in
    /// nanoseconds, for how long a command ran.
    mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>, now: UInt64,
                       output: inout [UInt8]) -> [Signal] {
        var signals: [Signal] = []
        for byte in bytes { step(byte, now: now, output: &output, signals: &signals) }
        return signals
    }

    /// The bytes of a sequence that is still open: held back, so neither in
    /// the output nor raised. When the terminal comes back they go to it
    /// first, and it reads the rest of the sequence as it arrives.
    var unfinished: [UInt8] {
        let escape: [UInt8] = pendingEscape ? [0x1B] : []
        switch state {
        case .ground: return []
        case .escape: return [0x1B]
        case .oscNumber: return [0x1B, 0x5D] + body + escape
        case .oscSignal:
            guard let number else { return [] }
            return [0x1B, 0x5D] + Array("\(number);".utf8) + body + escape
        case .oscPassing, .string: return escape
        }
    }

    private mutating func step(_ byte: UInt8, now: UInt64, output: inout [UInt8], signals: inout [Signal]) {
        switch state {
        case .ground:
            if byte == 0x1B {
                state = .escape
            } else if byte == 0x07 {
                signals.append(.bell)
            } else {
                output.append(byte)
            }

        case .escape:
            switch byte {
            case 0x5D: // ]
                state = .oscNumber
                body.removeAll(keepingCapacity: true)
                overflowed = false
                number = nil
            case 0x50, 0x5F, 0x5E, 0x58: // P _ ^ X
                output += [0x1B, byte]
                state = .string
            case 0x1B:
                output.append(0x1B) // a lone ESC; this one may start something
            default:
                output += [0x1B, byte]
                state = .ground
            }

        case .string:
            if pendingEscape {
                pendingEscape = false
                if byte == 0x5C {
                    output += [0x1B, 0x5C]
                    state = .ground
                } else {
                    // ESC that is not the terminator ends the string and
                    // starts a sequence of its own.
                    state = .escape
                    step(byte, now: now, output: &output, signals: &signals)
                }
            } else if byte == 0x1B {
                pendingEscape = true
            } else {
                output.append(byte)
                if byte == 0x18 || byte == 0x1A { state = .ground }
            }

        case .oscNumber, .oscSignal, .oscPassing:
            if pendingEscape {
                pendingEscape = false
                if byte == 0x5C {
                    if let signal = finishOSC(terminator: [0x1B, 0x5C], now: now, output: &output) {
                        signals.append(signal)
                    }
                } else {
                    // ESC not followed by `\`: the OSC is cut off, and this
                    // ESC starts whatever comes next.
                    abandonOSC(output: &output)
                    state = .escape
                    step(byte, now: now, output: &output, signals: &signals)
                }
                return
            }
            switch byte {
            case 0x07:
                if let signal = finishOSC(terminator: [0x07], now: now, output: &output) { signals.append(signal) }
            case 0x1B:
                pendingEscape = true
            case 0x18, 0x1A: // CAN, SUB: cancelled
                abandonOSC(output: &output)
                output.append(byte)
                state = .ground
            default:
                oscByte(byte, output: &output)
            }
        }
    }

    /// One byte of an OSC's content.
    private mutating func oscByte(_ byte: UInt8, output: inout [UInt8]) {
        switch state {
        case .oscNumber:
            if byte == 0x3B { // ;
                number = Int(String(decoding: body, as: UTF8.self))
                if let number, Self.signalNumbers.contains(number) {
                    state = .oscSignal
                    body.removeAll(keepingCapacity: true)
                } else {
                    output += [0x1B, 0x5D] + body + [byte]
                    state = .oscPassing
                }
            } else if (0x30...0x39).contains(byte), body.count < 8 {
                body.append(byte)
            } else {
                output += [0x1B, 0x5D] + body + [byte]
                state = .oscPassing
            }
        case .oscSignal:
            if body.count < Self.maximumLength { body.append(byte) } else { overflowed = true }
        default:
            output.append(byte)
        }
    }

    private mutating func finishOSC(terminator: [UInt8], now: UInt64, output: inout [UInt8]) -> Signal? {
        defer {
            state = .ground
            body.removeAll(keepingCapacity: true)
        }
        switch state {
        case .oscPassing:
            output += terminator
            return nil
        case .oscNumber:
            // No `;` at all: `OSC 133 ST` and the like say nothing here, and
            // anything else is the terminal's to read.
            let digits = Int(String(decoding: body, as: UTF8.self))
            if let digits, Self.signalNumbers.contains(digits) { return nil }
            output += [0x1B, 0x5D] + body + terminator
            return nil
        default:
            guard !overflowed, let number,
                  let text = String(bytes: body, encoding: .utf8) else { return nil }
            // Prompt marks other than a command's end raise nothing, and the
            // terminal that comes back needs them to know where its prompts
            // are (whether closing it would interrupt something).
            if number == 133, !text.hasPrefix("D") {
                output += Array("\u{1B}]133;".utf8) + body + terminator
            }
            return signal(number: number, text: text, now: now)
        }
    }

    /// An OSC that never finished. One that was passing through has already
    /// gone out; a signal is dropped, as the terminal would have.
    private mutating func abandonOSC(output: inout [UInt8]) {
        if state == .oscNumber { output += [0x1B, 0x5D] + body }
        body.removeAll(keepingCapacity: true)
    }

    private mutating func signal(number: Int, text: String, now: UInt64) -> Signal? {
        switch number {
        case 0, 2:
            return .title(text)
        case 7:
            return Self.pwd(from: text).map(Signal.pwd)
        case 9:
            return Self.progress(text) ?? notification(number: number, text: text)
        case 777, 99:
            return notification(number: number, text: text)
        case 133:
            return semanticPrompt(text, now: now)
        default:
            return nil
        }
    }

    private mutating func notification(number: Int, text: String) -> Signal? {
        notifications.read(number: number, text: text).map { .notification(title: $0.title, body: $0.body) }
    }

    /// OSC 9;4: ConEmu's progress, the one of its subcommands that means
    /// anything here. nil for anything else.
    private static func progress(_ text: String) -> Signal? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.first == "4", parts.count >= 2, let state = Int(parts[1]) else { return nil }
        switch state {
        case 0, 4: return .progress(active: false, errored: false) // remove, pause
        case 1, 3: return .progress(active: true, errored: false)  // set, indeterminate
        case 2: return .progress(active: true, errored: true)      // error
        default: return nil
        }
    }

    /// OSC 133: C is a command starting, D one ending, with its exit code if
    /// the shell gave one (-1 if not, as libghostty reports it).
    private mutating func semanticPrompt(_ text: String, now: UInt64) -> Signal? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        switch parts.first {
        case "C":
            commandStartedAt = now
            return nil
        case "D":
            let exit = parts.count > 1 ? Int(parts[1]) ?? -1 : -1
            let duration = commandStartedAt.map { now >= $0 ? now - $0 : 0 } ?? 0
            commandStartedAt = nil
            return .commandFinished(exitCode: exit, durationNs: duration)
        default:
            return nil
        }
    }

    /// OSC 7's URL as a path, when it names a directory on this Mac.
    static func pwd(from text: String) -> String? {
        guard let components = URLComponents(string: text),
              components.scheme == "file" || components.scheme == "kitty-shell-cwd",
              let host = components.host, !host.isEmpty, isLocal(host: host)
        else { return nil }
        let path = components.path
        return path.isEmpty ? nil : path
    }

    private static func isLocal(host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" { return true }
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return false }
        let name = String(cString: buffer).lowercased()
        return lowered == name || lowered == name.split(separator: ".").first.map(String.init)
            || name.split(separator: ".").first.map(String.init) == lowered
    }
}
