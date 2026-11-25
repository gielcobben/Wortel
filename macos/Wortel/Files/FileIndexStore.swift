import CoreServices
import Foundation

/// The file lists ⌘P searches, one per folder, kept current while they're
/// in use.
///
/// **In a repository** the list is git's index (`git ls-files`, read in
/// about 100 ms for half a million files, no walk), plus the files git
/// neither tracks nor ignores. Those come from the git panel's last status
/// when it has a current one, and otherwise from one `ls-files --others`
/// the first time the folder is searched, which walks the work tree and is
/// seconds on a monorepo, so it waits behind the other background scans
/// and the tracked files are shown before it ends.
///
/// **Elsewhere** the folder is walked as Zed walks it (`FileListing`).
///
/// **Kept current** by an FSEvents watch on the folder, as Zed's worktree
/// is:
/// - The index changing (a commit, an add) reads git's list again.
/// - A folder whose contents changed is read again by itself, not
///   recursively. Its new files are asked about with `check-ignore`, and a
///   new folder that isn't ignored with `ls-files --others` on it alone.
/// - A dropped or coalesced event reads the untracked files under it again.
///
/// Built when ⌘P opens, not when a session is selected, so the cost
/// follows use. At most four folders, each let go 30 minutes after its
/// last search, which also ends its watch.
@MainActor
final class FileIndexStore {
    static let shared = FileIndexStore()

    static let folderLimit = 4
    static let idleLimit: TimeInterval = 30 * 60
    /// Repositories inside a walked folder that are listed, at most.
    static let nestedRepositoryLimit = 64

    /// A folder's index changed: told its root.
    var onChange: ((String) -> Void)?
    /// What the git panel already knows of a work tree's status.
    var knownStatus: ((String) -> (status: GitStatus, isCurrent: Bool)?)?

    enum Mode { case git, folder }

    final class Folder {
        /// The real path (FSEvents reports real paths).
        let root: String
        let mode: Mode
        /// Where git keeps this work tree's index.
        let gitDir: String?
        fileprivate(set) var index = FileIndex.empty
        fileprivate(set) var isLoading = true
        /// The walk stopped at its cap: what's listed is part of the folder.
        fileprivate(set) var isPartial = false

        fileprivate var tracked: [UInt8] = []
        fileprivate var untracked: Set<String> = []
        /// Tracked files gone from the disk (deleted, not yet committed).
        fileprivate var missing: Set<String> = []
        fileprivate var walked: Set<String> = []
        /// Repositories inside a walked folder, by their folder: listed by
        /// git, its tracked files read again when its index moves.
        fileprivate var nested: [String: (tracked: [String], untracked: [String])] = [:]
        fileprivate var dirtyRepositories: Set<String> = []
        fileprivate var needsWalk = false
        /// Folders git ignores (a build's output, `node_modules`): their
        /// events are dropped without asking git again.
        fileprivate var ignoredFolders: Set<String> = []
        /// A repository at the home folder or above (a dotfiles repository):
        /// its tracked files only. An untracked scan or a watch there would
        /// be one of the whole home folder.
        var tracksOnly: Bool { mode == .git && !FileListing.mayWalk(root) }
        fileprivate var indexStamp: String?
        fileprivate var watcher: GitRepoWatcher?
        fileprivate var lastUsed = Date()
        fileprivate var generation = 0
        fileprivate var changedFolders: Set<String> = []
        fileprivate var rescans: Set<String> = []
        fileprivate var pendingWork: DispatchWorkItem?
        /// When the pending update was first asked for: events keep coming
        /// (a dev server writing its cache), and an update put off past a
        /// second runs anyway.
        fileprivate var pendingSince: Date?
        fileprivate var isUpdating = false

        init(root: String, mode: Mode, gitDir: String?) {
            self.root = root
            self.mode = mode
            self.gitDir = gitDir
        }
    }

    private var folders: [String: Folder] = [:]

