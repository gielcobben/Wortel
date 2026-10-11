import Darwin
import Foundation

/// `wortel-keeper` — the process that holds Wortel's ptys.
///
/// It exists so that shells stop being the app's children. Quitting Wortel then
/// closes a window rather than killing whatever your agents were in the middle
/// of, and the next launch attaches to work already in progress.
///
/// Deliberately tiny and deliberately dumb: it forks what it is told to fork and
/// hands out descriptors. Every decision about *what* to run is made by the app
/// and arrives as data, because this is the one process that has to be trusted
/// to outlive everything else — and the way to earn that is to have almost no
/// reason to change.
///
/// Started by the app on demand, in its own session (`setsid`) so it is not in
/// the app's process group and does not die with it. It exits on its own once
/// there is nothing left to hold.

setvbuf(stdout, nil, _IOLBF, 0)

let server = KeeperServer()
/// `idleWork` is touched only on this queue: `onIdle` is called from whichever
/// connection or pty queue noticed, and two of them at once raced on it.
let idleQueue = DispatchQueue(label: "sh.wortel.keeper.idle")
var idleWork: DispatchWorkItem?

// Nothing held and nobody connected: go away rather than linger as a stray
// process. Delayed, because "the app is restarting" looks exactly like "the app
// has gone" for a second or two, and re-spawning is slower than waiting. Whether
// it is *still* idle when the wait is over is the server's to answer, in one
// step with any `open` that might be arriving: see `stopIfIdle`.
server.onIdle = {
    idleQueue.async {
        idleWork?.cancel()
        let work = DispatchWorkItem {
            guard server.stopIfIdle() else { return }
            KeeperLog.log.notice("keeper \(getpid(), privacy: .public) ending: nothing left to hold")
            exit(0)
        }
        idleWork = work
        idleQueue.asyncAfter(deadline: .now() + 30, execute: work)
    }
}

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("wortel-keeper: \(error)\n".utf8))
    KeeperLog.log.error("keeper \(getpid(), privacy: .public) could not start: \(String(describing: error), privacy: .public)")
    exit(1)
}
// Its whole life is outliving things, so its start is worth a line: the next
// investigation can tell which keeper held the shells, and since when. An end
// by SIGKILL (a Force Quit, the Dock stopping it) can't be logged from here;
// the app logs that one when it sees the process go.
KeeperLog.log.notice("""
    keeper \(getpid(), privacy: .public) started, protocol \(Keeper.version, privacy: .public), \
    build \(server.build ?? "unknown", privacy: .public)
    """)

// SIGHUP would otherwise arrive when the terminal that launched us goes away —
// which, for a process whose entire job is outliving things, is exactly wrong.
signal(SIGHUP, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
// A terminating signal should still tidy the socket file up.
//
// **The array is load-bearing.** `signal(…, SIG_IGN)` is required before a
// DispatchSource can observe a signal — but if the source is then released, the
// ignore stays and nothing observes it, so the process becomes unkillable by
// anything short of SIGKILL. `withExtendedLifetime` does not help: it ends at
// the closing brace. Three orphaned keepers, each still holding shells and
// deaf to `pkill`, is what that looked like.
var signalSources: [DispatchSourceSignal] = []
for terminating in [SIGTERM, SIGINT] {
    signal(terminating, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: terminating, queue: .main)
    source.setEventHandler {
        KeeperLog.log.notice("""
            keeper \(getpid(), privacy: .public) ending on signal \(terminating, privacy: .public), \
            closing \(server.sessionCount, privacy: .public) sessions
            """)
        server.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
