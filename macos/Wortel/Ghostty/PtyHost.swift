import Darwin
import Foundation
import os

/// A pty and the process on the other end of it, owned by **us** rather than by
/// libghostty.
///
/// The ground process survival stands on. `ghostty.h` declares a second IO
/// backend, `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, where libghostty is
/// purely the emulator and the host does the forkpty, the read loop, the
/// TIOCSWINSZ and the waitpid. Once the pty is ours, moving that ownership into
/// a process that outlives the app (`wortel-keeper`) is ordinary plumbing.
///
/// One class, two roles, because both ends share this file:
///
/// - **In the keeper** it forks (`start`): it owns the child, reaps it, and
///   reads the pty only while no app is attached (`pauseReading`).
/// - **In the app** it only ever *adopts* the descriptor the keeper passed
///   (`init(adopting:)`): it reads and writes it, and never signals or reaps a
///   process that isn't its own. It learns the shell ended from the pty
///   hanging up (`onHangup`).
///
/// What the exec backend did for a child beyond forking it (`/usr/bin/login`,
/// TERM and terminfo, the shell integration) is `ShellSpawn`'s, and arrives
/// here as a finished plan. `WORTEL_NO_KEEPER=1` opts a launch out entirely and
/// puts it back on libghostty's exec backend.

/// Something that wants a copy of the bytes the terminal sends the program.
/// Each `feed` is one whole write: one key press, one reply to a query, one
/// part of a paste, never a sequence cut in two (see `TypedLineBuilder`).
protocol PtyInputListener: AnyObject, Sendable {
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int)
}

final class PtyHost: @unchecked Sendable {
    /// An escape hatch, not a feature switch: survival is the default, and
    /// `WORTEL_NO_KEEPER=1` puts a launch back on libghostty's exec backend.
    /// Kept because "is this the keeper's fault?" is the first question anyone
    /// will ask about a strange session, and answering it should not require a
    /// build.
    ///
    /// Behind a lock rather than a bare `static var`: it is written once in
    /// `main.swift` and only read afterwards, but it is read from whichever
    /// thread creates a surface, and "written once, honestly" is not something
    /// the compiler can be told.
    private static let disabled = OSAllocatedUnfairLock(initialState: false)
    static var isDisabled: Bool { disabled.withLock { $0 } }

    /// Latch the flag from the environment.
    ///
    /// Must be called from `main.swift` **before** `InheritedEnvironment.apply()`,
    /// which deletes every `WORTEL_`-prefixed variable — including this one. Read
    /// any later and the answer is always false, which is a properly confusing
    /// twenty minutes: the app launches, ignores the flag, and behaves exactly
    /// as it would have anyway.
    static func readEnableFlag() {
        let off = ProcessInfo.processInfo.environment["WORTEL_NO_KEEPER"] == "1"
        disabled.withLock { $0 = off }
    }

