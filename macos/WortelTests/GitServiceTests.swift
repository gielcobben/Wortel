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
}
