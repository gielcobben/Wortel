import Foundation

/// Watches a git work tree with FSEvents and fires `onChange` whenever anything
/// under it changes — working-tree files *or* `.git` internals. Git itself has
/// no event API, so a filesystem watch is how we notice commits, stages,
/// checkouts, stashes, and edits made outside Wortel, and keep the changes list
/// live without the user re-selecting the session.
///
/// It takes a *list* of paths because a linked worktree's git state isn't under
/// its work tree: the work tree gives us the file edits, and the checkout's own
/// gitdir (`<primary>/.git/worktrees/<name>`) gives us its HEAD and index. See
/// `GitService.externalGitDir`. `excluding` is the other half of the same split
/// — the primary checkout's watch covers its whole `.git`, which holds every
/// worktree's state under `worktrees/`, and being woken by another session's
/// index is being woken for nothing.
///
/// The callback runs on a background queue; callers marshal to the main actor.
/// FSEvents coalesces bursts (see the latency below), and callers debounce
/// again, so a busy repo (a build, an agent editing files) collapses to a
/// handful of refreshes rather than one per write.
final class GitRepoWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// FSEvents coalescing window, seconds. Big enough to batch a burst of
    /// writes, small enough that a commit feels immediate.
    private static let latency: CFTimeInterval = 0.25

    init(paths: [String], excluding: [String] = [], onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(paths: paths, excluding: excluding)
    }

    deinit { stop() }

    private func start(paths: [String], excluding: [String]) {
        guard !paths.isEmpty else { return }
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitRepoWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf))
        else { return }

        self.stream = stream
        // Capped at 8 by FSEvents, and it rejects the whole list if it's longer.
        if !excluding.isEmpty {
            FSEventStreamSetExclusionPaths(stream, Array(excluding.prefix(8)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
