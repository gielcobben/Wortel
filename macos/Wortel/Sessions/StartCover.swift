import Foundation

/// When to lift the cover over a session that was just made.
///
/// A new session is a login shell with a line typed into it (`claude`, or
/// whatever Settings says: `NewSessionCommand`). Shown as it happens, that is
/// a prompt, the line appearing on it, and the agent's interface popping in
/// half a second to a second and a half later (measured 2026-11-24: the shell
/// takes about 0.2 s, Claude Code's first frame 0.4 to 1.3 s more). None of
/// it can be made faster from here, so it is kept out of sight: the terminal
/// is covered by an empty page (`TerminalHostViewController`) until the
/// program has its interface up, and what is typed meanwhile is held
/// (`PtyHost.holdTyping`) and handed to it then.
///
/// This is the rule alone: events in, the moment and the reason out. It keeps
/// no clock, timer or view of its own, so it can be tested with numbers.
///
/// **What it listens for**, all of it in the session's own output
/// (`StartScanner`), plus the agent's marker:
///
/// - `OSC 133;C`: the shell started the line. Nothing before it counts,
///   because zsh turns bracketed paste on at its own prompt, which reads
///   exactly like a program's interface coming up.
/// - A mode a full-screen program sets as it starts (bracketed paste, focus
///   reports, the alternate screen, the mouse, the keyboard protocol). Then
///   the output going quiet, which is its first frame being whole.
/// - `OSC 133;D` before any of that: the line ended and the shell is back.
/// - The marker (`AgentResumeStore`): the line was an agent. Without one the
///   wait is short, so `wortel new -- npm run dev` is not kept behind a page
///   for an interface it will never have.
///
/// **What is typed is only ever handed to the program the session was made
/// for.** When the cover lifts with the shell in front (the agent is not
/// installed, it exited at once, the shell never ran the line) the keys are
/// dropped: a sentence meant for an agent, with its Return, is a command to a
/// shell.
struct StartCover {
    /// How long each wait lasts, in seconds.
    struct Patience: Equatable {
        /// For the shell to start the line. A shell that takes longer is
        /// asking something, or has no integration to say so.
        var shell: TimeInterval = 3
        /// For the program's interface, once the line has started. Short on
        /// purpose: a start this slow is updating, asking to log in or
        /// stuck, and the terminal says which. The slowest ordinary start
        /// measured was 1.2 s (Pi, 2026-11-24).
        var interface: TimeInterval = 2
        /// For the marker, once the line has started: a line that is no
        /// agent and sets no mode is not waited for past this.
        var marker: TimeInterval = 0.15
        /// How long the output is quiet before the first frame counts as
        /// whole.
        var quiet: TimeInterval = 0.05
        /// The longest that quiet is waited for, from the first mode: a
        /// program that never stops writing is shown anyway.
        var frame: TimeInterval = 0.3
    }

    /// Something heard about the start.
    enum Event: Equatable {
        /// `OSC 133;C`: the shell started running a line.
        case commandStarted
        /// `OSC 133;D`: a line ended.
        case commandEnded
        /// The program set a mode a full-screen interface sets.
        case interfaceMode
        /// Output arrived (once per read, after what was in it).
        case output
        /// The session's agent marker appeared: the line is an agent.
        case agentKnown
    }

    /// Why the cover lifted.
    enum End: Equatable {
        /// The program's interface is up and drawn.
        case ready
        /// The line is running, is no agent, and set no mode.
        case notAnAgent
        /// The line ended before an interface came up: the shell is back.
        case ended
        /// The shell never started the line.
        case noCommand
        /// The line is running and nothing came of it in time.
        case tookTooLong

        /// Whether what was typed under the cover goes to the terminal: only
        /// while the line is what would read it.
        var deliversTyping: Bool {
            switch self {
            case .ready, .notAnAgent, .tookTooLong: return true
            case .ended, .noCommand: return false
            }
        }
    }

