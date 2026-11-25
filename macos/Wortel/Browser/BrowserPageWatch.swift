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
///
/// Nothing here runs until the kernel reports an event: a watch is an open
/// descriptor and no more. The stats are a few dozen at most, on the main
/// actor, a moment after the last event of a burst.
@MainActor
final class BrowserPageWatch {
    /// A watched file changed. Called once per burst of writes.
    var onChange: () -> Void = {}

    /// The page's own file and the local files it loaded, with how each last
    /// looked on disk.
    private var files: [String: Stamp] = [:]
    private var fileWatchers: [String: DirectoryWatcher] = [:]
    private var folderWatchers: [String: DirectoryWatcher] = [:]
    private var settling: Task<Void, Never>?

    /// The page's file and at most this many of the files it loaded.
    static let maxResources = 32
    /// How long after the last event the files are looked at: an agent writes
    /// a file in pieces, and a save is often a write and then a rename.
    static let settle: Duration = .milliseconds(150)

    /// How a file looks on disk; all nil when it isn't there.
    struct Stamp: Equatable {
        var modified: Date?
        var size: Int64?
        var inode: UInt64?

        var exists: Bool { inode != nil }

        static func of(_ path: String) -> Stamp {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return Stamp() }
            return Stamp(modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.int64Value,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
    }

    /// Watch `page` and what it loaded, in place of whatever was watched. A
    /// file already watched keeps its watch and what was known of it, so
    /// calling this after every load costs nothing when nothing moved.
    func watch(page: String, resources: [String]) {
        var wanted = [page]
        for path in resources where !wanted.contains(path) && wanted.count <= Self.maxResources {
            wanted.append(path)
        }
        for path in files.keys where !wanted.contains(path) {
            files[path] = nil
            fileWatchers[path] = nil
        }
        for path in wanted where files[path] == nil {
            files[path] = Stamp.of(path)
            watchFile(path)
        }
        let folders = Set(wanted.map { ($0 as NSString).deletingLastPathComponent })
        for folder in folderWatchers.keys where !folders.contains(folder) { folderWatchers[folder] = nil }
        for folder in folders where folderWatchers[folder] == nil {
            folderWatchers[folder] = DirectoryWatcher(path: folder) { [weak self] _ in
                Task { @MainActor in self?.eventArrived() }
            }
        }
    }

    func stop() {
        settling?.cancel()
        files = [:]
        fileWatchers = [:]
        folderWatchers = [:]
    }

    /// What is watched, for the tests.
    var watchedFiles: Set<String> { Set(files.keys) }

    private func watchFile(_ path: String) {
        fileWatchers[path] = DirectoryWatcher(path: path) { [weak self] vanished in
            Task { @MainActor in
                guard let self else { return }
                // Replaced or deleted: this watch has said its last. The check
                // below makes a new one if a file is there again.
                if vanished { self.fileWatchers[path] = nil }
                self.eventArrived()
            }
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
        var moved = false
        for (path, known) in files {
            let now = Stamp.of(path)
            if now.exists, fileWatchers[path] == nil { watchFile(path) }
            // Gone: the page keeps showing what it has.
            guard now.exists, now != known else { continue }
            files[path] = now
            moved = true
        }
        if moved { onChange() }
    }
}
