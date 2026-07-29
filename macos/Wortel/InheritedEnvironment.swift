import Foundation

/// Drops the environment of whatever launched Wortel, before it can reach a shell.
///
/// Wortel gets started from inside a coding agent's tool shell routinely — that's
/// how it's developed: `scripts/release.sh` installs to `/Applications` and opens
/// the app, and the agent runs that script from its own shell. The app inherits
/// that shell's whole environment and then *keeps* it: launchd reparents the app,
/// so those variables outlive the session that set them, and libghostty hands them
/// to every surface's shell (`ghostty_surface_config_s.env_vars` can only add, so
/// the inherited copy is the baseline). Three things break, and all of them are
/// silent:
///
/// - **An agent CLI started in Wortel thinks it's a nested run of itself.** Claude
///   Code, for one, sees `CLAUDE_CODE_CHILD_SESSION` and writes no transcript for
///   the session: no history, no `--resume`, and `AgentResumeStore` has no
///   conversation to bring back after a relaunch. The marker it obeys was set by a
///   process that exited hours ago.
/// - **Another libghostty host's `GHOSTTY_RESOURCES_DIR` beats our bundle.** The
///   Zig core checks the variable before it looks for the `terminfo` sentinel
///   (`src/os/resourcesdir.zig`), so we'd load *its* shell integration and
///   terminfo instead of the ones we ship — with Wortel being deliberately
///   bundle-only (see the resources rule in `CLAUDE.md`).
/// - **A dead session's private files stay on our path.** Per-session CLI shims in
///   the temp directory shadow the real binary (`claude` resolving to another
///   app's wrapper), and a `NODE_OPTIONS` `--require` pointing there breaks every
///   `node` we launch once that temp directory is swept.
///
/// Dropping all of it is safe, and that is the load-bearing point: each surface
/// spawns a **login** shell, which re-exports everything the user actually
/// configured. What's removed here can only ever be a leftover of the process that
/// launched us.
enum InheritedEnvironment {

    /// What `scrub` decided about an environment. Separated from applying it so the
    /// decision is testable without mutating the test runner's own environment.
    struct Changes: Equatable {
        /// Variables to remove entirely.
        var removed: Set<String> = []
        /// Variables to keep under a different value — `PATH`, in practice, which
        /// is filtered entry-by-entry rather than dropped.
        var rewritten: [String: String] = [:]

        var isEmpty: Bool { removed.isEmpty && rewritten.isEmpty }
    }

    /// Session identity an agent CLI exports for its own child processes. Removed
    /// by prefix so a new `CLAUDE_CODE_*` marker is covered the day it ships —
    /// which matters because the failure mode is a missing transcript, not an
    /// error. Preferences like `CLAUDE_EFFORT` are deliberately *not* matched:
    /// they say how the user wants an agent to behave, not that one is running.
    private static let agentSessionPrefixes = ["CLAUDE_CODE_"]

    /// The same thing under names that aren't prefixed: Claude Code's "you are
    /// inside me" flag and pid, and the generic marker several tools set.
    private static let agentSessionNames: Set<String> = ["AI_AGENT", "CLAUDECODE", "CLAUDE_PID"]

    /// The terminal host's own namespace. Ours is set per-surface by libghostty at
    /// spawn; an inherited copy describes a different host's bundle and surface.
    ///
    /// `WORTEL_` is in here for the same reason, and it's the case that bites
    /// hardest: `WORTEL_SESSION_ID` keys a session's agent marker file
    /// (`AgentResumeStore`), so an inherited one names a session belonging to the
    /// *previous* app instance — one that no longer exists. Markers would be
    /// written under a dead id and matched to no session, which silently costs
    /// both agent resume and every agent notification, since the sampler only
    /// watches sessions with a live marker. Launching Wortel from a shell inside
    /// Wortel is exactly how it's developed, so this is the common path.
    private static let terminalHostPrefixes = ["GHOSTTY_", "WORTEL_"]

    /// Scrub this process's environment. Call before anything spawns a child —
    /// a surface's shell, or a `git` read from `GitService`.
    static func apply(temporaryDirectory: String = NSTemporaryDirectory()) {
        let changes = scrub(ProcessInfo.processInfo.environment,
                            temporaryDirectory: temporaryDirectory)
        for name in changes.removed {
            unsetenv(name)
        }
        for (name, value) in changes.rewritten {
            setenv(name, value, 1)
        }
    }

    static func scrub(_ environment: [String: String], temporaryDirectory: String) -> Changes {
        let temporaryPrefixes = temporaryDirectoryPrefixes(temporaryDirectory)
        var changes = Changes()

        for (name, value) in environment {
            if name == "PATH" { continue }   // filtered per entry below, never dropped

            if isAgentSessionMarker(name) || isTerminalHostVariable(name) {
                changes.removed.insert(name)
                continue
            }
            // A value reaching into the temp directory names a file that belongs to
            // the launching session, not to us. Coarse on purpose: a variable that
            // mixes such a path with something legitimate (a `NODE_OPTIONS`
            // `--require`) is dropped whole rather than edited, because a
            // half-honoured injection is harder to reason about than none.
            if pointsInsideTemporaryDirectory(value, prefixes: temporaryPrefixes) {
                changes.removed.insert(name)
            }
        }

        if let path = environment["PATH"] {
            let kept = path.split(separator: ":", omittingEmptySubsequences: false)
                .filter { !pointsInsideTemporaryDirectory(String($0), prefixes: temporaryPrefixes) }
            let rewritten = kept.joined(separator: ":")
            // Never hand back an empty PATH: if every entry looked like a shim,
            // the reading is wrong and a broken PATH is worse than a dirty one.
            if rewritten != path, !kept.isEmpty {
                changes.rewritten["PATH"] = rewritten
            }
        }

        return changes
    }

    private static func isAgentSessionMarker(_ name: String) -> Bool {
        agentSessionNames.contains(name) || agentSessionPrefixes.contains { name.hasPrefix($0) }
    }

    private static func isTerminalHostVariable(_ name: String) -> Bool {
        terminalHostPrefixes.contains { name.hasPrefix($0) }
    }

    /// `NSTemporaryDirectory()` is the per-user `/var/folders/…/T/` path, but the
    /// same directory is reached through `/private/var/…` and paths in the wild
    /// carry doubled slashes, so match every spelling.
    private static func temporaryDirectoryPrefixes(_ temporaryDirectory: String) -> [String] {
        var directory = temporaryDirectory
        while directory.hasSuffix("/") {
            directory.removeLast()
        }
        guard !directory.isEmpty else { return [] }

        var prefixes = [directory + "/", directory + "//"]
        if directory.hasPrefix("/private/") {
            prefixes += [String(directory.dropFirst("/private".count)) + "/"]
        } else {
            prefixes += ["/private" + directory + "/"]
        }
        return prefixes
    }

    /// True when `value` names something *inside* the temp directory. The path has
    /// to continue past the prefix, which is what keeps `TMPDIR` — whose value is
    /// that directory — from deleting itself.
    private static func pointsInsideTemporaryDirectory(_ value: String, prefixes: [String]) -> Bool {
        for prefix in prefixes {
            var searchRange = value.startIndex..<value.endIndex
            while let match = value.range(of: prefix, range: searchRange) {
                if match.upperBound < value.endIndex, value[match.upperBound] != ":" {
                    return true
                }
                searchRange = match.upperBound..<value.endIndex
            }
        }
        return false
    }
}
