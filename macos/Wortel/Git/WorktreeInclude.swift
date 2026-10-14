import Darwin
import Foundation

/// The ignored files a new worktree needs to run, copied in from the checkout
/// it was made from.
///
/// A fresh worktree has every tracked file and none of the ignored ones, and
/// the ignored ones are exactly what makes a project run here: `.env`, a local
/// config, a key file. Without them the first thing an agent does in a new
/// worktree is fail to start the app and go looking for why.
///
/// Which files is said by **`.worktreeinclude`** at the root of the source
/// checkout, in gitignore syntax: the convention Claude Code, Codex, Conductor,
/// Orca and cmux all read, so a repository that has one already works here.
/// Without one, `.env*` at any depth. Only files that are ignored *and*
/// untracked qualify (a tracked file arrives with the checkout), and nothing is
/// ever overwritten.
///
/// Cheap by construction: git lists the ignored entries with `--directory`,
/// which reports an ignored directory as one entry instead of walking it, so a
/// `node_modules` costs one line (30 entries in 25 ms on this repository,
/// against 22 thousand without the flag). A pattern only reaches inside an
/// ignored directory when it names a path in it (`vendor/config/*.yml`); an
/// unanchored one never does, so `.env*` doesn't copy `node_modules/x/.env`.
/// Copies are APFS clones where the volume allows, which are instant and take
/// no space until either side changes.
enum WorktreeInclude {
    static let fileName = ".worktreeinclude"
    static let defaultPatterns = [".env*"]

    /// Past this, the copy stops with a warning: a `.worktreeinclude` asking
    /// for more is almost certainly asking for a dependency folder.
    static let byteBudget: Int64 = 2 << 30
    static let entryBudget = 50_000

    /// What to copy: a file, or a directory whole.
    struct Item: Equatable {
        let path: String
        let isDirectory: Bool
    }

    struct Report: Equatable {
        var copied = 0
        var skippedExisting = 0
        var warnings: [String] = []
        /// Whether the patterns came from the repository's own file, for the
        /// page to say which.
        var usedDefault = false
    }

    // MARK: - Choosing

    /// The patterns for a checkout: its `.worktreeinclude`, or the default.
    static func patterns(fileText: String?) -> IgnorePatterns {
        guard let fileText else { return IgnorePatterns(lines: defaultPatterns) }
        return IgnorePatterns(text: fileText)
    }

    /// The items to copy, from `git ls-files --others --ignored --directory`
    /// output (directories end in `/`), and the directories that have to be
    /// looked inside because a pattern names something within them.
    static func plan(candidates: [String], patterns: IgnorePatterns) -> (items: [Item], descend: [String]) {
        var items: [Item] = []
        var descend: [String] = []
        // git can list both `.claude/` and `.claude/worktrees/`; the inner one
        // is already part of the outer.
        let entries = Set(candidates)
        for entry in candidates.sorted() {
            let isDirectory = entry.hasSuffix("/")
            let path = isDirectory ? String(entry.dropLast()) : entry
            guard !path.isEmpty, !isInsideGit(path),
                  !hasListedAncestor(path, in: entries) else { continue }
            if patterns.matches(path, isDirectory: isDirectory) {
                items.append(Item(path: path, isDirectory: isDirectory))
            } else if isDirectory, patterns.mayMatchInside(path) {
                descend.append(path)
            }
        }
        return (items, descend)
    }

    /// The files inside an ignored directory a pattern selects, as paths
    /// relative to the checkout. `contents` are the directory's entries
    /// relative to it, directories ending in `/`.
    static func plan(inside directory: String, contents: [String], patterns: IgnorePatterns) -> [Item] {
        contents.sorted().compactMap { entry in
            let isDirectory = entry.hasSuffix("/")
            let relative = isDirectory ? String(entry.dropLast()) : entry
            let path = directory + "/" + relative
            guard !isDirectory, !isInsideGit(path), patterns.matches(path, isDirectory: false) else { return nil }
            return Item(path: path, isDirectory: false)
        }
    }

