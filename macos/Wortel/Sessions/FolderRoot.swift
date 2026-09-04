import Foundation

/// A sidebar folder's **directory**: the path a new session in that folder
/// starts in.
///
/// Folders used to be a name and nothing else — `SessionName` splits "GFPC/api"
/// into a folder and a leaf, and that split was the whole of the feature. So
/// "New Session in GFPC" filed a session under GFPC and started it in whatever
/// directory the *selected* session had last `cd`'d to, which is the one thing
/// nobody means by it. Giving a folder a root is what makes it a project rather
/// than a label.
///
/// All of it is string handling over paths, which is the shape of code that
/// fails silently: a wrong ancestor doesn't throw, it quietly moves where every
/// new session starts. Hence a pure enum with no AppKit and no `SessionManager`,
/// pinned by `FolderRootTests`.
enum FolderRoot {
    /// Normalized for comparison: no trailing slash, no `..`, no doubled
    /// separators. Empty in, nil out — a session that has never reported a
    /// working directory has no path to compare.
    static func normalize(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let standard = (path as NSString).standardizingPath
        guard standard != "/" else { return "/" }
        // standardizingPath already drops a trailing slash, but it leaves one on
        // a root-relative path it can't shorten, and a stray one would make
        // "/a/b/" and "/a/b" different folders.
        let trimmed = standard.hasSuffix("/") ? String(standard.dropLast()) : standard
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `path` is `root` or sits underneath it.
    ///
    /// The `/` guard is the whole point: a plain `hasPrefix` says
    /// `/Users/giel/wortel-web` is inside `/Users/giel/wortel`, and the sibling
    /// project would silently inherit the wrong folder's directory.
    static func root(_ root: String, contains path: String) -> Bool {
        guard let root = normalize(root), let path = normalize(path) else { return false }
        if root == path { return true }
        return path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// The deepest folder whose root contains `path`, or nil when none does.
    ///
    /// Deepest rather than first: with "Wortel" rooted at `~/Developer/wortel`
    /// and a "Web" folder rooted at `~/Developer/wortel/web`, opening the web
    /// directory means the folder that *is* it, not the one it's inside. Ties
    /// are impossible — two folders with the same root are the same directory,
    /// and the name breaks it only so the answer never depends on dictionary
    /// order.
    static func folder(containing path: String, in roots: [String: String]) -> String? {
        roots
            .filter { root($0.value, contains: path) }
            .max { a, b in
                let (x, y) = (a.value.count, b.value.count)
                return x == y ? a.key > b.key : x < y
            }?
            .key
    }

    /// The deepest directory every one of `paths` sits in, or nil when they
    /// share nothing but `/`.
    static func commonAncestor(of paths: [String]) -> String? {
        let components = paths.compactMap { normalize($0) }.map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        guard var shared = components.first else { return nil }
        for other in components.dropFirst() {
            var i = 0
            while i < shared.count, i < other.count, shared[i] == other[i] { i += 1 }
            shared = Array(shared.prefix(i))
        }
        guard !shared.isEmpty else { return nil }
        return "/" + shared.joined(separator: "/")
    }

    /// The root to adopt for a folder that has never had one set, derived from
    /// where its sessions already are. Nil means "leave it a label".
    ///
    /// This runs once, on the first launch after folders gained directories, so
    /// nobody has to sit and point at ten folders by hand. Three rules keep it
    /// from guessing loudly:
    ///
    /// - **`/` and the home directory are not answers.** They're what unrelated
    ///   sessions have in common, not a project, and a folder rooted at `~` says
    ///   nothing while looking like it means something.
    /// - **Worktree checkouts don't vote, and can't carry the answer alone.** A
    ///   session in `~/.wortel/worktrees/<repo>/<branch>` is a branch of a
    ///   project, not the project, and including one drags the ancestor up to
    ///   the worktree root or past it. The primary sessions in the same folder
    ///   already name the repository; a folder that holds nothing else derives
    ///   nothing, because the ancestor of two branch checkouts is the directory
    ///   that *contains* them, which is not a checkout at all.
    /// - **A drifted `cd` is accepted.** Only the last reported directory
    ///   survives in an old `sessions.json`, so a folder whose one session was
    ///   left three levels deep adopts that. It is still strictly better than
    ///   what it replaces (the same drifted path, invisible and unchangeable),
    ///   and the sidebar now *shows* the root, so a wrong one is a thing you can
    ///   see and fix rather than a mystery about where sessions come from.
    static func derived(
        from cwds: [String], excludingUnder excluded: [String], home: String
    ) -> String? {
        let voting = cwds.filter { cwd in
            !excluded.contains { root($0, contains: cwd) }
        }
        guard let ancestor = commonAncestor(of: voting) else { return nil }
        guard ancestor != "/", ancestor != normalize(home) else { return nil }
        return ancestor
    }
}