    private enum Phase: Equatable {
        /// The shell is starting, or at its prompt with the line unread.
        case shell
        /// The line is running; no interface yet.
        case command(since: TimeInterval)
        /// The interface is coming up: shown once the output is quiet.
        case interface(since: TimeInterval, quietAt: TimeInterval)
        case over(End)
    }

    private let patience: Patience
    private let madeAt: TimeInterval
    private var phase = Phase.shell
    private var isAgent = false

    /// `now` and every time after it are seconds on one monotonic clock.
    init(now: TimeInterval, patience: Patience = Patience()) {
        madeAt = now
        self.patience = patience
    }

    /// How it ended, once it has.
    var end: End? {
        if case .over(let end) = phase { return end }
        return nil
    }

    /// Take an event that happened at `now`. Returns the end, the first time
    /// there is one.
    mutating func heard(_ event: Event, at now: TimeInterval) -> End? {
        switch (event, phase) {
        case (_, .over):
            return nil
        case (.commandStarted, .shell):
            phase = .command(since: now)
        case (.interfaceMode, .command):
            phase = .interface(since: now, quietAt: now + patience.quiet)
        case (.output, .interface(let since, _)):
            phase = .interface(since: since, quietAt: min(now + patience.quiet, since + patience.frame))
        case (.commandEnded, .command):
            // With an interface up this is the program's own mark (Pi wraps
            // what it renders in them), and before a line started it is
            // nobody's.
            phase = .over(.ended)
            return .ended
        case (.agentKnown, _):
            isAgent = true
        default:
            break
        }
        return check(at: now)
    }

    /// Whether a wait has run out by `now`. Returns the end, the first time
    /// there is one.
    mutating func check(at now: TimeInterval) -> End? {
        guard let (time, end) = next, now >= time else { return nil }
        phase = .over(end)
        return end
    }

    /// When `check` next has something to say, if nothing is heard first.
    var deadline: TimeInterval? { next?.time }

    private var next: (time: TimeInterval, end: End)? {
        switch phase {
        case .shell:
            return (madeAt + patience.shell, .noCommand)
        case .command(let since):
            if !isAgent { return (since + patience.marker, .notAnAgent) }
            return (since + patience.interface, .tookTooLong)
        case .interface(_, let quietAt):
            return (quietAt, .ready)
        case .over:
            return nil
        }
    }
}

/// Reads a new session's output for what `StartCover` listens for.
///
/// One pass, in order, because the order inside a single read is the whole
/// point: zsh's prompt turns bracketed paste on, reads the line that was
/// already waiting, turns it off and marks the command started, often in one
/// read. Two scanners over the same bytes would lose which came first.
///
/// It reads only `OSC 133;C`, `OSC 133;D` and `CSI ? … h` / `CSI > … u`, and
/// skips the strings that can carry another terminal's sequences (DCS, APC,
/// PM, SOS), as `CSIScanner` does. Not thread-safe: one per session, on its
/// pty queue, and only while the session starts.
struct StartScanner {
    /// The modes that mean an interface: what a full-screen program sets once
    /// and keeps (`TerminalModes.restorable`), without the two a shell's line
    /// editor sets for itself between commands.
    static let interfaceModes: Set<Int> = [
        9, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016,
        1047, 1048, 1049, 2004, 2031,
    ]

    private enum State {
        case text
        case escape
        /// `ESC [`, before its first byte.
        case csiStart
        /// A CSI with a private introducer: its parameters.
        case csi
        /// A CSI that says nothing here: waiting for its end.
        case csiSkipping
        /// An OSC: its first bytes are kept, to tell a 133 by.
        case osc
        /// DCS, APC, PM or SOS: waiting for its terminator.
        case string
    }

    private var state = State.text
    private var introducer: UInt8 = 0
    private var body: [UInt8] = []
    /// ESC seen inside an OSC or a string: `\` next ends it.
    private var pendingEscape = false