    private static func isInsideGit(_ path: String) -> Bool {
        path.split(separator: "/").contains(".git")
    }

    private static func hasListedAncestor(_ path: String, in entries: Set<String>) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix += component + "/"
            if entries.contains(prefix) { return true }
        }
        return false
    }

    // MARK: - Copying

    /// Copy what `.worktreeinclude` (or the default) selects from `source` to
    /// `target`. Blocking: git and the file system, so call off the main actor.
    static func copy(from source: String, to target: String) async -> Report {
        let includeURL = URL(fileURLWithPath: source).appendingPathComponent(fileName)
        let fileText = try? String(contentsOf: includeURL, encoding: .utf8)
        let patterns = patterns(fileText: fileText)
        var report = Report(usedDefault: fileText == nil)
        let listing = await GitService.runData(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], in: source)
        let candidates = listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var (items, descend) = plan(candidates: candidates, patterns: patterns)
        for directory in descend {
            items += plan(inside: directory, contents: listContents(of: source + "/" + directory),
                          patterns: patterns)
        }
        copy(items, from: source, to: target, into: &report)
        return report
    }

    static func copy(_ items: [Item], from source: String, to target: String, into report: inout Report) {
        var bytes: Int64 = 0
        var entries = 0
        var failed: [String] = []
        for item in items {
            let from = source + "/" + item.path
            let to = target + "/" + item.path
            let size = measure(from)
            if size.hasRepository {
                report.warnings.append("Skipped \(item.path): it's a git repository of its own.")
                continue
            }
            if bytes + size.bytes > byteBudget || entries + size.entries > entryBudget {
                report.warnings.append("""
                    Stopped copying at \(item.path): that's more than a worktree should carry \
                    (over 2 GB or 50,000 files).
                    """)
                break
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: to, isDirectory: &isDirectory) || isSymlink(to) {
                report.skippedExisting += 1
                continue
            }
            try? FileManager.default.createDirectory(
                atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // CLONE falls back to a real copy where cloning can't happen
            // (another volume), implies EXCL (so it never overwrites), and
            // copies a symlink as a link rather than what it points at.
            var flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_NOFOLLOW)
            if item.isDirectory { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
            if copyfile(from, to, nil, flags) == 0 {
                report.copied += size.entries
                bytes += size.bytes
                entries += size.entries
            } else {
                failed.append(item.path)
            }
        }
        if !failed.isEmpty {
            let shown = failed.prefix(3).joined(separator: ", ")
            let more = failed.count > 3 ? " and \(failed.count - 3) more" : ""
            report.warnings.append("Couldn't copy \(shown)\(more).")
        }
    }

    /// Files and bytes under `path` (1 and its size for a file), and whether a
    /// `.git` sits anywhere inside: a nested repository is not ours to clone.
    /// Stops counting once past the budget, which is all the caller needs to
    /// know.
    private static func measure(_ path: String) -> (entries: Int, bytes: Int64, hasRepository: Bool) {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0, false) }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            return (1, Int64(values.fileSize ?? 0), false)
        }
        var entries = 0
        var bytes: Int64 = 0
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [])
        else { return (0, 0, false) }
        for case let child as URL in walker {
            if child.lastPathComponent == ".git" { return (entries, bytes, true) }
            let childValues = try? child.resourceValues(forKeys: keys)
            entries += 1
            bytes += Int64(childValues?.fileSize ?? 0)
            if entries > entryBudget || bytes > byteBudget { break }
        }
        return (entries, bytes, false)
    }

    /// Everything under `directory`, relative to it, directories ending in
    /// `/`. By path rather than by URL: the URL enumerator hands back resolved
    /// paths (`/private/var/…` for `/var/…`), and cutting a prefix off those
    /// gives garbage.
    private static func listContents(of directory: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
        var contents: [String] = []
        while let relative = walker.nextObject() as? String {
            let isDirectory = walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            if (relative as NSString).lastPathComponent == ".git" {
                if isDirectory { walker.skipDescendants() }
                continue
            }
            contents.append(isDirectory ? relative + "/" : relative)
            if contents.count > entryBudget { break }
        }
        return contents
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}

