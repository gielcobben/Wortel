import Foundation

/// Raster image extensions rendered visually instead of as a binary/patch diff —
/// shared by the working-tree changes list and the History pane's per-commit
/// files. (SVG is text — it flows through the normal diff — so it's excluded.)
private let imageFileExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico",
]

private func isImageFilePath(_ path: String) -> Bool {
    imageFileExtensions.contains((path as NSString).pathExtension.lowercased())
}

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

    var isImage: Bool { isImageFilePath(path) }

    /// True when this row represents a removal (worktree or index).
    var isDeletion: Bool { statusCode == "D" }
}

/// How significant a porcelain status code is, when two of them describe the
/// same thing and only one can be drawn: a file that is both staged and modified
/// in the changes list, or a collapsed directory whose dot has to stand for
/// everything beneath it. A conflict outranks a deletion outranks a
/// modification outranks a plain addition or an untracked file.
///
/// Lives here rather than beside the colours because it's a fact about git, not
/// about drawing — and because `FileTreeDecorations`, which needs it, is
/// deliberately free of any UI framework so it can be tested without one.
func gitStatusRank(_ code: Character) -> Int {
    switch code {
    case "U": return 5
    case "D": return 4
    case "M", "T": return 3
    case "R", "C": return 2
    case "A": return 1
    case "?": return 0
    default: return -1
    }
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

/// A ref pointing at a commit, shown as a chip on its History row.
///
/// Parsed from `git log --decorate=full`'s `%D`, which is why every case here
/// keys off a full `refs/…` prefix rather than the short name. Short names are
/// ambiguous in exactly the case that matters: `origin/main` is a remote branch
/// but `feature/login` is a local one, and nothing in the string says which.
/// `--decorate=full` spends nothing to answer it — `refs/remotes/origin/main` vs
/// `refs/heads/feature/login`.
struct GitRef: Hashable {
    enum Kind: Hashable {
        case localBranch
        case remoteBranch
        case tag
        /// A detached HEAD pointing straight at this commit.
        case detachedHead
    }

    /// Display name, prefix stripped: "main", "origin/main", "v1.2".
    let name: String
    let kind: Kind
    /// True when HEAD resolves here — the `HEAD -> main` form, or a bare `HEAD`.
    /// Drives the chip that says "you are here".
    let isHead: Bool

    /// Parse one `%D` decoration list. Tokens are comma-separated, and the one
    /// HEAD points at arrives as "HEAD -> refs/heads/main".
    ///
    /// `refs/remotes/*/HEAD` is dropped: it's a symref to the remote's default
    /// branch, so it rides along on every `origin/main` and reads as a duplicate
    /// chip that means nothing to a person.
    static func parse(decoration: String) -> [GitRef] {
        decoration
            .split(separator: ",")
            .compactMap { token in
                var text = token.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }

                var isHead = false
                if let arrow = text.range(of: "->") {
                    // "HEAD -> refs/heads/main"
                    isHead = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces) == "HEAD"
                    text = String(text[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else if text == "HEAD" {
                    return GitRef(name: "HEAD", kind: .detachedHead, isHead: true)
                }

                // A tag keeps its "tag: " marker even under --decorate=full, so
                // it arrives as "tag: refs/tags/v1.0" — the marker comes off
                // before the prefix underneath it can match.
                if let tag = text.stripping("tag: ") {
                    let name = tag.stripping("refs/tags/") ?? tag
                    return GitRef(name: name, kind: .tag, isHead: isHead)
                }
                if let name = text.stripping("refs/heads/") {
                    return GitRef(name: name, kind: .localBranch, isHead: isHead)
                }
                if let name = text.stripping("refs/remotes/") {
                    guard !name.hasSuffix("/HEAD") else { return nil }
                    return GitRef(name: name, kind: .remoteBranch, isHead: isHead)
                }
                return nil
            }
    }
}

/// A branch the switcher can check out. Local and remote branches are the same
/// shape; `isRemote` decides whether checking it out creates a tracking branch.
struct GitBranch: Identifiable, Hashable {
    /// Short name: "main", "origin/main".
    let name: String
    let isRemote: Bool
    /// The commit it points at, so the switcher can reveal it in the log.
    let sha: String
    /// Its upstream's short name, if it tracks one. Local branches only.
    let upstream: String?
    /// True for the checked-out branch.
    let isCurrent: Bool

    var id: String { (isRemote ? "r:" : "l:") + name }
}

private extension String {
    /// The remainder after `prefix`, or nil when it doesn't match.
    func stripping(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
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
    /// Branches and tags pointing here, for the row's chips. Empty for the vast
    /// majority of commits.
    let refs: [GitRef]
    /// Everything after the subject line, trimmed. Read by the row's tooltip and
    /// nothing else — a log row shows one line, and this is how you read the rest
    /// without leaving the pane. Defaulted so the graph and ordering tests, which
    /// build commits by hand, don't have to care about it. A `var` purely so the
    /// memberwise initialiser still accepts it — a `let` with a default is
    /// dropped from that initialiser entirely.
    var body: String = ""

    var id: String { sha }
    /// Subject and body as one block, for hovering a row whose subject the pane
    /// had to truncate. Just the message: the author, SHA and age are already
    /// their own columns on the row.
    var fullMessage: String {
        body.isEmpty ? subject : "\(subject)\n\n\(body)"
    }
    var shortSHA: String { String(sha.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
    /// True when HEAD is at this commit — the row "Jump to HEAD" reveals.
    var isHead: Bool { refs.contains(where: \.isHead) }

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

/// One file changed by a single commit — a row in the History pane's per-commit
/// accordion. Unlike `GitFileChange` (a working-tree row, staged or unstaged)
/// this is a point-in-time record: a status letter plus the additions and
/// deletions the commit made to that one file. A binary file reports no counts
/// (both come back as -1, git's "-").
struct CommitFileChange: Identifiable, Hashable {
    /// Repo-relative path (the new path for a rename/copy).
    let path: String
    /// Repo-relative old path for a rename/copy, else nil — carried so the
    /// per-file diff can be fetched with both pathspecs (a rename resolves under
    /// neither name alone).
    let originalPath: String?
    /// Single-letter status shown in the badge: M/A/D/R/C/T.
    let statusCode: Character
    /// Lines added / removed. Both -1 for a binary file, which has no line count.
    let additions: Int
    let deletions: Int

    var id: String { path }
    var isBinary: Bool { additions < 0 || deletions < 0 }
    /// A raster image — expanding it shows the picture(s), not "binary not shown".
    var isImage: Bool { isImageFilePath(path) }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Which pane the trailing inspector shows. Held per session by GitPanelModel
/// (see `setPane`), and driven by the toolbar's segmented control — whose
/// segments, tooltips and overflow entries are all built from `allCases`, so a
/// case added here appears in the toolbar without touching it.
///
/// `files` is not source control, but it lives here because the *column* is one
/// thing with three panes and one selection; splitting the enum would just mean
/// mapping two of them onto the same control.
enum InspectorPane: String, CaseIterable, Identifiable {
    case changes
    case history
    case files

    var id: String { rawValue }

    /// Whether this pane is a view of the repository, i.e. one of the two the
    /// "Show Source Control" command can land on. Files is reachable on its own
    /// command instead, and is what makes this distinction necessary.
    var isSourceControl: Bool { self != .files }

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .history: return "History"
        case .files: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .changes: return "doc.on.doc"
        case .history: return "clock"
        case .files: return "folder"
        }
    }
}

/// One tab in the side column: one of the inspector's panes, or a terminal of
/// the session's own that runs beside its main one.
///
/// The column used to *be* the three panes, with one of them showing. It is now
/// a strip of tabs a session opens and closes, which is what lets a terminal (and
/// later a preview or a page) sit beside the session the way the panes do, and
/// what makes "open something next to this" a cheap, reversible act instead of a
/// window. The panes keep their own identity (`InspectorPane`), so everything
/// that already reads `pane` still works; a terminal tab carries the id its shell
/// is kept alive under by the keeper, which is how it survives a relaunch.
///
/// Stored as a string (`"changes"`, `"terminal:<uuid>"`) so `PersistedSession`
/// stays a plain reading of the file, the same bargain `inspectorPane` makes.
enum SideTab: Hashable, Sendable {
    case pane(InspectorPane)
    case terminal(UUID)
    /// The session's own terminal, as a tab of the main area's row. It can be
    /// reordered there but never closed, and never leaves that row: it is what
    /// the main area goes back to.
    case session

    private static let terminalPrefix = "terminal:"

    init?(rawValue: String) {
        if let pane = InspectorPane(rawValue: rawValue) {
            self = .pane(pane)
        } else if rawValue.hasPrefix(Self.terminalPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.terminalPrefix.count))) {
            self = .terminal(id)
        } else if rawValue == "session" {
            self = .session
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .pane(let pane): return pane.rawValue
        case .terminal(let id): return Self.terminalPrefix + id.uuidString
        case .session: return "session"
        }
    }

    var pane: InspectorPane? {
        if case .pane(let pane) = self { return pane }
        return nil
    }

    var terminalID: UUID? {
        if case .terminal(let id) = self { return id }
        return nil
    }
}

/// Where a tab can live: the main area (beside the session's own terminal,
/// which is always its first tab), the side column, or the strip under the
/// session's terminal. Panes go in either of the first two; the strip takes
/// terminals only (a diff or a tree in a short, full-width strip is useless).
enum TabRegion: String, Sendable {
    case main, side, bottom
}

extension SideTab {
    /// Whether this tab may be put in `region`.
    func fits(_ region: TabRegion) -> Bool {
        if self == .session { return region == .main }
        return region != .bottom || terminalID != nil
    }
}

/// A tab that was closed, and where it was, so ⌘⇧T can put it back. A pane
/// comes back as itself; a terminal's shell ended with it, so it comes back as
/// a new one in the same place.
struct ClosedTab: Equatable, Sendable {
    let tab: SideTab
    let region: TabRegion
    let index: Int

    /// `side:2:changes`, the form it's saved in: a relaunch shouldn't empty
    /// the list of what ⌘⇧T can bring back.
    var rawValue: String { "\(region.rawValue):\(index):\(tab.rawValue)" }

    init(tab: SideTab, region: TabRegion, index: Int) {
        self.tab = tab
        self.region = region
        self.index = index
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let region = TabRegion(rawValue: parts[0]),
              let index = Int(parts[1]), let tab = SideTab(rawValue: parts[2]) else { return nil }
        self.init(tab: tab, region: region, index: index)
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
    /// The file this line belongs to (post-image path, e.g. `web/src/app.ts`),
    /// carried so syntax highlighting can pick a grammar. A commit diff in the
    /// History pane concatenates many files into one result, so this varies
    /// down the list; nil when the header carried no usable path. Every line of
    /// one file shares the same String instance — cheap to carry per line.
    let path: String?
}

/// Parsed diff for one file. `isBinary` short-circuits the line view.
struct DiffResult: Sendable {
    var lines: [DiffLine]
    var isBinary: Bool
    /// The patch was too big to show in full and was cut short — see
    /// DiffParser's limits. The pane says so rather than implying the file
    /// simply ends there.
    var truncated: Bool = false
    /// Syntax-highlight spans keyed by `DiffLine.id`, filled in asynchronously
    /// by `DiffHighlighter` after the diff is first shown (so the diff — and the
    /// terminal beside it — never wait on tree-sitter). Empty until then, and
    /// for lines in unsupported languages; the cell falls back to plain text.
    var highlights: [Int: [HighlightSpan]] = [:]

    var isEmpty: Bool { lines.isEmpty && !isBinary }
}
