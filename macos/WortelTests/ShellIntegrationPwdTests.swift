import XCTest

/// The bundled shell integration's cwd report is what the sidebar subtitle and
/// the git panel's whole repo choice rest on: `Session.cwd` starts as a copy of
/// whatever session you branched off, and OSC 7 is the *only* thing that ever
/// corrects it. So a dropped report doesn't degrade anything visibly — it
/// silently pins a session to a stale directory for its entire life, and the
/// git panel faithfully shows the wrong repo.
///
/// libghostty accepts an OSC 7 only when its host is "localhost" or an exact
/// `gethostname()` match; anything else — including a missing host — is a remote
/// path and is dropped with no error ("OSC 7 uri must contain a hostname" /
/// "OSC 7 host () must be local"). Upstream's integration interpolates the
/// shell's own `$HOST`, which fails two ways that both really happen:
///
/// 1. It's an ordinary parameter. An environment that clears it (shadowenv does)
///    emits a hostless `kitty-shell-cwd:///usr` — rejected.
/// 2. It's captured at shell start. macOS renames the machine mid-session under
///    an mDNS collision (the "-2" suffix), and the captured value no longer
///    matches `gethostname()` — rejected.
///
/// Hence "localhost", and hence these tests: they pin that the emitted host is
/// *independent of the environment*, which is the actual invariant. Both cases
/// below fail against the unpatched upstream script.
///
/// These drive the real script in a real zsh — no pty and no sleeps. `zsh -i -c`
/// sets the interactive flag (so `.zshenv` loads the integration) but never
/// reaches a prompt, so `_ghostty_deferred_init` is called by hand to do what
/// the first precmd would.
final class ShellIntegrationPwdTests: XCTestCase {

    /// `macos/Resources/ghostty`, found from this file rather than a bundle
    /// resource: the scripts ship as a folder reference in the *app*, and this
    /// test bundle isn't the app (it's deliberately unhosted).
    private static var ghosttyResources: URL {
        URL(fileURLWithPath: #filePath)     // …/macos/WortelTests/ShellIntegrationPwdTests.swift
            .deletingLastPathComponent()    // …/macos/WortelTests
            .deletingLastPathComponent()    // …/macos
            .appendingPathComponent("Resources/ghostty")
    }

    // MARK: - zsh, end to end

    /// The case actually hit in the wild: `$HOST` cleared by the environment.
    /// Unpatched, this emits `kitty-shell-cwd:///usr` and libghostty drops it.
    func testZshReportsLocalhostWhenHostIsEmpty() throws {
        XCTAssertEqual(try lastReportedURI(host: "", cd: "/usr"),
                       "kitty-shell-cwd://localhost/usr")
    }

    /// The rename case: `$HOST` is populated but stale, so it no longer matches
    /// `gethostname()`. Unpatched, this emits the stale name and is dropped.
    func testZshReportsLocalhostWhenHostIsStale() throws {
        XCTAssertEqual(try lastReportedURI(host: "stale-name.local", cd: "/usr"),
                       "kitty-shell-cwd://localhost/usr")
    }

    /// Even unset — where zsh helpfully populates `$HOST` itself and upstream
    /// would happen to work — the host must not vary with the environment.
    func testZshReportsLocalhostWhenHostIsUnset() throws {
        XCTAssertEqual(try lastReportedURI(host: nil, cd: "/usr"),
                       "kitty-shell-cwd://localhost/usr")
    }

    /// The feature itself: a `cd` reports the directory moved to, not the one
    /// started in. (`/usr` and `/etc` over `/tmp`, which is a symlink to
    /// `/private/tmp` and would report resolved.)
    func testZshReportsTheDirectoryCdIntoRatherThanTheStartingOne() throws {
        XCTAssertEqual(try lastReportedURI(host: "", cd: "/etc"),
                       "kitty-shell-cwd://localhost/etc")
    }

    // MARK: - The shells we can't drive as cheaply

    /// bash and fish have the identical exposure (`$HOSTNAME` / `$hostname`) and
    /// no equally cheap harness — bash reports only from its prompt hook, fish
    /// only from a `--on-variable PWD` handler. A structural check is worth more
    /// than nothing here, because the regression this guards against is a
    /// re-vendor from upstream silently restoring the variable.
    ///
    /// elvish is deliberately absent: it calls `platform:hostname` live at emit
    /// time, so it always matches `gethostname()` and can't go stale.
    func testBashAndFishDoNotInterpolateAHostnameVariable() throws {
        for (shell, path) in [
            ("bash", "shell-integration/bash/ghostty.bash"),
            ("fish", "shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"),
        ] {
            let script = try String(contentsOf: Self.ghosttyResources.appendingPathComponent(path),
                                    encoding: .utf8)
            // Match on the URI scheme rather than the "]7;" prefix: fish escapes
            // the sequence character by character (\e\]7\;), so the literal
            // prefix doesn't appear in its source.
            let emitters = script
                .split(separator: "\n")
                .filter { ($0.contains("kitty-shell-cwd://") || $0.contains("file://"))
                          && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

            XCTAssertFalse(emitters.isEmpty, "\(shell): no OSC 7 emitter found — did the script move?")
            for line in emitters {
                XCTAssertTrue(line.contains("localhost"),
                              "\(shell): OSC 7 must hardcode localhost, got: \(line)")
                for variable in ["$HOSTNAME", "$hostname", "$HOST"] {
                    XCTAssertFalse(line.contains(variable),
                                   "\(shell): OSC 7 host must not depend on \(variable), got: \(line)")
                }
            }
        }
    }

    // MARK: - Harness

    /// Run the bundled zsh integration and return the URI of its last OSC 7.
    ///
    /// Hermetic: `HOME` is an empty temp dir, so the integration's `.zshenv`
    /// (which sources `${ZDOTDIR-$HOME}/.zshenv`) finds no user dotfiles, and the
    /// environment is replaced wholesale rather than inherited.
    ///
    /// Runs under `script(1)` for its pty. That isn't ceremony: the integration
    /// opens its own write fd on `$TTY`/`/dev/tty` and only falls back to stdout
    /// when neither is writable (ghostty-integration:86-92). Spawned bare, its
    /// reports would go to whatever terminal the *test runner* is attached to and
    /// never reach this pipe — passing or failing depending on whether the run
    /// has a tty, which is exactly the flakiness worth designing out.
    private func lastReportedURI(host: String?, cd directory: String) throws -> String? {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-shellintegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var environment = [
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "HOME": home.path,
            "ZDOTDIR": Self.ghosttyResources.appendingPathComponent("shell-integration/zsh").path,
            "GHOSTTY_RESOURCES_DIR": Self.ghosttyResources.path,
        ]
        if let host { environment["HOST"] = host }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // Interactive (so .zshenv loads the integration) but prompt-less, so the
        // deferred init the first precmd would run is invoked by hand.
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-i", "-c",
                             "_ghostty_deferred_init 2>/dev/null; cd \(directory)"]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // OSC 7 is ESC ] 7 ; <uri> BEL.
        let reports = String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\u{1b}]7;")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "\u{07}").first }
        XCTAssertFalse(reports.isEmpty, "the integration emitted no OSC 7 at all — harness broken?")
        return reports.last
    }
}
