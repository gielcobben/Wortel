import Darwin
import Foundation

/// A pty and the process on the other end of it, owned by **us** rather than by
/// libghostty.
///
/// This is the spike behind process survival. Today every shell is a child of
/// libghostty's exec backend, which is why quitting the app takes the agents
/// with it. libghostty turns out not to need that: `ghostty.h` declares a second
/// IO backend, `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, where it is purely the
/// emulator and the host does the forkpty, the read loop, the TIOCSWINSZ and the
/// waitpid. Nothing has to *adopt* an existing descriptor — the note that said
/// otherwise was wrong. Once we own the pty, moving that ownership into a
/// process that outlives the app is ordinary plumbing.
///
/// **What this class is not** is a replacement for the exec backend. That
/// backend also wraps the shell in `/usr/bin/login`, sets TERM and the terminfo
/// path, and injects the shell integration (`ZDOTDIR` for zsh, `--rcfile` for
/// bash) that busy detection, agent markers, OSC 133 timing, cwd reporting and
/// the `wortel` command's PATH all depend on. None of that is here, and none of
/// it is free. Knowing exactly how much of it goes dead is the point of the
/// spike: turn it on, look at what the session loses.
///
/// In the app this only ever *adopts* a descriptor the keeper passed; the keeper
/// is the one that forks. `WORTEL_NO_KEEPER=1` opts a launch out entirely and
/// puts it back on libghostty's exec backend.
final class PtyHost: @unchecked Sendable {
    /// An escape hatch, not a feature switch: survival is the default, and
    /// `WORTEL_NO_KEEPER=1` puts a launch back on libghostty's exec backend.
    /// Kept because "is this the keeper's fault?" is the first question anyone
    /// will ask about a strange session, and answering it should not require a
    /// build.
    private(set) static var isDisabled = false

    /// Latch the flag from the environment.
    ///
    /// Must be called from `main.swift` **before** `InheritedEnvironment.apply()`,
    /// which deletes every `WORTEL_`-prefixed variable — including this one. Read
    /// any later and the answer is always false, which is a properly confusing
    /// twenty minutes: the app launches, ignores the flag, and behaves exactly
    /// as it would have anyway.
    static func readEnableFlag() {
        isDisabled = ProcessInfo.processInfo.environment["WORTEL_NO_KEEPER"] == "1"
    }

    /// The pty master. Reading it gives what the program wrote; writing it is
    /// what the user typed.
    private(set) var master: Int32 = -1
    private(set) var pid: pid_t = -1

    /// Output from the program. Called on `queue`, never on main — it's the hot
    /// path, and a terminal that hops to the main actor per read is a terminal
    /// that stutters under `cat` of a large file.
    var onOutput: ((UnsafePointer<UInt8>, Int) -> Void)?
    /// The program exited: code, and how long it ran.
    var onExit: ((Int32, UInt64) -> Void)?