    /// Everything here is touched from more than one thread, so it lives behind
    /// one lock rather than in bare `var`s under an `@unchecked Sendable` that
    /// asserted the problem away.
    ///
    /// Who touches what: the read source's handlers run on `queue`; `write` is
    /// called from libghostty's IO thread; `resize` from the main thread;
    /// `pauseReading` / `resumeReading` from the keeper's state queue; `stop`
    /// and `release` from whichever thread closed the session. `pid`,
    /// `startedAt` and `ownsProcess` stay outside because they are written once
    /// before this object is published to anyone and never again.
    private struct Shared {
        var master: Int32 = -1
        var isReading = false
        /// Set once the child has been reaped, so nothing signals a pid the
        /// system is free to hand to someone else.
        var hasExited = false
        var reader: DispatchSourceRead?
        /// Owed a forced repaint once the real window size has been applied.
        /// See `requestRedrawAfterNextResize`.
        var needsRedraw = false
    }
    /// `uncheckedState` only because `DispatchSourceRead` is not Sendable; it
    /// never leaves the lock except to be cancelled by the one caller that took
    /// it out.
    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())

    /// Whoever is listening for the user's next typed line, if anyone. Set and
    /// cleared on the main thread by the session manager while it waits for an
    /// agent's first prompt (`PromptTap`); read on the write path, hence the
    /// lock. nil is the normal state, and costs one lock take per write. A
    /// protocol rather than the concrete tap because this file is also the
    /// keeper's, which has no sessions to name.
    private let tap = OSAllocatedUnfairLock<(any PtyInputListener)?>(initialState: nil)
    var promptTap: (any PtyInputListener)? {
        get { tap.withLock { $0 } }
        set { tap.withLock { $0 = newValue } }
    }
    /// A second listener, for a move waiting on the agent (`DraftTap`). Its
    /// own slot because a session can be waiting for an agent's first prompt
    /// and on a move at once, and neither may unhook the other.
    private let secondTap = OSAllocatedUnfairLock<(any PtyInputListener)?>(initialState: nil)
    var draftTap: (any PtyInputListener)? {
        get { secondTap.withLock { $0 } }
        set { secondTap.withLock { $0 = newValue } }
    }

    /// The pty master. Reading it gives what the program wrote; writing it is
    /// what the user typed. -1 once the descriptor has been closed.
    var master: Int32 { shared.withLock { $0.master } }
    private(set) var pid: pid_t = -1

    /// Output from the program. Called on `queue`, never on main — it's the hot
    /// path, and a terminal that hops to the main actor per read is a terminal
    /// that stutters under `cat` of a large file.
    var onOutput: ((UnsafePointer<UInt8>, Int) -> Void)?
    /// The program exited: code, and how long it ran. Only for a host that
    /// forked its process; an adopted pty has no child to reap.
    var onExit: ((Int32, UInt64) -> Void)?
    /// The far side of an **adopted** pty hung up: the shell and everything
    /// else that had the tty open are gone. Called once, on `queue`, and never
    /// after `release`.
    ///
    /// The app's only way to learn that a keeper-hosted shell ended. The
    /// keeper reaps it, but while the app is attached the keeper is not
    /// reading, and the exec backend's "process exited" never comes because
    /// libghostty spawned nothing. Without this the terminal just stopped.
    var onHangup: (() -> Void)?

    private let queue = DispatchQueue(label: "sh.wortel.pty", qos: .userInteractive)
    private var startedAt = DispatchTime.now()
    /// Fires when the child exits. Held so it outlives `start`.
    private var childSource: DispatchSourceProcess?

    /// Whether this host forked the process on the other end. The keeper does;
    /// the app, holding a descriptor passed to it, does not — and must never
    /// signal or reap a child that isn't its own.
    private(set) var ownsProcess = true

    init() {}

    /// Take over a pty someone else opened — the descriptor the keeper passed
    /// us. There is no child here: the shell belongs to the keeper, and killing
    /// it is the keeper's business.
    init(adopting descriptor: Int32) {
        shared.withLock { $0.master = descriptor }
        ownsProcess = false
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // **Deliberately not reading yet.** The surface it feeds does not exist
        // at this point, and the first thing a reattached session produces is
        // whatever the shell wrote a moment ago — dropping it would show a blank
        // terminal for work that is still running. The caller wires `onOutput`,
        // writes the replay, and only then calls `beginReading`.
    }

    /// Run `work` on the read queue, in order with the reads.
    ///
    /// The queue is serial and the read source targets it, so that is the
    /// whole guarantee, and it serves two callers:
    ///
    /// - **Before the first read**, the bytes that must reach the terminal
    ///   first: the saved modes and the keeper's replay. They go into
    ///   libghostty through `ghostty_surface_write_buffer`, which runs the VT
    ///   parser on whichever thread calls it, and the parser pushes surface
    ///   messages (titles, cwd reports) into a 64-slot queue that only the
    ///   main thread drains, waiting forever when it's full. Fed from main, a
    ///   replay from an agent that kept working while detached, hundreds of
    ///   title updates, blocked the main thread on a queue it alone could
    ///   empty: the beach ball of 2026-10-07.
    /// - **After `release`**, freeing the surface that queue writes into, once
    ///   the replay and any read in flight are done. Waiting for the queue
    ///   synchronously instead would deadlock on that same mailbox.
    func enqueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Wait until a read already under way has delivered its bytes.
    ///
    /// `pauseReading` stops the next read, not the current one: suspending a
    /// source does not interrupt a handler that is running. The keeper's
    /// handover needs both, or a chunk read just before the pause lands in the
    /// replay buffer *after* the app has taken it, and turns up stale in the
    /// next replay instead of this one. The read loop checks `isReading` before
    /// every `read`, so once this returns nothing more is read until
    /// `resumeReading`.
    ///
    /// Never call it on `queue`, or while holding anything a read hands its
    /// bytes to (the keeper's state queue): the read being waited for may be
    /// waiting on exactly that.
    func finishReadInFlight() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
    }

    /// A descriptor of our own for the pty, or nil once it has closed.
    ///
    /// Duplicated under the lock the read source's cancel handler closes the
    /// master under, so the number cannot be closed, and handed to something
    /// else by the kernel, between being read here and being duplicated. The
    /// keeper sends the copy and closes it after: a shell that ends while the
    /// reply is on its way then costs the app a dead pty, never someone
    /// else's file.
    func duplicateMaster() -> Int32? {
        shared.withLock { state -> Int32? in
            guard state.master >= 0 else { return nil }
            let copy = dup(state.master)
            return copy >= 0 ? copy : nil
        }
    }

    /// Start reading a descriptor adopted from the keeper. Separate from `init`
    /// so nothing is read before there is somewhere to put it.
    func beginReading() {
        let ready = shared.withLock { $0.reader == nil && $0.master >= 0 }
        guard ready else { return }
        startReading()
    }

    deinit { stop() }

    // MARK: - Starting

    /// Fork a shell onto a new pty.
    ///
    /// `forkpty` rather than `posix_spawn`, because the child needs the slave as
    /// its *controlling* terminal — that's what makes job control, `Ctrl-C` and
    /// window-size signals work at all — and `forkpty` does the `setsid` +
    /// `TIOCSCTTY` dance for you.
    ///
    /// **The child allocates nothing.** After a fork in a process with threads,
    /// only async-signal-safe calls are safe: another thread may have held the
    /// malloc lock at the instant of the fork, and the child's copy of it is
    /// then held forever. So every C string the child needs is built here,
    /// before the fork, and the child only resets signals, changes directory
    /// and execs. The keeper forks from libdispatch's pool, where other threads
    /// are always running.
    @discardableResult
    func start(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String?, columns: UInt16, rows: UInt16
    ) -> Bool {
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let directory = CStringArray(workingDirectory.map { [$0] } ?? [])
        defer { [argv, envp, directory].forEach { $0.free() } }
        // **Give the child default signal handling.** An *ignored* disposition
        // survives `execve` (handlers reset, SIG_IGN does not), and the keeper
        // ignores SIGHUP on purpose, because its whole job is outliving the
        // terminal that started it. Without this reset every shell it forks
        // inherits that, and closing a session politely does nothing at all:
        // the kill succeeds, and the process carries on. That is exactly how
        // it presented: `kill(-pid, SIGHUP)` returning 0 with `sleep 60` still
        // in state Ss+.
        let defaulted = [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGTTIN, SIGTTOU]

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        guard pid >= 0 else {
            NSLog("wortel: forkpty failed: %s", strerror(errno))
            return false
        }

        if pid == 0 {
            for signalNumber in defaulted { signal(signalNumber, SIG_DFL) }
            // And an unblocked mask: libdispatch blocks signals on its worker
            // threads, and the child inherits the mask of whichever thread
            // happened to fork it, which would otherwise make this
            // nondeterministic rather than merely wrong.
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)

            if let cwd = directory.pointer[0] { _ = chdir(cwd) }
            execve(argv.pointer[0], argv.pointer, envp.pointer) // argv[0] is the executable
            _exit(127) // exec failed; the parent sees the pty close
        }

        // `forkpty` needed somewhere to write, so `master` above is a `var`;
        // copy it before it reaches a closure.
        let descriptor = master
        self.shared.withLock { $0.master = descriptor }
        self.pid = pid
        self.startedAt = .now()
        // Non-blocking: the read source tells us when there's something, and a
        // blocking read on a pty whose child is idle would park the queue.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        startReading()
        reapWhenItExits()
        return true
    }

    private func startReading() {
        let fd = shared.withLock { $0.master }
        guard fd >= 0 else { return }
        // Both handlers use the descriptor they were built for rather than
        // re-reading it. libdispatch guarantees the cancel handler runs after
        // the last event handler on this queue, so the close below cannot land
        // under a read in progress, and a captured value cannot go stale the way
        // a re-read field could.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            // Asked before every read, not once: the keeper pauses this source
            // to hand the pty to the app, and a suspended source does not stop
            // a handler already in this loop. Without the check it went on
            // reading beside the app, two readers splitting one stream.
            while self.shared.withLock({ $0.isReading }) {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    buffer.withUnsafeBufferPointer { raw in
                        guard let base = raw.baseAddress else { return }
                        self.onOutput?(base, count)
                    }
                    // A short read means the pty had nothing more; going round
                    // again would just return EAGAIN.
                    if count < buffer.count { return }
                } else {
                    // 0 is the child closing the slave; EIO is the same thing on
                    // a pty once the last slave fd goes. Anything else that
                    // isn't "try later" is fatal for this descriptor.
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
                    self.hangUp()
                    return
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else {
                close(fd)
                return
            }
            self.shared.withLock { state in
                guard state.master == fd else { return }
                close(fd)
                state.master = -1
            }
        }
        shared.withLock {
            $0.reader = source
            $0.isReading = true
        }
        source.resume()
    }

    /// The pty's far side is gone. Stop reading, and for an adopted pty say so.
    ///
    /// Taking the reader out of `shared` is what makes `onHangup` fire once and
    /// never for a pty already let go of: whoever takes it first owns the
    /// ending, and `release` taking it means the app chose to stop listening,
    /// which is not news about the shell.
    private func hangUp() {
        guard let reader = takeReader() else { return }
        reader.cancel()
        if !ownsProcess { onHangup?() }
    }

    /// Notice the child exiting, and reap it.
    ///
    /// A `DispatchSource` rather than a thread parked in `waitpid`. The obvious
    /// version — one blocking wait per child — costs a thread per session for as
    /// long as the session lives, and the keeper's whole job is holding a lot of
    /// sessions for a long time. It also starves: with enough of them the pool
    /// stops handing out threads, exits go unnoticed and the children pile up as
    /// zombies that `kill(pid, 0)` still answers for, which is exactly how this
    /// showed up — a session that had been killed and would not die.
    ///
    /// `waitpid` still runs, because it is the only way to learn the exit *code*
    /// — but only once, when there is genuinely something to collect.
    ///
    /// **And once more, straight after arming.** The kernel never reports an
    /// exit that happened before it was asked, so a child whose `execve`
    /// failed at once (a shell path that no longer exists) could be gone
    /// before the source was registered. It then sat as a zombie, and the
    /// keeper held its session until something else noticed the pty close.
    private func reapWhenItExits() {
        let pid = self.pid
        let started = self.startedAt
        // Held directly, not through `self`: the keeper frees the host the
        // moment it closes a session, and `stop`'s SIGKILL follow-up reads this
        // to know the pid hasn't been reaped and recycled.
        let shared = self.shared
        // Whichever of the two below collects the child reports it; the other
        // finds nothing to collect. Both run on `queue`, one after the other.
        let report: (Int32) -> Void = { [weak self] status in
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            self?.onExit?(code, ms)
        }
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler {
            source.cancel()
            // Blocking: the exit has been reported, so this returns as soon as
            // the kernel has finished making it collectable.
            if let status = Self.reap(pid, in: shared, options: 0) { report(status) }
        }
        childSource = source
        source.resume()
        queue.async {
            guard let status = Self.reap(pid, in: shared, options: WNOHANG) else { return }
            source.cancel()
            report(status)
        }
    }

    private typealias SharedState = OSAllocatedUnfairLock<Shared>

    /// Collect the child's exit status, once.
    ///
    /// Under the lock `signalGroup` takes, and that is the point: the moment
    /// `waitpid` returns, the pid is free for the system to hand to someone
    /// else, so "not reaped yet" and "signal it" have to be one step. A flag
    /// set after the fact left a window where `stop` could SIGHUP a stranger.
    private static func reap(_ pid: pid_t, in shared: SharedState, options: Int32) -> Int32? {
        shared.withLock { state -> Int32? in
            guard !state.hasExited else { return nil }
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, options) } while reaped < 0 && errno == EINTR
            guard reaped == pid else { return nil }
            state.hasExited = true
            return status
        }
    }

    /// Signal the child's **process group**, unless it has been reaped. See
    /// `reap` for why the check and the signal share the lock.
    ///
    /// The group, not just the shell: forkpty makes the child a session
    /// leader, so its own children share its group, and signalling only the
    /// leader leaves a `sleep`, a build or an agent running with nobody to
    /// reap it. The negative pid is what says "the group".
    private static func signalGroup(_ signalNumber: Int32, of pid: pid_t, in shared: SharedState) {
        shared.withLock { state in
            guard !state.hasExited else { return }
            if kill(-pid, signalNumber) != 0 { kill(pid, signalNumber) }
        }
    }

    // MARK: - The two directions

    /// What the user typed.
    ///
    /// The descriptor is taken under the lock rather than read from a bare
    /// field, which is what makes it a defined value here at all. What that
    /// still does not buy is atomicity against the close: the cancel handler can
    /// run between the read below and the syscall, so a write can land on a
    /// descriptor that has just closed. That returns EBADF and this gives up,
    /// which is the right outcome; the only genuinely bad case is the kernel
    /// handing the number to something else in that same instant, and closing
    /// *that* window needs the descriptor reference-counted rather than closed
    /// outright. Deliberately not done: it would put a retain/release on the
    /// keystroke path to fix a race no one has hit.
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) {
        if let tap = tap.withLock({ $0 }) { tap.feed(bytes, count: count) }
        if let tap = secondTap.withLock({ $0 }) { tap.feed(bytes, count: count) }
        let master = shared.withLock { $0.master }
        guard master >= 0 else { return }
        var offset = 0
        while offset < count {
            let written = Darwin.write(master, bytes + offset, count - offset)
            if written > 0 {
                offset += written
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN, Self.waitForRoom(in: master) {
                continue
            } else {
                return
            }
        }
    }

    /// How long a write waits for a program to take any of its input.
    private static let inputPatience: Int32 = 5_000 // ms

    /// Wait for the pty's input buffer to have room, and say whether it does.
    ///
    /// A full buffer is a program not reading its input: a large paste into
    /// one that is busy, or one that never reads at all. This used to spin on
    /// EAGAIN, a core at 100% for as long as the program took, and forever for
    /// one that never read, on libghostty's IO thread. Waiting is free, and
    /// giving up after a while with no room at all drops the rest of that one
    /// write rather than wedging the terminal behind it.
    private static func waitForRoom(in descriptor: Int32) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let ready = poll(&request, 1, inputPatience)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, request.revents & Int16(POLLOUT) != 0 else {
                if ready == 0 { NSLog("wortel: the program took no input for 5s; dropping the rest of a write") }
                return false
            }
            return true
        }
    }

    /// The window changed shape. This is what sends SIGWINCH, which is how every
    /// full-screen program learns to redraw.
    func resize(columns: UInt16, rows: UInt16, widthPx: UInt32, heightPx: UInt32) {
        let master = shared.withLock { $0.master }
        guard master >= 0 else { return }
        var size = winsize(
            ws_row: rows, ws_col: columns,
            ws_xpixel: UInt16(truncatingIfNeeded: widthPx),
            ws_ypixel: UInt16(truncatingIfNeeded: heightPx))
        _ = ioctl(master, TIOCSWINSZ, &size)

        let owed = shared.withLock { state -> Bool in
            defer { state.needsRedraw = false }
            return state.needsRedraw
        }
        guard owed, rows > 1 else { return }
        // Report one row fewer and then the true size again. Both writes are a
        // real change, so both raise SIGWINCH, and the program cannot dismiss
        // either as a resize that wasn't one. It lands on the size it started
        // from, so nothing about the terminal is left altered.
        var smaller = size
        smaller.ws_row = rows - 1
        _ = ioctl(master, TIOCSWINSZ, &smaller)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Make whatever is running paint itself again, once the real window size
    /// has been applied.
    ///
    /// For a session that survived an app restart with nothing to replay. The
    /// keeper only buffers while detached and hands that buffer over by
    /// draining it, so a session whose program sat idle while the app was gone
    /// comes back with **no bytes at all** — and a program at rest does not
    /// reprint itself unasked. The window is blank until you touch it.
    ///
    /// Why this is a size change and not a signal: a bare `SIGWINCH` does not
    /// work. Measured across nine real sessions, exactly one produced any
    /// output from one, because a TUI that tracks its own dimensions treats a
    /// resize that isn't one as nothing to do. Forcing a genuine change made
    /// the same session repaint immediately.
    ///
    /// Deferred to the next resize rather than done here because the size that
    /// matters is the window's, which libghostty reports a moment later. A
    /// repaint sent before that would be drawn for whatever the pty was last
    /// set to.
    func requestRedrawAfterNextResize() {
        shared.withLock { $0.needsRedraw = true }
    }

    /// Stop reading without giving up the pty.
    ///
    /// **The load-bearing rule of the whole design**: exactly one process may
    /// read a pty at a time. Two readers split the byte stream between them, and
    /// the corruption is intermittent and unreproducible. So the keeper pauses
    /// before handing the descriptor to the app, and resumes when the app lets
    /// go. Anything that arrives in the gap stays in the kernel's buffer, which
    /// is why nothing is lost between the two.
    ///
    /// This stops the *next* read; one already under way finishes first. A
    /// handover that must not race it follows this with `finishReadInFlight`.
    func pauseReading() {
        shared.withLock { state in
            guard let reader = state.reader, state.isReading else { return }
            state.isReading = false
            reader.suspend()
        }
    }

    func resumeReading() {
        shared.withLock { state in
            guard let reader = state.reader, !state.isReading else { return }
            state.isReading = true
            reader.resume()
        }
    }

    /// Take the read source out of `shared`, resuming it first if it is
    /// suspended: a suspended source cannot be cancelled — the cancel handler
    /// would never run and the descriptor would leak. Resume and removal happen
    /// together under the lock so two callers cannot both resume it.
    private func takeReader() -> DispatchSourceRead? {
        shared.withLock { state -> DispatchSourceRead? in
            guard let reader = state.reader else { return nil }
            if !state.isReading {
                state.isReading = true
                reader.resume()
            }
            state.reader = nil
            return reader
        }
    }

    /// Close this end. Kills the child **only if it is ours** — the app adopting
    /// a keeper's descriptor must let go without touching the shell, which is
    /// precisely what survival means.
    func stop() {
        takeReader()?.cancel()
        guard ownsProcess, pid > 0 else { return }
        // Both signals are guarded on `hasExited` (see `signalGroup`) rather than a
        // `kill(pid, 0)` probe: once the reaper has collected the child the
        // number is free to be reused, and signalling a recycled pid would kill
        // something that has nothing to do with us.
        Self.signalGroup(SIGHUP, of: pid, in: shared)

        // Then insist. Closing a session is the user saying so, and plenty of
        // things decline a SIGHUP — an agent with its own handler, a program
        // that blocked it, a process group that outlived the shell that led it.
        // A "closed" session with a live process in it is worse than either
        // outcome, because nothing on screen says it is still running.
        //
        // The state, not `self`, is what's held: the keeper drops the host as
        // it closes the session, so a `[weak self]` here was always nil by the
        // time it ran, and the SIGKILL never happened.
        let target = pid
        let shared = self.shared
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            Self.signalGroup(SIGKILL, of: target, in: shared)
        }
    }

    /// Let go of the pty without ending the session — the app detaching. The
    /// descriptor is closed (ours was a `dup`; the keeper still holds one) and
    /// the shell carries on with nobody watching. `onHangup` does not fire.
    func release() {
        takeReader()?.cancel()
    }
}

/// A NULL-terminated array of C strings, for `execve`, built before the fork so
/// the child only reads memory that already exists. Freed by the parent.
private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[count] = nil
    }

    func free() {
        for index in 0..<count { Darwin.free(pointer[index]) }
        pointer.deallocate()
    }
}
