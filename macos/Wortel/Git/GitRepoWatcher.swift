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
/// index is being woken for nothing. The same goes for a worktree that lives
/// *inside* the checkout (`wortel.worktreePath = .worktrees`, Claude Code's
/// `.claude/worktrees/<name>`): every file an agent writes there is under this
/// root too. See `exclusions(forCheckoutAt:)`.
///
/// The callback runs on a background queue; callers marshal to the main actor.
/// FSEvents coalesces bursts (see the latency below), and callers debounce
/// again, so a busy repo (a build, an agent editing files) collapses to a
/// handful of refreshes rather than one per write.
final class GitRepoWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    /// Everything left out, resolved the way FSEvents reports paths. The
    /// kernel takes the first `kernelExclusionLimit`; the callback drops
    /// events under any of them, which is what covers the rest.
    private let excluded: [String]

    /// FSEvents coalescing window, seconds. Big enough to batch a burst of
    /// writes, small enough that a commit feels immediate.
    private static let latency: CFTimeInterval = 0.25

    /// FSEvents takes at most this many exclusion paths, and rejects the whole
    /// list if it's longer.
    static let kernelExclusionLimit = 8

    init(paths: [String], excluding: [String] = [], onChange: @escaping () -> Void) {
        self.onChange = onChange
        // FSEvents reports real paths (`/private/var/…`); a caller's may be
        // the way it was reached.
        excluded = excluding.map(GitWorktree.realPath)
        start(paths: paths, excluding: excluding)
    }

    deinit { stop() }

    private func start(paths: [String], excluding: [String]) {
        guard !paths.isEmpty else { return }
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitRepoWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.deliver(count: count, paths: paths)
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
        if !excluding.isEmpty {
            FSEventStreamSetExclusionPaths(
                stream, Array(excluding.prefix(Self.kernelExclusionLimit)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// A batch of events: news unless every path in it is left out. Without
    /// `UseCFTypes` the paths come as C strings.
    private func deliver(count: Int, paths: UnsafeMutableRawPointer) {
        guard !excluded.isEmpty else { return onChange() }
        let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        for index in 0..<count where !Self.isExcluded(String(cString: list[index]), by: excluded) {
            return onChange()
        }
    }

    /// Whether `path` is one of `excluded` or under one, by whole components.
    /// (FSEvents ends a directory's path with a slash, which this allows.)
    static func isExcluded(_ path: String, by excluded: [String]) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

// MARK: - What a checkout's watch leaves out

extension GitRepoWatcher {
    /// What a watch on the checkout at `root` should leave out: the other
    /// worktrees' state in the primary's `.git/worktrees` (and the object
    /// store their `git add`s write to), and every linked worktree of the
    /// repository that lives inside `root`.
    ///
    /// The second is the cost on a large monorepo. A repository
    /// that keeps its worktrees inside itself (`wortel.worktreePath =
    /// .worktrees`, or Claude Code's `.claude/worktrees/<name>`) has every
    /// file an agent writes in one of them land under the main checkout's
    /// root as well, and each was a seven-second `git status` there, for a
    /// work tree that did not move. Git doesn't list them anyway (they're in
    /// `info/exclude`, or nested checkouts it won't descend into), so leaving
    /// them out loses nothing the status would have shown.
    ///
    /// Read off the disk, not from git: `<common>/worktrees/<name>/gitdir`
    /// names each worktree's `.git` file. Cheap enough to re-check after each
    /// status, which is how a worktree made inside the checkout later gets
    /// left out too (it wakes the watch once, as it's created).
    nonisolated static func exclusions(forCheckoutAt root: String) -> [String] {
        let root = GitWorktree.realPath(root)
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return [] }
        var always: [String] = []
        let common: String
        if isDirectory.boolValue {
            common = dotGit
            always.append((dotGit as NSString).appendingPathComponent("worktrees"))
            // And the object store: a `git add` in any other worktree writes a
            // blob here and nothing else this checkout has, so it woke a full
            // status for a work tree, index and HEAD that hadn't moved.
            // Everything that does change this checkout's status also writes
            // its index, its HEAD or a ref, which are still watched.
            always.append((dotGit as NSString).appendingPathComponent("objects"))
        } else {
            // A linked worktree: its git dir is `<common>/worktrees/<name>`.
            // Anything else (a submodule) has no worktrees of its own here.
            guard let gitDir = GitWorktree.Ownership.gitDir(ofWorktree: root) else { return [] }
            let parent = ((gitDir as NSString).standardizingPath as NSString).deletingLastPathComponent
            guard (parent as NSString).lastPathComponent == "worktrees" else { return [] }
            common = (parent as NSString).deletingLastPathComponent
        }
        return exclusions(
            root: root, always: always,
            worktrees: linkedWorktreeRoots(commonDir: common),
            contents: { try? FileManager.default.contentsOfDirectory(atPath: $0) })
    }

    /// The folder of every linked worktree of the repository whose git dir is
    /// `commonDir`, from the `gitdir` file git keeps for each. Real paths, as
    /// FSEvents reports them.
    nonisolated static func linkedWorktreeRoots(commonDir: String) -> [String] {
        let registry = (commonDir as NSString).appendingPathComponent("worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: registry)) ?? []
        return names.compactMap { name in
            let file = ((registry as NSString).appendingPathComponent(name) as NSString)
                .appendingPathComponent("gitdir")
            guard let pointer = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            let dotGit = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard dotGit.hasPrefix("/") else { return nil }
            return GitWorktree.realPath((dotGit as NSString).deletingLastPathComponent)
        }
    }

    /// The pure part: `always`, then each worktree inside `root`, with a
    /// folder that holds nothing but worktrees standing for all of them.
    ///
    /// Collapsing is for FSEvents' limit of eight, and it's also the better
    /// answer: `.worktrees` left out whole covers the next worktree made in
    /// it before anything knows it's there. Only a folder whose every entry
    /// is one of the worktrees (`contents`, by name; `.DS_Store` aside), never
    /// one that holds the repository's own files, and never `root` itself.
    /// Past eight the callback filters the rest (`deliver`), so the order
    /// says what the kernel gets: `always` first, as the busiest.
    static func exclusions(root: String, always: [String], worktrees: [String],
                           contents: (String) -> [String]?) -> [String] {
        let inside = Set(worktrees.filter { $0.hasPrefix(root + "/") })
        var byParent: [String: [String]] = [:]
        for worktree in inside {
            byParent[(worktree as NSString).deletingLastPathComponent, default: []].append(worktree)
        }
        var found: [String] = []
        for (parent, children) in byParent {
            let entries = parent.hasPrefix(root + "/")
                ? contents(parent)?.filter { $0 != ".DS_Store" } : nil
            if let entries, !entries.isEmpty, entries.allSatisfy({
                inside.contains((parent as NSString).appendingPathComponent($0))
            }) {
                found.append(parent)
            } else {
                found += children
            }
        }
        // A worktree inside another one (Claude Code's, in a worktree that is
        // itself inside the checkout) is left out with it already.
        found = found.filter { path in !found.contains { path.hasPrefix($0 + "/") } }
        return always + found.sorted()
    }
}
