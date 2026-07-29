import XCTest

/// Every failure this code prevents is silent: an agent that writes no transcript,
/// a shell integration loaded from someone else's bundle, a `node` that dies on a
/// `--require` into a swept temp directory. Nothing throws, and the app looks fine.
/// So the decision is pinned here against a real captured environment — a Wortel
/// launched from inside a Claude Code session running under another terminal —
/// rather than against names invented for the test.
///
/// The other half of the bar is what must *survive*: this runs before the app
/// exists, on the environment the user's own profile also lives in, and a scrub
/// that took `HOME` or `TMPDIR` with it would break every session instead of
/// fixing one.
final class InheritedEnvironmentTests: XCTestCase {

    private let temporaryDirectory = "/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/"

    /// The environment a real poisoned launch had (trimmed to the interesting
    /// variables), captured with `ps eww` from the running app.
    private var capturedLaunchEnvironment: [String: String] {
        [
            // Claude Code's markers for its own children. The first one is the bug:
            // an agent that sees it writes no transcript at all.
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_SESSION_ID": "54c34306-9695-4300-9f03-bb161eb13de4",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_EXECPATH": "/Users/giel/.local/share/claude/versions/2.1.220",
            "CLAUDECODE": "1",
            "CLAUDE_PID": "95075",
            "AI_AGENT": "claude-code_2-1-220_agent",
            // Another libghostty host's resources — these beat our bundle.
            "GHOSTTY_RESOURCES_DIR": "/Applications/Other.app/Contents/Resources/ghostty",
            "GHOSTTY_BIN_DIR": "/Applications/Other.app/Contents/MacOS",
            "GHOSTTY_SURFACE_ID": "0x259aa2f42e244b10",
            // Our own per-surface tag, inherited from the Wortel session that
            // launched this one — it names a session of the previous instance.
            "WORTEL_SESSION_ID": "11111111-2222-3333-4444-555555555555",
            // A per-session shim directory, and a require of a file inside it.
            "NODE_OPTIONS": "--require=/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/cli-shims/restore.cjs",
            "PATH": "/opt/homebrew/bin:/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T//cli-shims/ABC:/usr/bin",
            // Must survive: the user's own shell, tools and preferences.
            "TMPDIR": "/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/",
            "HOME": "/Users/giel",
            "SHELL": "/bin/zsh",
            "CLAUDE_EFFORT": "high",
            "BUN_INSTALL": "/Users/giel/.bun",
        ]
    }

    private func scrubbed(_ environment: [String: String]) -> [String: String] {
        let changes = InheritedEnvironment.scrub(environment, temporaryDirectory: temporaryDirectory)
        var result = environment
        for name in changes.removed {
            result.removeValue(forKey: name)
        }
        for (name, value) in changes.rewritten {
            result[name] = value
        }
        return result
    }

    // MARK: - What has to go

