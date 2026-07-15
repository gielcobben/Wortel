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
    /// HEAD's commit SHA, from the `# branch.oid` header. Nil on a repo with no
    /// commits. Free with every status, and how the History pane notices a
    /// commit made in the terminal rather than through the panel.
    var head: String?
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

/// One commit in the History pane. Parsed from `git log`'s machine format, not
/// its human output — see GitService.log.
struct GitCommit: Identifiable, Hashable {
    let sha: String
    let author: String
    let date: Date
    let subject: String
    /// Parent SHAs, first-parent first. Empty for a root commit; two or more for
    /// a merge. Drives CommitGraph's lane layout.
    let parents: [String]

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }

    /// Relative age for the row's trailing label ("2h", "3d"). Deliberately terse:
    /// the row is narrow and the exact timestamp is rarely what you're scanning for.
    func age(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        case ..<2_629_800: return "\(Int(seconds / 604_800))w"
        case ..<31_557_600: return "\(Int(seconds / 2_629_800))mo"
        default: return "\(Int(seconds / 31_557_600))y"
        }
    }
}

/// Which pane the source-control inspector shows. Persisted app-wide by
/// GitPanelModel, and driven by the toolbar's segmented control.
enum GitInspectorPane: String, CaseIterable, Identifiable {
    case changes
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .history: return "History"
        }
    }

    var symbol: String {
        switch self {
        case .changes: return "doc.on.doc"
        case .history: return "clock"
        }
    }
}

/// How a diff line renders: drives its gutter numbers, sign, and tint.
enum DiffLineKind: Sendable {
    case context
    case addition
    case deletion
    case hunkHeader
}

/// One rendered line of a unified diff, prefix stripped. Line numbers are nil
/// where they don't apply (additions have no old number, etc.).
struct DiffLine: Identifiable, Sendable {
    let id: Int
    let kind: DiffLineKind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

/// Parsed diff for one file. `isBinary` short-circuits the line view.
struct DiffResult: Sendable {
    var lines: [DiffLine]
    var isBinary: Bool
    /// The patch was too big to show in full and was cut short — see
    /// DiffParser's limits. The pane says so rather than implying the file
    /// simply ends there.
    var truncated: Bool = false

    var isEmpty: Bool { lines.isEmpty && !isBinary }
}
