import Foundation

/// Settings ▸ New sessions start with: the line typed into a new session's
/// shell as its first command, or nothing for a plain terminal.
///
/// The text is typed **as written**, never quoted: `claude --model opus` is a
/// command and two arguments, and whoever wrote it meant the shell to read it
/// that way. That is the difference from `wortel new -- <command>`, whose
/// words arrive already split and are quoted back together
/// (`WortelCommandParser.startupLine`). It is typed into the person's own login
/// shell, so their PATH, aliases and functions all apply.
///
/// What can't be typed is refused here rather than half run, by the same two
/// facts that command is held to: a control character is a key to a shell
/// that hasn't started reading, and a line over `MAX_CANON` bytes is thrown
/// away whole by the kernel. A newline is refused too: here it could only be
/// a second command pasted in by accident.
enum NewSessionCommand {
    enum Problem: Error, Equatable {
        case controlCharacter
        case tooLong
    }

    /// `text` as the line to type, newline included; nil when it is empty,
    /// which means a plain terminal.
    static func check(_ text: String) -> Result<String?, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.unicodeScalars.contains(where: WortelCommandParser.typesAsKey) {
            return .failure(.controlCharacter)
        }
        guard !trimmed.isEmpty else { return .success(nil) }
        let line = trimmed + "\n"
        guard line.utf8.count <= WortelCommandParser.typedLineLimit else { return .failure(.tooLong) }
        return .success(line)
    }

    /// The line for what Settings has stored. A stored value that can't be
    /// typed counts as none: the field never saves one, so this is only a
    /// value written into the defaults by hand.
    static func line(for stored: String) -> String? {
        (try? check(stored).get()) ?? nil
    }
}

/// What a new session starts with, decided by whoever asks for the session.
///
/// Every way of making a session names one of these, with no default, so the
/// compiler lists each place that has to decide. A wrong guess either starts
/// an agent nobody asked for or leaves out the one that was.
enum SessionStart: Equatable {
    /// What Settings says: the app's own ways in (⌘N, ⌥⌘N, ⇧⌘N, ⌘O, a
    /// folder's +, a folder dropped on the window).
    case preferred
    /// A shell and nothing typed: New Terminal, `wortel new` without a
    /// command, and a session the app makes for itself at launch. A launch is
    /// not a request for an agent.
    case plain
    /// This line, newline included: `wortel new -- <command>`.
    case line(String)

    /// The bytes to type into the new shell, or nil for none. `stored` is
    /// Settings' text as kept (`AppSettings.newSessionCommand`).
    func input(preferred stored: String) -> String? {
        switch self {
        case .preferred: return NewSessionCommand.line(for: stored)
        case .plain: return nil
        case .line(let line): return line
        }
    }

    /// Whether this session was started with Settings' command: the one
    /// thing reported about it, as a yes or no.
    func usesPreferredCommand(stored: String) -> Bool {
        self == .preferred && NewSessionCommand.line(for: stored) != nil
    }
}
