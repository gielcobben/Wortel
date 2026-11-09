import Foundation

/// Where a link in a *rendered* Markdown document goes.
///
/// A README's links are mostly relative — `macos/`, `web/README.md`,
/// `#third-party-code` — and a relative link parses into a `URL` with no scheme
/// at all. Handing one to the system, which is what a SwiftUI `Text` does with a
/// link by default, is not a quiet no-op: LaunchServices answers `-50`
/// (paramErr) and macOS puts up "The application can't be opened", which reads
/// as the app being broken rather than as the link being relative to a file the
/// system was never told about.
///
/// So every link is classified here first, and only the two kinds that mean
/// something outside this app are handed on. Pure, and separate from the view
/// that draws the document, because the interesting cases are all string
/// handling: a path with a `#fragment` after it, a percent-encoded space, `..`
/// climbing out of the directory the file sits in.
enum MarkdownLinkTarget: Equatable {
    /// A web link, for the browser.
    case web(URL)
    /// A file next to the document, for a preview window of its own.
    case file(URL)
    /// A directory. The one target no preview window can show, so it is the one
    /// that goes to Finder.
    case folder(URL)
    /// A folder Finder treats as one thing (an app, a bundle, a workflow).
    /// Shown in Finder, never opened: opening one runs it.
    case package(URL)
    /// A `#heading` in this same document: the fragment, slugified.
    case heading(String)
    /// Nothing to do. A link to a file that isn't there, or a scheme this app
    /// has no business launching — either way the click is dropped rather than
    /// turned into an error dialog about something the reader didn't do.
    case none

    /// Schemes worth leaving the app for. Deliberately a short allowlist rather
    /// than "anything with a scheme": a Markdown file is often something an
    /// agent just wrote, and a custom scheme is a registered application, so
    /// `everything else` would make a single click on a rendered document a way
    /// to launch an arbitrary app.
    static let webSchemes: Set<String> = ["http", "https", "mailto"]

    /// Classify `link`, resolving anything relative against `document` — the
    /// file being rendered, whose *directory* is what a relative link is
    /// relative to.
    static func resolve(_ link: URL, in document: URL?) -> MarkdownLinkTarget {
        if let scheme = link.scheme?.lowercased() {
            // A `file://` link is a path like any other, and is checked like one
            // — an absolute link into a repo that isn't on this Mac is a link to
            // nothing, whichever spelling it arrives in.
            if scheme == "file" { return local(link.path, in: document) }
            return webSchemes.contains(scheme) ? .web(link) : .none
        }
        // `relativePath` is the decoded path with the fragment and query already
        // off it, which is all three of the awkward cases in one property:
        // `docs/a%20b.md`, `CLAUDE.md#build`, `page.md?plain=1`.
        let path = link.relativePath
        guard !path.isEmpty else {
            guard let fragment = link.fragment, !fragment.isEmpty else { return .none }
            return .heading(MarkdownAnchor.slug(fragment))
        }
        return local(path, in: document)
    }

    /// The local file an image's `source` names, or nil when it names anything
    /// else: a remote URL, or a file that isn't there. Both are drawn as a chip
    /// rather than fetched (see `MarkdownImageView`).
    static func imageFile(_ source: String, in document: URL?) -> URL? {
        guard let url = URL(string: source) else { return nil }
        guard case .file(let file) = resolve(url, in: document) else { return nil }
        return file
    }

    /// A path on this Mac: what it is, or nothing if it isn't there.
    private static func local(_ path: String, in document: URL?) -> MarkdownLinkTarget {
        var path = path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            // No document means no directory to be relative to, so a relative
            // link has no meaning — the same conclusion `MarkdownLink` reaches
            // about a relative path clicked in the terminal.
            guard let document else { return .none }
            url = URL(fileURLWithPath: path,
                      relativeTo: document.deletingLastPathComponent())
        }
        let resolved = url.absoluteURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path,
                                             isDirectory: &isDirectory) else { return .none }
        guard isDirectory.boolValue else { return .file(resolved) }
        // Judged by what the link points at, not its own name: a symlink
        // called `docs` to an app is an app, and opening it runs it. The
        // URL handed back stays the one the link names.
        return isPackage(resolved.resolvingSymlinksInPath()) ? .package(resolved) : .folder(resolved)
    }

    /// Extensions that make a directory a program or a plug-in. Checked by
    /// name as well as by the system's own answer, so a bundle the system
    /// has not registered yet is still never opened.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "prefpane",
        "qlgenerator", "saver", "service", "workflow", "action", "xpc",
    ]

    static func isPackage(_ url: URL) -> Bool {
        if packageExtensions.contains(url.pathExtension.lowercased()) { return true }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }
}

/// The `#anchor` half: turning a heading into the fragment that links to it.
///
/// GitHub's rule, because that is the rule the documents were written against —
/// every `[see below](#status-and-licence)` in this repo was checked in a
/// browser, and an anchor that resolves to nothing is a link that silently does
/// nothing at all.
enum MarkdownAnchor {
    /// Lowercased, punctuation dropped, spaces hyphenated. Applied to the *link*
    /// as well as to the heading, so a hand-written `#Third-Party-Code` finds the
    /// same section its lowercase spelling would.
    static func slug(_ heading: String) -> String {
        // Inline markdown first: a heading is `## The `wortel` command`, and the
        // anchor is built from what the heading *says*, not from its source.
        let plain = String(MarkdownInline.parse(heading).characters)
        var slug = ""
        for character in plain.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    /// The id of the block `fragment` points at, or nil if no heading matches.
    ///
    /// Repeated headings are numbered in document order (`-1`, `-2`, ...), which
    /// is GitHub's rule and not a detail worth skipping: a document with a
    /// `### Options` under each command has every one of those links landing on
    /// the first one otherwise.
    static func blockID(for fragment: String, in blocks: [MarkdownBlock]) -> Int? {
        let wanted = slug(fragment)
        guard !wanted.isEmpty else { return nil }
        var seen: [String: Int] = [:]
        for block in blocks {
            guard case .heading = block.kind else { continue }
            let base = slug(block.text)
            guard !base.isEmpty else { continue }
            let count = seen[base, default: 0]
            seen[base] = count + 1
            let candidate = count == 0 ? base : "\(base)-\(count)"
            if candidate == wanted { return block.id }
        }
        return nil
    }
}
