import Foundation

/// Which paths in the file tree carry a git status, and which *directories* have
/// something changed underneath them.
///
/// Split out as a plain value type with no UI and no filesystem access for two
/// reasons: the ancestor roll-up is the one piece of logic here that can be
/// quietly wrong (a substring match decorating `src/foobar` because `src/foo`
/// changed shows the reader a lie they have no way to check), and it's the only
/// part of the pane that can be tested without a window, a repo and a shell.
///
/// Built from a `GitStatus` snapshot, so it costs one pass over the changed
/// files — a list bounded by what the user has actually touched — rather than
/// anything proportional to the repo.
struct FileTreeDecorations: Equatable {
    /// Repo-relative path → the status code to draw it in. A file staged *and*
    /// modified appears twice in `git status`; the more significant code wins,
    /// so a row can't flip between two colours depending on parse order.
    private(set) var codes: [String: Character] = [:]
    /// Repo-relative directory → the most significant code anywhere beneath it,
    /// so a collapsed folder can show a dot for work you can't currently see.
    private(set) var directoryCodes: [String: Character] = [:]

    init() {}

    init(changes: [GitFileChange]) {
        for change in changes {
            // A rename reports the new path; the old one is gone from the tree
            // anyway, so nothing needs decorating for it.
            record(change.path, change.statusCode)
            for ancestor in Self.ancestors(of: change.path) {
                recordDirectory(ancestor, change.statusCode)
            }
        }
    }

    /// The status for a repo-relative path, file or directory. Directories
    /// answer with their roll-up.
    func code(forRelativePath path: String, isDirectory: Bool) -> Character? {
        isDirectory ? directoryCodes[path] : codes[path]
    }

    private mutating func record(_ path: String, _ code: Character) {
        if let existing = codes[path], gitStatusRank(existing) >= gitStatusRank(code) {
            return
        }
        codes[path] = code
    }

    private mutating func recordDirectory(_ path: String, _ code: Character) {
        if let existing = directoryCodes[path], gitStatusRank(existing) >= gitStatusRank(code) {
            return
        }
        directoryCodes[path] = code
    }

    /// A filesystem path expressed relative to a work-tree root — the language
    /// `git status` and `check-ignore` both speak — or nil when it isn't inside
    /// that root. The root itself answers with the empty string, which is a real
    /// path (the repo) and not a directory anyone can decorate.
    ///
    /// Here rather than in the tree model for the same reason `ancestors` is: it
    /// is the same containment question, with the same trap. `…/wortel-old`
    /// starts with `…/wortel` as a string and is a different project, and the
    /// tempting answer for a non-match — hand back the absolute path — is worse
    /// than nil, because git would then answer about whatever sits at that path
    /// *inside* the repo.
    static func relativePath(of path: String, in root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Every directory containing `path`, repo-relative, innermost first.
    ///
    /// Built by splitting on `/` and re-joining rather than by prefix matching,
    /// which is the whole point: `src/foo` and `src/foobar` share a string
    /// prefix but not a component boundary, and only the latter distinction is
    /// the one a reader means by "inside".
    static func ancestors(of path: String) -> [String] {
        var components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        components.removeLast()
        var result: [String] = []
        while !components.isEmpty {
            result.append(components.joined(separator: "/"))
            components.removeLast()
        }
        return result
    }
}
