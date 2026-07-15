import Foundation

/// Watches a git work tree with FSEvents and fires `onChange` whenever anything
/// under it changes — working-tree files *or* `.git` internals. Git itself has
/// no event API, so a filesystem watch is how we notice commits, stages,
/// checkouts, stashes, and edits made outside Wortel, and keep the changes list
/// live without the user re-selecting the session.
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

    init(root: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(root: root)
    }

    deinit { stop() }

    private func start(root: String) {
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
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf))
        else { return }

        self.stream = stream
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
