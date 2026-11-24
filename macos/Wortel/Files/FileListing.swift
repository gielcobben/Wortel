import Darwin
import Foundation

/// Finding the files in a folder that isn't a repository, the way Zed does
/// (its `file_scan_depth`, `file_scan_exclusions` and `scan_symlinks`):
///
/// - Five levels deep at most. Deeper folders aren't read.
/// - Version control folders, `.DS_Store` and `node_modules` are skipped:
///   outside git nothing says the last is ignored, and it's the folder that
///   would fill the cap on its own.
/// - Symlinked folders aren't followed, and the walk never crosses onto
///   another volume.
/// - A repository met on the way is not walked: git lists it
///   (`FileIndexStore`), in full, as Zed reads a repository in full.
/// - 200,000 files at most, a backstop for a folder with one enormous flat
///   directory.
///
/// And never from `/`, the home folder or anything above it, or a volume's
/// top: a session there gets no file list rather than a walk of the disk.
///
/// Readdir with `d_type`, so no `stat` per file, on every core: workers take
/// folders off one shared list, as Zed's scanner does.
enum FileListing {
    static let maxDepth = 5
    static let cap = 200_000
    static let skipped: Set<String> = [
        ".git", ".svn", ".hg", ".jj", ".sl", ".repo", "CVS", ".DS_Store", "node_modules",
    ]

    /// Whether `root` may be walked at all.
    static func mayWalk(_ root: String, home: String = NSHomeDirectory()) -> Bool {
        let path = (root as NSString).standardizingPath
        let home = (home as NSString).standardizingPath
        if path == "/" || path == home { return false }
        // Above home: /Users, and the same for any other account.
        if (home + "/").hasPrefix(path + "/") { return false }
        let parts = path.split(separator: "/")
        if parts.first == "Volumes", parts.count <= 2 { return false }
        if parts.count == 1, parts.first == "Users" { return false }
        return true
    }

    struct Walk: Sendable {
        /// Relative to the root, unsorted.
        var files: [String] = []
        /// Folders with a `.git` in them, relative: listed by git instead.
        var repositories: [String] = []
        /// Stopped at `cap`.
        var truncated = false
    }

    /// Every file under `root` by the rules above. `prefix` is where `root`
    /// sits in the folder being listed, put before each path found, and
    /// `depth` how deep that is (a folder inside the root walked again).
    static func walk(_ root: String, prefix: String = "", depth startDepth: Int = 0,
                     maxDepth: Int = maxDepth, cap: Int = cap,
                     isCancelled: @Sendable () -> Bool = { false }) -> Walk {
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return Walk() }
        let device = rootInfo.st_dev

        final class Shared: @unchecked Sendable {
            let lock = NSCondition()
            var pending: [(relative: String, depth: Int)] = []
            var active = 0
            var result = Walk()
            var stop = false
        }
        let shared = Shared()
        shared.pending = [(prefix, startDepth)]
        let base = root.hasSuffix("/") ? root : root + "/"
        let rootPrefixLength = prefix.isEmpty ? 0 : prefix.count + 1

        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                shared.lock.lock()
                while shared.pending.isEmpty, shared.active > 0, !shared.stop { shared.lock.wait() }
                if shared.stop || shared.pending.isEmpty {
                    shared.lock.broadcast()
                    shared.lock.unlock()
                    return
                }
                let job = shared.pending.removeLast()
                shared.active += 1
                shared.lock.unlock()

                let relativeToRoot = String(job.relative.dropFirst(rootPrefixLength))
                let absolute = relativeToRoot.isEmpty ? root : base + relativeToRoot
                let listing = list(absolute, device: device)

                shared.lock.lock()
                shared.active -= 1
                if let listing {
                    let join = { (name: String) in job.relative.isEmpty ? name : job.relative + "/" + name }
                    for name in listing.files {
                        if shared.result.files.count >= cap {
                            shared.result.truncated = true
                            shared.stop = true
                            break
                        }
                        shared.result.files.append(join(name))
                    }
                    for name in listing.directories where !shared.stop {
                        let path = join(name)
                        if isRepository(absolute + "/" + name) {
                            shared.result.repositories.append(path)
                        } else if job.depth + 1 < maxDepth {
                            shared.pending.append((path, job.depth + 1))
                        }
                    }
                }
                if isCancelled() { shared.stop = true }
                shared.lock.broadcast()
                shared.lock.unlock()
            }
        }
        return shared.result
    }

    /// Whether `path` holds a repository: a `.git` folder, or the `.git` file
    /// of a linked worktree or submodule.
    static func isRepository(_ path: String) -> Bool {
        var info = stat()
        return lstat(path + "/.git", &info) == 0
    }

    struct Listing: Sendable {
        var files: [String] = []
        var directories: [String] = []
    }

    /// One folder's files and folders, by name, without what's skipped and
    /// without symlinked folders. A symlink to a file is a file. Nil when it
    /// can't be read.
    ///
    /// `device`: folders on any other volume are left out. `skipping`: the
    /// names left out. `symlinksAsFiles`: every symlink is a file, whatever
    /// it points at, as git tracks one (a repository's folder compared with
    /// git's list, where a skipped name or a dropped symlink would read as
    /// a deleted file).
    static func list(_ path: String, device: dev_t? = nil, skipping: Set<String> = skipped,
                     symlinksAsFiles: Bool = false) -> Listing? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var listing = Listing()
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." || skipping.contains(name) { continue }
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                var info = stat()
                guard lstat(path + "/" + name, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: type = DT_DIR
                case S_IFLNK: type = DT_LNK
                case S_IFREG: type = DT_REG
                default: continue
                }
            }
            switch type {
            case DT_REG:
                listing.files.append(name)
            case DT_DIR:
                if let device {
                    var info = stat()
                    guard lstat(path + "/" + name, &info) == 0, info.st_dev == device else { continue }
                }
                listing.directories.append(name)
            case DT_LNK:
                if symlinksAsFiles {
                    listing.files.append(name)
                    continue
                }
                // Followed only to see what it is: a file is listed, a
                // folder never walked.
                var info = stat()
                if stat(path + "/" + name, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                    listing.files.append(name)
                }
            default:
                continue
            }
        }
        return listing
    }
}
