import Foundation

/// Moving a session to another directory (`wortel cd`): what is typed and
/// what the caller is told. Pure, so `SessionMoveTests` can pin it;
/// `SessionManager` does the moving, on deep sleep's road (end the agent at
/// rest, type into the same shell, resume the exact conversation).
///
/// It came back on 2026-11-19 for agent sessions that start in a folder of
/// their own (`ChatFolder`): a chat that turns into work on a project moves
/// there, and the git panel, the sidebar and the agent's settings follow.
/// The agent asks first (`~/Wortel/CLAUDE.md`), so nothing moves by surprise.
/// No menu item: the way in is the agent, or the command.
enum SessionMove {
    /// The `cd` to type, or nil when the path can't be typed safely in every
    /// shell: a control character, or a backslash, which fish reads as an
    /// escape even inside single quotes. Its own line, never `cd x && claude
    /// …`: the shell integration reads the agent's directory from `$PWD` when
    /// the agent starts, and only zsh's reader follows a `cd` on the same
    /// line through a quoted path.
    static func cdLine(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" })
        else { return nil }
        let quoted = AgentCommandLine.isPlain(path)
            ? path
            : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted)"
    }

    /// What the caller is told when the move is accepted. Written for an
    /// agent to read and pass on: nothing has happened yet, because a command
    /// called `cd` reads as if it took effect at once.
    static func acceptedMessage(to path: String, waitsForTurn: Bool, instead previous: String? = nil) -> String {
        let shown = display(path)
        var parts: [String] = []
        if let previous { parts.append("Moving to \(shown) instead of \(display(previous)).") }
        if waitsForTurn {
            parts.append("Not moved yet. When this turn ends, the agent quits and continues this "
                + "conversation in \(shown), then waits for the person. Finish your reply and start "
                + "nothing else; anything still running when it quits stops.")
        } else {
            parts.append("Moving this session to \(shown): the agent quits and continues this "
                + "conversation there.")
        }
        return parts.joined(separator: " ")
    }

    /// A path as a person reads it: under home, with `~`.
    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// A move that has been accepted and hasn't finished. In memory only: a quit
/// drops it, and the agent is resumed where it was.
struct PendingMove {
    let path: String
    let requestedAt: Date
    /// The agent was already at rest when asked: no turn to wait for.
    let idleWhenAsked: Bool
    /// The agent has been signalled.
    var ending = false
    /// The `cd` has been typed; the move ends when the shell reports it.
    var typed = false

    /// A move still waiting this long is given up, and the person told.
    static let patience: TimeInterval = 60 * 60
}
