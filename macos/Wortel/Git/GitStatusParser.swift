import Foundation

/// Parses `git status --porcelain=v2 --branch` into a `GitStatus`.
///
/// Porcelain v2 line kinds we handle:
///   `# branch.head <name>`         current branch (or "(detached)")
///   `# branch.upstream <name>`     tracking branch
///   `# branch.ab +<a> -<b>`        ahead/behind counts
///   `1 <XY> ... <path>`            ordinary changed entry
///   `2 <XY> ... <score> <path>\t<orig>`  renamed/copied entry
///   `u <XY> ... <path>`            unmerged (conflict)
///   `? <path>`                     untracked
///
/// The XY field is two status letters: X = index vs HEAD (staged), Y = worktree
/// vs index (unstaged). A file with both non-`.` yields two rows.
enum GitStatusParser {
    static func parse(_ raw: String) -> GitStatus {
        var status = GitStatus()

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            guard let marker = line.first else { continue }

            switch marker {
            case "#":
                parseHeader(line, into: &status)
            case "1":
                parseOrdinary(line, into: &status)
            case "2":
                parseRenamed(line, into: &status)
            case "u":
                parseUnmerged(line, into: &status)
            case "?":
                // "? <path>"
                let path = String(line.dropFirst(2))
                if !path.isEmpty {
                    status.changes.append(GitFileChange(
                        path: path, originalPath: nil, statusCode: "?",
                        staged: false, untracked: true))
                }
            default:
                break
            }
        }
        return status
    }

    private static func parseHeader(_ line: String, into status: inout GitStatus) {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 2 else { return }
        switch fields[1] {
        case "branch.oid":
            // "# branch.oid <sha>" — or "(initial)" on a repo with no commits.
            if fields.count >= 3, fields[2] != "(initial)" { status.head = fields[2] }
        case "branch.head":
            let name = fields.count >= 3 ? fields[2] : ""
            status.branch = (name == "(detached)" || name.isEmpty) ? nil : name
        case "branch.upstream":
            if fields.count >= 3 { status.upstream = fields[2] }
        case "branch.ab":
            // "# branch.ab +2 -1"
            for token in fields.dropFirst(2) {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                else if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — 8 space-separated fields
    /// before the path, which is the remainder (may contain spaces).
    private static func parseOrdinary(_ line: String, into status: inout GitStatus) {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9 else { return }
        let xy = String(parts[1])
        let path = String(parts[8])
        appendChanges(xy: xy, path: path, originalPath: nil, into: &status)
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>\t<orig>` — 9 fields
    /// before the path; path and original are tab-separated.
    private static func parseRenamed(_ line: String, into status: inout GitStatus) {
        let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count == 10 else { return }
        let xy = String(parts[1])
        let pathField = String(parts[9])
        let split = pathField.split(separator: "\t", maxSplits: 1).map(String.init)
        let path = split.first ?? pathField
        let original = split.count > 1 ? split[1] : nil
        appendChanges(xy: xy, path: path, originalPath: original, into: &status)
    }

    /// `u <XY> ... <path>` — treat as a single conflicted, unstaged row.
    private static func parseUnmerged(_ line: String, into status: inout GitStatus) {
        // Fields: u XY sub m1 m2 m3 mW h1 h2 h3 path  (10 before path)
        let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count == 11 else { return }
        let path = String(parts[10])
        status.changes.append(GitFileChange(
            path: path, originalPath: nil, statusCode: "U",
            staged: false, untracked: false))
    }

    /// Emit a staged row (X) and/or an unstaged row (Y) for one XY code.
    private static func appendChanges(
        xy: String, path: String, originalPath: String?, into status: inout GitStatus
    ) {
        let chars = Array(xy)
        guard chars.count == 2 else { return }
        let index = chars[0]      // staged (X)
        let worktree = chars[1]   // unstaged (Y)

        if index != "." {
            status.changes.append(GitFileChange(
                path: path, originalPath: originalPath, statusCode: index,
                staged: true, untracked: false))
        }
        if worktree != "." {
            status.changes.append(GitFileChange(
                path: path, originalPath: originalPath, statusCode: worktree,
                staged: false, untracked: false))
        }
    }
}
