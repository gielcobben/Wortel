import Foundation

/// Git's refusals, said as a sentence: what went wrong, and what to do next.
///
/// Git writes for people who already know git: `fatal:` and `hint:` lines, a
/// full path, the flag that would have forced it. Shown as they are, they were
/// the most common thing people asked about ("worktree/Jump to is not a valid
/// branch name", "already used by worktree at '/Users/…'"). So the failures
/// that come up in everyday use are recognised and said in a sentence, naming
/// the files or folder involved; anything else is git's own words without the
/// `hint:` lines and the `fatal:`/`error:` prefixes, because an unrecognised
/// message (a commit hook's lint output, a server's refusal) is still the best
/// account of what happened.
///
/// Pure, so the recognising is tested against git's real wording.
enum GitMessage {
    /// What was being done, which some sentences need: "switching" and
    /// "pulling" overwrite files for different reasons.
    enum Action: Equatable {
        case switching(to: String)
        case pull
        case push
        case fetch
        case commit
        case worktree(branch: String)
        case other
    }

    static func readable(_ raw: String, while action: Action = .other) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fallbackSentence(for: action) }
        if let sentence = recognised(text, action: action) { return sentence }
        return cleaned(text)
    }

    // MARK: - Recognised

    private static func recognised(_ text: String, action: Action) -> String? {
        let lower = text.lowercased()
        let verb = verbing(action)

        // A branch checked out in another folder.
        if let folder = quoted(after: ["already used by worktree at '", "already checked out at '"], in: text) {
            let name = (folder as NSString).lastPathComponent
            return "\(branchName(action) ?? "That branch") is open in another folder, \(name). A branch can only be in one folder at a time."
        }
        if lower.contains("is not a valid branch name") {
            return "\(branchName(action) ?? "That") isn't a name git allows for a branch."
        }
        if let name = quoted(after: ["a branch named '"], in: text), lower.contains("already exists") {
            return "A branch called \u{201C}\(name)\u{201D} already exists."
        }
        // Local edits in the way.
        if lower.contains("your local changes to the following files would be overwritten") {
            return "\(verb.capitalizedFirst) would overwrite your changes to \(files(in: text)). Commit or stash them first."
        }
        if lower.contains("untracked working tree files would be overwritten") {
            return "\(verb.capitalizedFirst) would overwrite files git isn't tracking: \(files(in: text)). Move them or commit them first."
        }
        if lower.contains("conflict") && (lower.contains("automatic merge failed") || lower.contains("merge conflict")) {
            return "There are conflicts to resolve in \(conflictFiles(in: text)). Resolve them, then commit."
        }
        // Pushing behind the remote.
        if lower.contains("[rejected]") && (lower.contains("fetch first") || lower.contains("non-fast-forward")) {
            return "The remote has commits you don't have yet. Pull first, then push."
        }
        if lower.contains("protected branch") || lower.contains("gh006") {
            return "The remote refused the push: this branch is protected."
        }
        if lower.contains("not possible to fast-forward") || lower.contains("divergent branches")
            || lower.contains("diverging branches") {
            return "Your branch and the remote have both moved on. Merge or rebase in the terminal, then pull."
        }
        if lower.contains("there is no tracking information") || lower.contains("has no upstream branch") {
            return action == .push
                ? "This branch isn't on the remote yet. Push again to publish it."
                : "This branch isn't on the remote yet, so there's nothing to pull."
        }
        if lower.contains("you are not currently on a branch") {
            return "You're not on a branch here, so there's nothing to \(action == .push ? "push" : "pull")."
        }
        // Reaching the remote.
        if lower.contains("could not read username") || lower.contains("authentication failed")
            || lower.contains("terminal prompts disabled") || lower.contains("invalid username or password") {
            return "The remote wants you to sign in. Run git fetch once in the terminal to sign in, then try again."
        }
        if lower.contains("permission denied (publickey") || lower.contains("could not read from remote repository")
            || lower.contains("repository not found") {
            return "The remote didn't let you in. Check that you have access to this repository."
        }
        if lower.contains("could not resolve host") || lower.contains("connection timed out")
            || lower.contains("network is unreachable") || lower.contains("unable to access")
            || lower.contains("connection refused") {
            return "Couldn't reach the remote. Check your connection and try again."
        }
        // Committing.
        if lower.contains("please tell me who you are") || lower.contains("unable to auto-detect email address") {
            return "Git doesn't know your name and email yet. Set them with git config user.name and user.email, then commit again."
        }
        if lower.contains("nothing to commit") || lower.contains("no changes added to commit") {
            return "There's nothing staged to commit."
        }
        // The folder.
        if lower.contains("index.lock") && lower.contains("exists") {
            return "Another git command is busy in this folder. Try again in a moment."
        }
        if lower.contains("not a git repository") {
            return "This folder isn't a git repository."
        }
        if lower.contains("invalid reference") || lower.contains("not a valid object name") {
            if case .worktree(let branch) = action {
                return "Couldn't find what \u{201C}\(branch)\u{201D} should start from. Fetch, or pick another branch to start from."
            }
            return "Git couldn't find that branch or commit. Fetch, or check the name."
        }
        if let path = quoted(after: ["'"], in: text), lower.contains("already exists"), case .worktree = action {
            return "The folder for this worktree is already there: \((path as NSString).lastPathComponent). Remove it, or pick another name."
        }
        if lower.contains("missing but locked worktree") || lower.contains("missing but already registered worktree") {
            return "Git still remembers an old worktree at that place. Clean Up Worktrees removes it."
        }
        return nil
    }

    // MARK: - Unrecognised

    /// Git's own words, minus its advice for git experts and its prefixes.
    /// Kept to a few lines: what's cut is rarely what you need first.
    static func cleaned(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.lowercased().hasPrefix("hint:") else { continue }
            for prefix in ["fatal: ", "error: ", "remote: ", "warning: "] where line.lowercased().hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "Git stopped without saying why." }
        let shown = lines.prefix(6)
        var result = shown.joined(separator: "\n")
        if lines.count > shown.count { result += "\n\u{2026}" }
        return result.capitalizedFirst
    }

    private static func fallbackSentence(for action: Action) -> String {
        switch action {
        case .switching(let name): return "Couldn't switch to \u{201C}\(name)\u{201D}."
        case .pull: return "Couldn't pull."
        case .push: return "Couldn't push."
        case .fetch: return "Couldn't fetch."
        case .commit: return "Couldn't commit."
        case .worktree(let branch): return "Couldn't open a worktree for \u{201C}\(branch)\u{201D}."
        case .other: return "Git stopped without saying why."
        }
    }

    // MARK: - Pieces

    private static func verbing(_ action: Action) -> String {
        switch action {
        case .switching: return "switching"
        case .pull: return "pulling"
        case .worktree: return "opening the worktree"
        default: return "this"
        }
    }

    private static func branchName(_ action: Action) -> String? {
        switch action {
        case .switching(let name), .worktree(let name): return "\u{201C}\(name)\u{201D}"
        default: return nil
        }
    }

    /// The text between the first of `markers` and the quote that closes it.
    private static func quoted(after markers: [String], in text: String) -> String? {
        for marker in markers {
            guard let start = text.range(of: marker) else { continue }
            let rest = text[start.upperBound...]
            guard let end = rest.firstIndex(of: "'") else { continue }
            let found = String(rest[..<end])
            if !found.isEmpty { return found }
        }
        return nil
    }

    /// The tab-indented file list git prints under "would be overwritten".
    private static func files(in text: String) -> String {
        let names = text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list(names, otherwise: "some files")
    }

    /// "CONFLICT (content): Merge conflict in a.swift" lines.
    private static func conflictFiles(in text: String) -> String {
        let names = text.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let range = line.range(of: "Merge conflict in ") else { return nil }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return list(names, otherwise: "some files")
    }

    /// "a.swift", "a.swift and b.swift", "a.swift, b.swift and 3 more".
    static func list(_ names: [String], otherwise: String) -> String {
        let names = names.map { ($0 as NSString).lastPathComponent }
        switch names.count {
        case 0: return otherwise
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