    /// The list for a session in `directory`: its repository's, or the
    /// folder's own. Started now if it isn't kept; nil for a folder that is
    /// never walked (`FileListing.mayWalk`).
    func folder(for directory: String) -> Folder? {
        letGoOfIdle()
        let repository = TerminalLink.repositoryRoot(of: directory)
        let root = GitWorktree.realPath(repository ?? directory)
        if let folder = folders[root] {
            folder.lastUsed = Date()
            return folder
        }
        if repository == nil, !FileListing.mayWalk(root) { return nil }
        let folder: Folder
        if repository != nil {
            let gitDir = GitWorktree.Ownership.gitDir(ofWorktree: root).map(GitWorktree.realPath)
                ?? (root as NSString).appendingPathComponent(".git")
            folder = Folder(root: root, mode: .git, gitDir: gitDir)
        } else {
            folder = Folder(root: root, mode: .folder, gitDir: nil)
        }
        folders[root] = folder
        checkIdleLater()
        if folders.count > Self.folderLimit,
           let oldest = folders.values.min(by: { $0.lastUsed < $1.lastUsed }) {
            letGo(oldest)
        }
        load(folder)
        return folder
    }

    /// A search in `folder`: it's in use, and kept.
    func touch(_ folder: Folder) {
        folder.lastUsed = Date()
    }

    private func letGoOfIdle() {
        let now = Date()
        for folder in folders.values where now.timeIntervalSince(folder.lastUsed) > Self.idleLimit {
            letGo(folder)
        }
    }

    private var idleCheckScheduled = false

