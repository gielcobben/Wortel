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
/// **The keeper keeps each session's terminal, and is its pty's one reader.**
/// It parses every byte the program writes into a terminal of its own
/// (libghostty-vt, no renderer), at the size the pty has, and forwards the
/// bytes to the app over a channel per session (`KeeperChannel`). The app's
/// surface is a copy of that terminal: restored from a snapshot of it, then
/// fed the same bytes. So nothing the app does or suffers (a quit, an update,
/// a crash, a surface dropped while out of sight) rebuilds a terminal. Until
/// protocol 2 (2026-11) the keeper passed the pty itself, the app read it, and
/// every relaunch and wake rebuilt the screen from a replay; every terminal
/// bug of 2026-11-18/20 was in one of those rebuilds.
///
/// One process reads a pty, the keeper, always: two readers would split the
/// bytes between them, and the corruption would be intermittent. The app
/// holds a copy of the pty's descriptor only to type into and to ask who is
/// in the foreground.
enum KeeperCommand: Codable, Equatable {
    /// Is anyone there, and which build?
    case ping
    /// End it: SIGHUP the shell and forget the session.
    case close(session: String)
    /// What is still running.
    case list
    /// Open a session, or attach to one that is already running, in which
    /// case the plan is ignored and `existing` says so.
    ///
    /// The keeper reads the pty itself and goes on reading: the app is given
    /// two descriptors, the session's **output channel** and the pty. The
    /// channel starts with a snapshot of the keeper's terminal for the session
    /// (`KeeperChannel`), then carries every byte the program writes after
    /// it, so nothing is lost or seen twice between the two. The pty is for
    /// typing, and for asking who is in the foreground; the app never reads
    /// it. Attaching again ends the previous channel after its last byte and
    /// starts a new one; a terminal shown again asks for `resync` instead.
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
    /// Send a snapshot of the session's terminal down its channel, between
    /// the next two reads (`KeeperChannel`): for a terminal the app shows
    /// again after dropping it.
    case resync(session: String)
    /// Write `bytes` into the session's terminal as though the program had
    /// written them, between two reads, and down its channel like any
    /// output: for what Wortel has to say to the terminal about a program it
    /// is ending (`TerminalModes.undo`), so both copies hear it.
    case inject(session: String, bytes: Data)

    var verb: String {
        switch self {
        case .ping: return "ping"
        case .close: return "close"
        case .list: return "list"
        case .terminal: return "terminal"
        case .resize: return "resize"
        case .appearance: return "appearance"
        case .modes: return "modes"
        case .resync: return "resync"
        case .inject: return "inject"
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

/// A session's output channel (`KeeperCommand.terminal`), keeper to app, as
/// frames: a type, a length, the bytes.
///
///     type (1 byte)  length (UInt32, big-endian)  payload
///
/// - `snapshot`: the keeper's terminal for the session, as libghostty-vt
///   encodes it. The first frame, and again whenever the app asks
///   (`KeeperCommand.resync`), always at a point between two reads of the
///   pty: what follows it is exactly what the program wrote after.
/// - `output`: what the program wrote, one read of the pty a frame.
///
/// In-band, so a snapshot can come at any point of a session's life without
/// the app ever having to line two streams up: a terminal shown again after
/// being dropped asks, and goes on from where its snapshot leaves off, while
/// whatever reads the session's output for its status never misses a byte.
/// A snapshot is only meaningful to a Ghostty built from the same commit as
/// the keeper's, which is the one in this app bundle.
enum KeeperChannel {
    enum Frame: UInt8 {
        case output = 1
        case snapshot = 2
    }

    static let headerSize = 5
    /// One frame's most, for a peer that is not a keeper.
    static let maximumFrame = 1 << 30

    static func header(_ frame: Frame, length: Int) -> [UInt8] {
        precondition(length <= maximumFrame)
        let n = UInt32(length)
        return [frame.rawValue, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    }

    /// The frame and length a complete header says, or nil for one that is
    /// not a header at all.
    static func parse(header bytes: some Collection<UInt8>) -> (frame: Frame, length: Int)? {
        guard bytes.count == headerSize, let frame = Frame(rawValue: bytes[bytes.startIndex]) else { return nil }
        let length = bytes.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        return length <= maximumFrame ? (frame, length) : nil
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
    /// For `terminal`: the session's latest output (`Keeper.replayLimit`),
    /// oldest first, for what the program said about itself. Base64 in the
    /// JSON, which is what `Data`'s Codable conformance does.
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
    /// For `terminal`: the session already existed and this attached to it,
    /// so nothing was forked and the plan, `initialInput` included, was
    /// ignored.
    var existing: Bool?
    /// For `terminal`: whether this keeper typed the session's `initialInput`
    /// into the pty when it forked the shell.
    var inputDelivered: Bool?
    /// For `terminal`: when the shell was forked, as seconds since
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
    /// "2" since the keeper keeps the terminal (2026-11): the app no longer
    /// reads the pty, so a keeper of protocol 1 cannot serve it, and the
    /// update that brought it ended every running shell, once, its agents
    /// resumed (`docs/decisions.md`). Before that it stayed "1" through every
    /// optional field added both ways (`initialInput`, `inputDelivered`,
    /// `startedAt`, `build`, `executable`, `existing`).
    ///
    /// A matching protocol says nothing about how old the keeper *binary* is,
    /// and that matters on its own: updating the app does not restart the
    /// keeper, and one keeper ran for days across four updates, so every shell
    /// it forked ran under an old binary that macOS's privacy grants (Full
    /// Disk Access) did not cover. That is `KeeperResponse.build`'s job.
    static let version = "2"

    /// A JSON reply is small; anything near this is a confused peer. The tail
    /// of a session's output is base64 inside that JSON, so the ceiling has
    /// to clear it.
    static let maximumLineBytes = replayLimit * 2

    /// How much of a session's latest output the keeper keeps beside its
    /// terminal, for an app that attaches to read what the program said about
    /// itself (`ProgramStatusWatch`), never to write into a terminal: the
    /// snapshot has all of it. Not scrollback.
    static let replayLimit = 512 * 1024

    /// Scrollback the keeper's terminal keeps for each session, in bytes: the
    /// same as the app's (`scrollback-limit-bytes` in `wortel.conf`), whose
    /// surface is a copy of it.
    static let scrollbackBytes = 10_000_000
}
