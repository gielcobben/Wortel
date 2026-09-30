import Foundation

/// The project directories Wortel has opened sessions in, remembered across
/// launches.
///
/// This exists for exactly one job: deciding which abandoned process is ours to
/// offer to kill. A dev server that outlived its session reparents to `launchd`
/// and keeps nothing pointing back at the terminal that started it except its
/// working directory — so attribution is "is this sitting inside a project I
/// have opened here". Without that test the orphan list is every login agent and
/// XPC service on the machine: 338 processes had `ppid == 1` under one uid on a
/// perfectly ordinary Mac.
///
/// The list has to outlive the session, because the interesting orphan is
/// precisely the one whose session closed days ago.
enum ProjectRoots {
    /// Enough to cover the projects anyone actually returns to, small enough
    /// that a stale entry from months ago can't quietly widen the net forever.
    static let limit = 40

    private static var fileURL: URL {
        DataDirectory.file("project-roots.json")
    }

    /// Whether a directory is specific enough to attribute a process by.
    ///
    /// Home, or anything above it, would match essentially every process this
    /// user runs, which turns "a server your session left behind" into "a list
    /// of your Mac". A session opened at `~` is perfectly normal, so this has
    /// to be refused here rather than assumed not to happen.
    static func isSpecificEnough(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard let root = FolderRoot.normalize(path),
              let home = FolderRoot.normalize(home) else { return false }
        guard root != "/", root != home else { return false }
        // An ancestor of home ("/Users") is broader still.
        return !FolderRoot.root(root, contains: home)
    }

    /// Fold newly seen directories into the remembered list, newest first.
    ///
    /// Pure, so the part that can silently widen or narrow the orphan net is
    /// testable without touching the disk.
    static func merge(_ existing: [String], adding: [String],
                      limit: Int = limit, home: String = NSHomeDirectory()) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for path in adding + existing {
            guard isSpecificEnough(path, home: home),
                  let normalized = FolderRoot.normalize(path),
                  seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Best-effort: a failure here costs the orphan list, never a session.
    static func save(_ roots: [String]) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(roots) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
