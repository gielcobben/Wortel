import Foundation

/// Decides whether a clicked terminal link is a local markdown file Wortel
/// should preview. Pure and cwd-free so it can run synchronously on
/// libghostty's callback thread (see `GhosttyRuntime`'s OPEN_URL handling): the
/// handler must decide *right there* whether to intercept the click or let
/// libghostty perform its own default open, and it has no main-actor session
/// state to consult.
///
/// Only **absolute** paths and `file://` URLs qualify — a relative link would
/// need the clicking session's cwd, which isn't reachable here without a data
/// race, so those fall through to libghostty. Everything non-markdown (http
/// links, other files, apps) also falls through, so Wortel never becomes the
/// thing that launches an arbitrary file on a single click.
enum MarkdownLink {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

    /// The existing local markdown file this link points at, or nil to let
    /// libghostty handle the open.
    static func fileURL(from link: String) -> URL? {
        var path = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            path = url.path
        }
        // A trailing `:line` / `:line:col` (grep -n / compiler style) isn't part
        // of the filename — drop it before resolving. A real markdown path never
        // ends in `.md:42`, so this only ever strips a location suffix.
        path = stripLocationSuffix(path)

        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        // Absolute only — a relative path has no meaning without a cwd here.
        guard path.hasPrefix("/") else { return nil }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard extensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Strip a trailing `:<digits>` or `:<digits>:<digits>` location suffix.
    private static func stripLocationSuffix(_ path: String) -> String {
        var result = path[...]
        for _ in 0..<2 {
            guard let colon = result.lastIndex(of: ":") else { break }
            let digits = result[result.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { break }
            result = result[..<colon]
        }
        return String(result)
    }
}
