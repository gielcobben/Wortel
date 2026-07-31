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
final class DirectoryWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject

    /// nil when the directory can't be opened — it was deleted between listing
    /// and watching, or we don't have permission. A tree row that never updates
    /// is a much better outcome there than a crash, and the next manual refresh
    /// still re-reads it.
    init?(path: String, onChange: @escaping () -> Void) {
        // O_EVTONLY: "I want events, not access" — it doesn't count as a use of
        // the file for unmount purposes, so a watched directory on an external
        // volume can't wedge its eject.
        let fd = open(path, O_EVTONLY)
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
        source.setEventHandler(handler: onChange)
        // Closing the descriptor is the cancel handler's job, not deinit's: the
        // source must be fully cancelled before the fd goes away, or the kernel
        // is left holding a descriptor number that has been reused.
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
