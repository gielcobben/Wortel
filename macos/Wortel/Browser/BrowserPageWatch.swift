import Foundation

/// Says when a page shown from a file should be loaded again: its file
/// changed on disk, or one of the local files it loaded did (its stylesheet,
/// a script, a picture).
///
/// The watching is `PreviewDocument`'s, for more than one file:
///
/// - **Each file and its folder, never a subtree.** A vnode watch follows an
///   inode, and an agent saving a file replaces it (write a temporary file,
///   rename it over), so the watch on the old inode says "gone" and goes deaf.
///   The file's own watch catches a write in place and is made again when it
///   dies; the folder's watch catches the file coming back.
/// - **Stat before saying anything.** A folder's watch fires for every file in
///   it. Only a watched file whose date, size or inode moved counts.
/// - **A file that is gone changes nothing.** The page stays as it last was,
///   and loads again when the file is back.
/// - **A folder that is gone is waited for.** `rm -rf dist` and a rebuild
///   take the folder's inode away with it, and a watch on it goes deaf for
///   good. While a folder is missing the nearest folder above it that exists
///   is watched instead, and the folder's own watch is made again once it is
///   back. Until 2026-11-27 a page stopped reloading for good after its
///   folder was made again, and ⌘R did not bring it back.
/// - **Only files and folders.** A page names any path it likes, and `open`
///   on a FIFO or a serial port never returns (`DirectoryWatcher`). Such a
///   path is left out. A path that isn't there yet is kept: it may come.
///   Where a path is doesn't matter: a page loads `../style.css` as well as
///   `style.css` (`architecture/workspace-tabs.md`), so limiting what is
///   watched to the page's own folder would lose real reloads, and what made
///   a path dangerous was what it is, not where.
///
/// Nothing here runs until the kernel reports an event: a watch is an open
/// descriptor and no more. The stats are a few dozen at most, on the main
/// actor, a moment after the last event of a burst, and on each load.
@MainActor
final class BrowserPageWatch {
    /// A watched file changed. Called once per burst of writes.
    var onChange: () -> Void = {}

    /// The page's own file and the local files it loaded, with how each last
    /// looked on disk.
    private var files: [String: Stamp] = [:]
    private var fileWatchers: [String: Watch] = [:]
    /// The folders the files are in, and what is watched for each: the
    /// folder, or while it is missing the nearest one above it that exists.
    private var folders: Set<String> = []
    private var folderWatchers: [String: Watch] = [:]
    private var settling: Task<Void, Never>?

    /// The page's file and at most this many of the files it loaded.
    static let maxResources = 32
    /// How long after the last event the files are looked at: an agent writes
    /// a file in pieces, and a save is often a write and then a rename.
    static let settle: Duration = .milliseconds(150)

    /// How a file looks on disk; all nil when it isn't there, or is
    /// something other than a file or a folder.
    struct Stamp: Equatable {
        var modified: Date?
        var size: Int64?
        var inode: UInt64?

        var exists: Bool { inode != nil }

        static func of(_ path: String) -> Stamp {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return Stamp() }
            let type = attributes[.type] as? FileAttributeType
            // A link is followed by the watch, and read here as the link.
            guard type == .typeRegular || type == .typeDirectory || type == .typeSymbolicLink else {
                return Stamp()
            }
            return Stamp(modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.int64Value,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
    }

    /// One open watch, and the inode it is on: a watch whose path now has
    /// another inode is deaf, whatever it reported.
    private struct Watch {
        let path: String
        let inode: UInt64
        let watcher: DirectoryWatcher
    }

