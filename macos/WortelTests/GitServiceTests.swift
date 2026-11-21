import XCTest

/// Integration tests: these run the real `git` binary against real repos, which
/// is the point — the parsing here exists to survive git's actual output.
final class GitServiceTests: XCTestCase {
    private var repo: URL!

    override func tearDown() {
        if let repo { GitFixture.destroy(repo) }
        repo = nil
        super.tearDown()
    }

    /// The reason the log format uses US/RS separators instead of spaces and
    /// newlines: a subject can contain anything, and splitting on "\n" would
    /// shear one commit into two bogus rows.
    func testSubjectsContainingNewlinesDoNotShearRows() async {
        repo = GitFixture.newRepo("newlines")
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git commit -q --allow-empty -m 'subject line' -m 'a body paragraph'",
                      in: repo)
        GitFixture.commit("third", in: repo)

        let commits = await GitService.log(root: repo.path, limit: 100)
        XCTAssertEqual(commits.count, 3, "a multi-paragraph message must stay one row")
        XCTAssertEqual(commits.map(\.subject), ["third", "subject line", "first"])
        // The body is carried alongside, and the subject must not absorb it —
        // the row's tooltip is the only place a long message can be read.
        XCTAssertEqual(commits[1].body, "a body paragraph")
        XCTAssertEqual(commits[1].fullMessage, "subject line\n\na body paragraph")
        XCTAssertEqual(commits[0].body, "", "a subject-only commit has no body")
        XCTAssertEqual(commits[0].fullMessage, "third")
    }

    /// A body is free text over many lines, and the row it belongs to has to
    /// survive whatever is in it. The commits either side are the actual
    /// assertion: a body that shears its record would take them with it.
    func testAwkwardBodiesStayInsideTheirOwnCommit() async {
        repo = GitFixture.newRepo("bodies")
        GitFixture.commit("before", in: repo)
        GitFixture.sh("""
            git commit -q --allow-empty -m 'awkward' \
              -m 'line one

            a paragraph with a colon: and a | pipe
            - a bullet
            '
            """, in: repo)
        GitFixture.commit("after", in: repo)

        let commits = await GitService.log(root: repo.path, limit: 100)
        XCTAssertEqual(commits.map(\.subject), ["after", "awkward", "before"])
        XCTAssertTrue(commits[1].body.contains("a | pipe"))
        XCTAssertTrue(commits[1].body.contains("- a bullet"))
        XCTAssertTrue(commits[1].body.hasPrefix("line one"))
    }

    func testParsesAuthorDateAndParents() async {
        repo = GitFixture.newRepo("fields")
        GitFixture.commit("base", in: repo)
        GitFixture.sh("git checkout -q -b side", in: repo)
        GitFixture.commit("side work", in: repo)
        GitFixture.sh("git checkout -q main", in: repo)
        GitFixture.commit("main work", in: repo)
        GitFixture.sh("git merge -q --no-ff -m 'Merge side' side", in: repo)

        let commits = await GitService.log(root: repo.path, limit: 100)
        let merge = commits[0]
        XCTAssertEqual(merge.subject, "Merge side")
        XCTAssertEqual(merge.parents.count, 2, "a merge reports both parents")
        XCTAssertTrue(merge.isMerge)
        XCTAssertEqual(merge.author, "Test User")
        XCTAssertEqual(merge.shortSHA.count, 7)
        XCTAssertEqual(commits.last?.parents, [], "the root commit has no parents")
        XCTAssertFalse(commits.last!.isMerge)
    }

    /// Paging depends on skip/limit carving the history into disjoint,
    /// contiguous windows.
    func testSkipAndLimitPageWithoutGapsOrOverlap() async {
        repo = GitFixture.newRepo("paging")
        GitFixture.importHistory(trunk: 120, concurrent: 3, lifetime: 40, in: repo)

        let all = await GitService.log(root: repo.path, limit: 1_000)
        let page1 = await GitService.log(root: repo.path, limit: 20, skip: 0)
        let page2 = await GitService.log(root: repo.path, limit: 20, skip: 20)
        let page3 = await GitService.log(root: repo.path, limit: 20, skip: 40)

        XCTAssertEqual(page1.count, 20)
        XCTAssertEqual((page1 + page2 + page3).map(\.sha), Array(all.prefix(60)).map(\.sha),
                       "pages must reassemble into git's own ordering")
        XCTAssertTrue(Set(page1.map(\.sha)).isDisjoint(with: Set(page2.map(\.sha))))
    }

    func testShortPageAtTheEndOfHistory() async {
        repo = GitFixture.newRepo("end")
        for i in 0..<5 { GitFixture.commit("c\(i)", in: repo) }

        let page = await GitService.log(root: repo.path, limit: 300, skip: 0)
        XCTAssertEqual(page.count, 5, "a short page is how the pane knows it hit the root")

        let past = await GitService.log(root: repo.path, limit: 300, skip: 5)
        XCTAssertTrue(past.isEmpty)
    }

    func testEmptyRepoAndNonRepo() async {
        repo = GitFixture.newRepo("empty")
        let commits = await GitService.log(root: repo.path, limit: 300)
        XCTAssertTrue(commits.isEmpty, "a repo with no commits yields no rows, not a crash")

        let status = await GitService.status(root: repo.path)
        XCTAssertNil(status.head)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-tests-not-a-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { GitFixture.destroy(outside) }
        let root = await GitService.repoRoot(for: outside.path)
        XCTAssertNil(root)
    }

    func testRepoRootResolvesFromASubdirectory() async {
        repo = GitFixture.newRepo("root")
        GitFixture.commit("base", in: repo)
        GitFixture.sh("mkdir -p deep/nested", in: repo)

        let root = await GitService.repoRoot(for: repo.appendingPathComponent("deep/nested").path)
        // Compare resolved paths: the temp dir is a symlink on macOS.
        XCTAssertEqual(root.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       repo.resolvingSymlinksInPath().path)
    }

    /// HEAD comes free with every status; it's what the History pane watches to
    /// notice a commit made in the terminal.
    func testStatusReportsHeadAndChanges() async {
        repo = GitFixture.newRepo("status")
        GitFixture.commit("base", in: repo)
        GitFixture.sh("echo hello > tracked.txt && git add tracked.txt", in: repo)
        GitFixture.sh("echo untracked > loose.txt", in: repo)

        let status = await GitService.status(root: repo.path)
        XCTAssertEqual(status.head, GitFixture.sh("git rev-parse HEAD", in: repo))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.stagedChanges.map(\.path), ["tracked.txt"])
        XCTAssertTrue(status.unstagedChanges.contains { $0.path == "loose.txt" && $0.untracked })
    }

    func testCommitDiffOfAMergeIsNotEmpty() async {
        repo = GitFixture.newRepo("mergediff")
        GitFixture.sh("echo a > f.txt && git add f.txt && git commit -q -m base", in: repo)
        GitFixture.sh("git checkout -q -b side && echo side > s.txt && git add s.txt "
                      + "&& git commit -q -m 'side file'", in: repo)
        GitFixture.sh("git checkout -q main && git merge -q --no-ff -m 'Merge side' side", in: repo)

        let head = GitFixture.sh("git rev-parse HEAD", in: repo)
        let patch = await GitService.commitDiff(root: repo.path, sha: head)
        XCTAssertFalse(patch.isEmpty, "git shows nothing for a merge by default; we pass -m")
        XCTAssertTrue(patch.contains("s.txt"))
    }

    /// The History accordion's file list zips numstat (counts) against
    /// name-status (status + paths) by index — the fiddly part is a rename, whose
    /// two commands spell the path differently. This pins that they still line up.
    func testCommitFilesReportsStatusCountsAndRenames() async {
        repo = GitFixture.newRepo("commitfiles")
        // move.txt is several lines so a one-line append keeps it well above the
        // rename-similarity threshold — the rename is unambiguous.
        GitFixture.sh("printf 'a\\nb\\nc\\n' > keep.txt "
                      + "&& printf 'l1\\nl2\\nl3\\nl4\\nl5\\n' > move.txt "
                      + "&& git add . && git commit -q -m base", in: repo)
        // One modified file, one added file, and a rename with a small edit.
        GitFixture.sh("printf 'a\\nB\\nc\\nd\\n' > keep.txt", in: repo)
        GitFixture.sh("echo fresh > added.txt && git add added.txt", in: repo)
        GitFixture.sh("git mv move.txt moved.txt && echo l6 >> moved.txt", in: repo)
        GitFixture.sh("git add -A && git commit -q -m 'edit, add, rename'", in: repo)

        let head = GitFixture.sh("git rev-parse HEAD", in: repo)
        let files = await GitService.commitFiles(root: repo.path, sha: head)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        XCTAssertEqual(byPath["keep.txt"]?.statusCode, "M")
        XCTAssertEqual(byPath["keep.txt"]?.additions, 2)   // "B" and "d"
        XCTAssertEqual(byPath["keep.txt"]?.deletions, 1)   // "b"

        XCTAssertEqual(byPath["added.txt"]?.statusCode, "A")
        XCTAssertEqual(byPath["added.txt"]?.deletions, 0)

        // The rename keeps the new path and remembers the old one for the diff.
        let moved = byPath["moved.txt"]
        XCTAssertEqual(moved?.statusCode, "R")
        XCTAssertEqual(moved?.originalPath, "move.txt")
        XCTAssertEqual(moved?.additions, 1, "the '+more' line, counted against the right file")
    }

    /// The History accordion renders an image row from the blob at the commit and
    /// the blob at its first parent; an added image has no parent side. (Content
    /// is plain bytes here — the service just returns them; decoding is the
    /// model's job.)
    func testCommitImageDataReadsBothSides() async {
        repo = GitFixture.newRepo("commitimg")
        GitFixture.sh("printf 'v1' > logo.png && git add logo.png && git commit -q -m 'add image'", in: repo)
        GitFixture.sh("printf 'v2-longer' > logo.png && git commit -q -am 'change image'", in: repo)

        let head = GitFixture.sh("git rev-parse HEAD", in: repo)
        let changed = (await GitService.commitFiles(root: repo.path, sha: head)).first { $0.path == "logo.png" }!
        XCTAssertTrue(changed.isImage)
        let (old, new) = await GitService.commitImageData(root: repo.path, sha: head, file: changed)
        XCTAssertEqual(old.map { String(decoding: $0, as: UTF8.self) }, "v1")
        XCTAssertEqual(new.map { String(decoding: $0, as: UTF8.self) }, "v2-longer")

        // A newly added image (the first commit) has no parent blob to show.
        let firstSHA = (await GitService.log(root: repo.path)).last!.sha
        let added = (await GitService.commitFiles(root: repo.path, sha: firstSHA)).first!
        let sides = await GitService.commitImageData(root: repo.path, sha: firstSHA, file: added)
        XCTAssertNil(sides.old, "an added image has no first-parent blob")
        XCTAssertEqual(sides.new.map { String(decoding: $0, as: UTF8.self) }, "v1")
    }

    /// A non-ASCII filename must come back as its real name (not git's default
    /// `"caf\303\251.txt"` C-quoting) so the row's diff/open/reveal all resolve.
    func testCommitFilesHandlesNonASCIIPaths() async {
        repo = GitFixture.newRepo("unicode")
        GitFixture.sh("printf 'hi\\n' > 'café.txt' && git add . && git commit -q -m 'add café'", in: repo)
        GitFixture.sh("printf 'hi\\nthere\\n' > 'café.txt' && git commit -q -am 'edit café'", in: repo)

        let head = GitFixture.sh("git rev-parse HEAD", in: repo)
        let files = await GitService.commitFiles(root: repo.path, sha: head)
        XCTAssertEqual(files.map(\.path), ["café.txt"], "the path is unquoted, its real name")

        let diff = await GitService.commitFileDiff(
            root: repo.path, sha: head, path: "café.txt", originalPath: nil)
        XCTAssertTrue(diff.contains("+there"), "the diff resolves under the real name")
    }

    // MARK: - What a preview window asks about one file

    /// Three states, not a bool, and the reason is the third one: git cannot
    /// diff a file it has never seen. `diff HEAD -- new.swift` prints *nothing*
    /// for an untracked file, so a window that treated "untracked" as "changed"
    /// opened on a diff and announced "No changes to this file" over a file that
    /// was nothing but changes.
    func testWorkingTreeStateSeparatesUntrackedFromChanged() async {
        repo = GitFixture.newRepo("state")
        GitFixture.sh("printf 'one\n' > tracked.txt && git add -A && git commit -q -m first",
                      in: repo)

        var state = await GitService.workingTreeState(root: repo.path, path: "tracked.txt")
        XCTAssertEqual(state, .unchanged)
        XCTAssertFalse(state.hasChanges)

        GitFixture.sh("printf 'two\n' >> tracked.txt", in: repo)
        state = await GitService.workingTreeState(root: repo.path, path: "tracked.txt")
        XCTAssertEqual(state, .changed)
        XCTAssertTrue(state.hasChanges)

        GitFixture.sh("printf 'new\n' > fresh.txt", in: repo)
        state = await GitService.workingTreeState(root: repo.path, path: "fresh.txt")
        XCTAssertEqual(state, .untracked)
        XCTAssertTrue(state.hasChanges, "an untracked file is not an unchanged one")
    }

    /// Staging doesn't change the answer: the tree and a ⌘-clicked path are
    /// asking "what has happened to this file since the last commit", which is
    /// both sides at once.
    func testWorkingTreeStateCountsStagedChanges() async {
        repo = GitFixture.newRepo("staged")
        GitFixture.sh("printf 'one\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'two\n' >> a.txt && git add a.txt", in: repo)

        let state = await GitService.workingTreeState(root: repo.path, path: "a.txt")
        XCTAssertEqual(state, .changed)
    }

    /// The bug this pair exists for, stated as git's own behaviour: the diff
    /// against HEAD is empty for a file git has never seen, and the /dev/null
    /// diff is what actually shows it.
    func testUntrackedFileHasNoDiffAgainstHeadButDoesAgainstNothing() async {
        repo = GitFixture.newRepo("untracked-diff")
        GitFixture.sh("printf 'one\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'hello\nworld\n' > fresh.txt", in: repo)

        let againstHead = await GitService.diffAgainstHead(root: repo.path, path: "fresh.txt")
        XCTAssertTrue(againstHead.isEmpty, "git has nothing to say about a file it never saw")

        let againstNothing = await GitService.untrackedDiff(root: repo.path, path: "fresh.txt")
        let added = DiffParser.parse(againstNothing).lines.filter { $0.kind == .addition }
        XCTAssertEqual(added.map(\.text), ["hello", "world"],
                       "an untracked file reads as all additions")
    }

    /// Everything since the last commit, both sides together — the question the
    /// file tree is asking, where the staged/unstaged split has no meaning.
    func testDiffAgainstHeadIncludesStagedAndUnstagedTogether() async {
        repo = GitFixture.newRepo("both-sides")
        GitFixture.sh("printf 'one\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'staged\n' >> a.txt && git add a.txt", in: repo)
        GitFixture.sh("printf 'unstaged\n' >> a.txt", in: repo)

        let patch = await GitService.diffAgainstHead(root: repo.path, path: "a.txt")
        let added = DiffParser.parse(patch).lines.filter { $0.kind == .addition }.map(\.text)
        XCTAssertEqual(added, ["staged", "unstaged"])
    }

    /// Wortel runs git in any folder a terminal reports, and a repository's own
    /// config can name a program for git to run on a diff. Every diff Wortel
    /// shows must be git's own, with none of those programs started: each kind
    /// of driver is configured here, pointed at a script that leaves a mark.
    func testNoDiffRunsAProgramTheRepositoryNames() async {
        repo = GitFixture.newRepo("diff-drivers")
        let script = repo.appendingPathComponent("driver.sh")
        let mark = repo.appendingPathComponent("ran")
        try? "#!/bin/sh\necho \"$*\" >> '\(mark.path)'\necho DRIVER\n"
            .write(to: script, atomically: true, encoding: .utf8)
        GitFixture.sh("chmod +x driver.sh && printf 'driver.sh\\nran\\n' > .git/info/exclude", in: repo)
        GitFixture.sh("printf '*.txt diff=evil\\n' > .gitattributes "
                      + "&& printf 'one\\n' > a.txt && git add -A && git commit -q -m first "
                      + "&& printf 'two\\n' > a.txt && git commit -q -am second", in: repo)
        GitFixture.sh("printf 'staged\\n' >> a.txt && git add a.txt "
                      + "&& printf 'unstaged\\n' >> a.txt && printf 'new\\n' > fresh.txt", in: repo)
        let quoted = GitFixture.shellQuoted(script.path)
        GitFixture.sh("git config diff.external \(quoted) "
                      + "&& git config diff.evil.command \(quoted) "
                      + "&& git config diff.evil.textconv \(quoted)", in: repo)
        let head = GitFixture.sh("git rev-parse HEAD", in: repo)

        let patches = [
            await GitService.commitDiff(root: repo.path, sha: head),
            await GitService.commitFileDiff(root: repo.path, sha: head, path: "a.txt",
                                            originalPath: nil),
            await GitService.diffAgainstHead(root: repo.path, path: "a.txt"),
            await GitService.diff(root: repo.path, change: GitFileChange(
                path: "a.txt", originalPath: nil, statusCode: "M", staged: true, untracked: false)),
            await GitService.diff(root: repo.path, change: GitFileChange(
                path: "a.txt", originalPath: nil, statusCode: "M", staged: false, untracked: false)),
            await GitService.untrackedDiff(root: repo.path, path: "fresh.txt"),
            await GitService.stagedDiff(root: repo.path)?.patch ?? "",
        ]
        let files = await GitService.commitFiles(root: repo.path, sha: head)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path),
                       "a diff ran the repository's program: "
                       + ((try? String(contentsOf: mark, encoding: .utf8)) ?? ""))
        for patch in patches {
            XCTAssertTrue(patch.contains("diff --git"), "git's own diff, got: \(patch)")
            XCTAssertFalse(patch.contains("DRIVER"))
        }
        XCTAssertEqual(files.map(\.path), ["a.txt"])
        XCTAssertEqual(files.first?.additions, 1)
    }

    /// The same for signatures: a repository can turn `log.showSignature` on
    /// and name its own `gpg.program`, and then every `log` and `show` starts it
    /// for a signed commit. The commit here carries a signature header written
    /// by hand, which is all git needs to try to verify it.
    func testHistoryNeverRunsTheRepositorysSignatureProgram() async {
        repo = GitFixture.newRepo("signatures")
        let script = repo.appendingPathComponent("gpg.sh")
        let mark = repo.appendingPathComponent("ran")
        try? "#!/bin/sh\necho \"$*\" >> '\(mark.path)'\ncat > /dev/null\n"
            .write(to: script, atomically: true, encoding: .utf8)
        GitFixture.sh("chmod +x gpg.sh && printf 'gpg.sh\\nran\\n' > .git/info/exclude", in: repo)
        GitFixture.sh("""
            printf 'one\\n' > a.txt && git add a.txt && tree=$(git write-tree) && \
            commit=$(printf 'tree %s\\nauthor t <t@t> 1700000000 +0000\\ncommitter t <t@t> 1700000000 +0000\\ngpgsig -----BEGIN PGP SIGNATURE-----\\n \\n abc\\n -----END PGP SIGNATURE-----\\n\\nsigned\\n' "$tree" \
              | git hash-object -t commit -w --stdin) && git update-ref refs/heads/main "$commit"
            """, in: repo)
        GitFixture.sh("git config log.showSignature true && git config gpg.program "
                      + GitFixture.shellQuoted(script.path), in: repo)
        // The fixture is sound: plain git does run it.
        GitFixture.sh("git log -n 1 --format=%s", in: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path))
        try? FileManager.default.removeItem(at: mark)

        let commits = await GitService.log(root: repo.path, limit: 10)
        let subjects = await GitService.recentCommitSubjects(root: repo.path)
        let patch = await GitService.commitDiff(root: repo.path, sha: commits.first?.sha ?? "HEAD")

        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path),
                       "git ran the repository's gpg.program")
        XCTAssertEqual(commits.map(\.subject), ["signed"])
        XCTAssertEqual(subjects, ["signed"])
        XCTAssertTrue(patch.contains("+one"))
    }

    /// A path outside the repo, a repo with no commits, a deleted file: none of
    /// these should throw or hang a window that is only asking which view to open
    /// on.
    func testWorkingTreeStateOnAwkwardInput() async {
        repo = GitFixture.newRepo("awkward")

        // No commits at all yet — `status` still answers.
        GitFixture.sh("printf 'x\n' > a.txt", in: repo)
        let beforeAnyCommit = await GitService.workingTreeState(root: repo.path, path: "a.txt")
        XCTAssertEqual(beforeAnyCommit, .untracked)

        GitFixture.sh("git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("rm a.txt", in: repo)
        let deleted = await GitService.workingTreeState(root: repo.path, path: "a.txt")
        XCTAssertEqual(deleted, .changed, "a deleted file has changed")

        let absent = await GitService.workingTreeState(root: repo.path, path: "never-existed.txt")
        XCTAssertEqual(absent, .unchanged)
    }

    // MARK: - Worktrees

    /// Against real git: a worktree on a new branch, listed back, then removed.
    /// The parse is unit-tested separately; this pins that the commands we build
    /// are the ones git actually accepts.
    func testAddListAndRemoveAWorktree() async {
        repo = GitFixture.newRepo("worktree")
        GitFixture.sh("printf 'one\\n' > a.txt && git add -A && git commit -q -m first", in: repo)

        let path = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        let failure = await GitService.addWorktree(
            root: repo.path, at: path, branch: "feature/x", source: .newBranch(from: "HEAD"))
        XCTAssertNil(failure, "git refused: \(failure ?? "")")

        let trees = await GitService.worktrees(root: repo.path)
        XCTAssertEqual(trees.count, 2)
        XCTAssertTrue(trees[0].isPrimary)
        XCTAssertEqual(trees.first(where: { !$0.isPrimary })?.branch, "feature/x")
        // The branch is really checked out there, not just registered.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"))

        let removal = await GitService.removeWorktree(root: repo.path, at: path)
        XCTAssertNil(removal)
        let after = await GitService.worktrees(root: repo.path)
        XCTAssertEqual(after.count, 1)
    }

    /// One branch, two worktrees is what git refuses — and the reason the
    /// session path looks for an existing worktree before creating one.
    func testABranchCannotBeCheckedOutTwice() async {
        repo = GitFixture.newRepo("worktree-twice")
        GitFixture.sh("printf 'one\\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        let base = repo.deletingLastPathComponent()

        let first = base.appendingPathComponent("wt1-\(UUID().uuidString)").path
        let firstFailure = await GitService.addWorktree(
            root: repo.path, at: first, branch: "shared", source: .newBranch(from: "HEAD"))
        XCTAssertNil(firstFailure)

        let second = base.appendingPathComponent("wt2-\(UUID().uuidString)").path
        let failure = await GitService.addWorktree(
            root: repo.path, at: second, branch: "shared", source: .existingBranch)
        XCTAssertNotNil(failure, "git allowed one branch in two worktrees")
        // The message names where it already is, which is why it's shown verbatim.
        XCTAssertTrue(failure?.contains(first) == true, failure ?? "")

        _ = await GitService.removeWorktree(root: repo.path, at: first)
    }

    /// A worktree with uncommitted work is not removed. That refusal is the
    /// safety in "remove worktree" being a menu item rather than a side effect
    /// of closing a session.
    func testWorktreeWithChangesIsNotRemoved() async {
        repo = GitFixture.newRepo("worktree-dirty")
        GitFixture.sh("printf 'one\\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        let path = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        let added = await GitService.addWorktree(
            root: repo.path, at: path, branch: "dirty", source: .newBranch(from: "HEAD"))
        XCTAssertNil(added)

        GitFixture.sh("printf 'uncommitted\\n' >> a.txt", in: URL(fileURLWithPath: path))
        let refusal = await GitService.removeWorktree(root: repo.path, at: path)
        XCTAssertNotNil(refusal, "git removed a worktree containing uncommitted work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"))

        GitFixture.sh("git checkout -- a.txt", in: URL(fileURLWithPath: path))
        _ = await GitService.removeWorktree(root: repo.path, at: path)
    }

    /// A freshly `git init`ed repository has no commits, so HEAD points at a
    /// branch that does not exist. Handing that HEAD to `worktree add` as a base
    /// fails with `invalid reference: HEAD` — which is what "git init, then open
    /// a session on a branch" did.
    func testWorktreeInARepositoryWithNoCommits() async {
        repo = GitFixture.newRepo("unborn")
        let hasCommits = await GitService.hasCommits(root: repo.path)
        XCTAssertFalse(hasCommits, "a fresh init has no commits")

        let path = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        // Asking for HEAD is the bug, kept here so the fix can't quietly regress.
        let withHead = await GitService.addWorktree(
            root: repo.path, at: path, branch: "first", source: .newBranch(from: "HEAD"))
        XCTAssertNotNil(withHead)
        XCTAssertTrue(withHead?.contains("HEAD") == true, withHead ?? "")

        // Without a base, git infers an orphan branch — the right answer for the
        // first branch in an empty repository.
        let orphan = await GitService.addWorktree(
            root: repo.path, at: path, branch: "first", source: .newBranch(from: nil))
        XCTAssertNil(orphan, "git refused an orphan worktree: \(orphan ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        _ = await GitService.removeWorktree(root: repo.path, at: path)
    }

    func testHasCommitsBecomesTrueAfterTheFirstOne() async {
        repo = GitFixture.newRepo("first-commit")
        var has = await GitService.hasCommits(root: repo.path)
        XCTAssertFalse(has)
        GitFixture.commit("first", in: repo)
        has = await GitService.hasCommits(root: repo.path)
        XCTAssertTrue(has)
    }

    /// A worktree whose directory was deleted by hand stays registered, and the
    /// next `add` for that branch fails on a directory nobody can see. Adding
    /// prunes first.
    func testStaleWorktreeRecordDoesNotBlockANewOne() async {
        repo = GitFixture.newRepo("stale")
        GitFixture.sh("printf 'one\\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        let path = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path

        let added = await GitService.addWorktree(
            root: repo.path, at: path, branch: "recycled", source: .newBranch(from: "HEAD"))
        XCTAssertNil(added)
        try? FileManager.default.removeItem(atPath: path) // deleted behind git's back

        let again = await GitService.addWorktree(
            root: repo.path, at: path, branch: "recycled", source: .existingBranch)
        XCTAssertNil(again, "a stale record blocked reuse: \(again ?? "")")
        _ = await GitService.removeWorktree(root: repo.path, at: path)
    }

    /// `rev-parse --show-toplevel` run inside a linked worktree answers with
    /// *that worktree's* path, not the repository's — so anything deriving a
    /// repo identity from it is wrong the moment it runs in a worktree. The
    /// listing is the reliable source: the primary tree is always first.
    func testPrimaryWorktreeIsFoundFromInsideALinkedOne() async {
        repo = GitFixture.newRepo("from-linked")
        GitFixture.sh("printf 'one\\n' > a.txt && git add -A && git commit -q -m first", in: repo)
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        let added = await GitService.addWorktree(
            root: repo.path, at: linked, branch: "linked", source: .newBranch(from: "HEAD"))
        XCTAssertNil(added)

        // Resolved on both sides: git reports real paths, and on macOS /var is
        // a symlink to /private/var — the same trap the worktree-ownership check
        // has to avoid.
        func resolved(_ path: String?) -> String? {
            path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }

        // What the naive question answers, from inside the worktree.
        let toplevel = await GitService.repoRoot(for: linked)
        XCTAssertEqual(resolved(toplevel), resolved(linked),
                       "show-toplevel answers with the worktree")

        // What the listing answers, asked from the same place.
        let trees = await GitService.worktrees(root: linked)
        XCTAssertEqual(resolved(trees.first(where: { $0.isPrimary })?.path),
                       resolved(repo.path))

        _ = await GitService.removeWorktree(root: repo.path, at: linked)
    }

    /// Where a checkout keeps its git state, which is what the FSEvents watcher
    /// has to cover. A linked worktree's `.git` is a file, and its HEAD and index
    /// live under the primary's `.git/worktrees/<name>` — so *nothing under its
    /// own work tree moves when you stage or commit there*, and a watch rooted at
    /// the work tree sees none of it. That's the whole reason this exists; the
    /// commit below is the proof, asserted against the file that actually moved.
    func testExternalGitDirCoversWhatAWorktreeCommitTouches() async {
        repo = GitFixture.newRepo("gitdir")
        GitFixture.commit("first", in: repo)

        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        // The primary holds its `.git` inside the work tree: nothing extra.
        let primary = await GitService.externalGitDir(root: repo.path)
        XCTAssertNil(primary, "the primary checkout's git dir is already watched")

        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        let added = await GitService.addWorktree(
            root: repo.path, at: linked, branch: "linked", source: .newBranch(from: "HEAD"))
        XCTAssertNil(added)

        guard let gitDir = await GitService.externalGitDir(root: linked) else {
            return XCTFail("a linked worktree's git dir is outside its work tree")
        }
        XCTAssertFalse(resolved(gitDir).hasPrefix(resolved(linked) + "/"),
                       "if it were inside the work tree the root watch would cover it")

        // Commit in the worktree, and check the index it wrote is the one we
        // just said we'd watch — not something under the work tree.
        let tree = URL(fileURLWithPath: linked)
        GitFixture.sh("printf 'work\\n' >> a.txt", in: tree)
        GitFixture.sh("git add a.txt && git commit -q -m 'in the worktree'", in: tree)
        let index = (gitDir as NSString).appendingPathComponent("index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index),
                      "the worktree's index is what a commit there rewrites")

        _ = await GitService.removeWorktree(root: repo.path, at: linked)
    }

    // MARK: - Bulk mutations

    private func change(_ path: String, staged: Bool, untracked: Bool = false) -> GitFileChange {
        GitFileChange(path: path, originalPath: nil,
                      statusCode: untracked ? "?" : "M", staged: staged, untracked: untracked)
    }

    /// The three kinds of discard are not interchangeable, and mixing them up is
    /// quiet in both directions: `clean` on a tracked path does nothing and
    /// leaves the edit sitting there, `restore` on an untracked file fails with
    /// "pathspec did not match" while the row disappears from the list anyway on
    /// the next status. Both look exactly like a discard that worked.
    func testDiscardGroupsEachKindIntoItsOwnCommand() {
        let commands = GitService.discardCommands(for: [
            change("staged.txt", staged: true),
            change("edited.txt", staged: false),
            change("new.txt", staged: false, untracked: true),
            change("also-staged.txt", staged: true),
        ])

        XCTAssertEqual(commands.count, 3, "one git per kind, not one per file")
        XCTAssertEqual(commands[0].arguments,
                       ["restore", "--staged", "--worktree", "--source=HEAD", "--"])
        XCTAssertEqual(commands[0].paths, ["staged.txt", "also-staged.txt"])
        XCTAssertEqual(commands[1].arguments, ["restore", "--"])
        XCTAssertEqual(commands[1].paths, ["edited.txt"])
        XCTAssertEqual(commands[2].arguments, ["clean", "-f", "--"])
        XCTAssertEqual(commands[2].paths, ["new.txt"])
    }

    /// An untracked file is untracked whichever section it was clicked in, and
    /// `restore` has nothing to restore it from.
    func testAnUntrackedFileIsNeverRestored() {
        let commands = GitService.discardCommands(for: [
            change("new.txt", staged: true, untracked: true),
        ])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, ["clean", "-f", "--"])
    }

    func testDiscardingNothingRunsNothing() {
        XCTAssertTrue(GitService.discardCommands(for: []).isEmpty)
    }

    /// Select All on a repo with an unignored build directory is thousands of
    /// rows. An argv past ARG_MAX doesn't come back as a git error, it comes back
    /// as a spawn failure with nothing done, so the split is by bytes.
    func testPathsAreChunkedToFitAnArgumentList() {
        let paths = (0..<500).map { "src/some/deep/directory/file-\($0).swift" }
        let chunks = GitService.chunked(paths, budget: 1024)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap { $0 }, paths, "every path survives, in order")
        for chunk in chunks {
            let size = chunk.reduce(0) { $0 + $1.utf8.count + 1 }
            XCTAssertLessThanOrEqual(size - (chunk.last!.utf8.count + 1), 1024)
        }
    }

    /// A single path over the whole budget still has to be run rather than
    /// silently dropped, which is the one thing a chunker must not do.
    func testAnOversizedPathStillGetsItsOwnChunk() {
        let long = String(repeating: "x", count: 4096)
        let chunks = GitService.chunked(["a.txt", long, "b.txt"], budget: 64)
        XCTAssertEqual(chunks.flatMap { $0 }, ["a.txt", long, "b.txt"])
    }

    func testChunkingNothingProducesNoCommands() {
        XCTAssertTrue(GitService.chunked([]).isEmpty)
    }

    /// The end-to-end shape: one confirmation, a mixed selection, and every kind
    /// actually gone afterwards.
    func testDiscardingAMixedSelectionRevertsAndDeletesInOneGo() async {
        repo = GitFixture.newRepo("bulk-discard")
        GitFixture.sh("printf 'one\\n' > a.txt && printf 'two\\n' > b.txt", in: repo)
        GitFixture.sh("git add -A && git commit -q -m first", in: repo)
        GitFixture.sh("printf 'edit\\n' >> a.txt", in: repo)
        GitFixture.sh("printf 'edit\\n' >> b.txt && git add b.txt", in: repo)
        GitFixture.sh("printf 'new\\n' > c.txt", in: repo)

        let status = await GitService.status(root: repo.path)
        XCTAssertEqual(status.changes.count, 3)

        let result = await GitService.discard(root: repo.path, changes: status.changes)
        XCTAssertTrue(result.ok, result.stderr)

        let after = await GitService.status(root: repo.path)
        XCTAssertTrue(after.isClean, "every kind of change was discarded: \(after.changes)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repo.appendingPathComponent("c.txt").path),
            "an untracked file has no earlier version, so discarding it deletes it")
        XCTAssertEqual(GitFixture.sh("cat b.txt", in: repo), "two",
                       "a staged edit goes back to HEAD, index and worktree both")
    }

    /// A path is a path. `app/[id]/x.txt` is a character class to git unless
    /// told otherwise, and would take `app/i/x.txt` with it.
    func testDiscardingABracketedPathLeavesItsGlobMatchesAlone() async {
        repo = GitFixture.newRepo("literal-pathspec")
        GitFixture.sh("mkdir -p 'app/[id]' app/i && printf 'one\\n' > 'app/[id]/t.txt' && printf 'one\\n' > app/i/t.txt", in: repo)
        GitFixture.sh("git add -A && git commit -q -m first", in: repo)
        // Tracked edits in both, untracked files in both.
        GitFixture.sh("printf 'edit\\n' >> 'app/[id]/t.txt' && printf 'edit\\n' >> app/i/t.txt", in: repo)
        GitFixture.sh("printf 'new\\n' > 'app/[id]/u.txt' && printf 'new\\n' > app/i/u.txt", in: repo)

        let status = await GitService.status(root: repo.path)
        let bracketed = status.changes.filter { $0.path.hasPrefix("app/[id]/") }
        XCTAssertEqual(bracketed.count, 2)

        let result = await GitService.discard(root: repo.path, changes: bracketed)
        XCTAssertTrue(result.ok, result.stderr)

        XCTAssertEqual(GitFixture.sh("cat app/i/t.txt", in: repo), "one\nedit",
                       "the edit in the file that only matched as a glob is still there")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("app/i/u.txt").path),
                      "the untracked file that only matched as a glob was not deleted")
        XCTAssertEqual(GitFixture.sh("cat 'app/[id]/t.txt'", in: repo), "one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("app/[id]/u.txt").path))
    }

    /// One `.gitignore` write for the whole selection. A write per entry would
    /// race itself: each one reads the file, appends its line and writes the
    /// whole thing back, so the last one to land is the only entry that survives.
    func testIgnoringASelectionAppendsEveryEntry() async {
        repo = GitFixture.newRepo("bulk-ignore")
        GitFixture.sh("printf 'existing\\n' > .gitignore", in: repo)

        await GitService.addToGitignore(root: repo.path, paths: ["build", "dist/out.js"])

        let contents = GitFixture.sh("cat .gitignore", in: repo)
        XCTAssertEqual(contents, "existing\n/build\n/dist/out.js")
    }
}