    /// Longer than `133;C` or any mode list; the rest of a long OSC (a
    /// title, a path) is read past, not kept.
    private static let kept = 32

    /// The events in `bytes`, in order, with `.output` last when there was
    /// anything at all.
    mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> [StartCover.Event] {
        var events: [StartCover.Event] = []
        for byte in bytes { step(byte, &events) }
        if !bytes.isEmpty { events.append(.output) }
        return events
    }

    private mutating func step(_ byte: UInt8, _ events: inout [StartCover.Event]) {
        switch state {
        case .text:
            if byte == 0x1B { state = .escape }

        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                state = .csiStart
            case UInt8(ascii: "]"):
                state = .osc
                body.removeAll(keepingCapacity: true)
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                state = .string
            case 0x1B:
                break
            default:
                state = .text
            }

        case .csiStart:
            switch byte {
            case UInt8(ascii: "?"), UInt8(ascii: ">"):
                introducer = byte
                body.removeAll(keepingCapacity: true)
                state = .csi
            case 0x1B:
                state = .escape
            case 0x40...0x7E:
                state = .text
            default:
                state = .csiSkipping
            }

        case .csi:
            switch byte {
            case 0x30...0x3B: // digits, `:` and `;`
                if body.count < Self.kept { body.append(byte) } else { state = .csiSkipping }
            case 0x40...0x7E:
                finishCSI(final: byte, &events)
                state = .text
            case 0x1B:
                state = .escape
            default:
                state = .csiSkipping
            }

        case .csiSkipping:
            switch byte {
            case 0x1B: state = .escape
            case 0x40...0x7E: state = .text
            default: break
            }

        case .osc:
            if pendingEscape {
                pendingEscape = false
                if byte == UInt8(ascii: "\\") {
                    finishOSC(&events)
                    state = .text
                } else {
                    // Cut off: this ESC starts whatever comes next.
                    state = .escape
                    step(byte, &events)
                }
            } else if byte == 0x07 {
                finishOSC(&events)
                state = .text
            } else if byte == 0x1B {
                pendingEscape = true
            } else if byte == 0x18 || byte == 0x1A {
                state = .text
            } else if body.count < Self.kept {
                body.append(byte)
            }

        case .string:
            if pendingEscape {
                pendingEscape = false
                if byte == UInt8(ascii: "\\") {
                    state = .text
                } else if byte == 0x1B {
                    pendingEscape = true
                }
            } else if byte == 0x1B {
                pendingEscape = true
            } else if byte == 0x07 || byte == 0x18 || byte == 0x1A {
                state = .text
            }
        }
    }

    private func finishCSI(final: UInt8, _ events: inout [StartCover.Event]) {
        switch (introducer, final) {
        case (UInt8(ascii: "?"), UInt8(ascii: "h")):
            // `ESC[?1000;1002;1006h` is one sequence setting three modes.
            let modes = String(decoding: body, as: UTF8.self).split(separator: ";").compactMap { Int($0) }
            if modes.contains(where: Self.interfaceModes.contains) { events.append(.interfaceMode) }
        case (UInt8(ascii: ">"), UInt8(ascii: "u")):
            // The keyboard protocol asked for; `CSI > u` alone is flags 0.
            let flags = String(decoding: body, as: UTF8.self).split(separator: ";").first.flatMap { Int($0) } ?? 0
            if flags != 0 { events.append(.interfaceMode) }
        default:
            break
        }
    }

    private func finishOSC(_ events: inout [StartCover.Event]) {
        let prefix = Array("133;".utf8)
        guard body.count > prefix.count, body.starts(with: prefix) else { return }
        let after = body.count > prefix.count + 1 ? body[prefix.count + 1] : UInt8(ascii: ";")
        guard after == UInt8(ascii: ";") else { return }
        switch body[prefix.count] {
        case UInt8(ascii: "C"): events.append(.commandStarted)
        case UInt8(ascii: "D"): events.append(.commandEnded)
        default: break
        }
    }
}