    /// The reported bug, end to end: none of the markers that make a fresh agent
    /// believe it is a nested run may reach the shell.
    func testDropsAgentSessionMarkers() {
        let result = scrubbed(capturedLaunchEnvironment)
        for name in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
                     "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
                     "CLAUDECODE", "CLAUDE_PID", "AI_AGENT"] {
            XCTAssertNil(result[name], "\(name) survived the scrub")
        }
    }

    /// Prefix-matched, so a marker added in a future agent release is covered
    /// without shipping a Wortel update for it.
    func testDropsUnknownFutureClaudeCodeMarkers() {
        let result = scrubbed(["CLAUDE_CODE_SOMETHING_NEW": "1"])
        XCTAssertNil(result["CLAUDE_CODE_SOMETHING_NEW"])
    }

    /// Wortel is bundle-only by design; the Zig core reads this variable before it
    /// looks for our `terminfo` sentinel, so an inherited copy silently swaps our
    /// shell integration for another host's.
    func testDropsAnotherTerminalHostsResources() {
        let result = scrubbed(capturedLaunchEnvironment)
        XCTAssertNil(result["GHOSTTY_RESOURCES_DIR"])
        XCTAssertNil(result["GHOSTTY_BIN_DIR"])
        XCTAssertNil(result["GHOSTTY_SURFACE_ID"])
    }

    /// Our own namespace, and the costliest one to leak: `WORTEL_SESSION_ID` keys
    /// the agent marker file, so an inherited one files markers under a session
    /// of the app instance that launched us — matched to nothing here. That
    /// silently loses agent resume *and* every agent notification, because the
    /// screen sampler only watches sessions with a live marker. Launching Wortel
    /// from a shell inside Wortel is the normal development path, so this leak is
    /// the common case rather than an edge one.
    func testDropsOurOwnInheritedSessionTag() {
        let result = scrubbed(capturedLaunchEnvironment)
        XCTAssertNil(result["WORTEL_SESSION_ID"])
    }

    /// A `--require` into the launching session's temp directory breaks every node
    /// process we start once that directory is swept. Dropped whole: a variable
    /// that mixes such a path with anything else is not worth editing.
    func testDropsInjectionsPointingIntoTheTemporaryDirectory() {
        XCTAssertNil(scrubbed(capturedLaunchEnvironment)["NODE_OPTIONS"])
    }

    /// PATH is filtered, never dropped — a shim directory keyed to a session that
    /// ended shadows the real `claude`, while the rest of PATH is the user's.
    func testFiltersShimDirectoriesOutOfPath() {
        let result = scrubbed(capturedLaunchEnvironment)
        XCTAssertEqual(result["PATH"], "/opt/homebrew/bin:/usr/bin")
    }

    /// The same directory is spelled `/private/var/folders/…` half the time.
    func testMatchesThePrivateSpellingOfTheTemporaryDirectory() {
        let result = scrubbed([
            "PATH": "/usr/bin:/private/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/cli-shims/ABC",
        ])
        XCTAssertEqual(result["PATH"], "/usr/bin")
    }

    // MARK: - What has to survive

    /// `TMPDIR`'s value *is* the temp directory, so a naive "mentions the temp
    /// directory" rule deletes it — and a shell with no TMPDIR is a broken shell.
    func testKeepsTmpdirItself() {
        let result = scrubbed(capturedLaunchEnvironment)
        XCTAssertEqual(result["TMPDIR"], "/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/")
    }

    /// A preference says how the user wants an agent to behave; it is not evidence
    /// that one is running, and it is not ours to throw away.
    func testKeepsAgentPreferencesAndTheUsersOwnEnvironment() {
        let result = scrubbed(capturedLaunchEnvironment)
        XCTAssertEqual(result["CLAUDE_EFFORT"], "high")
        XCTAssertEqual(result["HOME"], "/Users/giel")
        XCTAssertEqual(result["SHELL"], "/bin/zsh")
        XCTAssertEqual(result["BUN_INSTALL"], "/Users/giel/.bun")
    }

    /// A clean launch (from Finder, or after this fix) must be left exactly alone —
    /// no rewrite, so nothing to reason about in the normal case.
    func testCleanEnvironmentIsUntouched() {
        let clean = ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/giel",
                     "TMPDIR": "/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/"]
        let changes = InheritedEnvironment.scrub(clean, temporaryDirectory: temporaryDirectory)
        XCTAssertTrue(changes.isEmpty)
    }

    /// If every PATH entry looked like a shim the reading is wrong, and handing back
    /// an empty PATH would break the shell instead of the inheritance.
    func testNeverHandsBackAnEmptyPath() {
        let onlyShims = ["PATH": "/var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/cli-shims/ABC"]
        let changes = InheritedEnvironment.scrub(onlyShims, temporaryDirectory: temporaryDirectory)
        XCTAssertNil(changes.rewritten["PATH"])
    }
}