    private let queue = DispatchQueue(label: "sh.wortel.pty", qos: .userInteractive)
    private var reader: DispatchSourceRead?
    private var isReading = false
    private var startedAt = DispatchTime.now()
    /// Set once the child has been reaped, so nothing signals a pid the system
    /// is free to hand to someone else.
    private var hasExited = false
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
        master = descriptor
        ownsProcess = false
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // **Deliberately not reading yet.** The surface it feeds does not exist
        // at this point, and the first thing a reattached session produces is
        // whatever the shell wrote a moment ago — dropping it would show a blank
        // terminal for work that is still running. The caller wires `onOutput`,
        // writes the replay, and only then calls `beginReading`.
    }

    /// Start reading a descriptor adopted from the keeper. Separate from `init`
    /// so nothing is read before there is somewhere to put it.
    func beginReading() {
        guard reader == nil, master >= 0 else { return }
        startReading()
    }

    deinit { stop() }

    // MARK: - Starting

    /// Fork a shell onto a new pty.
    ///
    /// `forkpty` rather than `posix_spawn`, because the child needs the slave as
    /// its *controlling* terminal — that's what makes job control, `Ctrl-C` and
    /// window-size signals work at all — and `forkpty` does the `setsid` +
    /// `TIOCSCTTY` dance for you. The child does nothing but `execve` before
    /// handing over, which is the only thing that's safe after a fork in a
    /// process with threads.
    @discardableResult
    func start(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String?, columns: UInt16, rows: UInt16
    ) -> Bool {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        guard pid >= 0 else {
            NSLog("wortel: forkpty failed: %s", strerror(errno))
            return false
        }

        if pid == 0 {
            // **Give the child default signal handling.** An *ignored*
            // disposition survives `execve` — handlers reset, SIG_IGN does not —
            // and the keeper ignores SIGHUP on purpose, because its whole job is
            // outliving the terminal that started it. Without this reset every
            // shell it forks inherits that, and closing a session politely does
            // nothing at all: the kill succeeds, and the process carries on.
            // That is exactly how it presented — `kill(-pid, SIGHUP)` returning
            // 0 with `sleep 60` still in state Ss+.
            for ignored in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGTTIN, SIGTTOU] {
                signal(ignored, SIG_DFL)
            }
            // And an unblocked mask: libdispatch blocks signals on its worker
            // threads, and the child inherits the mask of whichever thread
            // happened to fork it — which would otherwise make this
            // nondeterministic rather than merely wrong.
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)

            if let workingDirectory { _ = workingDirectory.withCString { chdir($0) } }
            var argv: [UnsafeMutablePointer<CChar>?] =
                ([executable] + arguments).map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] =
                environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            execve(executable, &argv, &envp)
            _exit(127) // exec failed; the parent sees the pty close
        }

        self.master = master
        self.pid = pid
        self.startedAt = .now()
        // Non-blocking: the read source tells us when there's something, and a
        // blocking read on a pty whose child is idle would park the queue.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        startReading()
        reapWhenItExits()
        return true
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(self.master, &buffer, buffer.count)
                if count > 0 {
                    buffer.withUnsafeBufferPointer { raw in
                        self.onOutput?(raw.baseAddress!, count)
                    }
                    // A short read means the pty had nothing more; going round
                    // again would just return EAGAIN.
                    if count < buffer.count { return }
                } else {
                    // 0 is the child closing the slave; EIO is the same thing on
                    // a pty once the last slave fd goes. Anything else that
                    // isn't "try later" is fatal for this descriptor.
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
                    self.reader?.cancel()
                    return
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.master >= 0 else { return }
            close(self.master)
            self.master = -1
        }
        reader = source
        isReading = true
        source.resume()
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
    private func reapWhenItExits() {
        let pid = self.pid
        let started = self.startedAt
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            self?.hasExited = true
            self?.onExit?(code, ms)
            source.cancel()
        }
        childSource = source
        source.resume()
    }

    // MARK: - The two directions

    /// What the user typed.
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard master >= 0 else { return }
        var offset = 0
        while offset < count {
            let written = Darwin.write(master, bytes + offset, count - offset)
            if written > 0 {
                offset += written
            } else if errno == EINTR || errno == EAGAIN {
                continue // a full pty buffer; the reader on the far side will drain it
            } else {
                return
            }
        }
    }

    /// The window changed shape. This is what sends SIGWINCH, which is how every
    /// full-screen program learns to redraw.
    func resize(columns: UInt16, rows: UInt16, widthPx: UInt32, heightPx: UInt32) {
        guard master >= 0 else { return }
        var size = winsize(
            ws_row: rows, ws_col: columns,
            ws_xpixel: UInt16(truncatingIfNeeded: widthPx),
            ws_ypixel: UInt16(truncatingIfNeeded: heightPx))
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Stop reading without giving up the pty.
    ///
    /// **The load-bearing rule of the whole design**: exactly one process may
    /// read a pty at a time. Two readers split the byte stream between them, and
    /// the corruption is intermittent and unreproducible. So the keeper pauses
    /// before handing the descriptor to the app, and resumes when the app lets
    /// go. Anything that arrives in the gap stays in the kernel's buffer, which
    /// is why nothing is lost between the two.
    func pauseReading() {
        guard let reader, isReading else { return }
        isReading = false
        reader.suspend()
    }

    func resumeReading() {
        guard let reader, !isReading else { return }
        isReading = true
        reader.resume()
    }

    /// Close this end. Kills the child **only if it is ours** — the app adopting
    /// a keeper's descriptor must let go without touching the shell, which is
    /// precisely what survival means.
    func stop() {
        // A suspended source cannot be cancelled: the cancel handler would never
        // run and the descriptor would leak. Resume first, always.
        if let reader, !isReading {
            isReading = true
            reader.resume()
        }
        reader?.cancel()
        reader = nil
        guard ownsProcess, pid > 0 else { return }
        // The **process group**, not just the shell. forkpty makes the child a
        // session leader, so its own children share its group — signalling only
        // the leader leaves a `sleep`, a build or an agent running with nobody
        // to reap it. The negative pid is what says "the group".
        if kill(-pid, SIGHUP) != 0 { kill(pid, SIGHUP) }

        // Then insist. Closing a session is the user saying so, and plenty of
        // things decline a SIGHUP — an agent with its own handler, a program
        // that blocked it, a process group that outlived the shell that led it.
        // A "closed" session with a live process in it is worse than either
        // outcome, because nothing on screen says it is still running.
        //
        // Guarded on `hasExited` rather than a `kill(pid, 0)` probe: once the
        // reaper has collected the child the number is free to be reused, and
        // signalling a recycled pid would kill something that has nothing to do
        // with us.
        let target = pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.hasExited else { return }
            if kill(-target, SIGKILL) != 0 { kill(target, SIGKILL) }
        }
    }

    /// Let go of the pty without ending the session — the app detaching. The
    /// descriptor is closed (ours was a `dup`; the keeper still holds one) and
    /// the shell carries on with nobody watching.
    func release() {
        if let reader, !isReading {
            isReading = true
            reader.resume()
        }
        reader?.cancel()
        reader = nil
    }
}
