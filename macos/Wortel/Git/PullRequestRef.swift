import Foundation

/// A pull request (or GitLab merge request) as typed into the branch sheet or
/// given to `wortel new --pr`: `#123`, `123`, or its URL.
///
/// Checked out with plain git, no `gh`: every GitHub repository publishes a
/// pull request's head as `refs/pull/<n>/head` and every GitLab one as
/// `refs/merge-requests/<n>/head`, including for pull requests from forks,
/// which is the case a branch name can't reach. Being typed into a field
/// otherwise meant for branch names is why parsing is strict: a bare number is
/// only a pull request when no branch has that name (the sheet's call).
struct PullRequestRef: Equatable {
    enum Forge: Equatable { case github, gitlab }

    let number: Int
    /// From a URL: whose pull request it is, so the right remote is used.
    var host: String?
    var path: String?
    var forge: Forge?

    /// `#123` or `123` or a URL, or nil for anything else. `allowsBareNumber`
    /// is false when a branch is called that number.
    static func parse(_ text: String, allowsBareNumber: Bool = true) -> PullRequestRef? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { return number(text.dropFirst()).map { PullRequestRef(number: $0) } }
        if allowsBareNumber, let n = number(Substring(text)) { return PullRequestRef(number: n) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host?.lowercased()
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        // GitHub: /owner/repo/pull/123[/files…]
        if let index = parts.firstIndex(of: "pull"), index == 2, index + 1 < parts.count,
           let n = number(Substring(parts[index + 1])) {
            return PullRequestRef(number: n, host: host, path: parts[0..<index].joined(separator: "/"),
                                  forge: .github)
        }
        // GitLab: /group/…/repo/-/merge_requests/123[/diffs…]
        if let dash = parts.firstIndex(of: "-"), dash >= 2, dash + 2 < parts.count,
           parts[dash + 1] == "merge_requests", let n = number(Substring(parts[dash + 2])) {
            return PullRequestRef(number: n, host: host, path: parts[0..<dash].joined(separator: "/"),
                                  forge: .gitlab)
        }
        return nil
    }

    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
              let n = Int(text), n > 0 else { return nil }
        return n
    }

    /// The branch it's checked out on: in Wortel's namespace, so Clean Up may
    /// delete it, and the same every time, so opening it again reuses it.
    var branch: String { GitWorktree.branchNamespace + "pr-\(number)" }

    /// What it's called on screen.
    var label: String { "#\(number)" }

    /// The ref the forge publishes it under, given what the remote is.
    func ref(remoteURL: String?) -> String {
        let gitlab = forge == .gitlab || (forge == nil && remoteURL?.lowercased().contains("gitlab") == true)
        return gitlab ? "refs/merge-requests/\(number)/head" : "refs/pull/\(number)/head"
    }

    /// Whether `remoteURL` is the repository this URL named. Compares host and
    /// path, whatever the transport: `git@github.com:o/r.git`,
    /// `ssh://git@github.com/o/r`, `https://github.com/o/r.git`.
    func matches(remoteURL: String) -> Bool {
        guard let host, let path else { return false }
        guard let parsed = Self.hostAndPath(remoteURL) else { return false }
        return parsed.host == host && parsed.path.lowercased() == path.lowercased()
    }

    static func hostAndPath(_ remote: String) -> (host: String, path: String)? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasSuffix("/") { text.removeLast() }
        if let url = URL(string: text), url.scheme != nil, let host = url.host {
            let path = url.path.split(separator: "/").joined(separator: "/")
            return (host.lowercased(), path)
        }
        // scp-like: [user@]host:path
        guard let colon = text.firstIndex(of: ":") else { return nil }
        var host = String(text[..<colon])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        let path = text[text.index(after: colon)...].split(separator: "/").joined(separator: "/")
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host.lowercased(), path)
    }
}
