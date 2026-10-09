import XCTest

/// The PATH every git the app runs is given. An app opened from the Dock has
/// only the system's folders on it, and a repository whose checkout runs a
/// tool from anywhere else (`git-lfs`, for one) couldn't be forked: "git-lfs:
/// command not found", from a git that worked in every shell.
final class GitToolPathTests: XCTestCase {
    private var repo: URL?
    private var tools: URL?

    override func tearDown() {
        if let repo { GitFixture.destroy(repo) }
        if let tools { GitFixture.destroy(tools) }
        super.tearDown()
    }

    private static let launchdPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The install folders come after what's there, so the `git` the app
    /// already ran is still the one that runs.
    func testInstallFoldersComeAfterTheExistingPath() {
        let path = GitService.toolPath(Self.launchdPATH, adding: ["/opt/homebrew/bin", "/x/bin"])
        XCTAssertEqual(path, "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/x/bin")
    }

    /// Launched from a shell, the app's PATH already has some of them: those
    /// keep their place rather than appearing twice.
    func testFoldersAlreadyOnThePathAreNotRepeated() {
        let path = GitService.toolPath("/opt/homebrew/bin:/usr/bin", adding: ["/opt/homebrew/bin", "/x/bin"])
        XCTAssertEqual(path, "/opt/homebrew/bin:/usr/bin:/x/bin")
    }

    func testNoPathStartsFromTheSystemFolders() {
        XCTAssertEqual(GitService.toolPath(nil, adding: ["/x/bin"]), Self.launchdPATH + ":/x/bin")
        XCTAssertEqual(GitService.toolPath("", adding: []), Self.launchdPATH)
    }

    /// The real defaults include the places Homebrew and Nix put things.
    func testTheDefaultsCoverHomebrewAndNix() {
        let path = GitService.toolPath(Self.launchdPATH)
        XCTAssertTrue(path.hasPrefix(Self.launchdPATH + ":"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/.nix-profile/bin"))
        XCTAssertTrue(path.contains("/etc/profiles/per-user/"))
    }

    /// The failure itself, end to end: a worktree for a branch with a file
    /// behind a required filter, whose program lives outside the system
    /// folders, the way `git-lfs` does. With the Dock's PATH git can't find
    /// it and the worktree is refused; with the folder added, it checks out.
    func testAWorktreeFindsAFilterOutsideTheSystemFolders() async throws {
        let tools = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-tests-tools-\(UUID().uuidString)")
        self.tools = tools
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let filter = tools.appendingPathComponent("fake-lfs")
        try "#!/bin/sh\nexec cat\n".write(to: filter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filter.path)

        let repo = GitFixture.newRepo("tool-path")
        self.repo = repo
        GitFixture.sh("git config filter.fake.clean cat && git config filter.fake.smudge fake-lfs"
                      + " && git config filter.fake.required true", in: repo)
        GitFixture.sh("echo '*.bin filter=fake' > .gitattributes && echo data > a.bin"
                      + " && git add . && git commit -q -m files", in: repo)

        func addWorktree(_ name: String, path: String) async -> GitService.CommandResult {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let target = repo.appendingPathComponent(".wt-\(name)").path
            return await GitService.runTool(["/usr/bin/git", "worktree", "add", "-b", name, target],
                                            environment: env, in: repo.path, timeout: 30)
        }

        let without = await addWorktree("before", path: Self.launchdPATH)
        XCTAssertFalse(without.ok, "the filter should be out of reach on the Dock's PATH")
        XCTAssertTrue(without.stderr.contains("fake-lfs"), without.stderr)

        let with = await addWorktree("after", path: GitService.toolPath(Self.launchdPATH, adding: [tools.path]))
        XCTAssertTrue(with.ok, with.stderr)
        let checkedOut = try String(contentsOfFile: repo.appendingPathComponent(".wt-after/a.bin").path, encoding: .utf8)
        XCTAssertEqual(checkedOut, "data\n")
    }
}
