import XCTest

/// `GitMessage` against git's real wording: each test makes git fail the way
/// it fails in use, and checks the sentence that comes out. Git rewords its
/// messages between versions, which is exactly what a test with copied
/// strings would miss.
final class GitMessageTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        dirs.forEach(GitFixture.destroy)
        dirs = []
        super.tearDown()
    }

    private func repo(_ label: String) -> URL {
        let dir = GitFixture.newRepo(label)
        dirs.append(dir)
        return dir
    }

    /// Git's stderr (and stdout) for a command expected to fail.
    private func failing(_ command: String, in dir: URL) -> String {
        GitFixture.sh("\(command) 2>&1; true", in: dir)
    }

    private func assertSays(_ sentence: String, contains parts: [String],
                            file: StaticString = #filePath, line: UInt = #line) {
        for part in parts {
            XCTAssertTrue(sentence.contains(part), "\"\(sentence)\" should mention \(part)",
                          file: file, line: line)
        }
        XCTAssertFalse(sentence.lowercased().contains("fatal"), sentence, file: file, line: line)
        XCTAssertFalse(sentence.lowercased().contains("hint:"), sentence, file: file, line: line)
    }

    func testSwitchingOverLocalChangesNamesTheFiles() {
        let dir = repo("dirty")
        GitFixture.sh("echo one > a.txt && git add -A && git commit -q -m one", in: dir)
        GitFixture.sh("git checkout -q -b other && echo two > a.txt && git commit -q -am two && git checkout -q main", in: dir)
        GitFixture.sh("echo mine > a.txt", in: dir)
        let said = GitMessage.readable(failing("git checkout other", in: dir), while: .switching(to: "other"))
        assertSays(said, contains: ["a.txt", "Commit or stash"])
    }

    func testABranchInAnotherFolderNamesTheFolder() {
        let dir = repo("busy")
        GitFixture.commit("one", in: dir)
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("wortel-msg-\(UUID().uuidString)")
        dirs.append(tree)
        GitFixture.sh("git branch busy && git worktree add -q \(tree.path) busy", in: dir)
        let said = GitMessage.readable(failing("git checkout busy", in: dir), while: .switching(to: "busy"))
        assertSays(said, contains: ["\u{201C}busy\u{201D}", tree.lastPathComponent, "one folder at a time"])
        XCTAssertFalse(said.contains("/"), "the folder's name, not its path")
    }

    func testAnInvalidBranchName() {
        let dir = repo("name")
        GitFixture.commit("one", in: dir)
        let said = GitMessage.readable(failing("git worktree add -b 'worktree/Jump to' ../x", in: dir),
                                       while: .worktree(branch: "worktree/Jump to"))
        assertSays(said, contains: ["isn't a name git allows"])
    }

    func testPushingBehindTheRemoteSaysPullFirst() {
        let remote = repo("remote")
        GitFixture.sh("rm -rf .git && git init -q --bare -b main .", in: remote)
        let a = repo("a")
        GitFixture.commit("one", in: a)
        GitFixture.sh("git remote add origin \(remote.path) && git push -q -u origin main", in: a)
        let b = repo("b")
        GitFixture.sh("rm -rf .git && git clone -q \(remote.path) .", in: b)
        GitFixture.commit("theirs", in: b)
        GitFixture.sh("git push -q", in: b)
        GitFixture.commit("mine", in: a)
        let said = GitMessage.readable(failing("git push", in: a), while: .push)
        assertSays(said, contains: ["Pull first"])
    }

    func testPullingDivergedBranchesSaysWhatToDo() {
        let remote = repo("remote2")
        GitFixture.sh("rm -rf .git && git init -q --bare -b main .", in: remote)
        let a = repo("a2")
        GitFixture.commit("one", in: a)
        GitFixture.sh("git remote add origin \(remote.path) && git push -q -u origin main", in: a)
        let b = repo("b2")
        GitFixture.sh("rm -rf .git && git clone -q \(remote.path) .", in: b)
        GitFixture.commit("theirs", in: b)
        GitFixture.sh("git push -q", in: b)
        GitFixture.commit("mine", in: a)
        let said = GitMessage.readable(failing("git pull --ff-only", in: a), while: .pull)
        assertSays(said, contains: ["both moved on"])
    }

    func testNothingToCommit() {
        let dir = repo("empty")
        GitFixture.commit("one", in: dir)
        let said = GitMessage.readable(failing("git commit -m x", in: dir), while: .commit)
        assertSays(said, contains: ["nothing staged"])
    }

    func testOutsideARepository() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wortel-norepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let said = GitMessage.readable(failing("GIT_CEILING_DIRECTORIES=\(dir.deletingLastPathComponent().path) git status", in: dir))
        assertSays(said, contains: ["isn't a git repository"])
    }

    /// Anything unrecognised is git's own words, without its advice lines and
    /// prefixes: a hook's output is still the best account of what happened.
    func testUnrecognisedKeepsGitsWordsWithoutTheNoise() {
        let raw = """
            error: pre-commit hook failed: lint found 2 problems
            hint: use --no-verify to bypass
            fatal: aborting
            """
        XCTAssertEqual(GitMessage.readable(raw), "Pre-commit hook failed: lint found 2 problems\naborting")
    }

    func testListsShortenLongFileLists() {
        XCTAssertEqual(GitMessage.list(["a"], otherwise: "x"), "a")
        XCTAssertEqual(GitMessage.list(["a", "b"], otherwise: "x"), "a and b")
        XCTAssertEqual(GitMessage.list(["a", "b", "c", "d", "e"], otherwise: "x"), "a, b and 3 more")
        XCTAssertEqual(GitMessage.list(["src/deep/a.swift"], otherwise: "x"), "a.swift")
    }
}
