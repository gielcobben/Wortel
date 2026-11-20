import AppKit

/// One Wortel per data folder (`DataDirectory`).
///
/// Two copies sharing a folder cannot share the sessions: the keeper hands a
/// session to one app at a time, and the second copy gets fresh shells of its
/// own. What they do share is the files. Each keeps a copy in memory from the
/// moment it launched and writes it back when it quits, so whichever quits
/// last rolls back everything the other learned since: the session list, and
/// what each terminal was told. An agent that lost its `?2031` that way stays
/// in the wrong light or dark palette for good, because it only asks once, at
/// startup. Test builds from other worktrees, running beside the real app, did
/// exactly that.
///
/// So a second copy does not run. It brings the one that owns the folder
/// forward, the way opening an app that is already running does, and quits. A
/// copy meant to run beside it takes a folder of its own (`WORTEL_DATA_DIR`).
///
/// `flock`, so the lock ends with the process however the process ends: a
/// crash or a `kill -9` never leaves a folder locked.
enum InstanceLock {
    /// Held open for the life of the process: closing it releases the lock.
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    /// The process that had the folder before this one, read from the lock
    /// file before this one writes its own: the last app to run here,
    /// whichever build it was. `SavedScreens` uses a screen only if this is
    /// the app that saved it.
    nonisolated(unsafe) private(set) static var previousOwner: Int32?

    /// Take the data folder, or hand off to whoever has it and exit. Called
    /// first thing in main.swift, before anything reads or writes the folder.
    static func acquireOrHandOff() {
        let directory = DataDirectory.url
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path
        // O_CLOEXEC: the keeper and every shell are started from this process,
        // and a child holding the descriptor would hold the lock after we quit.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        // A folder we can't lock is one we can't write either; run and let the
        // stores fail as they always have, rather than refuse to open at all.
        guard fd >= 0 else { return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let owner = ownerPID(fd)
            close(fd)
            handOff(to: owner)
        }
        previousOwner = ownerPID(fd).map { Int32($0) }
        // Who has it, for the next copy to bring forward.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        descriptor = fd
    }

    private static func ownerPID(_ fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func handOff(to owner: pid_t?) -> Never {
        let running = owner.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first { $0.processIdentifier != getpid() }
        // Said on stderr for whoever launched this from a terminal or an agent:
        // otherwise a second copy that quits at once looks like a crash.
        let who = running?.bundleURL?.path ?? owner.map { "pid \($0)" } ?? "another copy"
        let message = "wortel: \(DataDirectory.url.path) is in use by \(who); bringing it forward. "
            + "Set \(DataDirectory.variable) to run this copy with a data folder of its own.\n"
        FileHandle.standardError.write(Data(message.utf8))
        running?.unhide()
        running?.activate()
        exit(0)
    }
}
