import AppKit

/// What a `wortel` command actually does to the app.
///
/// The transport is `WortelCLIServer`'s problem; this is the other half — and
/// it is where the two rules that make the CLI safe to leave running live:
///
/// **It never steals focus.** Every window it opens is ordered front, and the
/// app is never activated. A command typed in Wortel therefore appears exactly
/// as you'd expect (Wortel is already frontmost), while a hook firing behind
/// your back while you're in another app leaves the window waiting rather than
/// yanking you out of what you were doing. That distinction is the difference
/// between a tool you can wire into an agent and one you turn off after a day.
///
/// **A command means the session it was run in.** `rename` and `notify` take no
/// session argument: the shell already knows which one it is
/// (`$WORTEL_SESSION_ID`), so the identity comes from where you ran the command
/// rather than from something you have to look up and could get wrong.
///
/// **Except the four that reach other sessions** (`list`, `read`, `send`,
/// `wait`), whose whole point is another session: one agent starting a second,
/// handing it a prompt, waiting for it and reading the answer. They go through
/// the same doors a person does, the screen, a paste and the Return key, and
/// they leave no mark: see `docs/cli.md` for why there is no prompt and no
/// label.
@MainActor
final class WortelCLIService {
    private let manager: SessionManager
    private let openPreview: (URL) -> Void
    /// Brought forward for anything that opens a window. Not activated — see
    /// the type's note.
    private let orderFront: () -> Void
    /// What came of asking a session's window for a split.
    enum SplitOutcome {
        case made
        /// The session's main row is too small to halve, which is what ⌘D
        /// beeps at.
        case noRoom
        case notMade
    }
    /// Split a session's main area on an edge of its main row, holding the
    /// tab, in whichever window the session is in, with nothing brought
    /// forward and the keyboard left where it is. The app layer's, because
    /// the rows are a window's (`GitPanelModel.splitFromCommand`).
    private let splitMainArea: (Session, SplitLayout.Edge, SideTab) -> SplitOutcome
    private var server: WortelCLIServer?

    init(manager: SessionManager, openPreview: @escaping (URL) -> Void,
         orderFront: @escaping () -> Void,
         splitMainArea: @escaping (Session, SplitLayout.Edge, SideTab) -> SplitOutcome) {
        self.manager = manager
        self.openPreview = openPreview
        self.orderFront = orderFront
        self.splitMainArea = splitMainArea
    }

