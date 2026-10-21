import Foundation

/// A git worktree: a second checkout of one repository, on its own branch, in
/// its own directory, sharing a single `.git`.
///
/// This is the answer to the thing that makes several agents in one repo a
/// footgun — they share a working tree, so two of them editing at once is two
/// of them editing the same files, and switching branches under a running agent
/// changes the ground beneath it mid-task. A worktree per session gives each one
/// its own branch and its own files, at the cost of a directory rather than a
/// clone: history, remotes and objects stay shared.
///
/// The path derivation and the porcelain parsing live here, apart from the
/// commands, because both are string handling with silent failure modes — a slug
/// that collides puts two branches in one directory, and a mis-parsed listing
/// makes an existing worktree invisible so the next attempt tries to create it
/// again and fails.
struct GitWorktree: Equatable {
    /// The checkout's directory.
    let path: String
    /// The branch checked out there, short name. nil for a detached HEAD.
    let branch: String?
    /// The repository's own working tree — the one that isn't a linked worktree.
    let isPrimary: Bool
    /// `git worktree lock`ed: someone said not to remove it. Cleanup respects it.
    var isLocked = false
    /// The commit checked out. For a detached HEAD this is the only thing
    /// holding its commits, so cleanup has to know it.
    var head: String?
    /// Its folder is gone: git still lists it until `worktree prune`.
    var isPrunable = false
    /// The repository has no working tree of its own (a bare clone, as
    /// worktree-first tools set them up). Only ever the first entry.
    var isBare = false
}

