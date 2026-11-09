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
    /// `new --pr`: a session on a pull request, by number or URL. A case of
    /// its own rather than a field on `newSession`, because an older app
    /// decoding a field it doesn't know would ignore it and open a plain
    /// session; an unknown case is refused, which says what happened.
    case newFromPullRequest(cwd: String?, name: String?, pr: String)
    /// `new --worktree`: a session in a worktree of its own on a new branch
    /// Wortel names, as ⇧⌘N makes one. Its own case for the reason
    /// `newFromPullRequest` is.
    case newWorktree(cwd: String?, name: String?)
    /// `new … -- <command>`: any of the three above, with `argv` typed into
    /// the new session's shell as its first line. A case wrapping them rather
    /// than a field on each, for the reason `newFromPullRequest` is its own:
    /// an older app would drop the field and open a session that runs nothing.
    indirect case newRunning(WortelCommand, argv: [String])
    /// Rename a session — by default the one the caller is running in.
    case rename(session: String?, name: String)
    /// Raise attention on a session: the dot, the badge, the notification.
    case notify(session: String?, title: String, body: String?)
    /// Colour a session in the sidebar, or clear it with "none". The colour
    /// goes over as typed and is checked by the app: the colours are the
    /// app's (`SessionColour`), and this file is also compiled into the CLI
    /// and the keeper, which have no business knowing them.
    case mark(session: String?, colour: String)
    /// Every open session, described (`WortelSessionInfo`, as JSON in the
    /// reply's `value`). `caller` is the asking shell's `$WORTEL_SESSION_ID`,
    /// so the list can say which row is "you".
    case list(caller: String?)
    /// The text on a session's screen. `session` is an id or a name
    /// (`WortelSessionAddress`); `lines` asks for the last that many lines,
    /// scrollback included, instead of the screen.
    case read(session: String, lines: Int?)
    /// Text into a session's terminal as a paste, then Return if `enter`.
    /// Unmarked, like a person typing: see `docs/cli.md`.
    case send(session: String, text: String, enter: Bool)
    /// Hold the connection open until the session shows `text` (new since
    /// the wait began, unless `fromStart`), goes idle, or exits, whichever
    /// of the asked-for conditions comes first. `timeout` is in seconds, 0
    /// for none.
    case wait(session: String, text: String?, fromStart: Bool, idle: Bool, exit: Bool,
              timeout: Double)
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
        case .newSession, .newFromPullRequest, .newWorktree, .newRunning: return "new"
        case .rename: return "rename"
        case .notify: return "notify"
        case .mark: return "mark"
        case .list: return "list"
        case .read: return "read"
        case .send: return "send"
        case .wait: return "wait"
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

    /// The longest command the app will read, and the longest reply the CLI
    /// will, before giving up.
    ///
    /// Guards, not budgets: without them, a peer that never sends a newline
    /// makes the reader grow a buffer until something else breaks. They are
    /// two numbers because the two directions carry different things now. A
    /// command is a path or a name, except `send`'s text, which is capped
    /// below what fits here even escaped. A reply is a sentence, except
    /// `read --lines`, which can be a long stretch of scrollback.
    static let maximumRequestBytes = 2 * 1024 * 1024
    static let maximumResponseBytes = 16 * 1024 * 1024
    /// The most `wortel send` takes. A prompt is a few kilobytes; this is a
    /// file pasted whole, and JSON-escaped (a control character becomes six
    /// bytes) it still fits in `maximumRequestBytes`.
    static let maximumSendBytes = 256 * 1024
    /// The most lines `wortel read --lines` gives. libghostty can bound a
    /// read to the active screen or read the whole scrollback, nothing in
    /// between (`ghostty_surface_read_text` clamps an exact row to the
    /// screen's height), so more lines than the screen holds costs a read of
    /// all of it whatever N is (`ScreenText.lastLines`). This bounds the
    /// answer, not that read.
    static let maximumReadLines = 10_000
    /// How long the CLI waits for the app's answer to anything but a `wait`
    /// (whose bound is its own `--timeout`). The app can be busy in ways the
    /// CLI can't see, and a command line that never returns is worse than one
    /// that says so.
    static let answerTimeout: TimeInterval = 10
    /// How long the app holds a `send` for its terminal to take a paste (a
    /// session just warmed, its keeper replay still being written and its
    /// old queries answered; `SurfaceView.whenPasteReachesProgram`). Past
    /// it, the app says so and types **nothing**. It has to end well inside
    /// `answerTimeout`, `send --enter`'s Return included: an app that typed
    /// after the CLI had already reported a failure made a script that
    /// retries send its prompt twice. Derived from it rather than a second
    /// number, so the two can't drift apart.
    static let sendPatience: TimeInterval = answerTimeout / 2
    /// The exit status of a `wortel wait` that ran out of time: the one GNU
    /// `timeout` uses, so a script that already knows that one reads it right.
    static let waitTimedOutStatus: Int32 = 124

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
    /// The exit status for a failure, when it isn't the usual 1: a `wait`
    /// that timed out (`WortelCLI.waitTimedOutStatus`) has to be told apart
    /// from one that couldn't start. Absent in every other reply, and an older
    /// CLI that doesn't know the field ignores it and exits 1.
    var status: Int32?

    static func failure(_ message: String, status: Int32? = nil) -> WortelResponse {
        WortelResponse(ok: false, message: message, value: nil, status: status)
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
          new [--cwd <path>] [--name <name>] [--branch <branch>] [--from <ref>] [--pr <n|url>] [--worktree] [-- <command>]
                                   start a session; --branch gives it a worktree,
                                   --from picks what a new branch forks from,
                                   --pr checks out a pull request in one,
                                   --worktree makes one on a new branch,
                                   and a command after -- runs in its shell
          rename [--session <s>] <name>
                                   rename this session
          notify [--session <s>] <title> [body]
                                   raise attention on this session
          mark [--session <s>] <colour>
                                   colour this session in the sidebar: red, orange,
                                   yellow, green, blue, purple, grey, or none

          list [--json]            the open sessions: id, name, state, agent,
                                   branch and directory
          read <session> [--lines <n>] [--json]
                                   the text on a session's screen; --lines gives
                                   the last n lines, scrollback included
          send <session> [text] [--enter] [--stdin]
                                   type text into a session as a paste; --enter
                                   presses Return after it, --stdin reads the text
                                   from standard input
          wait <session> [--for <text> [--from-start]] [--idle] [--exit] [--timeout <dur>]
                                   wait until the text appears, the session is
                                   idle (the default), or it exits; --timeout is
                                   30s unless given (90s, 5m, 0 for none). Exits 0
                                   when met, \(WortelCLI.waitTimedOutStatus) on timeout, 1 on error

          --version                this command's version, and the running app's
          --help                   this

        Commands act on the session they are run in, via $\(sessionVariable), unless
        given one. <session> is an id (the short one `list` prints will do) or a
        name: exact, or the start of one if only one session's name starts that way.
        """

    /// A parsed command line: the command for the app, and how the CLI should
    /// print what comes back. `json` never goes over the wire; it is a
    /// question of presentation, and the app answers the same either way.
    struct Invocation: Equatable {
        var command: WortelCommand
        var json = false
    }

    /// Parse `arguments` (without the program name). `environment` supplies the
    /// caller's session and directory.
    static func parse(
        _ arguments: [String], environment: [String: String] = [:], currentDirectory: String? = nil,
        standardInput: (() throws -> String)? = nil
    ) throws -> WortelCommand {
        try parseInvocation(arguments, environment: environment, currentDirectory: currentDirectory,
                            standardInput: standardInput).command
    }

    /// The same, with the printing options. `standardInput` is how
    /// `send --stdin` gets its text: handed in rather than read here, so the
    /// parser stays something a test can call.
    static func parseInvocation(
        _ arguments: [String], environment: [String: String] = [:], currentDirectory: String? = nil,
        standardInput: (() throws -> String)? = nil
    ) throws -> Invocation {
        guard let verb = arguments.first else { throw ParseError.noCommand }
        let rest = Array(arguments.dropFirst())
        let session = environment[sessionVariable]

        switch verb {
        case "list":
            let words = try Words(rest, valued: [], switches: ["--json"])
            if let extra = words.positionals.first { throw ParseError.unexpected(extra, verb) }
            return Invocation(command: .list(caller: session), json: words.isOn("--json"))

        case "read":
            let words = try Words(rest, valued: ["--lines"], switches: ["--json"])
            let target = try words.target(for: verb)
            var lines: Int?
            if let text = words["--lines"] {
                guard let count = Int(text), (1...WortelCLI.maximumReadLines).contains(count) else {
                    throw ParseError.invalid("--lines", text, "a number of lines, 1 to \(WortelCLI.maximumReadLines)")
                }
                lines = count
            }
            return Invocation(command: .read(session: target, lines: lines), json: words.isOn("--json"))

        case "send":
            let words = try Words(rest, valued: [], switches: ["--enter", "--stdin"])
            guard let target = words.positionals.first else { throw ParseError.missing("a session", verb) }
            guard words.positionals.count <= 2 else {
                throw ParseError.unexpected(words.positionals[2], verb)
            }
            let given = words.positionals.count == 2 ? words.positionals[1] : nil
            let enter = words.isOn("--enter")
            var text = given ?? ""
            if words.isOn("--stdin") {
                guard given == nil else { throw ParseError.conflict("--stdin", "text on the command line") }
                guard let standardInput else { throw ParseError.missing("text to read", "--stdin") }
                // One trailing newline off, as `$(…)` takes it: `echo hi |`
                // means "hi", and a newline inside a paste is a line break in
                // the agent's input box rather than nothing.
                // ("\r\n" is one Character to Swift, so one removal either way.)
                text = try standardInput()
                if let last = text.last, last == "\n" || last == "\r\n" { text.removeLast() }
            } else if given == nil, !enter {
                throw ParseError.missing("text, --stdin or --enter", verb)
            }
            guard text.utf8.count <= WortelCLI.maximumSendBytes else {
                throw ParseError.invalid("the text", "\(text.utf8.count) bytes",
                                         "at most \(WortelCLI.maximumSendBytes / 1024) KB")
            }
            return Invocation(command: .send(session: target, text: text, enter: enter))

        case "wait":
            let words = try Words(rest, valued: ["--for", "--timeout"],
                                  switches: ["--from-start", "--idle", "--exit"])
            let target = try words.target(for: verb)
            let text = words["--for"]
            if let text, text.isEmpty { throw ParseError.invalid("--for", "\"\"", "some text to wait for") }
            let fromStart = words.isOn("--from-start")
            if fromStart, text == nil { throw ParseError.missing("--for", "--from-start") }
            var timeout = defaultWaitTimeout
            if let given = words["--timeout"] {
                guard let seconds = duration(given) else {
                    throw ParseError.invalid("--timeout", given, "a duration like 30s, 5m or 0, up to 7 days")
                }
                timeout = seconds
            }
            // Nothing asked for means idle: the question nearly every wait is,
            // after a prompt has been sent.
            let exit = words.isOn("--exit")
            let idle = words.isOn("--idle") || (text == nil && !exit)
            return Invocation(command: .wait(session: target, text: text, fromStart: fromStart,
                                             idle: idle, exit: exit, timeout: timeout))

        default:
            return Invocation(command: try parseActingOnCaller(verb, rest, session: session,
                                                               currentDirectory: currentDirectory))
        }
    }

    /// How long `wait` waits when not told. Long enough for a short agent turn,
    /// short enough that a wait for something that will never happen doesn't
    /// look like a hang.
    static let defaultWaitTimeout: Double = 30

    /// The longest `--timeout` taken: a week. Anything longer is a typo or
    /// `1e19`, and 0 already says "no limit". Bounded because the number
    /// ends up in a `timeval` and an `Int(...)`, which trap on a Double
    /// past `Int.max` rather than failing.
    static let maximumDuration: Double = 7 * 24 * 3600

    /// A duration as typed: `90s`, `5m`, `1h`, `500ms`, or a bare number of
    /// seconds, up to `maximumDuration`. 0 is valid and means "no limit" to
    /// `wait`. Nil for anything else, negative numbers included.
    static func duration(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(suffix: String, seconds: Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        // `ms` before `s` and `m`: both are suffixes of it.
        let unit = units.first { text.hasSuffix($0.suffix) } ?? ("", 1)
        let number = text.dropLast(unit.suffix.count)
        guard !number.isEmpty, let value = Double(number), value >= 0, value.isFinite else { return nil }
        // Checked after the unit, which can carry a finite number past it.
        let seconds = value * unit.seconds
        guard seconds <= maximumDuration else { return nil }
        return seconds
    }

    /// Whether a timeout that came over the socket is one `duration` could
    /// have produced. The app checks it too: the socket is also spoken to
    /// directly, and a wait's timeout is printed with `Int(...)`.
    static func isValidTimeout(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= maximumDuration
    }

    /// The verbs that act on the caller's own session unless told otherwise,
    /// and `open` and `new`, which act on no session.
    private static func parseActingOnCaller(
        _ verb: String, _ rest: [String], session callerSession: String?, currentDirectory: String?
    ) throws -> WortelCommand {
        // `--session` on the three that only label a session: naming one from
        // elsewhere is as safe as naming your own.
        var rest = rest
        var session = callerSession
        if ["rename", "notify", "mark"].contains(verb), let flag = rest.firstIndex(of: "--session") {
            guard flag + 1 < rest.count else { throw ParseError.missing("a value", "--session") }
            session = rest[flag + 1]
            rest.removeSubrange(flag...(flag + 1))
        }

        switch verb {
        case "open":
            guard let path = rest.first else { throw ParseError.missing("a path", verb) }
            // Resolved against the caller's directory, because a CLI is nearly
            // always handed a relative path and the app is nowhere near it.
            return .open(path: absolute(path, from: currentDirectory))

        case "new":
            // Everything after `--` is the command, its own flags included:
            // `-- claude --resume x` must not have `--resume` read as ours.
            guard let separator = rest.firstIndex(of: "--") else {
                return try parseNew(rest, currentDirectory: currentDirectory)
            }
            let argv = Array(rest[(separator + 1)...])
            guard !argv.isEmpty else { throw ParseError.missing("a command after --", verb) }
            let new = try parseNew(Array(rest[..<separator]), currentDirectory: currentDirectory)
            // Checked here too, not only by the app, so a command that can't
            // be typed is a usage error before anything opens.
            _ = try startupLine(argv)
            return .newRunning(new, argv: argv)

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

        case "mark":
            guard let colour = rest.first, !colour.isEmpty else {
                throw ParseError.missing("a colour, or none", verb)
            }
            return .mark(session: session, colour: colour)

        default:
            throw ParseError.unknown(verb)
        }
    }

    /// `new`'s flags: which of the three it is, and where.
    private static func parseNew(_ rest: [String], currentDirectory: String?) throws -> WortelCommand {
        let flags = try Flags(rest, allowed: ["--cwd", "--name", "--branch", "--from", "--pr"],
                              switches: ["--worktree"])
        if flags.isOn("--worktree") {
            guard flags["--branch"] == nil, flags["--from"] == nil, flags["--pr"] == nil else {
                throw ParseError.conflict("--worktree", "--branch, --from or --pr")
            }
            return .newWorktree(
                cwd: flags["--cwd"].map { absolute($0, from: currentDirectory) } ?? currentDirectory,
                name: flags["--name"])
        }
        if let pr = flags["--pr"] {
            guard flags["--branch"] == nil, flags["--from"] == nil else {
                throw ParseError.conflict("--pr", "--branch or --from")
            }
            return .newFromPullRequest(
                cwd: flags["--cwd"].map { absolute($0, from: currentDirectory) } ?? currentDirectory,
                name: flags["--name"], pr: pr)
        }
        return .newSession(
            cwd: flags["--cwd"].map { absolute($0, from: currentDirectory) } ?? currentDirectory,
            name: flags["--name"],
            branch: flags["--branch"],
            base: flags["--from"])
    }

    /// `argv` as one line a shell runs as those words: plain words as they
    /// are, so it reads in history the way you'd have typed it, the rest
    /// single-quoted.
    ///
    /// A quote or a backslash inside is closed out of the quotes and escaped
    /// there (`'\''`, `'\\'`), the one spelling zsh, bash and fish all read
    /// back the same: fish takes `\\` and `\'` as escapes even inside single
    /// quotes, so a backslash left in them would be read wrong, and one at
    /// the end of a word would leave the quote open.
    ///
    /// The words arrive already expanded by the caller's shell, so nothing
    /// may be expanded twice: no `~` and no `%` count as plain, and no
    /// leading `=` (zsh reads `=ls` as ls's path), though `--model=x` is. Nor
    /// is an `=` in the first word, which a shell reads as an assignment
    /// (`FOO=1 make` sets FOO; the caller asked for a program named that).
    static func shellLine(_ argv: [String]) -> String {
        argv.enumerated().map { index, word in
            let plain = !word.isEmpty && !word.hasPrefix("=") && !(index == 0 && word.contains("="))
                && word.unicodeScalars.allSatisfy(plainCharacters.contains)
            guard !plain else { return word }
            // One pass: the second of two replacements would rewrite the
            // quotes the first one wrote.
            let escaped = word.map { character -> String in
                switch character {
                case "'": return "'\\''"
                case "\\": return "'\\\\'"
                default: return String(character)
                }
            }.joined()
            return "'" + escaped + "'"
        }.joined(separator: " ")
    }

    private static let plainCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_./:@+=,-"))

    /// `argv` as the line a new session's shell is given, newline included,
    /// or why it can't be.
    ///
    /// The line is *typed*: the keeper writes it into the pty before the
    /// shell has read a byte, while the terminal is still in canonical mode,
    /// so two things that are fine in an argument are not fine as keys. A
    /// control character is a key there (a tab completes, ^C interrupts, ^U
    /// erases), quotes or no quotes; a newline is the one that reads back as
    /// itself inside quotes. And the kernel holds at most `MAX_CANON` bytes of
    /// an unfinished line: past that the whole line is thrown away, and the
    /// session opens with nothing run and nothing said (measured: 1022 bytes
    /// ran, 1027 vanished). Refused with a reason instead.
    static func startupLine(_ argv: [String]) throws -> String {
        // C0 and DEL only: `controlCharacters` also holds format characters
        // like the joiner inside every family emoji, which type fine.
        let isKey = { (scalar: Unicode.Scalar) in
            (scalar.value < 0x20 && scalar != "\n") || scalar.value == 0x7F
        }
        if argv.contains(where: { $0.unicodeScalars.contains(where: isKey) }) {
            throw ParseError.unrunnable(
                "it has a tab or another control character in it, which a shell would take as a key")
        }
        let line = shellLine(argv) + "\n"
        let limit = Int(MAX_CANON)
        guard line.utf8.count <= limit else {
            throw ParseError.unrunnable(
                "it is \(line.utf8.count) bytes long, and at most \(limit) can be typed into a shell at once")
        }
        return line
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
        /// Two options that can't be given together.
        case conflict(String, String)
        /// An argument after the ones a command takes.
        case extra(String, String)
        /// A command `new` can't type into a shell, and why.
        case unrunnable(String)
        /// A word after the ones a command takes (`extra` says "directory").
        case unexpected(String, String)
        /// An option given a value it can't use: the option, the value, and
        /// what it wanted instead.
        case invalid(String, String, String)

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
            case .conflict(let option, let others):
                return "\(option) can't be used with \(others)"
            case .extra(let token, let verb):
                return "\(verb) takes one directory, not \"\(token)\" too (quote a path with spaces)"
            case .unrunnable(let why):
                return "new can't run that command: \(why). Put it in a script and run the script."
            case .unexpected(let token, let verb):
                return "\(verb) doesn't take \"\(token)\" (quote text with spaces, or put it after --)"
            case .invalid(let option, let value, let wanted):
                return "\(option) can't be \(value): it takes \(wanted)"
            }
        }
    }

    /// Positional words and `--options` in any order, for the verbs that take
    /// both. Everything after `--` is positional, so text that starts with a
    /// dash can still be sent: `wortel send x -- --help`.
    ///
    /// Unknown options are refused for the reason `Flags` refuses them. A lone
    /// `-` is a word, not an option.
    private struct Words {
        private(set) var positionals: [String] = []
        private var values: [String: String] = [:]
        private var on: Set<String> = []

        init(_ arguments: [String], valued: Set<String>, switches: Set<String>) throws {
            var index = 0
            var literal = false
            while index < arguments.count {
                let word = arguments[index]
                index += 1
                if literal || !word.hasPrefix("-") || word == "-" {
                    positionals.append(word)
                } else if word == "--" {
                    literal = true
                } else if switches.contains(word) {
                    on.insert(word)
                } else if valued.contains(word) {
                    guard index < arguments.count else { throw ParseError.missing("a value", word) }
                    values[word] = arguments[index]
                    index += 1
                } else {
                    throw ParseError.unknown(word)
                }
            }
        }

        subscript(option: String) -> String? { values[option] }
        func isOn(_ option: String) -> Bool { on.contains(option) }

        /// The one session a verb is about, and nothing after it.
        func target(for verb: String) throws -> String {
            guard let target = positionals.first, !target.isEmpty else {
                throw ParseError.missing("a session (an id or a name; `wortel list` shows them)", verb)
            }
            if positionals.count > 1 { throw ParseError.unexpected(positionals[1], verb) }
            return target
        }
    }

    /// `--flag value` pairs, rejecting anything not on the list.
    ///
    /// Rejecting rather than ignoring: a typo'd flag that is silently dropped
    /// gives you a session in the wrong directory and no clue why, and that is a
    /// worse ten minutes than an error message.
    private struct Flags {
        private var values: [String: String] = [:]
        private var on: Set<String> = []

        /// `allowed` take a value; `switches` stand alone.
        init(_ arguments: [String], allowed: Set<String>, switches: Set<String> = []) throws {
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                if switches.contains(flag) {
                    on.insert(flag)
                    index += 1
                    continue
                }
                guard allowed.contains(flag) else { throw ParseError.unknown(flag) }
                guard index + 1 < arguments.count else {
                    throw ParseError.missing("a value", flag)
                }
                values[flag] = arguments[index + 1]
                index += 2
            }
        }

        subscript(flag: String) -> String? { values[flag] }
        func isOn(_ flag: String) -> Bool { on.contains(flag) }
    }
}
