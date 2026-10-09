import Foundation

/// The open pull request for a branch, as GitHub's own `gh` reports it.
///
/// Shown only when it's certain: there is no git-level way to ask "what's the
/// PR for this branch" (hosts keep PRs as refs like `refs/pull/*`, and listing
/// them is every PR the repository ever had), and a link guessed from the
/// remote's address leads to a "not found" page when there isn't one. `gh`
/// knows, for GitHub and GitHub Enterprise, with the login the user already
/// has. No `gh`, not logged in, another host, no PR, a closed one: no icon.
/// (Meteorite and other GitHub clients read the same PRs, so the GitHub link
/// is the one to open.)
/// What the header offers: the PR, or to create one. Only ever what `gh`
/// said, never a guess.
enum PullRequestState: Equatable, Sendable {
    case open(PullRequest)
    /// `gh` looked for this branch and found none.
    case none(branch: String)

    var branch: String {
        switch self {
        case .open(let pr): return pr.branch
        case .none(let branch): return branch
        }
    }
}

struct PullRequest: Equatable, Sendable {
    let number: Int
    let url: URL
    let isDraft: Bool
    /// The branch it was looked up for, so a PR is never shown beside
    /// another branch while the next lookup runs.
    let branch: String

    /// What `gh` says about the branch checked out in `root`: an open PR, or
    /// for certain none. nil when it can't say (no `gh`, not logged in,
    /// another host, offline) or the PR there is closed or merged, which is
    /// not a branch to offer a new one for.
    static func lookUp(branch: String, root: String) async -> PullRequestState? {
        guard let gh = ghPath else { return nil }
        // Without an argument `gh` takes the checked-out branch and works out
        // which remote and owner it was pushed to: a fork's PR with the same
        // branch name isn't this one.
        let result = await GitService.runTool(
            [gh, "pr", "view", "--json", "number,url,state,isDraft,headRefName"],
            environment: environment(for: gh), in: root, timeout: 20)
        // gh's own words for "asked, and there is none": the one failure that
        // is an answer.
        if !result.ok, result.stderr.contains("no pull requests found") {
            return .none(branch: branch)
        }
        guard result.ok,
              let data = result.stdout.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.state == "OPEN", reply.headRefName == branch,
              let url = URL(string: reply.url), url.scheme == "https"
        else { return nil }
        return .open(PullRequest(number: reply.number, url: url, isDraft: reply.isDraft, branch: branch))
    }

    /// Open the host's page for a new pull request from the checked-out
    /// branch, in the browser: `gh pr create --web` works out the base and,
    /// for a fork, which repository it goes to. Nothing is created until you
    /// press the button there. Returns gh's complaint, or nil.
    static func create(root: String) async -> String? {
        guard let gh = ghPath else { return "GitHub's gh command isn't installed." }
        let result = await GitService.runTool(
            [gh, "pr", "create", "--web"], environment: environment(for: gh), in: root, timeout: 30)
        guard !result.ok else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Couldn't open a new pull request." : message
    }

    private struct Reply: Decodable {
        let number: Int
        let url: String
        let state: String
        let isDraft: Bool
        let headRefName: String
    }

    /// Where `gh` is. An app opened from the Dock has the system's PATH, which
    /// has none of the places it's installed, so those are looked in by name.
    /// Read once: installing it while the app runs is picked up on relaunch.
    private static let ghPath: String? = {
        GitService.toolPath(ProcessInfo.processInfo.environment["PATH"])
            .split(separator: ":").map(String.init)
            .map { ($0 as NSString).appendingPathComponent("gh") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// `gh` runs git itself, so its own directory goes on the PATH too (a Nix
    /// profile has both side by side). Never a prompt, never an update notice.
    private static func environment(for gh: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = (gh as NSString).deletingLastPathComponent
        env["PATH"] = [dir, GitService.toolPath(env["PATH"])].joined(separator: ":")
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}
