import Foundation

/// Where a ⌘-clicked link in a terminal goes, when it is a path.
///
/// libghostty finds the link (its URL regex, or an OSC 8 hyperlink) and hands
/// the text to `GhosttyRuntime`'s OPEN_URL handler, which takes every one. A
/// path is resolved here, because only the app knows what it is relative to;
/// any other link is decided by `external(_:)`.
///
/// The case that made this a type: an agent writes `docs/decisions.md`, relative
/// to the folder it was started in. libghostty's own open runs `open` from the
/// app's working directory, `/`, so a relative path opened nothing at all. Here
/// it is tried against the folders the clicking terminal knows: where its shell
/// last said it was, where the session was born, and the repository each of
/// those is in (an agent names files from the repo root even when the shell is
/// two levels down).
///
/// The text libghostty matched is not quite a path either. Its regex takes a
/// sentence's full stop (`docs/decisions.md.`), and a compiler's location
/// (`App.swift:42:7`) or GitHub's (`README.md#L12`) rides along. Each spelling
/// is tried until one exists. Nothing here launches anything: it only says what
/// the link is, and the caller decides.
///
/// Pure Foundation and main-thread free, so it is tested without the app.
enum TerminalLink {
    struct Target: Equatable {
        enum Kind: Equatable {
            /// A Markdown file, for the in-app preview.
            case markdown
            /// Any other file.
            case file
            /// A directory.
            case folder
            /// A folder Finder treats as one thing (an app, a bundle). Opening
            /// one runs it, so it is only ever shown.
            case package
        }

        let url: URL
        let kind: Kind
        /// The line a `:42` or `#L42` suffix named, if there was one.
        var line: Int?
    }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

