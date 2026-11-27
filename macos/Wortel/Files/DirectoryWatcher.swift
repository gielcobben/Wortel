import Foundation

/// Watches **one directory, not its subtree**, and fires `onChange` when its
/// contents move — a file created, deleted, or renamed inside it.
///
/// This exists instead of reusing `GitRepoWatcher` because FSEvents is always
/// recursive, and recursive is exactly wrong here. The file tree only ever draws
/// the directories you have expanded, so those are the only ones whose contents
/// can be stale: one watcher per expanded directory means a collapsed
/// `node_modules` costs nothing at all — no watcher, no listing, no ignore
/// check — and a session rooted at `~` doesn't end up watching `~/Library`
/// churn. It's the same rule as the git panel's, applied to the filesystem:
/// cost tracks the window, not the tree.
///
/// The callback runs on a background queue; callers marshal to the main actor.
/// The kernel coalesces bursts within a single `.write` notification and callers
/// debounce again, so a directory being written into hard collapses to a handful
/// of re-listings rather than one per file.
///
/// **A watch is on an inode, not on a path**, and that distinction is the whole
/// reason `onChange` reports `vanished`. Verified with a standalone harness: a
/// watcher on `dist/` sees files appear inside it, sees `dist/` itself be
/// deleted — and then sees *nothing ever again*, including every file written
/// into the new `dist/` at the same path. A branch switch, an `rm -rf build`, an
/// agent recreating a folder: each one silently kills the watch, and a tree that
/// stops updating looks exactly like a tree with nothing to report. So the
/// caller is told when the directory it asked about is gone, and re-establishes
/// the watch on whatever now lives at that path.
final class DirectoryWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject

    /// nil when the directory can't be opened — it was deleted between listing
    /// and watching, or we don't have permission. A tree row that never updates
    /// is a much better outcome there than a crash, and the next manual refresh
    /// still re-reads it.
    ///
    /// `onChange` receives `vanished: true` when the event was this directory
    /// being deleted or renamed rather than its contents moving — at which point
    /// this watcher is watching an inode nobody can reach and must be replaced.
    ///
    /// Only a directory or a regular file is watched. Anything else at the
    /// path (a FIFO, a serial port like `/dev/tty.Bluetooth-Incoming-Port`)
    /// gives nil: `open` on one of those waits for a writer or a carrier and,
    /// measured 2026-11-27, never returned, on the main thread. A browser
    /// tab watches whatever paths a local page names, so a page could freeze
    /// the app by naming one. The stat says no to those; `O_NONBLOCK` covers
    /// a path swapped for one between the stat and the open. It changes
    /// nothing for a directory or a regular file, which is all any caller
    /// watches.
    init?(path: String, onChange: @escaping (_ vanished: Bool) -> Void) {
        guard Self.isWatchable(path) else { return nil }
        // O_EVTONLY: "I want events, not access" — it doesn't count as a use of
        // the file for unmount purposes, so a watched directory on an external
        // volume can't wedge its eject.
        let fd = open(path, O_EVTONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        descriptor = fd
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // `.write` is the one that fires for entries appearing and
            // disappearing. `.rename`/`.delete` are about *this* directory
            // rather than its contents — the parent's own watcher reports the
            // change, but they're included so a directory that moves out from
            // under us stops the source rather than silently watching an inode
            // nobody can reach.
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak source] in
            guard let events = source?.data else { return }
            onChange(events.contains(.delete) || events.contains(.rename))
        }
        // Closing the descriptor is the cancel handler's job, not deinit's: the
        // source must be fully cancelled before the fd goes away, or the kernel
        // is left holding a descriptor number that has been reused.
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// A directory or a regular file, after symbolic links, as `open`
    /// follows them. A `stat` never opens, so it can't wait on a device.
    static func isWatchable(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFDIR || kind == S_IFREG
    }
}