extension GitWorktree {
    /// Where Wortel keeps the worktrees it creates: outside the repository, so
    /// they can never be committed, never confuse a build that walks the project,
    /// and never disappear when the branch they belong to is deleted.
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".wortel/worktrees", isDirectory: true)
    }

    /// The namespace every branch Wortel generates lives in (⇧⌘N names its
    /// branch `worktree/<adjective>-<noun>-<hex>` until the work has a name). It exists to group them
    /// under one heading in `git branch`, where they are disposable and you will
    /// want to sweep them later. One constant, because the half that makes the
    /// name and the half that reads it back must never drift apart.
    static let branchNamespace = "worktree/"

    /// A typed name made into one git accepts: what you meant, not a refusal.
    /// "worktree/Jump to" becomes "worktree/Jump-to".
    ///
    /// GitHub Desktop's rule (`sanitizedRefName`), which VS Code's
    /// `git.branchWhitespaceChar` default agrees with: every run of what
    /// `git check-ref-format` forbids (spaces and control characters,
    /// `~ ^ : ? * [ \`, `@{`, `..`) becomes one "-". Then the rules about
    /// where things may appear: no empty or dot-led path component, none ending
    /// in `.lock`, no leading "-", no trailing "." or "/". Case is kept: it's
    /// your name. Empty when nothing usable is left; git's own check at
    /// creation is still the last word.
    static func branchName(from typed: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(
            of: #"[\x00-\x20\x7F~^:?*\[\\]+|@\{|\.\.+"#, with: "-", options: .regularExpression)
        let components = name.split(separator: "/", omittingEmptySubsequences: true).map { part in
            var part = String(part)
            while part.hasPrefix(".") { part.removeFirst() }
            while part.hasSuffix(".lock") { part.removeLast(".lock".count) }
            return part
        }
        name = components.filter { !$0.isEmpty }.joined(separator: "/")
        name = name.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        while name.hasPrefix("-") || name.hasPrefix("+") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix("/") { name.removeLast() }
        return name == "@" ? "" : name
    }

    /// What a worktree session is called in the sidebar before an agent says
    /// what it is for: the branch, minus Wortel's own namespace.
    ///
    /// The prefix is on every branch the app makes, so in a sidebar where every
    /// one of these rows carries it, it distinguishes nothing. A namespace you
    /// chose yourself (`fix/login`) is kept: there it is the half that says what
    /// the branch is for.
    ///
    /// Whatever survives is made slash-free (`SessionName.asLeaf`), and that is
    /// the point of this existing at all. A session's folder is the part of its
    /// name before the last slash, so a branch dropped in whole filed its
    /// session under a folder named for the branch's namespace — a second,
    /// sibling group in the sidebar holding exactly the sessions that belong in
    /// the first one. Every other automatic name already passes through
    /// `asLeaf`; this was the one path that did not.
    static func sessionLeaf(forBranch branch: String) -> String {
        guard branch.hasPrefix(branchNamespace) else { return SessionName.asLeaf(branch) }
        let stripped = branch.dropFirst(branchNamespace.count)
        // A branch that is nothing but the namespace has no leaf to show, and an
        // empty row is worse than a redundant one.
        return SessionName.asLeaf(stripped.isEmpty ? branch : String(stripped))
    }

    /// A worktree session's name with the phantom folder an earlier build gave
    /// it removed, or nil when there is nothing to repair.
    ///
    /// Until `sessionLeaf` above, a worktree session was named
    /// "<folder>/<branch>" with the branch whole, so `GFPC` plus
    /// `worktree/wakker-slide` became a session called `wakker-slide` in a
    /// folder called `GFPC/worktree`. The agent rename that followed kept the
    /// folder half (only the leaf changes), which is why the phantom folder
    /// outlives the placeholder that made it and has to be undone here rather
    /// than just stopped.
    ///
    /// Only the branch's own namespace is stripped, and only from the end of the
    /// folder, so a folder someone deliberately named "worktree" for unrelated
    /// sessions is untouched: those sessions have no branch to match it against.
    static func repairedSessionName(_ name: String, branch: String) -> String? {
        let namespace = (branch as NSString).deletingLastPathComponent
        guard !namespace.isEmpty, let folder = SessionName.folder(of: name) else { return nil }
        let leaf = SessionName.leaf(of: name)
        if folder == namespace { return leaf }
        guard folder.hasSuffix("/" + namespace) else { return nil }
        return String(folder.dropLast(namespace.count + 1)) + "/" + leaf
    }

    /// A branch name as one path component. Branch names may contain slashes
    /// (`feature/preview-window`), which would otherwise nest directories, and
    /// characters a path shouldn't carry.
    ///
    /// Collisions matter more than beauty here, and simply replacing the awkward
    /// characters isn't enough: `feature/x` and `feature-x` are *different
    /// branches* that both flatten to `feature-x`, and one directory for two
    /// branches means the second session silently lands in the first one's
    /// files. (A test caught exactly that.)
    ///
    /// So a name that is already a safe path component is used verbatim — branch
    /// names are unique, so those can't collide — and only a name that had to be
    /// rewritten carries a short digest of the original, which restores the
    /// distinction the rewrite destroyed. `main` stays `main`; `feature/x`
    /// becomes `feature-x-<digest>`.
    nonisolated static func slug(forBranch branch: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let isSafe = !branch.isEmpty
            && branch.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !branch.hasPrefix("-") && !branch.hasPrefix(".")
            && !branch.hasSuffix("-") && !branch.hasSuffix(".")
        if isSafe { return branch }

        let mapped = branch.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let stem = trimmed.isEmpty ? "worktree" : trimmed
        return "\(stem)-\(digest(branch))"
    }

    /// FNV-1a, and hand-written for one reason: the path has to be the *same
    /// path* next launch. Swift's `hashValue` is seeded per process, so a
    /// worktree keyed on it would be unfindable the moment the app restarts.
    private nonisolated static func digest(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in Array(text.utf8) {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(format: "%06x", hash & 0xFF_FFFF)
    }

    /// `~/.wortel/worktrees/<repo>/<branch-slug>`. The repository's own directory
    /// name groups them, so two projects with a `main` branch don't collide and
    /// the folder is readable when you go looking.
    /// The checkout `path` is inside, as the directory Wortel made for it
    /// (`~/.wortel/worktrees/<repo>/<checkout>`), whatever depth the shell has
    /// since `cd`'d to. nil outside Wortel's worktrees, and for the repository
    /// folders themselves.
    static func checkout(containing path: String?, under base: String = root.path) -> String? {
        guard let path, path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "\(base)/\(parts[0])/\(parts[1])"
    }

    /// The branch checked out in the worktree at `path`, read from the files
    /// git keeps there rather than by running git: its `.git` file names the
    /// worktree's own git folder, and that folder's `HEAD` names the branch.
    /// Instant, so a list of worktrees can show the right names before any
    /// git has answered. nil for a detached HEAD, a folder that isn't a
    /// linked worktree, or anything unreadable; the slower check has the
    /// last word.
    nonisolated static func checkedOutBranch(at path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
              pointer.hasPrefix("gitdir:") else { return nil }
        var gitDir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !gitDir.hasPrefix("/") { gitDir = (path as NSString).appendingPathComponent(gitDir) }
        guard let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"),
                                     encoding: .utf8) else { return nil }
        var ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref == "ref: refs/heads/\(reftableStubBranch)" {
            guard let target = Reftable.symbolicTarget(
                of: "HEAD", inStack: (gitDir as NSString).appendingPathComponent("reftable")) else { return nil }
            ref = "ref: " + target
        }
        guard ref.hasPrefix("ref: refs/heads/") else { return nil }
        let branch = String(ref.dropFirst("ref: refs/heads/".count))
        return branch.isEmpty ? nil : branch
    }

    /// What the HEAD file names in a repository that keeps its refs in a
    /// reftable (`git init --ref-format=reftable`): the real HEAD is in the
    /// table (`Reftable`), and the file is a stub pointing at a name no
    /// branch can have, so a tool that reads only the file fails instead of
    /// guessing. Taken for a branch, every worktree row said ".invalid".
    nonisolated static let reftableStubBranch = ".invalid"

    /// A linked worktree, wherever it is and whoever made it: Wortel, another
    /// app, a script, or `git worktree add` by hand.
    struct Linked: Equatable {
        /// The checkout's own folder, the one holding its `.git` file.
        let root: String
        /// Where the repository lives: the primary checkout's folder, or for a
        /// bare clone set up the worktree-first way (`repo/.bare` beside
        /// `repo/main`, `repo/feature`), the folder holding it and its
        /// worktrees. nil for a bare clone anywhere else.
        let repoHome: String?
        /// The worktree's own folder inside the repository's git dir
        /// (`.git/worktrees/<name>`), where its HEAD and index live.
        var gitDir: String = ""
        /// Wortel made it (`Ownership`): the one kind it may remove.
        var isOwned = false
    }

    /// The linked worktree `path` is in, at any depth, read from the files git
    /// keeps rather than by running git, so it's cheap enough for every `cd`.
    ///
    /// The nearest `.git` decides. A folder is a repository's own checkout
    /// (nil); a file pointing into `<common>/worktrees/<name>` is a linked
    /// worktree. A file pointing anywhere else is a submodule, which is a
    /// repository of its own, not a worktree (nil).
    nonisolated static func linked(containing path: String) -> Linked? {
        var directory = (path as NSString).standardizingPath
        let files = FileManager.default
        while true {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue,
                      let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      pointer.hasPrefix("gitdir:") else { return nil }
                var gitDir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !gitDir.hasPrefix("/") { gitDir = (directory as NSString).appendingPathComponent(gitDir) }
                let parts = (gitDir as NSString).standardizingPath.split(separator: "/").map(String.init)
                guard parts.count >= 3, parts[parts.count - 2] == "worktrees" else { return nil }
                let common = "/" + parts.dropLast(2).joined(separator: "/")
                let leaf = (common as NSString).lastPathComponent
                let home = leaf == ".git" || leaf == ".bare" ? (common as NSString).deletingLastPathComponent : nil
                let root = realPath(directory)
                return Linked(root: root, repoHome: home.map(realPath), gitDir: gitDir,
                              isOwned: Ownership.isOwned(root: root, gitDir: gitDir))
            }
            let parent = (directory as NSString).deletingLastPathComponent
            guard parent != directory, !parent.isEmpty else { return nil }
            directory = parent
        }
    }

    // MARK: - Generated branches, and naming them for the work

    /// Herdr's scheme, because it had the right idea and there is nothing to
    /// improve on: `worktree/brave-river-1a2f`. An adjective and a noun make it
    /// sayable and tellable apart in a sidebar, where a timestamp is just a
    /// number you have to read carefully; the hex tail keeps it unique; and the
    /// `worktree/` prefix groups every branch the app made under one heading in
    /// `git branch`. See `worktree.rs:generated_branch_slug` in
    /// ogulcancelik/herdr, whose word lists these are.
    ///
    /// It's a placeholder: once the session has a real name, the branch is
    /// renamed for it (`renamedBranch`).
    private static let slugAdjectives = [
        "brave", "calm", "clear", "green", "lucky", "quiet", "rapid", "silver",
    ]
    private static let slugNouns = [
        "river", "cloud", "field", "forest", "harbor", "meadow", "stone", "valley",
    ]

    static func generatedBranch(seed: UInt64) -> String {
        let adjective = slugAdjectives[Int(seed % UInt64(slugAdjectives.count))]
        let noun = slugNouns[Int((seed / UInt64(slugAdjectives.count)) % UInt64(slugNouns.count))]
        return branchNamespace + String(format: "%@-%@-%04x", adjective, noun, Int(seed & 0xffff))
    }

    /// Seeded from the clock, then walked until the name is free. A name that
    /// already exists is not a new branch, it is a checkout of somebody's work,
    /// and offering that by default is a quiet way to land in the wrong place.
    static func generatedBranch(now: Date = Date(), isTaken: (String) -> Bool) -> String {
        var seed = UInt64(max(0, now.timeIntervalSince1970) * 1_000_000)
        // Bounded: 64 collisions in a row means something is wrong with the
        // list, not with the name, and a loop is not the place to find out.
        for _ in 0..<64 {
            let candidate = generatedBranch(seed: seed)
            if !isTaken(candidate) { return candidate }
            seed &+= 1
        }
        return generatedBranch(seed: seed)
    }

    /// Whether `branch` is still the placeholder `generatedBranch` made.
    static func isGenerated(_ branch: String) -> Bool {
        guard branch.hasPrefix(branchNamespace) else { return false }
        let parts = branch.dropFirst(branchNamespace.count).split(separator: "-")
        guard parts.count == 3, let hex = parts.last, hex.count == 4,
              hex.allSatisfy(\.isHexDigit) else { return false }
        return slugAdjectives.contains(String(parts[0])) && slugNouns.contains(String(parts[1]))
    }

    /// The branch a session called `name` should be on, renamed from its
    /// placeholder: the name as a branch, lower case, cut at a word to stay
    /// readable in `git branch` and a pull request, and `-2`, `-3` past one
    /// that's taken. nil when the name makes no branch (all punctuation), or
    /// is itself still a placeholder.
    static func renamedBranch(forName name: String, isTaken: (String) -> Bool) -> String? {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var stem = ""
        for word in words {
            let next = stem.isEmpty ? word : stem + "-" + word
            if next.count > 40, !stem.isEmpty { break }
            stem = String(next.prefix(40))
        }
        guard !stem.isEmpty, !isGenerated(branchNamespace + stem) else { return nil }
        let base = branchName(from: stem)
        var candidate = base, n = 2
        while isTaken(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Whether a placeholder branch may still be renamed: Wortel made it, it
    /// was never pushed (no upstream, and no remote carries the name), and
    /// it's checked out in this one worktree. Past any of those, someone may
    /// already know it by name.
    static func mayRename(_ branch: String, createdByWortel: Bool, hasUpstream: Bool,
                          onRemote: Bool, checkouts: Int) -> Bool {
        isGenerated(branch) && createdByWortel && !hasUpstream && !onRemote && checkouts == 1
    }

    /// The git dir shared by every checkout of the repository living at
    /// `home` (a `repoHome`): its `.git` folder, a worktree-first clone's
    /// `.bare`, or wherever a `.git` file points. Off the disk, no git.
    nonisolated static func commonDir(ofHome home: String) -> String? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        let dotGit = (home as NSString).appendingPathComponent(".git")
        if files.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return dotGit }
            guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  pointer.hasPrefix("gitdir:") else { return nil }
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let gitDir = target.hasPrefix("/") ? target : (home as NSString).appendingPathComponent(target)
            // A linked worktree's `.git` points into `<common>/worktrees/<name>`.
            let parts = (gitDir as NSString).standardizingPath.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[parts.count - 2] == "worktrees" {
                return "/" + parts.dropLast(2).joined(separator: "/")
            }
            return (gitDir as NSString).standardizingPath
        }
        let bare = (home as NSString).appendingPathComponent(".bare")
        if files.fileExists(atPath: bare, isDirectory: &isDirectory), isDirectory.boolValue { return bare }
        return nil
    }

    /// The git dir every checkout of `path`'s repository shares, at any
    /// depth, so two folders are in the same repository exactly when theirs
    /// match, whichever worktree each is in. Off the disk, no git; nil
    /// outside a repository.
    nonisolated static func commonDir(containing path: String) -> String? {
        if let linked = linked(containing: path) {
            let worktrees = ((linked.gitDir as NSString).standardizingPath as NSString).deletingLastPathComponent
            return realPath((worktrees as NSString).deletingLastPathComponent)
        }
        return repositoryHome(containing: path).flatMap(commonDir(ofHome:)).map(realPath)
    }

    /// Where the repository `path` is in lives, at any depth: a linked
    /// worktree's `repoHome`, else the nearest folder holding a `.git`. Read
    /// off the disk, for a decision (which sidebar folder) that can't wait
    /// for git. nil outside a repository.
    nonisolated static func repositoryHome(containing path: String) -> String? {
        if let linked = linked(containing: path) { return linked.repoHome ?? linked.root }
        var directory = (path as NSString).standardizingPath
        while true {
            if FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) {
                return realPath(directory)
            }
            let parent = (directory as NSString).deletingLastPathComponent
            guard parent != directory, !parent.isEmpty else { return nil }
            directory = parent
        }
    }

    /// Which worktrees are Wortel's to remove, and which branches its to
    /// delete: the ones it made, as it recorded making them, wherever they
    /// are and whatever they're called since.
    ///
    /// **A marker, not a path.** A worktree Wortel creates gets a file in its
    /// own git folder (`.git/worktrees/<name>/wortel`), which git leaves alone
    /// and removes with the worktree; a branch it creates gets
    /// `branch.<name>.wortelCreated` in the repository's config, which git
    /// carries along when the branch is renamed and drops when it's deleted.
    /// A folder under `~/.wortel/worktrees` and a branch in `worktree/` count
    /// too, which is how everything made before the markers stays Wortel's.
    /// Nothing else ever is: a worktree another tool or a person made is
    /// shown, opened and archived like any, and never removed.
    enum Ownership {
        static let markerName = "wortel"
        static let createdKey = "wortelCreated"
        static let baseKey = "wortelBase"

        /// The worktree's git folder, from the `gitdir:` line of its `.git` file.
        nonisolated static func gitDir(ofWorktree root: String) -> String? {
            let dotGit = (root as NSString).appendingPathComponent(".git")
            guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  pointer.hasPrefix("gitdir:") else { return nil }
            let gitDir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return gitDir.hasPrefix("/") ? gitDir : (root as NSString).appendingPathComponent(gitDir)
        }

        /// Mark the worktree at `root` as Wortel's. Best effort: an unmarked
        /// worktree is only one Wortel won't offer to remove.
        nonisolated static func mark(root: String) {
            guard let gitDir = gitDir(ofWorktree: root) else { return }
            let marker = (gitDir as NSString).appendingPathComponent(markerName)
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? Data("created by Wortel \(stamp)\n".utf8).write(to: URL(fileURLWithPath: marker))
        }

        nonisolated static func isOwned(root: String, gitDir: String? = nil, under base: URL = GitWorktree.root) -> Bool {
            if let gitDir = gitDir ?? Self.gitDir(ofWorktree: root),
               FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent(markerName)) {
                return true
            }
            return isUnderLegacyRoot(root, base: base)
        }

        /// The rule before markers: anything in Wortel's own folder.
        nonisolated static func isUnderLegacyRoot(_ path: String, base: URL = GitWorktree.root) -> Bool {
            path.hasPrefix(base.path + "/") || realPath(path).hasPrefix(realPath(base.path) + "/")
        }
    }

    /// The folder for a worktree Wortel is about to create.
    ///
    /// `path(forBranch:repoRoot:)`, with two exceptions that keep a new
    /// worktree from landing where another's history is:
    /// - **Two repositories with the same name** (`work/app`, `side/app`)
    ///   would share `~/.wortel/worktrees/app`. The second gets
    ///   `app-<digest of its path>` once the first is there.
    /// - **A folder that was a worktree before.** Agents key their history by
    ///   directory (Claude's transcripts are per folder), so a new worktree in
    ///   an old one's place would offer the old conversation. `wasUsed` says
    ///   so; an existing folder always counts. A `-2`, `-3` goes on the end.
    ///
    /// `location` is where the repository wants its worktrees instead
    /// (`locationKey`, a `location(template:…)`), which replaces Wortel's
    /// folder and the same-name rule with it; the never-reused rule stands.
    nonisolated static func newWorktreePath(
        forBranch branch: String, repoRoot: String, under base: URL = root,
        location: String? = nil, wasUsed: (String) -> Bool = { _ in false }
    ) -> String {
        let repo = (repoRoot as NSString).lastPathComponent
        let leaf = slug(forBranch: branch)
        var candidate: String
        if let location {
            candidate = self.location(template: location, repoRoot: repoRoot, branch: branch)
        } else {
            var folder = base.appendingPathComponent(slug(forBranch: repo), isDirectory: true).path
            if holdsAnotherRepository(folder, than: repoRoot) {
                folder = base.appendingPathComponent(
                    "\(slug(forBranch: repo))-\(digest(realPath(repoRoot)))", isDirectory: true).path
            }
            candidate = (folder as NSString).appendingPathComponent(leaf)
        }
        let first = candidate
        var n = 2
        while FileManager.default.fileExists(atPath: candidate) || wasUsed(candidate) {
            candidate = "\(first)-\(n)"
            n += 1
        }
        return candidate
    }

    /// The git config key a repository names its worktree location in:
    /// `git config wortel.worktreePath <template>`, set by the folder menu's
    /// Worktree Location…, or for every repository under a folder with git's
    /// own `includeIf` (which is how a team's machines can share one rule
    /// with nothing of Wortel's to set up). Unset means Wortel's folder.
    static let locationKey = "wortel.worktreePath"

    /// Where a worktree goes for `template`:
    /// - `{repo}` is the repository's folder name, `{branch}` the branch as
    ///   a folder name (`slug`);
    /// - without `{branch}` the template names a folder, and the branch goes
    ///   inside it;
    /// - `~` is home, and a relative path is from the repository's folder,
    ///   so `.worktrees` puts them inside it and `../{repo}-worktrees` beside.
    nonisolated static func location(template: String, repoRoot: String, branch: String) -> String {
        var path = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.contains("{branch}") {
            path = path.hasSuffix("/") ? path + "{branch}" : path + "/{branch}"
        }
        path = path
            .replacingOccurrences(of: "{repo}", with: slug(forBranch: (repoRoot as NSString).lastPathComponent))
            .replacingOccurrences(of: "{branch}", with: slug(forBranch: branch))
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (repoRoot as NSString).appendingPathComponent(path) }
        return (path as NSString).standardizingPath
    }

    /// Whether `folder` holds worktrees of a repository other than `repoRoot`.
    private nonisolated static func holdsAnotherRepository(_ folder: String, than repoRoot: String) -> Bool {
        let mine = realPath(repoRoot)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return entries.contains { entry in
            let path = (folder as NSString).appendingPathComponent(entry)
            guard let home = linked(containing: path)?.repoHome, linked(containing: path)?.root == realPath(path)
            else { return false }
            return home != mine
        }
    }

    /// `path` with its symlinks resolved, as git records worktrees
    /// (`/private/var/…`), where a shell reports the way it was reached
    /// (`/var/…`, or a symlinked `~/work`). Unchanged when it can't be.
    /// Not `NSString.resolvingSymlinksInPath`, which strips `/private` again.
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func path(forBranch branch: String, repoRoot: String) -> String {
        let repo = (repoRoot as NSString).lastPathComponent
        return root
            .appendingPathComponent(slug(forBranch: repo), isDirectory: true)
            .appendingPathComponent(slug(forBranch: branch), isDirectory: true)
            .path
    }

    /// Parse `git worktree list --porcelain`.
    ///
    /// The format is stanzas separated by blank lines: a `worktree <path>` line,
    /// then optionally `HEAD <sha>`, then either `branch refs/heads/<name>` or
    /// `detached`. The first stanza is always the primary working tree.
    static func parse(porcelain: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var path: String?
        var branch: String?
        var locked = false
        var head: String?
        var prunable = false
        var bare = false

        func flush() {
            guard let current = path else { return }
            result.append(GitWorktree(path: current, branch: branch, isPrimary: result.isEmpty,
                                      isLocked: locked, head: head, isPrunable: prunable, isBare: bare))
            path = nil
            branch = nil
            locked = false
            head = nil
            prunable = false
            bare = false
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush() // a stanza that ran straight into the next one
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            } else if line == "bare" {
                bare = true
            }
        }
        flush()
        return result
    }
}
