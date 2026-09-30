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
    /// asks for a worktree the way the sidebar's picker does. `base` is what a
    /// *new* branch forks from — nil means the repository's own default branch,
    /// which is the answer a script almost always wants and never has to say.
    case newSession(cwd: String?, name: String?, branch: String?, base: String?)
    /// Rename a session — by default the one the caller is running in.
    case rename(session: String?, name: String)
    /// Raise attention on a session: the dot, the badge, the notification.
    case notify(session: String?, title: String, body: String?)
    /// Which Wortel is actually listening.
    ///
    /// Asked over the socket rather than read off disk because the two are
    /// different questions: the binary knows the bundle it *shipped in*, and
    /// this is the one that answered. They differ exactly when a `wortel`
    /// someone symlinked onto their PATH has outlived the app it came from —
    /// the drift this protocol is otherwise only able to complain about after
    /// it has already caused a failure.
    case version

    /// A command's name on the command line, and in the JSON.
    var verb: String {
        switch self {
        case .open: return "open"
        case .newSession: return "new"
        case .rename: return "rename"
        case .notify: return "notify"
        case .version: return "--version"
        }
    }
}

/// Where the two ends meet.
enum WortelCLI {
    /// The socket, beside `sessions.json` in Application Support — app state,
    /// which is what it is, and a directory both ends can derive without being
    /// told. A Unix socket path has to fit `sun_path` (104 bytes on Darwin), and
    /// this one spends about half of that.
    static var socketPath: String {
        DataDirectory.file("cli.sock").path
    }

    /// The `.app` a binary at `executable` lives in, or nil if it doesn't live
    /// in one.
    ///
    /// How the CLI finds its own version: it has no `Info.plist` of its own, so
    /// it reads the bundle it was copied into —
    /// `Wortel.app/Contents/Resources/bin/wortel` walking up to `Wortel.app`.
    ///
    /// Symlinks are resolved first, and that's the whole point rather than a
    /// detail: the case this has to survive is someone linking the command onto
    /// their `PATH`, and the path we were exec'd as is then the *link*, which
    /// lives in `/usr/local/bin` and is inside no bundle at all.
    static func appBundle(containing executable: String) -> String? {
        var url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url.path }
        }
        return nil
    }

    /// The maximum line either end will read before giving up.
    ///
    /// A guard, not a budget: the far end is a local socket carrying one JSON
    /// object, and anything approaching this is a confused peer rather than a
    /// long path. Without it, a peer that never sends a newline makes the reader
    /// grow a buffer until something else breaks.
    static let maximumLineBytes = 64 * 1024

    /// Fill a `sockaddr_un` for `path`.
    ///
    /// Shared because getting it wrong is silent on one side only: a truncated
    /// path binds a socket at a name the client will never find, and the app
    /// looks like it simply isn't listening.
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Call `body` with `address` as a plain `sockaddr`, which is what bind and
    /// connect take.
    static func withSockaddr<T>(
        _ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case notRunning
        case failed(String, errno: Int32)
        case badResponse

        var description: String {
            switch self {
            case .pathTooLong(let path):
                return "socket path is too long: \(path)"
            case .notRunning:
                return "Wortel isn't running."
            case .failed(let what, let code):
                return "\(what): \(String(cString: strerror(code)))"
            case .badResponse:
                return "Wortel sent a reply this version doesn't understand."
            }
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
          new [--cwd <path>] [--name <name>] [--branch <branch>] [--from <ref>]
                                   start a session; --branch gives it a worktree,
                                   --from picks what a new branch forks from
          rename <name>            rename this session
          notify <title> [body]    raise attention on this session

          --version                this command's version, and the running app's
          --help                   this

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
            let flags = try Flags(rest, allowed: ["--cwd", "--name", "--branch", "--from"])
            return .newSession(
                cwd: flags["--cwd"].map { absolute($0, from: currentDirectory) } ?? currentDirectory,
                name: flags["--name"],
                branch: flags["--branch"],
                base: flags["--from"])

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
            case .noCommand:
                return "no command given"
            // One case, two words for it: a mistyped `--brnach` is an option
            // and a mistyped `noew` is a command, and being told the wrong one
            // sends you looking in the wrong half of the usage.
            case .unknown(let token):
                return token.hasPrefix("-")
                    ? "unknown option \"\(token)\""
                    : "unknown command \"\(token)\""
            case .missing(let what, let verb):
                return "\(verb) needs \(what)"
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