    /// Every five minutes while any folder is kept: one not searched for 30
    /// minutes is let go, and its watch with it, whether ⌘P opens again or
    /// not.
    private func checkIdleLater() {
        guard !idleCheckScheduled else { return }
        idleCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60) { [weak self] in
            guard let self else { return }
            idleCheckScheduled = false
            letGoOfIdle()
            if !folders.isEmpty { checkIdleLater() }
        }
    }

    private func letGo(_ folder: Folder) {
        folder.watcher = nil
        folder.pendingWork?.cancel()
        folder.generation += 1
        folders[folder.root] = nil
    }

    private func isKept(_ folder: Folder) -> Bool { folders[folder.root] === folder }

    // MARK: - Loading

    private func load(_ folder: Folder) {
        Task { [weak self] in
            guard let self else { return }
            switch folder.mode {
            case .git: await loadRepository(folder)
            case .folder:
                await walk(folder)
                if isKept(folder) { watch(folder) }
            }
        }
    }

    private func loadRepository(_ folder: Folder) async {
        folder.indexStamp = Self.indexStamp(folder)
        folder.tracked = [UInt8](await GitService.trackedFiles(root: folder.root) ?? Data())
        var scanned = false
        if let known = knownStatus?(folder.root), known.isCurrent {
            folder.untracked = Set(known.status.changes.filter { $0.untracked && !$0.path.hasSuffix("/") }
                .map(\.path))
            scanned = true
        }
        await rebuild(folder)
        folder.isLoading = false
        onChange?(folder.root)
        // Watched from here, not after the untracked scan: on a monorepo
        // that takes seconds, and what changes meanwhile would be missed.
        guard !folder.tracksOnly, isKept(folder) else { return }
        watch(folder)
        guard !scanned else { return }
        let others = await GitService.untrackedFiles(root: folder.root)
        guard isKept(folder) else { return }
        folder.untracked.formUnion(Self.files(in: others))
        await rebuild(folder)
    }

    private func walk(_ folder: Folder) async {
        let root = folder.root
        let walk = await Task.detached(priority: .userInitiated) { FileListing.walk(root) }.value
        guard isKept(folder) else { return }
        folder.walked = Set(walk.files)
        let repositories = Array(walk.repositories.prefix(Self.nestedRepositoryLimit))
        for gone in folder.nested.keys where !repositories.contains(gone) { folder.nested[gone] = nil }
        await rebuild(folder, truncated: walk.truncated)
        folder.isLoading = false
        onChange?(folder.root)
        // Repositories met on the way, listed in full by git, as Zed reads
        // them: after the walk's own files are on screen. Their untracked
        // files are read once, when first met: a change inside one doesn't
        // scan it again (it may be a monorepo).
        var listed = false
        for repository in repositories where folder.nested[repository] == nil {
            let path = (root as NSString).appendingPathComponent(repository)
            let tracked = Self.paths(in: await GitService.trackedFiles(root: path) ?? Data())
            let others = Self.files(in: await GitService.untrackedFiles(root: path))
            guard isKept(folder) else { return }
            folder.nested[repository] = (tracked, others)
            listed = true
        }
        if listed { await rebuild(folder, truncated: walk.truncated) }
    }

    /// A new index from what the folder holds now, built off the main
    /// thread; dropped if a newer one was started meanwhile.
    ///
    /// `truncated`: the walk stopped at its cap (a walked folder only; nil
    /// keeps what the last walk said).
    private func rebuild(_ folder: Folder, truncated: Bool? = nil) async {
        folder.generation += 1
        let generation = folder.generation
        let (mode, tracked, untracked, missing, walked, nested) =
            (folder.mode, folder.tracked, folder.untracked, folder.missing, folder.walked, folder.nested)
        let walkTruncated = truncated ?? folder.isPartial
        let (index, partial) = await Task.detached(priority: .userInitiated) { () -> (FileIndex, Bool) in
            switch mode {
            case .git:
                var paths = FileIndex.split(nulSeparated: tracked)
                if !missing.isEmpty {
                    let gone = Set(missing.map { Array($0.utf8)[...] })
                    paths.removeAll { gone.contains($0) }
                }
                return (FileIndex.merging([(paths, .tracked), (FileIndex.sorted(untracked), .untracked)]), false)
            case .folder:
                var all = walked
                var partial = walkTruncated
                for (repository, files) in nested.sorted(by: { $0.key < $1.key }) where !partial {
                    for file in files.tracked + files.untracked {
                        guard all.count < FileListing.cap else { partial = true; break }
                        all.insert(repository + "/" + file)
                    }
                }
                return (FileIndex.merging([(FileIndex.sorted(all), .walked)]), partial)
            }
        }.value
        guard generation == folder.generation, isKept(folder) else { return }
        folder.index = index
        folder.isPartial = partial
        onChange?(folder.root)
    }

    /// The index file's size and date: whether git's list could have changed.
    private static func indexStamp(_ folder: Folder) -> String? {
        guard let gitDir = folder.gitDir else { return nil }
        var info = stat()
        guard stat((gitDir as NSString).appendingPathComponent("index"), &info) == 0 else { return nil }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
    }

    nonisolated static func paths(in data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `paths`, without the folders `ls-files --others` names whole: a
    /// repository or worktree inside the checkout is one `name/` entry, and
    /// it isn't a file to open.
    nonisolated static func files(in data: Data) -> [String] {
        paths(in: data).filter { !$0.hasSuffix("/") }
    }

    // MARK: - Keeping current

    private func watch(_ folder: Folder) {
        var paths = [folder.root]
        if let gitDir = folder.gitDir, !Self.isInside(gitDir, folder.root) { paths.append(gitDir) }
        let excluding = folder.mode == .git ? GitRepoWatcher.exclusions(forCheckoutAt: folder.root) : []
        let root = folder.root
        folder.watcher = GitRepoWatcher(paths: paths, excluding: excluding) { [weak self] paths, flags in
            Task { @MainActor [weak self] in self?.received(paths, flags, in: root) }
        }
    }

    private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags], in root: String) {
        guard let folder = folders[root] else { return }
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (path, flag) in zip(paths, flags) {
            let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            if folder.mode == .folder {
                noteWalkedChange(path, in: folder)
            } else if !folder.ignoredFolders.isEmpty, Self.isInside(path, folder.root),
                      folder.ignoredFolders.contains(where: { ignored in
                          let relative = String(path.dropFirst(folder.root.count + 1))
                          return relative == ignored || Self.isInside(relative, ignored)
                      }) {
                // A folder git ignores: nothing in it is ever listed.
                continue
            } else if flag & rescan != 0 {
                folder.rescans.insert(path)
            } else {
                folder.changedFolders.insert(path)
            }
        }
        guard folder.mode == .git || folder.needsWalk || !folder.dirtyRepositories.isEmpty else { return }
        schedule(folder, after: folder.mode == .git ? 0.3 : 1)
    }

    /// An event in a walked folder: inside a repository found there, only
    /// its index moving matters (its tracked files are read again); anywhere
    /// else, the folder is walked again.
    private func noteWalkedChange(_ path: String, in folder: Folder) {
        guard path != folder.root else { folder.needsWalk = true; return }
        guard Self.isInside(path, folder.root) else { return }
        let relative = String(path.dropFirst(folder.root.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        if let dotGit = parts.firstIndex(of: ".git") {
            let repository = parts[..<dotGit].joined(separator: "/")
            if folder.nested[repository] != nil { folder.dirtyRepositories.insert(repository) }
            return
        }
        // What the walk never reads: a skipped folder, or one too deep.
        if parts.contains(where: { FileListing.skipped.contains(String($0)) })
            || parts.count >= FileListing.maxDepth { return }
        if folder.nested.keys.contains(where: { Self.isInside(relative, $0) || relative == $0 }) { return }
        folder.needsWalk = true
    }

    private func schedule(_ folder: Folder, after delay: TimeInterval) {
        let now = Date()
        if folder.pendingWork != nil, let since = folder.pendingSince, now.timeIntervalSince(since) > 1 {
            return
        }
        folder.pendingWork?.cancel()
        if folder.pendingWork == nil { folder.pendingSince = now }
        let work = DispatchWorkItem { [weak self, weak folder] in
            guard let self, let folder else { return }
            folder.pendingWork = nil
            folder.pendingSince = nil
            Task { @MainActor in await self.update(folder) }
        }
        folder.pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func update(_ folder: Folder) async {
        guard isKept(folder) else { return }
        guard !folder.isUpdating else { return schedule(folder, after: 0.3) }
        folder.isUpdating = true
        defer { folder.isUpdating = false }
        let changed = folder.changedFolders, rescans = folder.rescans
        folder.changedFolders = []
        folder.rescans = []
        switch folder.mode {
        case .folder:
            // A walked folder is small by its rules: walked again whole.
            if folder.needsWalk {
                folder.needsWalk = false
                await walk(folder)
            }
            let dirty = folder.dirtyRepositories
            folder.dirtyRepositories = []
            for repository in dirty where folder.nested[repository] != nil {
                let path = (folder.root as NSString).appendingPathComponent(repository)
                let tracked = Self.paths(in: await GitService.trackedFiles(root: path) ?? Data())
                guard isKept(folder) else { return }
                folder.nested[repository]?.tracked = tracked
            }
            if !dirty.isEmpty { await rebuild(folder) }
        case .git:
            await updateRepository(folder, changed: changed, rescans: rescans)
        }
    }

    private func updateRepository(_ folder: Folder, changed: Set<String>, rescans: Set<String>) async {
        let root = folder.root
        let dotGit = (root as NSString).appendingPathComponent(".git")
        let all = changed.union(rescans)
        var dirty = false

        // Git's own folder: the index, if it moved.
        let gitDir = folder.gitDir ?? dotGit
        if all.contains(where: { Self.isInside($0, dotGit) || Self.isInside($0, gitDir) || $0 == gitDir }) {
            let stamp = Self.indexStamp(folder)
            if stamp != folder.indexStamp {
                folder.indexStamp = stamp
                if let tracked = await GitService.trackedFiles(root: root) {
                    folder.tracked = [UInt8](tracked)
                    // A checkout puts files back as well as taking them.
                    folder.missing = folder.missing.filter { !Self.exists($0, in: root) }
                    dirty = true
                }
            }
        }

        func relative(_ path: String) -> String? {
            if path == root { return "" }
            guard Self.isInside(path, root), path != dotGit, !Self.isInside(path, dotGit),
                  !path.hasSuffix("/.git"), !path.contains("/.git/") else { return nil }
            let relative = String(path.dropFirst(root.count + 1))
            // A submodule, or a repository or worktree inside the checkout:
            // its files are its own, and git can't be asked about them here.
            return Self.isInNestedRepository(relative, root: root) ? nil : relative
        }

        // Dropped events: what's untracked under them, read again by git.
        let rescanned = rescans.compactMap(relative)
        if !rescanned.isEmpty {
            let under = rescanned.contains("") ? [] : rescanned
            let others = Self.files(in: await GitService.untrackedFiles(root: root, under: under))
            folder.untracked = folder.untracked.filter { path in
                !under.isEmpty && !under.contains { Self.isInside(path, $0) || path == $0 }
            }
            folder.untracked.formUnion(others)
            dirty = true
        }

        // Folders whose contents changed: each read again by itself.
        var touched = changed.compactMap(relative).filter { path in
            !rescanned.contains { Self.isInside(path, $0) || $0 == "" || $0 == path }
                && !folder.ignoredFolders.contains { Self.isInside(path, $0) || $0 == path }
        }
        // A folder the index has nothing under may be one git ignores: asked
        // once, in one call, and remembered, so a build writing thousands of
        // files there costs nothing after its first event.
        let unknown = touched.filter { path in
            !path.isEmpty && folder.index.range(withPrefix: Array((path + "/").utf8)).isEmpty
                && !folder.untracked.contains { Self.isInside($0, path) }
        }
        if !unknown.isEmpty {
            // No answer: those folders wait for the next event rather than
            // have every file in them counted as new.
            let ignored = await GitService.checkedIgnore(root: root, paths: unknown) ?? Set(unknown)
            guard isKept(folder) else { return }
            folder.ignoredFolders.formUnion(ignored)
            touched.removeAll { path in ignored.contains { Self.isInside(path, $0) || $0 == path } }
        }
        if !touched.isEmpty {
            let index = folder.index
            let missing = folder.missing
            let diff = await Task.detached(priority: .utility) {
                Self.difference(of: touched, root: root, index: index, missing: missing)
            }.value
            guard isKept(folder) else { return }
            folder.missing.subtract(diff.back)
            for path in diff.gone {
                if folder.untracked.remove(path) == nil { folder.missing.insert(path) }
            }
            let asked = diff.newFiles + diff.newFolders
            // No answer: nothing new is added this time (never everything).
            let ignored = await GitService.checkedIgnore(root: root, paths: asked) ?? Set(asked)
            folder.untracked.formUnion(diff.newFiles.filter { !ignored.contains($0) })
            let newFolders = diff.newFolders.filter { !ignored.contains($0) }
            // A folder back on disk brings its tracked files back with it.
            folder.missing = folder.missing.filter { path in
                !(newFolders.contains { Self.isInside(path, $0) } && Self.exists(path, in: root))
            }
            if !newFolders.isEmpty {
                folder.untracked.formUnion(Self.files(in: await GitService.untrackedFiles(root: root, under: newFolders)))
            }
            if !diff.isEmpty { dirty = true }
        }
        guard dirty, isKept(folder) else { return }
        await rebuild(folder)
    }

    struct Difference: Sendable {
        /// Files on disk the index doesn't list.
        var newFiles: [String] = []
        /// Folders on disk with nothing in the index under them.
        var newFolders: [String] = []
        /// Listed paths no longer on disk.
        var gone: [String] = []
        /// Tracked files once missing, on disk again.
        var back: [String] = []
        var isEmpty: Bool { newFiles.isEmpty && newFolders.isEmpty && gone.isEmpty && back.isEmpty }
    }

    /// What changed in each of `folders` (relative to `root`) against the
    /// index: one `readdir` each, not recursive.
    nonisolated static func difference(of folders: [String], root: String, index: FileIndex,
                                       missing: Set<String>) -> Difference {
        var result = Difference()
        for folder in Set(folders) {
            let prefix = folder.isEmpty ? "" : folder + "/"
            let absolute = folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder)
            let range = index.range(withPrefix: Array(prefix.utf8))
            var listedFiles = Set<String>()
            var listedFolders = Set<String>()
            for entry in range {
                let rest = index.path(entry).dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/") {
                    listedFolders.insert(String(rest[..<slash]))
                } else {
                    listedFiles.insert(String(rest))
                }
            }
            // Nothing skipped but `.git`, and every symlink a file: git
            // tracks `node_modules` or a `.DS_Store` if it was told to, and
            // a symlink to a folder as one entry.
            guard let listing = FileListing.list(absolute, skipping: [".git"], symlinksAsFiles: true) else {
                // The folder itself is gone: everything under it.
                result.gone += range.map { index.path($0) }
                continue
            }
            // A submodule is one entry in git's list and a folder on disk.
            let onDisk = Set(listing.files).union(listing.directories)
            for name in listing.files where !listedFiles.contains(name) {
                let path = prefix + name
                if missing.contains(path) { result.back.append(path) } else { result.newFiles.append(path) }
            }
            for name in listedFiles where !onDisk.contains(name) {
                result.gone.append(prefix + name)
            }
            let foldersOnDisk = Set(listing.directories)
            for name in listing.directories where !listedFolders.contains(name) && !listedFiles.contains(name) {
                // A repository or worktree made inside: not this one's files.
                if FileListing.isRepository(absolute + "/" + name) { continue }
                result.newFolders.append(prefix + name)
            }
            for name in listedFolders where !foldersOnDisk.contains(name) {
                let gone = index.range(withPrefix: Array((prefix + name + "/").utf8))
                result.gone += gone.map { index.path($0) }
            }
        }
        return result
    }

    /// Whether `relative` is in a repository of its own inside `root`: it or
    /// a folder above it, below the root, has a `.git`.
    nonisolated static func isInNestedRepository(_ relative: String, root: String) -> Bool {
        PathWalk.upward(from: relative).contains {
            FileListing.isRepository((root as NSString).appendingPathComponent($0))
        }
    }

    private static func exists(_ path: String, in root: String) -> Bool {
        access((root as NSString).appendingPathComponent(path), F_OK) == 0
    }

    nonisolated static func isInside(_ path: String, _ folder: String) -> Bool {
        folder.isEmpty || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
