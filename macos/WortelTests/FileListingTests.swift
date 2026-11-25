import XCTest

/// Where ⌘P's files come from: git in a repository, Zed's walk elsewhere,
/// and what an event in one folder changes. Each limit of the walk is here,
/// since a walk without them is a walk of the disk.
final class FileListingTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wortel-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        GitFixture.destroy(dir)
    }

    private func touch(_ paths: String...) {
        for path in paths {
            let url = dir.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
    }

    private func walked(maxDepth: Int = FileListing.maxDepth, cap: Int = FileListing.cap) -> FileListing.Walk {
        FileListing.walk(dir.path, maxDepth: maxDepth, cap: cap)
    }

    // MARK: - The walk

    func testItListsFilesAtEveryDepthUpToFive() {
        touch("a.txt", "1/b.txt", "1/2/3/4/five.txt", "1/2/3/4/5/six.txt")
        XCTAssertEqual(Set(walked().files), ["a.txt", "1/b.txt", "1/2/3/4/five.txt"])
    }

    func testItSkipsVersionControlAndDependencyFolders() {
        touch("keep.c", ".svn/x", ".hg/x", ".jj/x", "node_modules/pkg/index.js", ".DS_Store", ".env")
        XCTAssertEqual(Set(walked().files), ["keep.c", ".env"])
    }

    func testItNeverFollowsASymlinkedFolder() throws {
        touch("real/inside.txt")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("wortel-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { GitFixture.destroy(outside) }
        FileManager.default.createFile(atPath: outside.appendingPathComponent("far.txt").path, contents: Data())
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        // A symlink to a file is a file.
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("alias.txt"),
                                                   withDestinationURL: dir.appendingPathComponent("real/inside.txt"))
        XCTAssertEqual(Set(walked().files), ["real/inside.txt", "alias.txt"])
    }

    func testItStopsAtTheCapAndSaysSo() {
        for index in 0..<50 { touch("f\(index).txt") }
        let walk = walked(cap: 10)
        XCTAssertEqual(walk.files.count, 10)
        XCTAssertTrue(walk.truncated)
        XCTAssertFalse(walked().truncated)
    }

    /// A repository inside is git's to list, in full: the walk hands it over.
    func testARepositoryInsideIsHandedToGit() {
        touch("notes.md", "project/deep/1/2/3/4/5/file.c")
        GitFixture.sh("git init -q", in: dir.appendingPathComponent("project"))
        let walk = walked()
        XCTAssertEqual(walk.files, ["notes.md"])
        XCTAssertEqual(walk.repositories, ["project"])
    }

    func testTheDiskIsNeverWalked() {
        let home = "/Users/someone"
        XCTAssertFalse(FileListing.mayWalk("/", home: home))
        XCTAssertFalse(FileListing.mayWalk("/Users", home: home))
        XCTAssertFalse(FileListing.mayWalk(home, home: home))
        XCTAssertFalse(FileListing.mayWalk(home + "/", home: home))
        XCTAssertFalse(FileListing.mayWalk("/Volumes/Backup", home: home))
        XCTAssertTrue(FileListing.mayWalk(home + "/Downloads/project", home: home))
        XCTAssertTrue(FileListing.mayWalk("/Volumes/Backup/project", home: home))
    }

    // MARK: - Git

    /// Tracked and untracked, never ignored, from git's own answers.
    func testGitListsTrackedAndUntrackedButNotIgnored() async {
        GitFixture.sh("git init -q -b main", in: dir)
        touch("tracked.c", "src/kept.h", ".gitignore", "build/out.o", "new.c")
        try? Data("build/\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
        GitFixture.sh("git add tracked.c src/kept.h .gitignore", in: dir)
        let tracked = await GitService.trackedFiles(root: dir.path) ?? Data()
        let untracked = await GitService.untrackedFiles(root: dir.path)
        XCTAssertEqual(FileIndexStore.paths(in: tracked), [".gitignore", "src/kept.h", "tracked.c"])
        XCTAssertEqual(FileIndexStore.paths(in: untracked), ["new.c"])
        // Scoped to a folder.
        touch("src/new.h")
        let scoped = await GitService.untrackedFiles(root: dir.path, under: ["src"])
        XCTAssertEqual(FileIndexStore.paths(in: scoped), ["src/new.h"])
    }

    /// Under the app's `GIT_LITERAL_PATHSPECS`, `check-ignore` refused every
    /// call (2026-11-09 to 2026-11-24), so nothing was ever ignored: the
    /// Files pane didn't grey a build folder, and ⌘P listed its files.
    func testCheckIgnoreAnswers() async {
        GitFixture.sh("git init -q -b main", in: dir)
        try? Data("build/\n*.o\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
        touch("build/sub/a.txt", "src/z.o", "src/keep.c", "app/[id]/page.tsx")
        let ignored = await GitService.checkIgnore(
            root: dir.path, paths: ["build", "build/sub/a.txt", "src/z.o", "src/keep.c", "app/[id]/page.tsx"])
        XCTAssertEqual(ignored, ["build", "build/sub/a.txt", "src/z.o"])
    }

    func testALinkedWorktreeListsItsOwnFiles() async {
        GitFixture.sh("git init -q -b main", in: dir)
        touch("a.c")
        GitFixture.sh("git add a.c && git commit -q -m a && git worktree add -q -b other wt", in: dir)
        touch("wt/b.c")
        GitFixture.sh("git add b.c", in: dir.appendingPathComponent("wt"))
        let tracked = await GitService.trackedFiles(root: dir.appendingPathComponent("wt").path) ?? Data()
        XCTAssertEqual(FileIndexStore.paths(in: tracked), ["a.c", "b.c"])
    }

    // MARK: - What an event in a folder changes

    func testAFolderReadAgainFindsWhatCameAndWent() {
        touch("src/a.c", "src/new.c", "src/added/x.c")
        let index = FileIndex.merging([
            (FileIndex.sorted(["src/a.c", "src/gone.c", "src/old/y.c", "src/old/z.c", "top.c"]), .tracked),
        ])
        let diff = FileIndexStore.difference(of: ["src"], root: dir.path, index: index, missing: [])
        XCTAssertEqual(diff.newFiles, ["src/new.c"])
        XCTAssertEqual(diff.newFolders, ["src/added"])
        XCTAssertEqual(Set(diff.gone), ["src/gone.c", "src/old/y.c", "src/old/z.c"])
        XCTAssertEqual(diff.back, [])
    }

    func testATrackedFileBackOnDiskIsBack() {
        touch("src/a.c")
        let index = FileIndex.merging([(FileIndex.sorted([String]()), .tracked)])
        let diff = FileIndexStore.difference(of: ["src"], root: dir.path, index: index, missing: ["src/a.c"])
        XCTAssertEqual(diff.back, ["src/a.c"])
        XCTAssertEqual(diff.newFiles, [])
    }

    func testAFolderGoneTakesEverythingUnderIt() {
        let index = FileIndex.merging([(FileIndex.sorted(["lib/a.c", "lib/sub/b.c", "other.c"]), .tracked)])
        let diff = FileIndexStore.difference(of: ["lib"], root: dir.path, index: index, missing: [])
        XCTAssertEqual(Set(diff.gone), ["lib/a.c", "lib/sub/b.c"])
    }

    /// What git tracks is compared with everything on disk: a tracked
    /// `node_modules` or `.DS_Store`, a symlink to a folder and a submodule
    /// (a folder on disk, one entry in git's list) are not "deleted", and a
    /// repository made inside isn't a new folder of this one's.
    func testAFolderReadAgainKeepsWhatTheWalkWouldSkip() throws {
        touch("vendor/node_modules/x/index.js", "vendor/.DS_Store", "vendor/lib/sub.c", "vendor/inner/a.c",
              "shared/doc.md")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("vendor/docs"),
                                                   withDestinationURL: dir.appendingPathComponent("shared"))
        GitFixture.sh("git init -q", in: dir.appendingPathComponent("vendor/inner"))
        let index = FileIndex.merging([(FileIndex.sorted([
            "vendor/node_modules/x/index.js", "vendor/.DS_Store", "vendor/docs", "vendor/lib",
        ]), .tracked)])
        let diff = FileIndexStore.difference(of: ["vendor"], root: dir.path, index: index, missing: [])
        XCTAssertEqual(diff.gone, [])
        XCTAssertEqual(diff.newFolders, [])
        XCTAssertEqual(diff.newFiles, [])
        XCTAssertTrue(FileIndexStore.isInNestedRepository("vendor/inner/src", root: dir.path))
        XCTAssertFalse(FileIndexStore.isInNestedRepository("vendor/lib", root: dir.path))
    }

    /// A repository inside the checkout is one `name/` line from git: never
    /// a file row.
    func testAFolderGitNamesWholeIsNotAFile() {
        XCTAssertEqual(FileIndexStore.files(in: Data("a.c\0.claude/worktrees/x/\0b.c\0".utf8)), ["a.c", "b.c"])
    }

    /// The top folder is "" and reads only its own files.
    func testTheTopFolderIsReadByItself() {
        touch("a.c", "b.c", "deep/c.c")
        let index = FileIndex.merging([(FileIndex.sorted(["a.c", "deep/c.c"]), .tracked)])
        let diff = FileIndexStore.difference(of: [""], root: dir.path, index: index, missing: [])
        XCTAssertEqual(diff.newFiles, ["b.c"])
        XCTAssertEqual(diff.newFolders, [])
        XCTAssertEqual(diff.gone, [])
    }

    // MARK: - The store, live

    /// Waits for `condition` on the main actor, up to `seconds`.
    @MainActor
    private func eventually(_ seconds: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// A repository's list follows the disk: a new file appears, a file in an
    /// ignored folder never does, a deleted one goes, and a commit keeps it.
    @MainActor
    func testARepositorysListFollowsTheDisk() async {
        GitFixture.sh("git init -q -b main", in: dir)
        touch("a.c", ".gitignore")
        try? Data("build/\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
        GitFixture.sh("git add -A && git commit -q -m a", in: dir)
        let store = FileIndexStore()
        guard let folder = store.folder(for: dir.appendingPathComponent(".").path) else {
            return XCTFail("no folder")
        }
        func listed() -> Set<String> { Set((0..<folder.index.count).map(folder.index.path)) }
        let loaded = await eventually { listed() == ["a.c", ".gitignore"] }
        XCTAssertTrue(loaded, "\(listed())")
        // Past the load: the watch starts once it's done.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // From another process, as an agent writes: the watch leaves out
        // the app's own writes (`IgnoreSelf`).
        GitFixture.sh("mkdir -p src build && touch src/new.c b.c build/out.o", in: dir)
        let appeared = await eventually { listed().isSuperset(of: ["b.c", "src/new.c"]) }
        XCTAssertTrue(appeared, "\(listed())")
        XCTAssertFalse(listed().contains("build/out.o"))

        GitFixture.sh("rm a.c", in: dir)
        let went = await eventually { !listed().contains("a.c") }
        XCTAssertTrue(went, "\(listed())")

        GitFixture.sh("git add -A && git commit -q -m b", in: dir)
        let committed = await eventually {
            folder.index.kinds.allSatisfy { $0 == .tracked } && listed() == [".gitignore", "b.c", "src/new.c"]
        }
        XCTAssertTrue(committed, "\(listed())")
    }

    /// The home folder is never walked, and nothing is listed for it.
    @MainActor
    func testNoListForTheHomeFolder() {
        XCTAssertNil(FileIndexStore().folder(for: "/"))
    }
}
