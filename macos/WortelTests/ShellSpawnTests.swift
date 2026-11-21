import XCTest

/// How a shell gets started when *we* own the pty rather than libghostty.
///
/// Every failure here is silent, which is the whole reason this is a pure type
/// with tests. A shell that starts without the integration looks completely
/// normal: it just never emits an OSC 133 mark, never writes an agent marker,
/// never reports its cwd. Busy dots stop, agent resume stops, and nothing
/// anywhere says so — you find out days later.
final class ShellSpawnTests: XCTestCase {
    private let resources = "/App/Contents/Resources/ghostty"
    private let terminfo = "/App/Contents/Resources/terminfo"

    private func plan(
        shell: String, environment: [String: String] = [:], login: Bool = false
    ) -> ShellSpawn.Plan {
        ShellSpawn.plan(
            shellPath: shell, resourcesDir: resources, terminfoDir: terminfo,
            environment: environment, shellFeatures: "ssh-env,title",
            binDir: "/App/Contents/MacOS", login: login, userName: "me")
    }

    // MARK: - What every shell gets

    /// Without these the terminal is a dumb one: no truecolor, and ncurses
    /// programs abort because the bundled xterm-ghostty entry can't be found.
    func testTerminalIdentityIsAlwaysSet() {
        for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/bin/tcsh"] {
            let env = plan(shell: shell).environment
            XCTAssertEqual(env["TERM"], "xterm-ghostty", shell)
            XCTAssertEqual(env["TERMINFO"], terminfo, shell)
            XCTAssertEqual(env["TERM_PROGRAM"], "ghostty", shell)
            XCTAssertEqual(env["GHOSTTY_RESOURCES_DIR"], resources, shell)
        }
    }

    /// TERM_PROGRAM is not decoration: agent CLIs key their notification
    /// support off it, which is where half the attention system's signal comes
    /// from.
    func testShellFeaturesReachTheScripts() {
        XCTAssertEqual(plan(shell: "/bin/zsh").environment["GHOSTTY_SHELL_FEATURES"],
                       "ssh-env,title")
    }

    // MARK: - zsh

    func testZshIsInjectedThroughZDOTDIR() {
        let plan = plan(shell: "/bin/zsh")
        XCTAssertEqual(plan.environment["ZDOTDIR"], "\(resources)/shell-integration/zsh")
        XCTAssertEqual(plan.arguments, ["-l"])
    }

    /// The shipped `.zshenv` restores the user's own ZDOTDIR from this. Lose it
    /// and anyone with a custom ZDOTDIR silently loses their entire config.
    func testZshKeepsTheUsersOwnZDOTDIR() {
        let plan = plan(shell: "/bin/zsh", environment: ["ZDOTDIR": "/Users/me/.config/zsh"])
        XCTAssertEqual(plan.environment["GHOSTTY_ZSH_ZDOTDIR"], "/Users/me/.config/zsh")
        XCTAssertEqual(plan.environment["ZDOTDIR"], "\(resources)/shell-integration/zsh")
    }

    func testZshWithoutAZDOTDIRDoesNotInventOne() {
        XCTAssertNil(plan(shell: "/bin/zsh").environment["GHOSTTY_ZSH_ZDOTDIR"])
    }

    // MARK: - bash

    /// bash has no ZDOTDIR, so upstream starts it in POSIX mode — where `ENV`
    /// is sourced — and the sourced script undoes POSIX mode and replays the
    /// startup files itself. All three parts are required: drop `--posix` and
    /// ENV is never read, drop GHOSTTY_BASH_INJECT and the script leaves the
    /// shell in POSIX mode with no rc files loaded.
    func testBashIsInjectedThroughPosixModeAndENV() {
        let plan = plan(shell: "/bin/bash")
        XCTAssertEqual(plan.arguments, ["--posix"])
        XCTAssertEqual(plan.environment["ENV"],
                       "\(resources)/shell-integration/bash/ghostty.bash")
        XCTAssertEqual(plan.environment["GHOSTTY_BASH_INJECT"], "1")
    }

    func testBashKeepsAnExistingENV() {
        let plan = plan(shell: "/bin/bash", environment: ["ENV": "/Users/me/.env"])
        XCTAssertEqual(plan.environment["GHOSTTY_BASH_ENV"], "/Users/me/.env")
    }

    // MARK: - fish

    /// fish autoloads `vendor_conf.d` from every XDG data directory, so
    /// prepending ours is the whole injection — and it must *prepend*, keeping
    /// what was there, or every other vendor's completions vanish.
    func testFishPrependsToTheDataDirsItFinds() {
        let plan = plan(shell: "/opt/homebrew/bin/fish",
                        environment: ["XDG_DATA_DIRS": "/opt/homebrew/share:/usr/share"])
        XCTAssertEqual(plan.environment["XDG_DATA_DIRS"],
                       "\(resources)/shell-integration:/opt/homebrew/share:/usr/share")
    }

    func testFishWithNoDataDirsStillGetsTheDefaults() {
        let value = plan(shell: "/opt/homebrew/bin/fish").environment["XDG_DATA_DIRS"] ?? ""
        XCTAssertTrue(value.hasPrefix("\(resources)/shell-integration:"), value)
        XCTAssertTrue(value.contains("/usr/share"), "the system defaults were dropped: \(value)")
    }

    // MARK: - Shells we don't know

    /// An unknown shell still gets a working terminal — just no integration.
    /// Silently refusing to start it would be much worse.
    func testAnUnknownShellStillRuns() {
        let plan = plan(shell: "/bin/tcsh")
        XCTAssertEqual(plan.executable, "/bin/tcsh")
        XCTAssertEqual(plan.arguments, ["-l"])
        XCTAssertNil(plan.environment["ZDOTDIR"])
        XCTAssertNil(plan.environment["GHOSTTY_BASH_INJECT"])
    }

    // MARK: - The login wrapper

    /// `-p` is the load-bearing flag: without it `login` wipes the environment
    /// and takes the entire shell integration with it.
    func testLoginPreservesTheEnvironment() {
        let plan = plan(shell: "/bin/zsh", login: true)
        XCTAssertEqual(plan.executable, "/usr/bin/login")
        XCTAssertEqual(plan.arguments.first, "-flp")
        XCTAssertTrue(plan.arguments.contains("me"))
        XCTAssertEqual(plan.environment["ZDOTDIR"], "\(resources)/shell-integration/zsh")
    }

    /// The trampoline `exec -l`s the real shell, which is what makes argv[0]
    /// start with a dash — how a shell knows it is a login shell at all.
    func testLoginExecsTheRealShellAsALoginShell() {
        let command = plan(shell: "/bin/zsh", login: true).arguments.last ?? ""
        XCTAssertTrue(command.hasPrefix("exec -l "), command)
        XCTAssertTrue(command.contains("'/bin/zsh'"), command)
    }

    /// Paths with spaces are ordinary on a Mac, and an unquoted one execs the
    /// wrong file or nothing.
    func testAShellPathWithSpacesSurvivesTheTrampoline() {
        let command = plan(shell: "/Users/some one/bin/zsh", login: true).arguments.last ?? ""
        XCTAssertTrue(command.contains("'/Users/some one/bin/zsh'"), command)
    }

    func testQuotingHandlesAQuote() {
        XCTAssertEqual(ShellSpawn.shellQuoted("a'b"), "'a'\\''b'")
    }

    // MARK: - The feature string

    /// **Pinned against a measurement.** A real session's shell, with
    /// `wortel.conf` saying `no-cursor,no-path,ssh-terminfo,ssh-env`, receives
    /// exactly this. If the derivation ever stops reproducing it, the shell we
    /// spawn ourselves has stopped matching the one libghostty spawns.
    func testFeaturesMatchWhatARealSessionReceives() {
        XCTAssertEqual(
            ShellSpawn.features(fromConfig: "no-cursor,no-path,ssh-terminfo,ssh-env"),
            "ssh-env,ssh-terminfo,title")
    }

    /// The config form and the exported form are different languages: one lists
    /// changes against the defaults, the other lists what is on. Passing the
    /// config form straight through would *enable* the features it names to
    /// disable, because the scripts match with `== *"path"*`.
    func testANegationDisablesRatherThanEnables() {
        XCTAssertFalse(ShellSpawn.features(fromConfig: "no-path").contains("path"))
        XCTAssertTrue(ShellSpawn.features(fromConfig: "").contains("path"))
    }

    func testDefaultsAreOnWithoutBeingNamed() {
        let features = ShellSpawn.features(fromConfig: "")
        for name in ["cursor", "path", "title"] {
            XCTAssertTrue(features.contains(name), "\(name) should default on")
        }
        XCTAssertFalse(features.contains("sudo"), "sudo should default off")
    }

    /// The bundled config is the source of truth, so the value we build has to
    /// be derived from the file rather than from a copy of it in Swift.
    func testTheBundledConfigStillParses() throws {
        let conf = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/wortel.conf")
        let text = try String(contentsOf: conf, encoding: .utf8)
        let line = text.split(separator: "\n")
            .first { $0.hasPrefix("shell-integration-features") }
        let value = try XCTUnwrap(line?.split(separator: "=").last?
            .trimmingCharacters(in: .whitespaces))
        let features = ShellSpawn.features(fromConfig: value)
        XCTAssertTrue(features.contains("title"), features)
        XCTAssertFalse(features.contains("no-"), "a negation leaked into the exported form")
    }

    // MARK: - Which shell

    func testLoginShellPrefersSHELL() {
        XCTAssertEqual(ShellSpawn.loginShell(environment: ["SHELL": "/opt/homebrew/bin/fish"]),
                       "/opt/homebrew/bin/fish")
    }

    /// An empty SHELL is not an answer — fall through to the passwd entry
    /// rather than trying to exec "".
    func testLoginShellIgnoresAnEmptySHELL() {
        XCTAssertFalse(ShellSpawn.loginShell(environment: ["SHELL": ""]).isEmpty)
    }

    func testShellRecognitionUsesTheLastComponent() {
        XCTAssertEqual(ShellSpawn.Shell(path: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertEqual(ShellSpawn.Shell(path: "/bin/zsh"), .zsh)
        XCTAssertEqual(ShellSpawn.Shell(path: "/usr/local/bin/bash"), .bash)
        // Not a substring match: `/bin/zshfoo` is not zsh.
        XCTAssertEqual(ShellSpawn.Shell(path: "/bin/zshfoo"), .other)
    }
}
