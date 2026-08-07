import Foundation

/// The wire protocol between the `wortel` CLI and the running app.
///
/// One JSON object per line, over a Unix domain socket. Line-delimited rather
/// than length-prefixed because both ends are Swift talking to a local socket
/// and the debuggability is worth more than the parsing: you can drive the whole
/// surface from `nc` while working on it.
///
/// **The point of having a socket at all** is that it inverts who has to know
/// about whom. Wortel ships no per-agent integrations — no hooks for Claude
/// Code, none for Codex, none for the ten that will exist next year — because
/// anything that can run a command can drive the app instead. An agent that just
/// wrote a file can open a preview of it; a `SessionStart` hook you wrote can
/// name the session after the ticket you're on. cmux took the other road and now
/// maintains adapters for six agents and explicitly skips ten more.
enum WortelCommand: Codable, Equatable {
    /// Open a file in a preview window.
    case open(path: String)
    /// Start a session. `cwd` defaults to the caller's directory, and `branch`
    /// asks for a worktree the way the sidebar's picker does.
    case newSession(cwd: String?, name: String?, branch: String?)
    /// Rename a session — by default the one the caller is running in.
    case rename(session: String?, name: String)
    /// Raise attention on a session: the dot, the badge, the notification.
    case notify(session: String?, title: String, body: String?)

    /// A command's name on the command line, and in the JSON.
    var verb: String {
        switch self {
        case .open: return "open"
        case .newSession: return "new"
        case .rename: return "rename"
        case .notify: return "notify"
        }
    }
}

/// What the app sends back. Always one line, always JSON, even for failures —
/// a CLI that sometimes prints prose and sometimes JSON can't be scripted.
struct WortelResponse: Codable, Equatable {
    var ok: Bool
    /// Human-readable, for the caller's terminal.
    var message: String?
    /// Machine-readable, for the caller's script: a session id, a path.
    var value: String?

    static func failure(_ message: String) -> WortelResponse {
        WortelResponse(ok: false, message: message, value: nil)
    }

    static func success(_ message: String? = nil, value: String? = nil) -> WortelResponse {
        WortelResponse(ok: true, message: message, value: value)
    }
}

/// Turning arguments into a command, and back.
///
/// Pure, and tested, because this is the layer where a CLI rots: an argument
/// silently ignored, a path taken as a name, an error the shell can't tell from
/// success. None of it needs a socket to check.
enum WortelCommandParser {
    /// The environment variable every Wortel shell already carries. It's what
    /// lets `wortel rename` mean "this session" without the caller knowing an
    /// id — see `GhosttyRuntime`, which exports it per surface.
    static let sessionVariable = "WORTEL_SESSION_ID"

    static let usage = """
        usage: wortel <command> [arguments]

          open <path>              open a file in a preview window
          new [--cwd <path>] [--name <name>] [--branch <branch>]
                                   start a session; --branch gives it a worktree
          rename <name>            rename this session
          notify <title> [body]    raise attention on this session

        Commands act on the session they are run in, via $\(sessionVariable).
        """

    /// Parse `arguments` (without the program name). `environment` supplies the
    /// caller's session and directory.
    static func parse(
        _ arguments: [String], environment: [String: String] = [:], currentDirectory: String? = nil
    ) throws -> WortelCommand {
        guard let verb = arguments.first else { throw ParseError.noCommand }
        let rest = Array(arguments.dropFirst())
        let session = environment[sessionVariable]

        switch verb {
        case "open":
            guard let path = rest.first else { throw ParseError.missing("a path", verb) }
            // Resolved against the caller's directory, because a CLI is nearly
            // always handed a relative path and the app is nowhere near it.
            return .open(path: absolute(path, from: currentDirectory))

        case "new":
            let flags = try Flags(rest, allowed: ["--cwd", "--name", "--branch"])
            return .newSession(
                cwd: flags["--cwd"].map { absolute($0, from: currentDirectory) } ?? currentDirectory,
                name: flags["--name"],
                branch: flags["--branch"])

        case "rename":
            guard let name = rest.first, !name.isEmpty else {
                throw ParseError.missing("a name", verb)
            }
            return .rename(session: session, name: name)

        case "notify":
            guard let title = rest.first else { throw ParseError.missing("a title", verb) }
            return .notify(session: session,
                           title: title,
                           body: rest.count > 1 ? rest[1] : nil)

        default:
            throw ParseError.unknown(verb)
        }
    }

    static func absolute(_ path: String, from directory: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/"), let directory else { return expanded }
        return URL(fileURLWithPath: directory).appendingPathComponent(expanded)
            .standardizedFileURL.path
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case noCommand
        case unknown(String)
        case missing(String, String)

        var description: String {
            switch self {
            case .noCommand: return "no command given"
            case .unknown(let verb): return "unknown command \"\(verb)\""
            case .missing(let what, let verb): return "\(verb) needs \(what)"
            }
        }
    }

    /// `--flag value` pairs, rejecting anything not on the list.
    ///
    /// Rejecting rather than ignoring: a typo'd flag that is silently dropped
    /// gives you a session in the wrong directory and no clue why, and that is a
    /// worse ten minutes than an error message.
    private struct Flags {
        private var values: [String: String] = [:]

        init(_ arguments: [String], allowed: Set<String>) throws {
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard allowed.contains(flag) else { throw ParseError.unknown(flag) }
                guard index + 1 < arguments.count else {
                    throw ParseError.missing("a value", flag)
                }
                values[flag] = arguments[index + 1]
                index += 2
            }
        }

        subscript(flag: String) -> String? { values[flag] }
    }
}
