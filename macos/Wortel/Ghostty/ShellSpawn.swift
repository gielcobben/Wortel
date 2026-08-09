import Foundation

/// How to start a login shell that behaves exactly like one libghostty's exec
/// backend started.
///
/// When we own the pty (see `PtyHost`) libghostty spawns nothing, so everything
/// its exec backend did for the child becomes ours to do. That is not cosmetic:
/// the shell integration it injects is what emits OSC 133 command marks, writes
/// the agent marker files `AgentResumeStore` reads, reports the cwd, and puts
/// the `wortel` command on `PATH`. Busy detection, the attention system and
/// agent resume are all downstream of this one decision.
///
/// Pure on purpose — a description in, a description out — because every failure
/// here is silent. A shell that starts without the integration looks completely
/// normal and simply never reports anything, and you find out days later when a
/// session stops showing a busy dot.
enum ShellSpawn {
    /// What to hand `execve`.
    struct Plan: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    /// The shells we can inject into. Anything else still gets a terminal, just
    /// without the integration — the same deal upstream offers.
    enum Shell: Equatable {
        case zsh, bash, fish, other

        init(path: String) {
            switch (path as NSString).lastPathComponent {
            case "zsh": self = .zsh
            case "bash": self = .bash
            case "fish": self = .fish
            default: self = .other
            }
        }
    }

    /// Build the plan.
    ///
    /// - `shellPath`: the user's login shell (from `SHELL`, or the passwd entry).
    /// - `resourcesDir`: the bundle's `Contents/Resources/ghostty`, which holds
    ///   `shell-integration/` and `terminfo/`.
    /// - `login`: wrap in `/usr/bin/login` the way upstream does on macOS, so
    ///   the session is a real login session. Off in tests.
    static func plan(
        shellPath: String,
        resourcesDir: String,
        terminfoDir: String,
        environment: [String: String],
        extraEnvironment: [String: String] = [:],
        shellFeatures: String,
        binDir: String?,
        login: Bool = true,
        userName: String = NSUserName()
    ) -> Plan {
        var env = environment
        // Ghostty's own namespace. These are set by the core in exec mode, and
        // the integration scripts read every one of them.
        env["TERM"] = "xterm-ghostty"
        env["TERMINFO"] = terminfoDir
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ghostty"
        env["GHOSTTY_RESOURCES_DIR"] = resourcesDir
        env["GHOSTTY_SHELL_FEATURES"] = shellFeatures
        if let binDir { env["GHOSTTY_BIN_DIR"] = binDir }
        for (key, value) in extraEnvironment { env[key] = value }

        let integration = (resourcesDir as NSString).appendingPathComponent("shell-integration")
        var arguments: [String] = []

        switch Shell(path: shellPath) {
        case .zsh:
            // The whole injection is one variable: zsh reads `.zshenv` from
            // ZDOTDIR, and the copy we ship there sources the user's real one
            // before loading the integration. The user's original has to be
            // handed along, because that shipped `.zshenv` restores it — drop it
            // and anyone with a custom ZDOTDIR silently loses their config.
            if let original = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = original }
            env["ZDOTDIR"] = (integration as NSString).appendingPathComponent("zsh")
            arguments = ["-l"]

        case .bash:
            // bash has no ZDOTDIR. Upstream's trick is to start it in POSIX
            // mode, where `ENV` is sourced, and have the sourced script undo
            // POSIX mode and replay the normal startup sequence itself. The
            // flags it must replay are passed in GHOSTTY_BASH_INJECT.
            if let original = env["ENV"] { env["GHOSTTY_BASH_ENV"] = original }
            env["ENV"] = (integration as NSString)
                .appendingPathComponent("bash/ghostty.bash")
            env["GHOSTTY_BASH_INJECT"] = "1"
            arguments = ["--posix"]

        case .fish:
            // fish autoloads `vendor_conf.d` from every XDG data directory, so
            // prepending ours is the whole injection. Prepended, and the
            // existing value kept — replacing it would cut off every other
            // vendor completion the user has.
            let existing = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = "\(integration):\(existing)"
            arguments = ["-l"]

        case .other:
            // No integration, but still a login shell in a proper terminal.
            arguments = ["-l"]
        }

        guard login else {
            return Plan(executable: shellPath, arguments: arguments, environment: env)
        }

        // `login` gives the child a real login session — utmp, and the
        // `Last login:` line people expect. `-f` skips authentication (we are
        // already this user), `-l` is not used because we exec the shell
        // ourselves, and **`-p` is load-bearing**: without it login wipes the
        // environment and every variable above — the entire shell integration —
        // is gone. The bash trampoline is upstream's shape too: it is what lets
        // us control the final `exec` and its argv[0].
        let command = "exec -l \(shellQuoted(shellPath)) \(arguments.joined(separator: " "))"
        return Plan(
            executable: "/usr/bin/login",
            arguments: ["-flp", userName, "/bin/bash", "--noprofile", "--norc", "-c", command],
            environment: env)
    }

    /// Ghostty's shell-integration features that default to **on**. Everything
    /// else is off unless `wortel.conf` asks for it.
    ///
    /// Derived rather than guessed: with `wortel.conf` saying
    /// `no-cursor,no-path,ssh-terminfo,ssh-env`, a real session's shell receives
    /// `GHOSTTY_SHELL_FEATURES=ssh-env,ssh-terminfo,title`. That is only
    /// consistent with cursor/path/title defaulting on and sudo defaulting off,
    /// and `featuresTests` pins the whole derivation against that measurement.
    static let featuresOnByDefault: Set<String> = ["cursor", "path", "title"]

    /// Turn `wortel.conf`'s `shell-integration-features` line into the value the
    /// core exports: the enabled features only, comma separated, sorted.
    ///
    /// The exported form lists what is **on**; the config form lists changes
    /// against the defaults, with `no-` to disable. They are not the same
    /// string, and handing the scripts the config form would enable everything
    /// it names — including the ones it names in order to turn them off, since
    /// the scripts test with `== *"path"*`.
    static func features(fromConfig config: String) -> String {
        var enabled = featuresOnByDefault
        for entry in config.split(separator: ",") {
            let name = entry.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("no-") {
                enabled.remove(String(name.dropFirst(3)))
            } else if !name.isEmpty {
                enabled.insert(name)
            }
        }
        return enabled.sorted().joined(separator: ",")
    }

    /// Single-quote for the trampoline's `-c`. Paths with spaces are ordinary
    /// on a Mac (`/Users/some one/bin/zsh`), and an unquoted one would exec the
    /// wrong file or nothing at all.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The user's login shell: what they configured, else the passwd entry,
    /// else the system default. `SHELL` is what every terminal honours.
    static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        if let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
