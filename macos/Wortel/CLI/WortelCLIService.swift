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
@MainActor
final class WortelCLIService {
    private let manager: SessionManager
    private let openPreview: (URL) -> Void
    /// Brought forward for anything that opens a window. Not activated — see
    /// the type's note.
    private let orderFront: () -> Void
    private var server: WortelCLIServer?

    init(manager: SessionManager, openPreview: @escaping (URL) -> Void,
         orderFront: @escaping () -> Void) {
        self.manager = manager
        self.openPreview = openPreview
        self.orderFront = orderFront
    }

    func start() {
        let server = WortelCLIServer { [weak self] command, reply in
            // The socket's queue, so hop before touching anything.
            Task { @MainActor in
                guard let self else { return reply(.failure("Wortel is shutting down.")) }
                self.handle(command, reply: reply)
            }
        }
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
    }

    // MARK: - Commands

    private func handle(_ command: WortelCommand, reply: @escaping @Sendable (WortelResponse) -> Void) {
        switch command {
        case .open(let path):
            reply(open(path))

        case .newSession(let cwd, let name, let branch, let base):
            newSession(cwd: cwd, name: name, branch: branch, base: base, reply: reply)

        case .rename(let session, let name):
            reply(withSession(session) { session in
                manager.rename(session, to: name)
                return .success("Renamed to \u{201c}\(session.name)\u{201d}.", value: session.name)
            })

        case .notify(let session, let title, let body):
            reply(withSession(session) { session in
                manager.notify(session, title: title, body: body ?? "")
                return .success()
            })

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
            reply(.success("Wortel \(version) (\(build))", value: Bundle.main.bundlePath))
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

    private func newSession(
        cwd: String?, name: String?, branch: String?, base: String?,
        reply: @escaping @Sendable (WortelResponse) -> Void
    ) {
        if let cwd {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return reply(.failure("No such directory: \(cwd)"))
            }
        }
        guard let branch else {
            let session = manager.newSession(cwd: cwd)
            if let name { manager.rename(session, to: name) }
            orderFront()
            return reply(.success("Started \u{201c}\(session.name)\u{201d}.",
                                  value: session.id.uuidString))
        }
        // The worktree path: git work, so the answer comes later. The repository
        // is taken from the caller's directory rather than from the selection —
        // a script in one repo must not open a worktree of whichever repo the
        // sidebar happens to be pointing at.
        Task { @MainActor in
            switch await manager.openSession(onBranch: branch, base: base, from: cwd) {
            case .success(let session):
                if let name { manager.rename(session, to: name) }
                orderFront()
                reply(.success("Started \u{201c}\(session.name)\u{201d}.",
                               value: session.id.uuidString))
            case .failure(let failure):
                // git's own words. "already checked out at …" names the
                // directory you want; a paraphrase would drop the path.
                reply(.failure(failure.message))
            }
        }
    }

    /// Run `body` on the session a command is about: the one it was run in.
    ///
    /// Two failures, and they read differently on purpose. No id at all means
    /// the command was run outside Wortel — from Terminal.app, or a launchd job
    /// — where "this session" names nothing. An id that no longer resolves means
    /// the session was closed while something in it was still running, which is
    /// the ordinary end of a background job whose shell outlived its row.
    private func withSession(
        _ id: String?, _ body: (Session) -> WortelResponse
    ) -> WortelResponse {
        guard let id, let uuid = UUID(uuidString: id) else {
            return .failure(
                "Not running inside a Wortel session (no $\(WortelCommandParser.sessionVariable)).")
        }
        guard let session = manager.session(id: uuid) else {
            return .failure("That session has closed.")
        }
        return body(session)
    }
}