    func start() {
        let server = WortelCLIServer(callerHandler: { [weak self] command, caller, reply in
            // The socket's queue, so hop before touching anything.
            Task { @MainActor in
                guard let self else { return reply(.failure("Wortel is shutting down.")) }
                self.handle(command, caller: caller, reply: reply)
            }
        })
        do {
            try server.start()
            self.server = server
        } catch {
            // Not fatal, and deliberately quiet: the terminal works without the
            // socket, and a modal on launch because a second copy is running
            // would be a worse morning than a command that says the app isn't
            // there.
            NSLog("wortel: CLI socket unavailable: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        waitTimer?.invalidate()
        waitTimer = nil
        waiters = []
    }

    // MARK: - Commands

    private func handle(_ command: WortelCommand, caller: WortelCLIServer.Caller,
                        reply: @escaping @Sendable (WortelResponse) -> Void) {
        // Which verbs anyone actually uses. The whole argument for having a
        // socket instead of per-agent integrations is that people wire it into
        // their own hooks, and this is the only way to find out whether they
        // do. The verb and nothing else: the path, the session name and the
        // notification text are all arguments this line does not touch.
        Telemetry.capture(.commandRun(verb: CommandVerb(command)))

        switch command {
        case .open(let path):
            reply(open(path))

        case .newSession, .newWorktree, .newFromPullRequest:
            let beside = callerSession(caller)
            manager.inWindow(window(of: beside)) { start(command, beside: beside, typing: nil, reply: reply) }

        case .newRunning(let new, let argv):
            // Checked again here: the socket is also spoken to directly.
            do {
                let line = try WortelCommandParser.startupLine(argv)
                let beside = callerSession(caller)
                manager.inWindow(window(of: beside)) { start(new, beside: beside, typing: line, reply: reply) }
            } catch {
                reply(.failure("\(error)"))
            }

        case .rename(let session, let name):
            reply(withSession(session) { session in
                manager.rename(session, to: name)
                return .success("Renamed to \u{201c}\(session.name)\u{201d}.", value: session.name)
            })

        case .mark(let session, let name):
            let clear = name.lowercased() == SessionColour.none
            guard clear || SessionColour.named(name) != nil else {
                let names = SessionColour.allCases.map(\.rawValue).joined(separator: ", ")
                reply(.failure("There's no colour \u{201c}\(name)\u{201d}. Use \(names), or none."))
                return
            }
            reply(withSession(session) { session in
                let colour = clear ? nil : SessionColour.named(name)
                manager.setColour(session, colour)
                return .success(colour.map { "Coloured \($0.rawValue)." } ?? "Colour cleared.",
                                value: colour?.rawValue ?? SessionColour.none)
            })

        case .remind(let session, let at):
            // Checked again here: the socket is also spoken to directly.
            let date = at.map { Date(timeIntervalSince1970: $0) }
            if let date, !(date.timeIntervalSinceNow > 0 && date.timeIntervalSinceNow <= ReminderTime.longest) {
                reply(.failure("A reminder has to be for a time ahead, within a year."))
                return
            }
            reply(withSession(session) { session in
                manager.setReminder(session, at: date)
                guard let date else { return .success("Reminder cancelled.") }
                return .success("Reminder set for \(ReminderTime.describe(date, now: Date())).",
                                value: ISO8601DateFormatter().string(from: date))
            })

        case .changeDirectory(let session, let path):
            // Answered at once even when the move waits for the agent's turn
            // to end: that agent is the one waiting on this reply, and its
            // turn can't end until it has it.
            reply(withSession(session) { target in manager.changeDirectory(target, to: path) })

        case .close(let session):
            // Answered at once, as `cd` is: the agent asking is waiting on
            // this reply, and the close waits for its turn to end.
            reply(withSession(session) { target in manager.closeFromCommand(target) })

        case .notify(let session, let title, let body):
            reply(withSession(session) { session in
                manager.notify(session, title: title, body: body ?? "")
                return .success()
            })

        case .split(let session, let edge, let argv):
            reply(split(session, on: edge, running: argv))

        case .list(let callerID):
            reply(list(caller: callerID))

        case .read(let query, let lines):
            read(query, lines: lines, reply: reply)

        case .send(let query, let text, let enter):
            send(text, to: query, pressingReturn: enter, caller: caller, reply: reply)

        case .wait(let query, let text, let fromStart, let idle, let exit, let timeout):
            // Checked again here, as for `.newRunning`: the socket is also
            // spoken to directly, and the timeout is printed with `Int(...)`.
            guard WortelCommandParser.isValidTimeout(timeout) else {
                return reply(.failure("That timeout isn't one: give a duration up to 7 days, or 0 for none."))
            }
            wait(for: query, text: text, fromStart: fromStart, idle: idle, exit: exit,
                 timeout: timeout, caller: caller, reply: reply)

        case .version:
            // Marketing version, because that's the one on the website and in
            // the Sparkle appcast — the number someone would quote in a bug
            // report. The build number rides along in the message for the case
            // where two builds share a version, which every local build does.
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            // The path goes in `value` rather than the sentence so the CLI can
            // compare it against its own bundle and only mention it when the
            // two differ — which is the entire thing this command is for.
            reply(.success("\(AppName.shown) \(version) (\(build))", value: Bundle.main.bundlePath))
        }
    }

    private func open(_ path: String) -> WortelResponse {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure("No such file: \(path)")
        }
        // A preview window shows a file. Refusing rather than guessing: the
        // plausible readings of a directory — reveal it in the Files pane, open
        // a session there — are different commands, and picking one silently
        // would make `wortel open .` do something surprising.
        guard !isDirectory.boolValue else {
            return .failure("\(path) is a directory. Use `wortel new --cwd` to open a session there.")
        }
        openPreview(URL(fileURLWithPath: path))
        orderFront()
        return .success(value: path)
    }

    /// The window of the session the command was run in, when it was run in
    /// one: a `wortel new` from a terminal in a window behind lands beside
    /// it, not in whichever window was last in front. Found by the caller's
    /// ancestry, as its jobs are (`RunningJobs`); nil from outside Wortel,
    /// and then the session goes to the active window.
    private func window(of session: Session?) -> SessionWindow? {
        guard manager.windows.count > 1 else { return nil }
        return session.map(manager.window(of:))
    }

    /// The session whose shell (or one of its terminals') the command came
    /// from, by the caller's ancestry; nil from outside Wortel. Found by
    /// process rather than `$WORTEL_SESSION_ID`, which `new` doesn't carry.
    private func callerSession(_ caller: WortelCLIServer.Caller) -> Session? {
        guard let pid = caller.pid else { return nil }
        let table = ProcessTable.snapshot()
        let parentOf = Dictionary(table.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        return manager.sessions.first { session in
            let shells = [session.shellPID].compactMap { $0 } + session.sideShells.map(\.pid)
            return shells.contains { pid == $0 || ProcessTable.isDescendant(pid, of: $0, parentOf: parentOf) }
        }
    }

    /// One of the `new`s, with `input` for its first shell to run. A worktree
    /// session is handed its line while it's still being made, before its
    /// row is selected: its shell starts once git is done, and the line is
    /// waiting for it.
    private func start(_ command: WortelCommand, beside: Session?, typing input: String?,
                       reply: @escaping @Sendable (WortelResponse) -> Void) {
        switch command {
        case .newSession(let cwd, let name, let branch, let base):
            newSession(cwd: cwd, name: name, branch: branch, base: base, beside: beside,
                       typing: input, reply: reply)

        case .newWorktree(let cwd, let name):
            guard let cwd = cwd ?? beside?.cwd ?? manager.placingSelected?.cwd else {
                return reply(.failure("No session to take a repository from."))
            }
            _ = manager.newWorktreeSession(
                from: cwd, inFolder: manager.folder(covering: cwd), starting: input.map(SessionStart.line) ?? .plain,
                completion: { [weak self] result, warnings in
                    self?.replyStarted(result, warnings: warnings, name: name, reply: reply)
                })

        case .newFromPullRequest(let cwd, let name, let text):
            guard let pr = PullRequestRef.parse(text) else {
                return reply(.failure("\u{201c}\(text)\u{201d} isn't a pull request: give its number or its URL."))
            }
            guard let cwd = cwd ?? beside?.cwd ?? manager.placingSelected?.cwd else {
                return reply(.failure("No session to take a repository from."))
            }
            _ = manager.newSession(
                onPullRequest: pr, from: cwd, inFolder: manager.folder(covering: cwd),
                starting: input.map(SessionStart.line) ?? .plain,
                completion: { [weak self] result, warnings in
                    self?.replyStarted(result, warnings: warnings, name: name, reply: reply)
                })

        // Listed rather than `default`, so a fourth kind of `new` is a
        // compile error here instead of this refusal.
        case .open, .rename, .notify, .mark, .remind, .changeDirectory, .close, .split, .version,
             .newRunning, .list, .read, .send, .wait:
            reply(.failure("Only a new session can be given a command to run."))
        }
    }

    private func newSession(
        cwd: String?, name: String?, branch: String?, base: String?, beside: Session?,
        typing input: String?, reply: @escaping @Sendable (WortelResponse) -> Void
    ) {
        if let cwd {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return reply(.failure("No such directory: \(cwd)"))
            }
        }
        guard let branch else {
            // Filed where ⌘O would file that directory, when a folder covers
            // it (a worktree's repository counts); otherwise next to the
            // session the command was run in when the directory is that
            // session's, else at the top level; only from outside Wortel
            // next to the selection. A script or an agent in
            // one project must not land its session in whichever folder the
            // sidebar happens to be showing.
            var folder = cwd.flatMap(manager.folder(covering:))
            if folder == nil, let beside, cwd.map({ manager.belongs($0, beside: beside) }) ?? true {
                folder = beside.folderPath
            }
            let session = manager.newSession(cwd: cwd, inFolder: folder, beside: beside,
                                             via: .cli, starting: input.map(SessionStart.line) ?? .plain)
            if let name { manager.rename(session, to: name) }
            orderFront()
            if let refusal = commandDropped(session) { return reply(refusal) }
            return reply(.success("Started \u{201c}\(session.name)\u{201d}.",
                                  value: session.id.uuidString))
        }
        // The worktree path: git work, so the answer comes later. The repository
        // is taken from the caller's directory rather than from the selection —
        // a script in one repo must not open a worktree of whichever repo the
        // sidebar happens to be pointing at. The row is on screen meanwhile,
        // saying it's preparing, as it is for the sheet.
        guard let cwd = cwd ?? beside?.cwd ?? manager.placingSelected?.cwd else {
            return reply(.failure("No session to take a repository from."))
        }
        let created = manager.newSession(
            onBranch: branch, base: base, from: cwd, inFolder: manager.folder(covering: cwd),
            starting: input.map(SessionStart.line) ?? .plain,
            completion: { [weak self] result, warnings in
                self?.replyStarted(result, warnings: warnings, name: name, reply: reply)
            })
        if created == nil { reply(.failure("No branch given.")) }
    }

    /// The answer to a `new` that waited on git: the session's id, and any
    /// notes from the way there after the "Started" line.
    private func replyStarted(_ result: Result<Session, SessionManager.Failure>, warnings: [String],
                              name: String?, reply: @escaping @Sendable (WortelResponse) -> Void) {
        switch result {
        case .success(let session):
            if let name { manager.rename(session, to: name) }
            orderFront()
            if let refusal = commandDropped(session) { return reply(refusal) }
            let notes = warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n")
            reply(.success("Started \u{201c}\(session.name)\u{201d}.\(notes)", value: session.id.uuidString))
        case .failure(let failure):
            // git's own words. "already checked out at …" names the
            // directory you want; a paraphrase would drop the path.
            reply(.failure(failure.message))
        }
    }

    /// A failure when the session opened but its command was not typed into
    /// it. A failure and not a note: a script that asked for a command needs
    /// the exit status to say it didn't run, so it can try something else.
    private func commandDropped(_ session: Session) -> WortelResponse? {
        guard session.startupInputDropped else { return nil }
        return .failure("Started \u{201c}\(session.name)\u{201d}, but its shell came up without "
            + "Wortel's keeper, so the command was not run in it.")
    }

    /// `wortel split`: a new terminal in a split on `edge` of the session's
    /// main row, in the session's folder, with `argv` as its shell's first
    /// line when there is one.
    ///
    /// Nothing is brought forward and nothing takes the keyboard: an agent
    /// runs this while a person is typing to it. In a session that is on
    /// screen the split appears beside what they are typing in; in one that
    /// isn't, it is there when the session is next selected. Either way the
    /// shell starts now (`SessionManager.startSideTerminal`), so the command
    /// is running whether or not anyone is looking.
    ///
    /// A session whose agent is asleep takes one like any other: the new
    /// terminal is a shell of its own, and nothing is typed at the agent, so
    /// there is nothing to wake it for (as there is for `send`).
    private func split(_ id: String?, on edgeName: String, running argv: [String]) -> WortelResponse {
        // Both checked again here: the socket is also spoken to directly.
        guard let edge = SplitLayout.Edge(rawValue: edgeName) else {
            return .failure("There's no side \u{201c}\(edgeName)\u{201d} to split on. Use right, down, left or up.")
        }
        var line: String?
        if !argv.isEmpty {
            do { line = try WortelCommandParser.startupLine(argv) } catch { return .failure("\(error)") }
        }
        return withSession(id) { session in
            let quoted = "\u{201c}\(session.name)\u{201d}"
            // As `read` and `send` say it: there is no folder for a shell
            // to start in yet.
            guard session.preparation == nil else {
                return .failure("\(quoted) has no terminal yet: its worktree is still being made.")
            }
            let terminal = UUID()
            switch splitMainArea(session, edge, .terminal(terminal)) {
            case .made:
                break
            case .noRoom:
                return .failure("There's no room for another split in \(quoted): both halves would be too "
                    + "small to use. Make the window bigger, or close a split.")
            case .notMade:
                return .failure("\(quoted) could not be split.")
            }
            // In the same turn as the split, before any row has had the
            // chance to make this terminal's view without its line.
            let view = manager.startSideTerminal(terminal, of: session, typing: line)
            if line != nil, view.initialInputDropped {
                // A failure, as for `new`: a script that asked for a command
                // needs the exit status to say it didn't run.
                return .failure("Split \(quoted), but the new shell came up without Wortel's keeper, "
                    + "so the command was not run in it.")
            }
            return .success()
        }
    }

    /// Run `body` on the session a command is about: the one it was run in.
    ///
    /// Two failures, and they read differently on purpose. No id at all means
    /// the command was run outside Wortel — from Terminal.app, or a launchd job
    /// — where "this session" names nothing. An id that no longer resolves means
    /// the session was closed while something in it was still running, which is
    /// the ordinary end of a background job whose shell outlived its row.
    ///
    /// A name instead of an id is `--session` on `rename`, `notify`, `mark`, `remind`
    /// or `split`, and is looked up the way `read` and `send` look one up.
    private func withSession(
        _ id: String?, _ body: (Session) -> WortelResponse
    ) -> WortelResponse {
        guard let id else {
            return .failure(
                "Not running inside a Wortel session (no $\(WortelCommandParser.sessionVariable)).")
        }
        guard let uuid = UUID(uuidString: id) else {
            switch lookUp(id) {
            case .found(let session): return body(session)
            case .refused(let refusal): return refusal
            }
        }
        guard let session = manager.session(id: uuid) else {
            return .failure("That session has closed.")
        }
        return body(session)
    }

    // MARK: - Reaching other sessions

    private enum Lookup {
        case found(Session)
        case refused(WortelResponse)
    }

    /// The session a `<session>` names (`WortelSessionAddress`), or the
    /// sentence that says why there isn't exactly one. An id is the session's
    /// or one of its terminals', as `$WORTEL_SESSION_ID` is.
    private func lookUp(_ query: String) -> Lookup {
        if let uuid = UUID(uuidString: query) {
            guard let session = manager.session(id: uuid) else {
                return .refused(.failure("There's no open session with the id \(query)."))
            }
            return .found(session)
        }
        let candidates = manager.sessions.map {
            WortelSessionAddress.Candidate(id: $0.id, name: $0.name, leaf: $0.leafName)
        }
        switch WortelSessionAddress.resolve(query, among: candidates) {
        case .found(let id):
            guard let session = manager.session(id: id) else { return .refused(.failure("That session has closed.")) }
            return .found(session)
        case .none:
            return .refused(.failure(
                "There's no session called \u{201c}\(query)\u{201d}. `wortel list` shows the open ones."))
        case .ambiguous(let matches):
            let names = matches.map { "\u{201c}\($0.name)\u{201d} (\($0.id.uuidString.prefix(8)))" }
            return .refused(.failure(
                "\u{201c}\(query)\u{201d} could be \(names.joined(separator: ", ")). "
                    + "Use more of the name, or the id."))
        }
    }

    /// `wortel list`: every open session in sidebar order: pinned, the folders, then
    /// the sessions in no folder, each section by its Sort By.
    private func list(caller: String?) -> WortelResponse {
        let you = caller.flatMap(UUID.init(uuidString:)).flatMap(manager.session(id:))
        // Each window's in turn, the one in front first; `selected` is the
        // session in front in its window, so with two windows two are.
        let sessions = manager.sessionsInSidebarOrder.map { session in
            WortelSessionInfo(
                id: session.id.uuidString, name: session.name, folder: session.folderPath,
                directory: session.cwd ?? session.originCwd,
                branch: session.worktreeBranch ?? session.linkedCheckout.flatMap { Self.branch(atGitDir: $0.gitDir) },
                worktree: session.linkedCheckout?.root,
                // An agent asleep is still this session's agent: sleep is
                // Wortel's business, and a script should not have to know.
                agent: session.runningAgent ?? session.sleep.agent?.marker.agent, state: state(of: session),
                selected: manager.isFront(session), caller: session === you)
        }
        guard let data = try? JSONEncoder().encode(sessions) else {
            return .failure("Couldn't describe the sessions.")
        }
        return .success(value: String(decoding: data, as: UTF8.self))
    }

    /// The branch a linked worktree has checked out, from its HEAD file: a
    /// read of a few bytes rather than a git process per row. nil on a
    /// detached HEAD, which has no branch to name.
    private static func branch(atGitDir gitDir: String) -> String? {
        guard !gitDir.isEmpty,
              let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let prefix = "ref: refs/heads/"
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// The state column, from what the sidebar already believes. Asking for
    /// action beats working: a title saying "Action Required" is the agent
    /// blocked, whatever its spinner last said.
    private func state(of session: Session) -> WortelSessionInfo.State {
        if session.preparation != nil { return .preparing }
        let activity = manager.activity(of: session)
        if activity.asksForAction { return .needsYou }
        if activity.busy || activity.settling { return .working }
        switch activity.outcome {
        case .needsInput?: return .needsYou
        case .failed?: return .failed
        case .turnDone?, .finished?: return .finished
        case nil: return .idle
        }
    }

    /// The session's terminal for `read`, `send` and `wait`, warmed if it
    /// hasn't been shown since launch, or the refusal.
    private func terminal(of session: Session) -> (SurfaceView?, WortelResponse?) {
        guard let view = manager.warmSurface(of: session) else {
            return (nil, .failure("\u{201c}\(session.name)\u{201d} has no terminal yet: its worktree is still being made."))
        }
        return (view, nil)
    }

    /// `wortel read`. A terminal warmed for the purpose is read once its
    /// replay has landed, so a session restored at launch and never shown
    /// reads as what it says rather than as blank.
    private func read(_ query: String, lines: Int?, reply: @escaping @Sendable (WortelResponse) -> Void) {
        let session: Session
        switch lookUp(query) {
        case .found(let found): session = found
        case .refused(let refusal): return reply(refusal)
        }
        let (view, refusal) = terminal(of: session)
        guard let view else { return reply(refusal ?? .failure("That session has closed.")) }
        let id = session.id.uuidString, name = session.name
        view.afterPendingOutput {
            // `--lines` reads the scrollback only when the screen doesn't
            // hold that many: a read of all of it is the one libghostty can
            // bound no tighter (`ScreenText.lastLines`).
            let text: String?
            if let lines {
                text = ScreenText.lastLines(lines, active: view.readText(includingScrollback: false),
                                            whole: { view.readText(includingScrollback: true) })
            } else {
                text = view.readText(includingScrollback: false).map { ScreenText.tidy($0) }
            }
            guard let text else { return reply(.failure("That session has closed.")) }
            let screen = WortelScreen(id: id, name: name, text: text)
            guard let data = try? JSONEncoder().encode(screen) else {
                return reply(.failure("Couldn't read \u{201c}\(name)\u{201d}."))
            }
            reply(.success(value: String(decoding: data, as: UTF8.self)))
        }
    }

    /// How long after a paste `send --enter` presses Return. A person's Return
    /// comes a beat after the paste, and some agents rely on that: Codex reads
    /// keys that arrive in a burst as one paste, and a Return inside the
    /// burst as a newline in the prompt rather than sending it. Long enough to
    /// be its own keypress, short enough not to be noticed.
    private static let returnAfterPaste: TimeInterval = 0.2

    /// `wortel send`: the text in as a paste, exactly as ⌘V would put it
    /// (`ghostty_surface_text`, bracketed when the program asked for that, so
    /// a multi-line prompt arrives in an agent's input as one input), then
    /// Return as a separate key. Nothing is added in front, nothing selects
    /// the session or takes focus, and the input tap (`PromptTap`) sees it
    /// as it sees typing, because it reaches the pty by
    /// the same road. It is not the user's input, though (`scripted`): it
    /// doesn't answer an attention raised while they were away, or count as
    /// them having touched the session.
    private func send(_ text: String, to query: String, pressingReturn enter: Bool,
                      caller: WortelCLIServer.Caller,
                      reply: @escaping @Sendable (WortelResponse) -> Void) {
        let session: Session
        switch lookUp(query) {
        case .found(let found): session = found
        case .refused(let refusal): return reply(refusal)
        }
        // Its agent is asleep, or on its way there (`AgentSleep`): what is
        // being sent is for the agent, and typed now it would land in the
        // bare shell and run as a command. So the agent is asked back, and
        // nothing is typed. What is said is what is actually happening: a
        // script that is told to try again must not be told so for ever.
        if session.sleep.agent != nil {
            let quoted = "\u{201c}\(session.name)\u{201d}"
            switch manager.wake(session) {
            case .starting:
                return reply(.failure("\(quoted) had its agent put to sleep and is bringing it back now, "
                    + "so nothing was typed. Send it again in a few seconds."))
            case .shellBusy:
                return reply(.failure("\(quoted) had its agent put to sleep, and its shell isn't at a prompt "
                    + "yet to bring it back from, so nothing was typed. Send it again in a few seconds."))
            case .gaveUp:
                return reply(.failure("\(quoted) had its agent put to sleep, and it didn't start again when "
                    + "resumed. Nothing was typed. The session is a plain shell now."))
            case .notAsleep:
                break
            }
        }
        let (view, refusal) = terminal(of: session)
        guard let view else { return reply(refusal ?? .failure("That session has closed.")) }
        let name = session.name
        // Within the CLI's own deadline, or not at all (`sendPatience`).
        view.whenPasteReachesProgram(within: WortelCLI.sendPatience) { ready in
            guard ready else {
                return reply(.failure("\u{201c}\(name)\u{201d} wasn't ready for input within "
                    + "\(Int(WortelCLI.sendPatience))s (its terminal is still being restored, or its program "
                    + "is still starting), so nothing was typed."))
            }
            // A CLI that gave up anyway (killed, ^C) must not have its text
            // typed behind its back either.
            guard !caller.hasHungUp() else { return reply(.failure("Nobody is waiting any more.")) }
            guard view.surface != nil else { return reply(.failure("That session has closed.")) }
            guard !view.shellHasExited else {
                return reply(.failure("\u{201c}\(name)\u{201d} has no shell any more: it exited."))
            }
            if !text.isEmpty { view.sendText(text, scripted: true) }
            guard enter else { return reply(.success()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (text.isEmpty ? 0 : Self.returnAfterPaste)) {
                MainActor.assumeIsolated {
                    view.pressReturn(scripted: true)
                    reply(.success())
                }
            }
        }
    }

    // MARK: - Waiting

    /// One `wortel wait` in progress: its connection is held open until a
    /// condition holds, the time runs out, or the CLI goes away.
    @MainActor
    private final class Waiter {
        let session: Session.ID
        let name: String
        let needle: String?
        /// What `--for` has seen so far (`NewTextWatch`): the active screen
        /// at the last look, and the count to beat when the whole terminal
        /// has to be read.
        var watch: NewTextWatch?
        var seenOutput: UInt64?
        var lastScreenRead: Date
        var lastWholeRead: Date = .distantPast
        let idle: Bool
        let exit: Bool
        let startedAt: Date
        let timeout: Double
        let deadline: Date?
        /// When the session was first seen quiet in the current quiet stretch.
        var quietSince: Date?
        /// The session was seen working at some point during the wait.
        var sawBusy = false
        let caller: WortelCLIServer.Caller
        let reply: @Sendable (WortelResponse) -> Void

        init(session: Session, needle: String?, watch: NewTextWatch?, seenOutput: UInt64?, idle: Bool,
             exit: Bool, timeout: Double, caller: WortelCLIServer.Caller,
             reply: @escaping @Sendable (WortelResponse) -> Void) {
            let now = Date()
            self.session = session.id
            self.name = session.name
            self.needle = needle
            self.watch = watch
            self.seenOutput = seenOutput
            self.lastScreenRead = now
            self.idle = idle
            self.exit = exit
            self.startedAt = now
            self.timeout = timeout
            self.deadline = timeout > 0 ? now.addingTimeInterval(timeout) : nil
            self.caller = caller
            self.reply = reply
        }
    }

    private var waiters: [Waiter] = []
    private var waitTimer: Timer?

    /// How often the waits are looked at. Each look is a few dictionary reads
    /// per wait; the screen is read only for a `--for` whose terminal has had
    /// output since the last look, and at most every `screenReadInterval`. The
    /// timer exists only while a wait does.
    private static let waitTick: TimeInterval = 0.25
    private static let screenReadInterval: TimeInterval = 0.5
    /// How often, at most, a `--for` reads the whole terminal, scrollback
    /// included, which it does only once more than a screenful has gone by
    /// between two looks (`NewTextWatch`). Text in a flood is found this
    /// late at worst, and the flood costs one big read per interval rather
    /// than two a second.
    private static let wholeReadInterval: TimeInterval = 3
    /// On the exec backend, which has no output counter, the screen is read
    /// this often instead.
    private static let blindScreenReadInterval: TimeInterval = 1
    /// A turn seen to start counts as over once the session has been quiet
    /// this long, unless it said how it ended: a gap between two tools in one
    /// turn is shorter.
    private static let quietAfterTurn: TimeInterval = 1
    /// With no turn seen, how long after the last thing typed into the session
    /// (a `send`), or after its shell started (a `new -- claude …` whose line
    /// is still on its way), its quiet is believed. An agent shows it has
    /// started within a second or so; until then, quiet means "not yet", not
    /// "done".
    private static let quietAfterInput: TimeInterval = 5

    /// `wortel wait`. The answer comes when a condition holds; until then the
    /// connection stays open and nothing on the main thread blocks: the
    /// waits are looked at on a timer, between everything else.
    private func wait(for query: String, text: String?, fromStart: Bool, idle: Bool, exit: Bool,
                      timeout: Double, caller: WortelCLIServer.Caller,
                      reply: @escaping @Sendable (WortelResponse) -> Void) {
        let session: Session
        switch lookUp(query) {
        case .found(let found): session = found
        case .refused(let refusal): return reply(refusal)
        }
        let (view, refusal) = terminal(of: session)
        guard let view else { return reply(refusal ?? .failure("That session has closed.")) }
        // After the replay, so a session warmed for this has its screen to
        // count against, and text it had already printed isn't taken as new.
        view.afterPendingOutput { [weak self] in
            guard let self else { return reply(.failure("Wortel is shutting down.")) }
            let seen = view.outputGeneration
            // The whole terminal is read once here, for the count to beat;
            // after that only when text may have scrolled past unseen. The
            // screen first, so text printed between the two reads is new to
            // the next look rather than to neither. `--from-start` beats 0,
            // and its first look is at everything at once: what's there
            // already counts.
            let watch = text.map { text in
                let screen = view.readText(includingScrollback: false) ?? ""
                let total = fromStart ? 0
                    : view.readText(includingScrollback: true).map { ScreenText.occurrences(of: text, in: $0) } ?? 0
                return NewTextWatch(needle: text, screen: screen, total: total, needsWholeRead: fromStart)
            }
            let waiter = Waiter(session: session, needle: text, watch: watch,
                                seenOutput: seen, idle: idle, exit: exit,
                                timeout: timeout, caller: caller, reply: reply)
            self.waiters.append(waiter)
            self.checkWaits()
            if !self.waiters.isEmpty, self.waitTimer == nil {
                let timer = Timer(timeInterval: Self.waitTick, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkWaits() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.waitTimer = timer
            }
        }
    }

    private func checkWaits() {
        let now = Date()
        for waiter in waiters {
            guard let answer = verdict(for: waiter, now: now) else { continue }
            waiters.removeAll { $0 === waiter }
            waiter.reply(answer)
        }
        if waiters.isEmpty {
            waitTimer?.invalidate()
            waitTimer = nil
        }
    }

    /// The answer for a wait, or nil while it should keep waiting.
    private func verdict(for waiter: Waiter, now: Date) -> WortelResponse? {
        // Answered anyway, though nobody will read it: the reply is what
        // closes the connection.
        if waiter.caller.hasHungUp() { return .failure("Nobody is waiting any more.") }
        guard let session = manager.session(id: waiter.session), session.id == waiter.session else {
            return waiter.exit ? .success(value: "exit")
                : .failure("\u{201c}\(waiter.name)\u{201d} closed before it \(goal(of: waiter)).")
        }
        var view = session.surfaceView
        if waiter.exit, view?.shellHasExited ?? false { return .success(value: "exit") }
        // Text is looked for on the screen, so a hibernated terminal wakes,
        // and is read once its screen is back: read half restored, text that
        // was there all along would look new when the rest arrives.
        if waiter.watch != nil, view?.isHibernated == true { _ = manager.warmSurface(of: session) }
        if view?.isHibernated == true || view?.isRestoring == true { view = nil }
        if var watch = waiter.watch, let view {
            defer { waiter.watch = watch }
            if screenIsDue(waiter, view: view, now: now) {
                waiter.lastScreenRead = now
                waiter.seenOutput = view.outputGeneration
                if let screen = view.readText(includingScrollback: false), watch.look(atScreen: screen) {
                    return .success(value: "text")
                }
            }
            // Not gated on new output: a flood that has just stopped still
            // owes its one read.
            if watch.needsWholeRead, now.timeIntervalSince(waiter.lastWholeRead) >= Self.wholeReadInterval,
               let screen = view.readText(includingScrollback: false),
               let whole = view.readText(includingScrollback: true) {
                waiter.lastWholeRead = now
                if watch.look(atWhole: whole, screen: screen) { return .success(value: "text") }
            }
        }
        if waiter.idle, isIdle(session, for: waiter, now: now) { return .success(value: "idle") }
        if let deadline = waiter.deadline, now >= deadline {
            return .failure(
                "Timed out after \(Self.display(waiter.timeout)) waiting for \u{201c}\(waiter.name)\u{201d} to \(goal(of: waiter, future: true)).",
                status: WortelCLI.waitTimedOutStatus)
        }
        return nil
    }

    /// Whether a `--for` should read the screen now: new output since the
    /// last read, and not more often than `screenReadInterval`.
    private func screenIsDue(_ waiter: Waiter, view: SurfaceView, now: Date) -> Bool {
        let since = now.timeIntervalSince(waiter.lastScreenRead)
        guard let generation = view.outputGeneration else { return since >= Self.blindScreenReadInterval }
        return generation != waiter.seenOutput && since >= Self.screenReadInterval
    }

    /// `--idle`: the agent's turn is over, or it's asking for you, or the
    /// shell is back at its prompt.
    ///
    /// The hard part is a wait that starts right after a `send`, before the
    /// agent has shown it started: it is quiet then, and that quiet means
    /// "not yet". So quiet counts only once a turn has been seen (a start
    /// reported after the wait began, or the session seen working during
    /// it), and otherwise only once nothing has been typed into the session
    /// for `quietAfterInput`. A session nobody has touched lately is idle at
    /// once.
    private func isIdle(_ session: Session, for waiter: Waiter, now: Date) -> Bool {
        let activity = manager.activity(of: session)
        if activity.busy { waiter.sawBusy = true }
        guard activity.asksForAction || (!activity.busy && !activity.settling) else {
            waiter.quietSince = nil
            return false
        }
        let quietSince = waiter.quietSince ?? now
        waiter.quietSince = quietSince
        let turnSeen = waiter.sawBusy || (activity.lastStarted.map { $0 > waiter.startedAt } ?? false)
        if turnSeen {
            // How it ended was said (the dot's own signal), or the quiet has
            // outlasted a pause between tools.
            return activity.asksForAction || (waiter.sawBusy && activity.outcome != nil)
                || now.timeIntervalSince(quietSince) >= Self.quietAfterTurn
        }
        let view = session.surfaceView
        let lastTouched = [view?.lastUserInputAt, view?.lastScriptedInputAt, view?.shellStartedAt,
                           activity.lastStarted].compactMap { $0 }.max() ?? .distantPast
        return now.timeIntervalSince(lastTouched) >= Self.quietAfterInput
    }

    /// What a wait was for, for its messages: "show \u{201c}DONE\u{201d} or go idle".
    private func goal(of waiter: Waiter, future: Bool = false) -> String {
        var parts: [String] = []
        if let needle = waiter.needle {
            parts.append(future ? "show \u{201c}\(needle)\u{201d}" : "showed \u{201c}\(needle)\u{201d}")
        }
        if waiter.idle { parts.append(future ? "go idle" : "went idle") }
        if waiter.exit { parts.append(future ? "exit" : "exited") }
        return parts.joined(separator: " or ")
    }

    /// A timeout as it was most likely typed: `30s`, `5m`, `1.5s`.
    private static func display(_ seconds: Double) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
        if seconds.rounded() == seconds { return "\(Int(seconds))s" }
        return String(format: "%.1fs", seconds)
    }
}
