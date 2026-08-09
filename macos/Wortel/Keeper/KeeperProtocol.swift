import Foundation

/// The wire between Wortel and the process that holds its ptys.
///
/// **Why a second process exists at all.** A shell is a child of whoever forked
/// it, and its pty master is a descriptor in that process. Quit the app and both
/// go away — which is why closing Wortel today takes every running agent with
/// it. The keeper is a small, long-lived process that does the forking instead,
/// so the app becomes something that *attaches* to work already in progress
/// rather than something the work depends on.
///
/// **Why the app still reads the pty itself.** The obvious design has the keeper
/// read the pty and forward everything over this socket, and it would cost a
/// copy, a context switch and a wakeup on the hottest path in a terminal — the
/// one thing Wortel is not allowed to be slow at. So the keeper passes the
/// *descriptor* instead (`SCM_RIGHTS`), and while a session is attached the app
/// reads it directly, exactly as it does today. The keeper's `dup` is what keeps
/// the pty alive when the app lets go.
///
/// That leaves one rule the whole design rests on: **only one process may read a
/// pty at a time.** Two readers would split the bytes between them, and the
/// corruption would be intermittent and unreproducible. So the keeper reads only
/// while detached, the app only while attached, and `attach`/`detach` are the
/// handover — anything that arrives between the keeper's last read and the app's
/// first stays in the kernel's buffer, which is why nothing is lost in the gap.
enum KeeperCommand: Codable, Equatable {
    /// Is anyone there, and which build?
    case ping
    /// Start a session: a pty, and a shell on the end of it. Replies with the
    /// pty descriptor attached.
    case open(session: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16)
    /// Take over reading a session that already exists. Replies with whatever
    /// was buffered while nobody was attached, and the descriptor.
    case attach(session: String)
    /// Hand reading back. Implied by disconnecting, which is what a crash looks
    /// like.
    case detach(session: String)
    /// End it: SIGHUP the shell and forget the session.
    case close(session: String)
    /// What is still running.
    case list

    var verb: String {
        switch self {
        case .ping: return "ping"
        case .open: return "open"
        case .attach: return "attach"
        case .detach: return "detach"
        case .close: return "close"
        case .list: return "list"
        }
    }
}

/// Everything needed to start a shell, as data — because the process that does
/// the forking is no longer the process that knows about bundles, sessions or
/// shell integration.
struct KeeperSpawnPlan: Codable, Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
}

/// What the keeper says back. One JSON line, and for `open`/`attach` a
/// descriptor rides alongside it as ancillary data.
struct KeeperResponse: Codable, Equatable {
    var ok: Bool
    var message: String?
    /// The shell's pid — what you check with `ps` to see it outlive the app.
    var pid: Int32?
    /// Output that arrived while nobody was attached, oldest first. Base64 in
    /// the JSON, which is what `Data`'s Codable conformance does.
    var replay: Data?
    /// For `list`.
    var sessions: [KeeperSessionState]?
    /// The keeper's own build, so a stale keeper left over from an older app can
    /// be recognised instead of talked to.
    var version: String?

    static func failure(_ message: String) -> KeeperResponse {
        KeeperResponse(ok: false, message: message)
    }

    static func success(
        message: String? = nil, pid: Int32? = nil, replay: Data? = nil,
        sessions: [KeeperSessionState]? = nil, version: String? = nil
    ) -> KeeperResponse {
        KeeperResponse(ok: true, message: message, pid: pid, replay: replay,
                       sessions: sessions, version: version)
    }
}

struct KeeperSessionState: Codable, Equatable {
    var session: String
    var pid: Int32
    /// True while some app has the descriptor. A session nobody is attached to
    /// is still running — that is the entire point.
    var attached: Bool
    /// How much output is waiting to be replayed.
    var buffered: Int
}

enum Keeper {
    /// Beside the CLI socket, and for the same reason: it is app state, and both
    /// ends can derive the path without being told.
    static var socketPath: String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Wortel/keeper.sock").path
    }

    /// The protocol version. Bumped when the wire changes shape; a keeper that
    /// doesn't match is killed and replaced rather than negotiated with, because
    /// it is *our* process and there is no user data in it to preserve beyond
    /// the shells — which is exactly what a mismatch would put at risk.
    static let version = "1"

    /// A JSON reply is small; anything near this is a confused peer. The replay
    /// payload is base64 inside that JSON, so the ceiling has to clear it.
    static let maximumLineBytes = replayLimit * 2

    /// A session's output is buffered only while nobody is attached, so this
    /// bounds "what you missed", not scrollback. Big enough for a build log,
    /// small enough that a runaway process detached overnight can't grow the
    /// keeper without limit.
    static let replayLimit = 512 * 1024
}