    /// Watch `page` and what it loaded, in place of whatever was watched. A
    /// file already watched keeps its watch and what was known of it, so
    /// calling this after every load costs nothing when nothing moved. A
    /// watch that died is made again here, so a reload (⌘R) mends one.
    func watch(page: String, resources: [String]) {
        var wanted = [page]
        for path in resources where wanted.count <= Self.maxResources
            && !wanted.contains(path) && Self.mayWatch(path) {
            wanted.append(path)
        }
        for path in files.keys where !wanted.contains(path) {
            files[path] = nil
            fileWatchers[path] = nil
        }
        for path in wanted {
            if files[path] == nil { files[path] = Stamp.of(path) }
            armFile(path)
        }
        folders = Set(wanted.map { ($0 as NSString).deletingLastPathComponent })
        for folder in folderWatchers.keys where !folders.contains(folder) { folderWatchers[folder] = nil }
        armFolders()
    }

    func stop() {
        settling?.cancel()
        files = [:]
        fileWatchers = [:]
        folders = []
        folderWatchers = [:]
    }

    /// What is watched, for the tests.
    var watchedFiles: Set<String> { Set(files.keys) }
    /// Each folder, and the path watched for it, for the tests.
    var watchedFolders: [String: String] { folderWatchers.mapValues(\.path) }

    /// A path a page named that may be watched: a file or a folder, or
    /// nothing yet. Never a FIFO, a device or a socket.
    static func mayWatch(_ path: String) -> Bool {
        inode(of: path) == nil || DirectoryWatcher.isWatchable(path)
    }

    /// Watch the file at `path`, unless the watch on it is already on the
    /// inode there now. Nothing there, or nothing that can be watched: no
    /// watch, and the next look makes one if that changes.
    private func armFile(_ path: String) {
        guard let inode = Self.inode(of: path) else { return }
        guard fileWatchers[path]?.inode != inode else { return }
        fileWatchers[path] = nil
        guard let watcher = DirectoryWatcher(path: path, onChange: { [weak self] vanished in
            Task { @MainActor in
                guard let self else { return }
                // Replaced or deleted: this watch has said its last. The check
                // below makes a new one if a file is there again.
                if vanished, self.fileWatchers[path]?.inode == inode { self.fileWatchers[path] = nil }
                self.eventArrived()
            }
        }) else { return }
        fileWatchers[path] = Watch(path: path, inode: inode, watcher: watcher)
    }

    /// Watch each folder, or the nearest folder above one that is missing,
    /// unless that is already what is watched for it.
    private func armFolders() {
        for folder in folders {
            guard let (target, inode) = Self.nearestFolder(to: folder) else {
                folderWatchers[folder] = nil
                continue
            }
            if let current = folderWatchers[folder], current.path == target, current.inode == inode { continue }
            folderWatchers[folder] = nil
            guard let watcher = DirectoryWatcher(path: target, onChange: { [weak self] vanished in
                Task { @MainActor in
                    guard let self else { return }
                    // Deleted or moved: watch what is at the path now, or
                    // what is above it while nothing is.
                    if vanished, self.folderWatchers[folder]?.inode == inode {
                        self.folderWatchers[folder] = nil
                        self.armFolders()
                    }
                    self.eventArrived()
                }
            }) else { continue }
            folderWatchers[folder] = Watch(path: target, inode: inode, watcher: watcher)
        }
    }

    private func eventArrived() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self else { return }
            self.check()
        }
    }

    private func check() {
        // A folder made again, or one deeper on the way back: watch it.
        armFolders()
        var moved = false
        for (path, known) in files {
            let now = Stamp.of(path)
            if now.exists { armFile(path) }
            // Gone: the page keeps showing what it has.
            guard now.exists, now != known else { continue }
            files[path] = now
            moved = true
        }
        if moved { onChange() }
    }

    /// The inode at `path`, after links, as `open` sees it; nil when
    /// nothing is there.
    private static func inode(of path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    /// `folder` if it is one, or the nearest folder above it that is.
    private static func nearestFolder(to folder: String) -> (String, UInt64)? {
        var path = folder
        while !path.isEmpty {
            var info = stat()
            if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return (path, UInt64(info.st_ino)) }
            if path == "/" { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }
}
