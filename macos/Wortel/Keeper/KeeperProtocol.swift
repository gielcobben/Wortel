import Foundation
import OSLog

/// What both ends of the keeper say about its life: started, connected,
/// replaced, ended and why, and what the app did about it.
///
/// Default level and up only, so it is kept on disk and can be read days
/// later. The keeper was the one process in the 2026-10-08 incident that had
/// left no trace at all; the investigation had to infer its death from a
/// security agent that happened to probe it every quarter of an hour. To read
/// it:
///
///     log show --last 1d --predicate 'subsystem == "com.gielcobben.Wortel" && category == "keeper"'
enum KeeperLog {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "keeper")
}

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
    /// like, and that is the only way the app ever detaches: it never sends
    /// this. Kept because a keeper has to understand every verb an app it may
    /// meet could send, and removing one is a protocol change.
    case detach(session: String)
    /// End it: SIGHUP the shell and forget the session.
    case close(session: String)
    /// What is still running.
    case list
    /// Open a session whose terminal the keeper keeps, or attach to one that
    /// is already running (the plan is then ignored, as for `open`).
    ///
    /// The keeper reads the pty itself and goes on reading: the app is given
    /// two descriptors, the session's **output channel** and the pty. The
    /// channel starts with a snapshot of the keeper's terminal for the session
    /// (`KeeperChannel`), then carries every byte the program writes after
    /// it, so nothing is lost or seen twice between the two. The pty is for
    /// typing, and for asking who is in the foreground; the app never reads
    /// it. Attaching again (a terminal shown after being dropped) ends the
    /// previous channel after its last byte and starts a new one.
    case terminal(session: String, plan: KeeperSpawnPlan, columns: UInt16, rows: UInt16)
    /// A new size for a session's pty and terminal, applied between two reads
    /// of its output, so what came before is parsed at the old size and what
    /// comes after at the new one.
    case resize(session: String, columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    /// What the app shows terminals in. For every session, and every one
    /// opened later: the keeper answers the programs that ask.
    case appearance(KeeperAppearance)
    /// Whether each of `modes` (DEC private mode numbers) is set in a
    /// session's terminal. Replied in `modes`, in the same order.
    case modes(session: String, modes: [UInt16])

    var verb: String {
        switch self {
        case .ping: return "ping"
        case .open: return "open"
        case .attach: return "attach"
        case .detach: return "detach"
        case .close: return "close"
        case .list: return "list"
        case .terminal: return "terminal"
        case .resize: return "resize"
        case .appearance: return "appearance"
        case .modes: return "modes"
        }
    }
}

/// The colours the app shows terminals in, and whether that is light or dark.
/// The keeper's terminals answer programs from it (OSC 10, 11, 12 and 4 for
/// colours, `CSI ? 996 n` for light or dark) and tell a program that asked to
/// hear (`?2031`) when light or dark changes, with or without the app.
struct KeeperAppearance: Codable, Equatable, Sendable {
    var dark: Bool
    /// 0xRRGGBB.
    var foreground: UInt32
    var background: UInt32
    var cursor: UInt32?
    /// 256 entries, or none for libghostty's own.
    var palette: [UInt32] = []
}

/// The start of a session's output channel (`KeeperCommand.terminal`): a
/// header, then a snapshot of the keeper's terminal as libghostty-vt encodes
/// it, then the program's output, raw, from the byte after the snapshot on.
///
///     "WKT1"  UInt64 big-endian snapshot length  snapshot bytes  output...
///
/// The snapshot is only meaningful to a Ghostty built from the same commit as
/// the keeper's, which is the one in this app bundle.
enum KeeperChannel {
    static let magic: [UInt8] = Array("WKT1".utf8)
    static let headerSize = 12

    static func header(snapshotLength: Int) -> [UInt8] {
        var length = UInt64(snapshotLength).bigEndian
        return magic + withUnsafeBytes(of: &length) { Array($0) }
    }

