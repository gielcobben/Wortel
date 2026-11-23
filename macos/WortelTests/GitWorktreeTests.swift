import XCTest

/// Worktree paths, the sidebar name a branch turns into, and the listing parse
/// — the pieces of the feature that are string handling, and whose failures are
/// silent: a slug that collides puts two branches in one directory, a branch
/// dropped into a name whole invents a sidebar folder, and a stanza parsed wrong
/// hides an existing worktree so the next attempt tries to create it again.
final class GitWorktreeTests: XCTestCase {
    // MARK: - Slugs

    /// A name that is already a safe path component is used as it is — branch
    /// names are unique, so those can never collide with each other.
    func testSimpleBranchIsItsOwnSlug() {
        XCTAssertEqual(GitWorktree.slug(forBranch: "main"), "main")
        XCTAssertEqual(GitWorktree.slug(forBranch: "feature-x"), "feature-x")
    }

    /// One that had to be rewritten carries a digest of the original, because
    /// the rewrite is what destroys the distinction between two branches.
    func testRewrittenBranchKeepsAReadableStem() {
        let slug = GitWorktree.slug(forBranch: "feature/preview-window")
        XCTAssertTrue(slug.hasPrefix("feature-preview-window-"), slug)
    }

    /// The digest has to survive a relaunch, so it cannot be `hashValue`, which
    /// is seeded per process.
    func testSlugIsStableAcrossRuns() {
        XCTAssertEqual(GitWorktree.slug(forBranch: "feature/x"), "feature-x-73876a")
    }

    /// The property that matters is that different branches stay different.
    /// `feature/x` and `feature-x` can both exist, and a slug that dropped the
    /// separator would give them one directory and one checkout.
    func testDifferentBranchesGetDifferentSlugs() {
        let names = ["feature/x", "feature-x", "feature_x", "feature.x", "Feature/X"]
        let slugs = Set(names.map(GitWorktree.slug(forBranch:)))
        XCTAssertEqual(slugs.count, names.count, "two branches collapsed onto one directory")
    }

    func testAwkwardCharactersBecomeSeparators() {
        XCTAssertTrue(GitWorktree.slug(forBranch: "fix/#123 crash").hasPrefix("fix-123-crash-"))
        XCTAssertTrue(GitWorktree.slug(forBranch: "spaced   out").hasPrefix("spaced-out-"))
    }

    /// A slug is a path component, so it must not start or end with the
    /// characters that make one awkward — and must never be empty.
    func testSlugIsAlwaysAUsablePathComponent() {
        for branch in ["/leading", "trailing/", "///", "", "-dashed", "dotted."] {
            let slug = GitWorktree.slug(forBranch: branch)
            XCTAssertFalse(slug.isEmpty)
            XCTAssertFalse(slug.hasPrefix("-") || slug.hasPrefix("."), slug)
            XCTAssertFalse(slug.contains("/"), slug)
        }
    }

    // MARK: - Paths