    /// Whether this link is a path (or a `file:` URL) for the app to resolve,
    /// rather than a web link, `mailto:` or another scheme for libghostty.
    ///
    /// Decided without touching the disk, because it runs on libghostty's
    /// thread and its answer is the handler's return value. `README.md:12`
    /// looks like a scheme to `URL(string:)`; a scheme here has no dot and is
    /// not followed by a digit, which no path with a line suffix satisfies.
    static func isPath(_ link: String) -> Bool {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return false }
        guard let colon = link.firstIndex(of: ":") else { return true }
        let scheme = link[..<colon]
        let isScheme = scheme.count > 1
            && scheme.first!.isLetter
            && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
        guard isScheme else { return true }
        let name = scheme.lowercased()
        if name == "file" { return true }
        // The schemes libghostty's regex takes without `//`: a digit after
        // `tel:` is a phone number, not a line.
        if bareSchemes.contains(name) { return false }
        let after = link[link.index(after: colon)...]
        return after.first?.isNumber ?? false
    }

    private static let bareSchemes: Set<String> = ["mailto", "tel", "magnet", "news", "ssh"]

    /// The address of a server on this Mac (`http://localhost:3000`,
    /// `127.0.0.1`, `[::1]`, `0.0.0.0`, `app.localhost`), or nil. A dev
    /// server's address belongs beside the terminal that started it, like a
    /// server picked from the running-jobs popover, and goes where those go.
    /// Any other web address is `external(_:)`'s (the system browser).
    static func localServer(_ link: String) -> URL? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // 127/8 only as an address: `127.example.com` is somewhere else.
        var address = in_addr()
        let isLoopbackV4 = host.hasPrefix("127.") && inet_pton(AF_INET, host, &address) == 1
        let isLoopback = host == "localhost" || host.hasSuffix(".localhost")
            || isLoopbackV4 || host == "::1" || host == "0.0.0.0"
        return isLoopback ? url : nil
    }

    /// What a link that is neither a path nor a server on this Mac does.
    enum External: Equatable {
        /// A web page or a mail address: straight to its app.
        case open(URL)
        /// Another scheme (`vscode:`, `tel:`, `ssh:`): its app is asked for
        /// by name first, because a program's output chose it.
        case ask(URL)
        /// Malformed, or hiding something: nothing happens.
        case refuse
    }

    /// The decision for a link that is not ours to resolve.
    ///
    /// These were libghostty's to open until its Oct 2026 change ("treat
    /// links from unknown sources as untrusted", `f9e8ef02d`): on macOS its
    /// fallback opener now refuses a matched URL and an OSC 8 hyperlink
    /// outright, and leaves the checks to the app. Wortel took the update
    /// with the keeper terminal (2026.47.4) and every web link went dead,
    /// first seen in Pi, which writes its links as OSC 8. The rules follow
    /// Ghostty.app's `UntrustedURL`: invisible and line-breaking characters
    /// refuse, a web link needs a host, a mail link an address.
    static func external(_ link: String) -> External {
        let link = link.trimmingCharacters(in: .whitespaces)
        guard !link.unicodeScalars.contains(where: isUnsafe),
              let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .refuse }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return .refuse }
            return .open(url)
        case "mailto":
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !parts.path.isEmpty else { return .refuse }
            return .open(url)
        case "file":
            // Paths are resolved by the app and open in the preview; one that
            // got here was not found, and goes nowhere else.
            return .refuse
        default:
            return .ask(url)
        }
    }

    /// Controls, bidirectional overrides, zero-width and line-separating
    /// characters: what can make the link shown differ from the link opened.
    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x202A...0x202E,
             0x2028...0x2029, 0x2060, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// The first spelling of `link` that exists, tried against `bases` in
    /// order when it is relative. nil when nothing matches.
    static func resolve(_ link: String, bases: [String]) -> Target? {
        resolveFirst([link], bases: bases)
    }

    /// `resolve` for each of `links` in order, the first that exists. The
    /// repository's folders are listed once for all of them, not once each:
    /// a click on a link broken over rows tries every join (`wrappedPaths`).
    static func resolveFirst(_ links: [String], bases: [String]) -> Target? {
        var folders: [String]?
        for link in links {
            let spellings = spellings(of: link)
            for (path, line) in spellings {
                for candidate in candidates(for: path, bases: bases) {
                    if let target = target(at: candidate, line: line) { return target }
                }
            }
            // An agent that went into `macos/` names `scripts/x.sh` from there,
            // and the shell never said so: the agent's own `cd` happens in a
            // shell of its own. So one folder down from each base, when exactly
            // one has it. Two (`macos/scripts/x.sh`, `web/scripts/x.sh`) is a
            // guess, and a click that opens the wrong file is worse than one
            // that opens none. Only below a repository's root: listing `~` or
            // `/` reaches into Documents (a privacy prompt) and network mounts
            // (a hang).
            let below = folders ?? {
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
                let roots = bases.filter { $0 != "/" && $0 != home && repositoryRoot(of: $0) == $0 }
                return roots.flatMap(subfolders(of:))
            }()
            folders = below
            for (path, line) in spellings where !path.hasPrefix("/") && !path.hasPrefix("~") {
                var found: [URL: Target] = [:]
                for folder in below {
                    let candidate = (folder as NSString).appendingPathComponent(path)
                    if let target = target(at: candidate, line: line) { found[target.url] = target }
                }
                if found.count == 1 { return found.values.first }
                if found.count > 1 { break }
            }
        }
        return nil
    }

    /// The folders directly in `base`, without hidden ones (`.git`). A file
    /// in the list makes a candidate that doesn't exist, which costs a stat.
    /// Listed once per click, whatever the number of spellings.
    private static func subfolders(of base: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { (base as NSString).appendingPathComponent($0) }
    }

    /// The folders a relative link is tried against: the given ones in order,
    /// then the repository root of each, without repeats.
    static func bases(_ folders: [String?]) -> [String] {
        let given = folders.compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        var result: [String] = []
        for folder in given + given.compactMap(repositoryRoot(of:)) {
            let standard = URL(fileURLWithPath: folder).standardizedFileURL.path
            if seen.insert(standard).inserted { result.append(standard) }
        }
        return result
    }

    /// The nearest folder at or above `folder` that holds a `.git` (a folder in
    /// a checkout, a file in a linked worktree). A walk of `stat`s, no git,
    /// through `PathWalk`: this is the walk that hung 2026.47.4 on macOS 15.5.
    static func repositoryRoot(of folder: String) -> String? {
        PathWalk.upward(from: URL(fileURLWithPath: folder).standardizedFileURL.path).first {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git"))
        }
    }

    // MARK: - Spellings

    /// Trailing characters a sentence or Markdown puts after a path. Since
    /// vt-1.0.2 libghostty's own match leaves `.`, `:`, `;`, `!` and `?` off a
    /// path's end, but not `*`, `)` or quotes, and a path joined from wrapped
    /// rows or tagged with OSC 8 never went through its pattern at all.
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "*", ")", "]", "'", "\"", "`", ">"]

    /// The paths `link` might mean, most literal first, each with the line its
    /// suffix named: as written, then with sentence punctuation taken off the
    /// end, then without a diff's `a/` or `b/`.
    static func spellings(of link: String) -> [(path: String, line: Int?)] {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("file:") {
            // `file:///a%20b.md`, `file://host/a.md`: the URL's own reading.
            guard let url = URL(string: text), url.isFileURL || url.scheme?.lowercased() == "file"
            else { return [] }
            text = url.path
            // A fragment (`#L12`) is not part of `path`; keep the line it names.
            if let fragment = url.fragment { text += "#" + fragment }
        }
        guard !text.isEmpty else { return [] }

        var result: [(String, Int?)] = []
        var current = Substring(text)
        // Two rounds of punctuation is enough for `foo.md).` or `foo.md:12.`.
        for _ in 0..<3 {
            result.append(withoutLocation(String(current)))
            guard let last = current.last, trailing.contains(last) else { break }
            current = current.dropLast()
            guard !current.isEmpty else { break }
        }
        // `git diff` prints `a/path` and `b/path`; a file called that is rare,
        // so the prefix is tried off only after every literal spelling.
        for (path, line) in result where path.hasPrefix("a/") || path.hasPrefix("b/") {
            result.append((String(path.dropFirst(2)), line))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.0).inserted }
    }

    /// Split a trailing location off: `#L12` or `#L12-L20` (GitHub), or
    /// `:12` / `:12:7` (grep, compilers). A real filename never ends in
    /// `.swift:42`, so this only ever takes a location.
    static func withoutLocation(_ path: String) -> (path: String, line: Int?) {
        if let hash = path.range(of: "#L", options: .backwards) {
            let rest = path[hash.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            let tail = rest.dropFirst(digits.count)
            let rangeTail = tail.isEmpty || tail.range(of: #"^-L?\d+$"#, options: .regularExpression) != nil
            if !digits.isEmpty, rangeTail {
                return (String(path[..<hash.lowerBound]), Int(digits))
            }
        }
        var rest = Substring(path)
        var numbers: [Int] = []
        for _ in 0..<2 {
            guard let colon = rest.lastIndex(of: ":") else { break }
            let digits = rest[rest.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) else { break }
            numbers.insert(value, at: 0)
            rest = rest[..<colon]
        }
        guard !rest.isEmpty else { return (path, nil) }
        return (String(rest), numbers.first)
    }

    // MARK: - On disk

    private static func candidates(for path: String, bases: [String]) -> [String] {
        var path = path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if path.hasPrefix("/") { return [path] }
        return bases.map { ($0 as NSString).appendingPathComponent(path) }
    }

    private static func target(at path: String, line: Int?) -> Target? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if isDirectory.boolValue {
            // Judged by what a symlink points at: one called `docs` that leads
            // to an app is an app.
            let isPackage = (try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            return Target(url: url, kind: isPackage == true ? .package : .folder)
        }
        let kind: Target.Kind = markdownExtensions.contains(url.pathExtension.lowercased())
            ? .markdown : .file
        return Target(url: url, kind: kind, line: line)
    }
}
