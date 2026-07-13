import Foundation

/// One entry in the source-control changes list. A file can appear twice — once
/// staged (differs between HEAD and the index) and once unstaged (differs
/// between the index and the working tree) — so identity folds in `staged`.
struct GitFileChange: Identifiable, Hashable {
    /// Repo-relative path (the new path for renames).
    let path: String
    /// Repo-relative old path for a rename/copy, else nil.
    let originalPath: String?
    /// Single-letter code shown in the row: M/A/D/R/C/?/U/T.
    let statusCode: Character
    /// True → this row belongs in "Staged Changes"; false → "Changes".
    let staged: Bool
    /// Not tracked by git at all (shows its whole content as additions).
    let untracked: Bool

    /// Section-qualified so a staged + unstaged pair of the same file are two
    /// distinct, selectable rows.
    var id: String { (staged ? "S:" : "W:") + path }

    /// Last path component for the primary label.
    var fileName: String { (path as NSString).lastPathComponent }

    /// Parent directory (repo-relative), shown dimmed after the name. Empty at
    /// the repo root.
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir
    }

    /// Raster image extensions we render visually instead of as a binary diff.
    /// (SVG is text — it flows through the normal diff — and is intentionally
    /// excluded.)
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico",
    ]

    var isImage: Bool {
        Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// True when this row represents a removal (worktree or index).
    var isDeletion: Bool { statusCode == "D" }
}

/// A snapshot of `git status`, plus branch/ahead-behind from the `--branch`
/// header. Value type — the model swaps a whole new one in on each refresh.
struct GitStatus: Equatable {
    var branch: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var changes: [GitFileChange] = []
    /// True when `git status` ran but the path wasn't inside a work tree.
    var isDetachedOrNoBranch: Bool { branch == nil }

    var stagedChanges: [GitFileChange] { changes.filter(\.staged) }
    var unstagedChanges: [GitFileChange] { changes.filter { !$0.staged } }
    var isClean: Bool { changes.isEmpty }
}

/// How a diff line renders: drives its gutter numbers, sign, and tint.
enum DiffLineKind {
    case context
    case addition
    case deletion
    case hunkHeader
}

/// One rendered line of a unified diff, prefix stripped. Line numbers are nil
/// where they don't apply (additions have no old number, etc.).
struct DiffLine: Identifiable {
    let id: Int
    let kind: DiffLineKind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

/// Parsed diff for one file. `isBinary` short-circuits the line view.
struct DiffResult {
    var lines: [DiffLine]
    var isBinary: Bool

    var isEmpty: Bool { lines.isEmpty && !isBinary }
}