    /// Grouped by repository, so two projects with a `main` branch don't land in
    /// the same directory.
    func testPathGroupsByRepository() {
        let a = GitWorktree.path(forBranch: "main", repoRoot: "/Users/x/Developer/wortel")
        let b = GitWorktree.path(forBranch: "main", repoRoot: "/Users/x/Developer/lijn")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix("/wortel/main"), a)
        XCTAssertTrue(b.hasSuffix("/lijn/main"), b)
    }

    /// Outside the repository — a worktree inside it would be committable, would
    /// confuse anything that walks the project, and would vanish with it.
    func testPathIsOutsideTheRepository() {
        let path = GitWorktree.path(forBranch: "x", repoRoot: "/Users/x/Developer/wortel")
        XCTAssertFalse(path.hasPrefix("/Users/x/Developer/wortel"))
        XCTAssertTrue(path.hasPrefix(GitWorktree.root.path))
    }

    // MARK: - Parsing

    /// The real shape of `git worktree list --porcelain`: stanzas separated by
    /// blank lines, the first being the repository's own working tree.
    func testParsesPrimaryAndLinkedWorktrees() {
        let porcelain = """
        worktree /Users/x/Developer/wortel
        HEAD 4bd0b1e0dcbaa3fbcbd0e14a72e0d7ee2ba7e0d1
        branch refs/heads/main

        worktree /Users/x/.wortel/worktrees/wortel/feature-x
        HEAD 9e1c0a1e0dcbaa3fbcbd0e14a72e0d7ee2ba7e0d
        branch refs/heads/feature/x

        """
        let trees = GitWorktree.parse(porcelain: porcelain)
        XCTAssertEqual(trees.count, 2)
        XCTAssertEqual(trees[0], GitWorktree(
            path: "/Users/x/Developer/wortel", branch: "main", isPrimary: true,
            head: "4bd0b1e0dcbaa3fbcbd0e14a72e0d7ee2ba7e0d1"))
        XCTAssertEqual(trees[1].branch, "feature/x", "the branch, not its slug")
        XCTAssertFalse(trees[1].isPrimary)
    }

    /// A detached worktree has no branch line at all. It must still be listed —
    /// it occupies a directory, and forgetting it means trying to reuse one.
    func testDetachedWorktreeHasNoBranch() {
        let porcelain = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /elsewhere
        HEAD def
        detached
        """
        let trees = GitWorktree.parse(porcelain: porcelain)
        XCTAssertEqual(trees.count, 2)
        XCTAssertNil(trees[1].branch)
    }

    func testEmptyListingParsesToNothing() {
        XCTAssertTrue(GitWorktree.parse(porcelain: "").isEmpty)
    }

    /// Only the first stanza is the primary tree, however many follow.
    func testOnlyTheFirstIsPrimary() {
        let porcelain = (0..<3).map { "worktree /w\($0)\nHEAD a\nbranch refs/heads/b\($0)" }
            .joined(separator: "\n\n")
        let trees = GitWorktree.parse(porcelain: porcelain)
        XCTAssertEqual(trees.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(trees.map(\.branch), ["b0", "b1", "b2"])
    }

    // MARK: - The sidebar name a branch turns into

    /// Wortel's own namespace is on every branch it generates, so in a sidebar
    /// where every one of these rows carries it, it says nothing.
    func testGeneratedBranchLosesWortelsOwnNamespace() {
        XCTAssertEqual(
            GitWorktree.sessionLeaf(forBranch: "worktree/brave-river-1a2f"),
            "brave-river-1a2f")
    }

    /// A namespace you chose yourself is the half that says what the branch is
    /// for, so it stays — with the one slash it contains swapped for the
    /// lookalike that is not a folder separator.
    func testYourOwnNamespaceIsKeptButCannotMakeAFolder() {
        XCTAssertEqual(GitWorktree.sessionLeaf(forBranch: "fix/login"), "fix\u{2215}login")
        XCTAssertNil(SessionName.folder(of: GitWorktree.sessionLeaf(forBranch: "fix/login")))
    }

    func testBranchWithNoNamespaceIsItsOwnLeaf() {
        XCTAssertEqual(GitWorktree.sessionLeaf(forBranch: "main"), "main")
    }

    /// A branch that is nothing but the namespace has no leaf to show, and an
    /// empty sidebar row is worse than a redundant one.
    func testBareNamespaceFallsBackToTheWholeBranch() {
        XCTAssertEqual(GitWorktree.sessionLeaf(forBranch: "worktree/"), "worktree\u{2215}")
    }

    /// The whole point: what goes in a name can never be read back as a folder.
    func testNoBranchCanInventAFolder() {
        for branch in ["worktree/brave-river-1a2f", "fix/login", "a/b/c", "main", "worktree/"] {
            let name = "Acme/" + GitWorktree.sessionLeaf(forBranch: branch)
            XCTAssertEqual(SessionName.folder(of: name), "Acme", branch)
        }
    }

    // MARK: - Undoing the folder an earlier build invented

    /// The real thing this was written for: two sessions sitting in a folder
    /// called "Acme/worktree" beside the Acme they belong to.
    func testTheInventedFolderIsStrippedFromTheName() {
        XCTAssertEqual(
            GitWorktree.repairedSessionName(
                "Acme/worktree/menubar-demo", branch: "worktree/menubar-slide"),
            "Acme/menubar-demo")
    }

    /// A worktree session that was never in a folder ends up at the top level,
    /// not in one called "worktree".
    func testATopLevelWorktreeSessionLosesItsFolderEntirely() {
        XCTAssertEqual(
            GitWorktree.repairedSessionName("worktree/dvd-screensaver-icon",
                                            branch: "worktree/app-ios-icon"),
            "dvd-screensaver-icon")
    }

    /// Only the branch's own namespace, and only off the end. A folder someone
    /// deliberately named this is somebody's project, not our bookkeeping.
    func testAnUnrelatedFolderIsLeftAlone() {
        XCTAssertNil(GitWorktree.repairedSessionName(
            "Acme/menubar-demo", branch: "worktree/menubar-slide"))
        XCTAssertNil(GitWorktree.repairedSessionName(
            "worktree extras/thing", branch: "worktree/x"))
        XCTAssertNil(GitWorktree.repairedSessionName(
            "Acme/worktree/thing", branch: "main"), "a branch with no namespace")
        XCTAssertNil(GitWorktree.repairedSessionName("Acme", branch: "worktree/x"),
                     "no folder half at all")
    }

    /// Branch namespaces nest, and so does the folder one of them invented.
    func testAMultiLevelNamespaceComesOffWhole() {
        XCTAssertEqual(
            GitWorktree.repairedSessionName("Acme/a/b/thing", branch: "a/b/c"),
            "Acme/thing")
    }

    /// It runs on every launch, so the second one must find nothing to do.
    func testRepairIsIdempotent() {
        let once = GitWorktree.repairedSessionName(
            "Acme/worktree/menubar-demo", branch: "worktree/menubar-slide")
        XCTAssertEqual(once, "Acme/menubar-demo")
        XCTAssertNil(GitWorktree.repairedSessionName(once!, branch: "worktree/menubar-slide"))
    }

    // MARK: - Typed branch names

    /// The case that failed: a space, which git refuses outright.
    func testASpaceBecomesADash() {
        XCTAssertEqual(GitWorktree.branchName(from: "worktree/Jump to"), "worktree/Jump-to")
        XCTAssertEqual(GitWorktree.branchName(from: "  fix   the  login "), "fix-the-login")
    }

    /// Every character `git check-ref-format` forbids, and the places it
    /// forbids others.
    func testWhatGitForbidsIsMadeValid() {
        XCTAssertEqual(GitWorktree.branchName(from: "a~b^c:d?e*f[g\\h"), "a-b-c-d-e-f-g-h")
        XCTAssertEqual(GitWorktree.branchName(from: "a..b"), "a-b")
        XCTAssertEqual(GitWorktree.branchName(from: "a@{b"), "a-b")
        XCTAssertEqual(GitWorktree.branchName(from: "feature//x/"), "feature/x")
        XCTAssertEqual(GitWorktree.branchName(from: "worktree/.hidden"), "worktree/hidden")
        XCTAssertEqual(GitWorktree.branchName(from: "thing.lock"), "thing")
        XCTAssertEqual(GitWorktree.branchName(from: "-leading"), "leading")
        XCTAssertEqual(GitWorktree.branchName(from: "trailing."), "trailing")
        XCTAssertEqual(GitWorktree.branchName(from: "@"), "")
        XCTAssertEqual(GitWorktree.branchName(from: "   "), "")
    }

    /// A good name is left exactly as typed, case and all.
    func testAValidNameIsUntouched() {
        for name in ["main", "worktree/calm-river-1a2f", "Someone/Mode_Toolbar.v2", "fix/1482"] {
            XCTAssertEqual(GitWorktree.branchName(from: name), name)
        }
    }

    /// Git is the oracle: whatever comes out, it accepts.
    func testGitAcceptsEveryResult() {
        let typed = ["worktree/Jump to", "a~b^c", "x..y", "a@{b", ".dot/.dot", "end.lock",
                     "-x", "y.", "tab\there", "emoji 🌱 name", "a//b", "über branch"]
        for input in typed {
            let name = GitWorktree.branchName(from: input)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["check-ref-format", "--branch", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(input) → \(name)")
        }
    }

    // MARK: - The checkout a directory is in

    /// However deep the shell has gone, the checkout is the directory Wortel
    /// made: the row's label is about the worktree, not the prompt.
    func testCheckoutIsTheWorktreeDirectoryAtAnyDepth() {
        let base = "/Users/x/.wortel/worktrees"
        XCTAssertEqual(GitWorktree.checkout(containing: "\(base)/wortel/fix-1", under: base), "\(base)/wortel/fix-1")
        XCTAssertEqual(GitWorktree.checkout(containing: "\(base)/wortel/fix-1/macos/Wortel", under: base),
                       "\(base)/wortel/fix-1")
    }

    func testNoCheckoutOutsideTheWorktrees() {
        let base = "/Users/x/.wortel/worktrees"
        XCTAssertNil(GitWorktree.checkout(containing: nil, under: base))
        XCTAssertNil(GitWorktree.checkout(containing: "/Users/x/Developer/wortel", under: base))
        // The repository's folder holds checkouts; it isn't one.
        XCTAssertNil(GitWorktree.checkout(containing: "\(base)/wortel", under: base))
        XCTAssertNil(GitWorktree.checkout(containing: base, under: base))
        // A sibling whose name merely starts the same.
        XCTAssertNil(GitWorktree.checkout(containing: "/Users/x/.wortel/worktrees-old/a/b", under: base))
    }

    // MARK: - The branch, from the worktree's own files

    /// Read without running git, and the same answer git gives.
    func testCheckedOutBranchIsReadFromTheWorktreesFiles() {
        let repo = GitFixture.newRepo("checked-out")
        defer { GitFixture.destroy(repo) }
        GitFixture.commit("first", in: repo)
        let worktree = repo.appendingPathComponent(".wt")
        GitFixture.sh("git worktree add -q -b feature/x \(worktree.path)", in: repo)
        XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), "feature/x")

        // Detached: no branch to name.
        GitFixture.sh("git checkout -q --detach", in: worktree)
        XCTAssertNil(GitWorktree.checkedOutBranch(at: worktree.path))
        // The primary checkout has a `.git` folder, not a file: not a
        // linked worktree.
        XCTAssertNil(GitWorktree.checkedOutBranch(at: repo.path))
        XCTAssertNil(GitWorktree.checkedOutBranch(at: "/nonexistent"))
    }

    /// What the git panel asks to tell "another worktree of this project"
    /// (stay on the session's own) from "another project" (follow the shell):
    /// every checkout of a repository, at any depth, shares one; another
    /// repository, a submodule included, doesn't; outside any, nil.
    func testCommonDirIsSharedByEveryCheckoutOfARepository() {
        let repo = GitFixture.newRepo("common-dir")
        let other = GitFixture.newRepo("common-dir-other")
        defer { GitFixture.destroy(repo); GitFixture.destroy(other) }
        GitFixture.commit("first", in: repo)
        GitFixture.commit("first", in: other)
        GitFixture.sh("mkdir -p sub/deeper", in: repo)
        let worktree = repo.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)")
        defer { GitFixture.destroy(worktree) }
        GitFixture.sh("git worktree add -q -b feature/x \(GitFixture.shellQuoted(worktree.path)) "
                      + "&& mkdir -p \(GitFixture.shellQuoted(worktree.path))/sub", in: repo)

        let common = GitWorktree.commonDir(containing: repo.path)
        XCTAssertNotNil(common)
        XCTAssertEqual(GitWorktree.commonDir(containing: repo.appendingPathComponent("sub/deeper").path), common)
        XCTAssertEqual(GitWorktree.commonDir(containing: worktree.path), common)
        XCTAssertEqual(GitWorktree.commonDir(containing: worktree.appendingPathComponent("sub").path), common)
        XCTAssertNotNil(GitWorktree.commonDir(containing: other.path))
        XCTAssertNotEqual(GitWorktree.commonDir(containing: other.path), common)
        XCTAssertNil(GitWorktree.commonDir(containing: "/"))
    }

    /// A reftable repository's HEAD file is a stub naming `.invalid`; the
    /// branch is read from the table instead, and agrees with git through
    /// switches, a detach, and either hash.
    func testCheckedOutBranchIsReadFromAReftable() {
        for format in ["sha1", "sha256"] {
            let repo = GitFixture.newRepo("reftable-\(format)")
            defer { GitFixture.destroy(repo) }
            GitFixture.sh("rm -rf .git && git init -q -b main --ref-format=reftable --object-format=\(format) "
                          + "&& git config user.email t@t && git config user.name t", in: repo)
            GitFixture.commit("first", in: repo)
            let worktree = repo.appendingPathComponent(".wt")
            GitFixture.sh("git worktree add -q -b feature/x \(worktree.path)", in: repo)
            let gitDir = GitFixture.sh("git rev-parse --absolute-git-dir", in: worktree)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8),
                           "ref: refs/heads/.invalid\n", format)
            XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), "feature/x", format)

            // Each switch writes a new table on the stack until git compacts
            // it; ORIG_HEAD and refs/bisect sit in the same table as HEAD.
            for branch in ["b", "a-much-longer-branch-name/with/slashes", "c"] {
                GitFixture.sh("git switch -q -c \(branch)", in: worktree)
                XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), branch, format)
            }
            GitFixture.sh("git update-ref ORIG_HEAD HEAD && git update-ref refs/bisect/bad HEAD", in: worktree)
            XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), "c", format)
            GitFixture.sh("git checkout -q --detach", in: worktree)
            XCTAssertNil(GitWorktree.checkedOutBranch(at: worktree.path), format)
            GitFixture.sh("git switch -q b", in: worktree)
            XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), "b", format)
            GitFixture.sh("git pack-refs --all", in: worktree)
            XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), "b", format)
        }
    }

    /// A table that doesn't mention HEAD defers to the one before: here the
    /// newest holds only refs/worktree/marker (a switch compacts the stack
    /// even with auto-compaction off, so HEAD is in the older).
    func testReftableReadsTheStackNewestFirst() {
        let repo = GitFixture.newRepo("reftable-stack")
        defer { GitFixture.destroy(repo) }
        GitFixture.sh("rm -rf .git && git init -q -b main --ref-format=reftable "
                      + "&& git config user.email t@t && git config user.name t "
                      + "&& git config reftable.autoCompaction false", in: repo)
        GitFixture.commit("first", in: repo)
        let worktree = repo.appendingPathComponent(".wt")
        GitFixture.sh("git worktree add -q -b one \(worktree.path) && git -C \(worktree.path) switch -q -c two "
                      + "&& git -C \(worktree.path) update-ref refs/worktree/marker HEAD", in: repo)
        let stack = GitFixture.sh("git rev-parse --absolute-git-dir", in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "/reftable"
        let tables = (try? String(contentsOfFile: stack + "/tables.list", encoding: .utf8))?
            .split(separator: "\n") ?? []
        XCTAssertGreaterThanOrEqual(tables.count, 2, "the marker should be a table of its own")
        XCTAssertEqual(Reftable.symbolicTarget(of: "HEAD", inStack: stack), "refs/heads/two")
        XCTAssertEqual(GitWorktree.checkedOutBranch(at: worktree.path), "two")

        // A name past every ref in a table runs off the end of its ref
        // section, into its logs or its footer: not here, not unreadable.
        let contents = tables.map { FileManager.default.contents(atPath: stack + "/" + $0).map { [UInt8]($0) } ?? [] }
        for (table, bytes) in zip(tables, contents) {
            XCTAssertEqual(Reftable.lookup(Array("refs/zzz".utf8), in: bytes), .notHere, String(table))
        }
        // Where the ref section ends in something no table has there, a
        // block boundary was misread, and an older table mustn't be asked.
        guard var newest = contents.last, newest.count > 28 else { return XCTFail("no newest table") }
        // (One ref block, which git leaves unpadded: what follows it starts
        // where it ends.)
        let header = newest[4] == 2 ? 28 : 24
        let end = Int(newest[header + 1]) << 16 | Int(newest[header + 2]) << 8 | Int(newest[header + 3])
        guard end < newest.count, newest[end] != 0 else { return XCTFail("the ref block should be unpadded") }
        newest[end] = UInt8(ascii: "x")
        XCTAssertEqual(Reftable.lookup(Array("refs/zzz".utf8), in: newest), .unreadable)
    }

    /// A table of many blocks (a compacted primary stack, 4 KiB each): a ref
    /// is found in whichever block holds it, and one that sorts between two
    /// others is absent rather than misread. A HEAD lookup never gets past
    /// the first block, but nothing about the reader is specific to HEAD.
    func testReftableFindsRefsPastTheFirstBlock() {
        let repo = GitFixture.newRepo("reftable-blocks")
        defer { GitFixture.destroy(repo) }
        GitFixture.sh("rm -rf .git && git init -q -b main --ref-format=reftable "
                      + "&& git config user.email t@t && git config user.name t", in: repo)
        GitFixture.commit("first", in: repo)
        let creates = (1...2000).map { "create refs/heads/team-\($0)/a-fairly-long-feature-branch-name HEAD" }
        GitFixture.sh("printf '%s\\n' \(creates.map(GitFixture.shellQuoted).joined(separator: " ")) "
                      + "| git update-ref --stdin", in: repo)
        for n in [5, 1000, 1999] {
            GitFixture.sh("git symbolic-ref refs/heads/team-\(n)/zz refs/heads/main", in: repo)
        }
        GitFixture.sh("git pack-refs --all", in: repo)
        let stack = repo.appendingPathComponent(".git/reftable").path
        let table = (try? String(contentsOfFile: stack + "/tables.list", encoding: .utf8))?
            .split(separator: "\n").last.map { stack + "/" + $0 }
        let size = table.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? 0
        XCTAssertGreaterThan(size, 16 * 4096, "should span many blocks")

        for n in [5, 1000, 1999] {
            XCTAssertEqual(Reftable.symbolicTarget(of: "refs/heads/team-\(n)/zz", inStack: stack), "refs/heads/main")
        }
        XCTAssertEqual(Reftable.symbolicTarget(of: "HEAD", inStack: stack), "refs/heads/main")
        let bytes = table.flatMap { FileManager.default.contents(atPath: $0) }.map { [UInt8]($0) } ?? []
        XCTAssertEqual(Reftable.lookup(Array("refs/heads/team-1500/a-fairly-long-feature-branch-name".utf8),
                                       in: bytes), .found(nil))
        XCTAssertEqual(Reftable.lookup(Array("refs/heads/team-1500/b".utf8), in: bytes), .notHere)
        XCTAssertEqual(Reftable.lookup(Array("refs/heads/zzz".utf8), in: bytes), .notHere)
    }

    // MARK: - Linked worktrees, whoever made them

    /// Every layout worktree tools use is recognised from any depth inside it,
    /// and each knows where its repository lives, which is what files it in
    /// the sidebar. Git is the oracle for the paths.
    func testLinkedWorktreeInEveryLayout() {
        let base = GitFixture.newRepo("linked")
        defer { GitFixture.destroy(base) }
        let repo = base.appendingPathComponent("repo")
        GitFixture.sh("git init -q -b main repo", in: base)
        GitFixture.commit("first", in: repo)
        let home = GitWorktree.realPath(repo.path)

        // Beside the repository, inside it, and somewhere else entirely.
        GitFixture.sh("git worktree add -q -b beside ../repo-beside", in: repo)
        GitFixture.sh("git worktree add -q -b inside .worktrees/inside", in: repo)
        GitFixture.sh("git worktree add -q -b far \(base.path)/elsewhere/far", in: repo)
        for (path, _) in [("repo-beside", "beside"), ("repo/.worktrees/inside", "inside"),
                          ("elsewhere/far", "far")] {
            let root = base.appendingPathComponent(path)
            GitFixture.sh("mkdir -p src/deep", in: root)
            for probe in [root.path, root.appendingPathComponent("src/deep").path, root.path + "/"] {
                let linked = GitWorktree.linked(containing: probe)
                XCTAssertEqual(linked?.root, GitWorktree.realPath(root.path), probe)
                XCTAssertEqual(linked?.repoHome, home, probe)
            }
        }
        // The repository's own checkout is not a linked worktree, nor is a
        // folder in it, even one holding the worktrees.
        XCTAssertNil(GitWorktree.linked(containing: repo.path))
        XCTAssertNil(GitWorktree.linked(containing: repo.appendingPathComponent(".worktrees").path))
        XCTAssertNil(GitWorktree.linked(containing: base.path))
        XCTAssertNil(GitWorktree.linked(containing: "/nonexistent/at/all"))
    }

    /// The worktree-first layout: a bare clone in `.bare` beside its
    /// worktrees. The folder holding both is where the repository lives.
    func testLinkedWorktreeOfABareClone() {
        let base = GitFixture.newRepo("bare")
        defer { GitFixture.destroy(base) }
        GitFixture.commit("first", in: base)
        let project = base.appendingPathComponent("project")
        GitFixture.sh("git clone -q --bare . project/.bare", in: base)
        let bare = project.appendingPathComponent(".bare")
        GitFixture.sh("git worktree add -q ../main main", in: bare)
        let linked = GitWorktree.linked(containing: project.appendingPathComponent("main").path)
        XCTAssertEqual(linked?.root, GitWorktree.realPath(project.appendingPathComponent("main").path))
        XCTAssertEqual(linked?.repoHome, GitWorktree.realPath(project.path))

        // A bare clone anywhere else: a worktree still, with no home to name.
        GitFixture.sh("git clone -q --bare . other.git", in: base)
        GitFixture.sh("git worktree add -q ../loose main", in: base.appendingPathComponent("other.git"))
        let loose = GitWorktree.linked(containing: base.appendingPathComponent("loose").path)
        XCTAssertNotNil(loose)
        XCTAssertNil(loose?.repoHome)

        // And git lists the bare entry as such.
        let listing = GitFixture.sh("git worktree list --porcelain", in: bare)
        let parsed = GitWorktree.parse(porcelain: listing)
        XCTAssertEqual(parsed.first?.isBare, true)
        XCTAssertEqual(parsed.dropFirst().map(\.isBare), [false])
    }

    /// A submodule's `.git` is a file too, pointing into `modules/`: a
    /// repository of its own, not a worktree.
    func testSubmoduleIsNotAWorktree() {
        let base = GitFixture.newRepo("submodule")
        defer { GitFixture.destroy(base) }
        let library = base.appendingPathComponent("library")
        GitFixture.sh("git init -q -b main library", in: base)
        GitFixture.commit("lib", in: library)
        let app = base.appendingPathComponent("app")
        GitFixture.sh("git init -q -b main app", in: base)
        GitFixture.commit("app", in: app)
        GitFixture.sh("git -c protocol.file.allow=always submodule add -q ../library vendor/library", in: app)
        XCTAssertNil(GitWorktree.linked(containing: app.appendingPathComponent("vendor/library").path))
    }

    /// A worktree whose folder is gone is listed by git as prunable, and is
    /// no worktree to open.
    func testPrunableIsParsed() {
        let repo = GitFixture.newRepo("prunable")
        defer { GitFixture.destroy(repo) }
        GitFixture.commit("first", in: repo)
        GitFixture.sh("git worktree add -q -b gone ../gone-\(UUID().uuidString)", in: repo)
        let listed = GitWorktree.parse(porcelain: GitFixture.sh("git worktree list --porcelain", in: repo))
        guard let gone = listed.last else { return XCTFail("no worktree") }
        XCTAssertFalse(gone.isPrunable)
        GitFixture.destroy(URL(fileURLWithPath: gone.path))
        let after = GitWorktree.parse(porcelain: GitFixture.sh("git worktree list --porcelain", in: repo))
        XCTAssertEqual(after.map(\.isPrunable), [false, true])
        XCTAssertEqual(after.last?.branch, "gone")
    }
}