/// gitignore's pattern language, for `.worktreeinclude`: the same rules, so a
/// file written for git or for another tool reads the same here.
///
/// Comments (`#`), blank lines, `!` negation (last match wins), a trailing `/`
/// for directories only, a leading or inner `/` anchoring to the root, `*`
/// and `?` within one path component, `[...]` classes, and `**` across
/// components. A path is selected when the last pattern that matches it, or
/// one of its parent directories, is a positive one.
struct IgnorePatterns {
    struct Rule {
        let regex: NSRegularExpression
        let negated: Bool
        let directoryOnly: Bool
        /// For an anchored pattern, its leading components that contain no
        /// wildcard: `vendor/config/*.yml` → `["vendor", "config"]`. What says
        /// a pattern may select something inside an ignored directory.
        let literalPrefix: [String]
        let anchored: Bool
    }

    let rules: [Rule]

    init(text: String) {
        self.init(lines: text.components(separatedBy: .newlines))
    }

    init(lines: [String]) {
        rules = lines.compactMap(Self.rule(from:))
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Whether `path` (relative to the root, no leading or trailing slash) is
    /// selected, by itself or through a parent directory.
    func matches(_ path: String, isDirectory: Bool) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        var prefix = ""
        for (index, component) in components.enumerated() {
            prefix += prefix.isEmpty ? component : "/" + component
            let last = index == components.count - 1
            if let verdict = verdict(prefix, isDirectory: last ? isDirectory : true), verdict {
                return true
            }
        }
        return false
    }

    /// Whether some pattern names a path inside `directory`, so it's worth
    /// listing what's in it.
    func mayMatchInside(_ directory: String) -> Bool {
        let components = directory.split(separator: "/").map(String.init)
        return rules.contains { rule in
            // The prefix is the pattern's directories (its last component
            // dropped), so `config/local.json` names something inside `config`.
            guard !rule.negated, rule.anchored, rule.literalPrefix.count >= components.count else { return false }
            return Array(rule.literalPrefix.prefix(components.count)) == components
        }
    }

    private func verdict(_ path: String, isDirectory: Bool) -> Bool? {
        let range = NSRange(path.startIndex..., in: path)
        for rule in rules.reversed() {
            if rule.directoryOnly && !isDirectory { continue }
            if rule.regex.firstMatch(in: path, range: range) != nil { return !rule.negated }
        }
        return nil
    }

    private static func rule(from raw: String) -> Rule? {
        var line = raw
        // Trailing spaces are dropped unless escaped.
        while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line.removeFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }
        // A slash at the start or in the middle anchors the pattern to the
        // root; without one it matches at any depth.
        let anchored = line.contains("/")
        if line.hasPrefix("/") { line.removeFirst() }
        let components = line.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let literalPrefix = anchored
            ? Array(components.dropLast().prefix { !$0.contains(where: { "*?[\\".contains($0) }) })
            : []
        let body = translate(line)
        let pattern = anchored ? "^" + body + "$" : "^(?:.*/)?" + body + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(regex: regex, negated: negated, directoryOnly: directoryOnly,
                    literalPrefix: literalPrefix, anchored: anchored)
    }

    /// gitignore glob → regular expression body.
    private static func translate(_ glob: String) -> String {
        let chars = Array(glob)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                let doubled = i + 1 < chars.count && chars[i + 1] == "*"
                let atStart = i == 0 || chars[i - 1] == "/"
                if doubled, atStart, i + 2 == chars.count {
                    out += ".*" // trailing `**`: everything inside
                    i += 2
                } else if doubled, atStart, i + 2 < chars.count, chars[i + 2] == "/" {
                    out += "(?:.*/)?" // `**/`: zero or more directories
                    i += 3
                } else {
                    out += "[^/]*"
                    i += doubled ? 2 : 1
                }
                continue
            case "?":
                out += "[^/]"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]"), close > i + 1 {
                    var set = String(chars[(i + 1)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close + 1
                    continue
                }
                out += "\\["
            case "\\":
                if i + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                    i += 2
                    continue
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out
    }
}
