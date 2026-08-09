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
/// Opt-in only, via `WORTEL_HOST_MANAGED=1` in the app's environment. Nothing on
/// the normal path reaches this file.
final class PtyHost: @unchecked Sendable {
    /// Whether the spike is switched on for this launch.
    private(set) static var isEnabled = false

    /// Latch the flag from the environment.
    ///
    /// Must be called from `main.swift` **before** `InheritedEnvironment.apply()`,
    /// which deletes every `WORTEL_`-prefixed variable — including this one. Read
    /// any later and the answer is always false, which is a properly confusing
    /// twenty minutes: the app launches, ignores the flag, and spawns exactly the
    /// sessions it always did.
    static func readEnableFlag() {
        isEnabled = ProcessInfo.processInfo.environment["WORTEL_HOST_MANAGED"] == "1"
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
    private var startedAt = DispatchTime.now()

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
        source.resume()
    }

    /// Wait for the child on a thread of its own. `waitpid` is the only way to
    /// learn the exit *code*, which the terminal wants to show and which
    /// `ghostty_surface_process_exit` takes.
    private func reapWhenItExits() {
        let pid = self.pid
        let started = self.startedAt
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            self?.onExit?(code, ms)
        }
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

    func stop() {
        reader?.cancel()
        reader = nil
        if pid > 0 { kill(pid, SIGHUP) }
    }
}