    /// The snapshot length a complete header says, or nil for one that is not
    /// a header at all.
    static func snapshotLength(header bytes: some Collection<UInt8>) -> Int? {
        guard bytes.count == headerSize, bytes.prefix(4).elementsEqual(magic) else { return nil }
        let length = bytes.dropFirst(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return length <= UInt64(Int.max) ? Int(length) : nil
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
    /// Typed into the pty as soon as the shell is forked: the agent's resume
    /// command for a restored session. The keeper does the typing rather than
    /// the app so that it can **remember having done it** (`inputDelivered`),
    /// which is what lets a later attach tell "the resume was never typed"
    /// from "it was typed and the agent has since gone". Optional, and absent
    /// from the wire when nil, so a keeper from before it simply never types
    /// and never claims to have.
    var initialInput: String? = nil
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
    /// For `ping`: the protocol the keeper speaks (`Keeper.version`). A
    /// different one is a keeper that cannot be talked to at all.
    var version: String?
    /// For `ping`: the app build the keeper binary came from (the bundle's
    /// `CFBundleVersion`), read when the keeper started. nil from a keeper that
    /// predates the field or could not read it, which the app treats as
    /// outdated. See `KeeperConnection.connect`.
    var build: String?
    /// For `ping`: the keeper's own executable, for the log line that says
    /// which keeper an app found.
    var executable: String?
    /// For `open`: the session already existed and this attached to it, so
    /// nothing was forked and the plan, `initialInput` included, was ignored.
    /// nil from a keeper that predates the field.
    var existing: Bool?
    /// For `open` and `attach`: whether this keeper typed the session's
    /// `initialInput` into the pty when it forked the shell. nil from a keeper
    /// that predates the field, which the app reads as "don't know", never as
    /// "no".
    var inputDelivered: Bool?
    /// For `open` and `attach`: when the shell was forked, as seconds since
    /// 1970. A shell young enough to still be reading its rc files has not had
    /// time to run what was typed into it; this is how the app tells that from
    /// an agent that ran and ended.
    var startedAt: Double?
    /// For `modes`: whether each mode asked about is set, in the order asked.
    var modes: [Bool]?

    static func failure(_ message: String) -> KeeperResponse {
        KeeperResponse(ok: false, message: message)
    }

    static func success(
        message: String? = nil, pid: Int32? = nil, replay: Data? = nil,
        sessions: [KeeperSessionState]? = nil, version: String? = nil,
        build: String? = nil, executable: String? = nil, existing: Bool? = nil,
        inputDelivered: Bool? = nil, startedAt: Double? = nil, modes: [Bool]? = nil
    ) -> KeeperResponse {
        KeeperResponse(ok: true, message: message, pid: pid, replay: replay,
                       sessions: sessions, version: version,
                       build: build, executable: executable, existing: existing,
                       inputDelivered: inputDelivered, startedAt: startedAt, modes: modes)
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
        DataDirectory.file("keeper.sock").path
    }

    /// The **wire protocol**, not the build. A keeper speaking another one
    /// cannot be talked to, so it is replaced, shells and all (see
    /// `KeeperConnection.connect`); bumping this is therefore the most
    /// expensive change in the app, and only a change in the wire's shape
    /// warrants it.
    ///
    /// Still "1" after `initialInput`, `inputDelivered`, `startedAt`, `build`,
    /// `executable` and `existing` were added, deliberately: all are optional
    /// both ways, so an old keeper decodes a new request and a new app reads an
    /// old reply. The app handles an old keeper by typing the resume itself
    /// (see `newSurface`).
    ///
    /// A matching protocol says nothing about how old the keeper *binary* is,
    /// and that matters on its own: updating the app does not restart the
    /// keeper, and one keeper ran for days across four updates, so every shell
    /// it forked ran under an old binary that macOS's privacy grants (Full
    /// Disk Access) did not cover. That is `KeeperResponse.build`'s job.
    static let version = "1"

    /// A JSON reply is small; anything near this is a confused peer. The replay
    /// payload is base64 inside that JSON, so the ceiling has to clear it.
    static let maximumLineBytes = replayLimit * 2

    /// A session's output is buffered only while nobody is attached, so this
    /// bounds "what you missed", not scrollback. Big enough for a build log,
    /// small enough that a runaway process detached overnight can't grow the
    /// keeper without limit.
    static let replayLimit = 512 * 1024

    /// Scrollback the keeper's terminal keeps for each session, in bytes: the
    /// same as the app's (`scrollback-limit-bytes` in `wortel.conf`), whose
    /// surface is a copy of it.
    static let scrollbackBytes = 10_000_000
}
