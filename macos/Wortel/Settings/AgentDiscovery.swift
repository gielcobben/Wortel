import Foundation

/// Which known agents this Mac has, for the pull-down in Settings.
///
/// **Asked of the person's own shell**, because nothing else knows. An app
/// opened from the Dock has launchd's PATH; an agent installed through nvm,
/// fnm, mise or bun, or one that is an alias or a function, exists only once
/// the login shell has read its files. And the command Settings holds is
/// typed into that same shell, so "the shell can run it" is exactly the
/// question.
///
/// Run once when the Settings window opens, off the main thread, and never
/// otherwise: nothing here costs anything while the window is closed.
enum AgentDiscovery {
    /// The lines around the answer. Whatever the shell's own files print
    /// (a banner, a version manager's notice) falls outside them.
    static let opening = "wortel-agents-begin"
    static let closing = "wortel-agents-end"

    /// The command line that prints, between the two sentinels, each of
    /// `names` the shell can run. nil for a shell Wortel doesn't know how to
    /// ask.
    static func script(for shell: ShellSpawn.Shell, names: [String]) -> String? {
        let list = names.joined(separator: " ")
        switch shell {
        case .zsh, .bash:
            return "echo \(opening); for c in \(list); do command -v \"$c\" >/dev/null 2>&1 && echo \"$c\"; done; echo \(closing)"
        case .fish:
            return "echo \(opening); for c in \(list); type -q $c; and echo $c; end; echo \(closing)"
        case .other:
            return nil
        }
    }

    /// The names in `output` between the sentinels, kept only when they are
    /// in `names`, in `names`' order. nil when the answer never came (no
    /// opening line, or no closing one: the shell was cut off).
    static func parse(_ output: String, names: [String]) -> [String]? {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let start = lines.lastIndex(of: opening),
              let end = lines[start...].firstIndex(of: closing) else { return nil }
        let found = Set(lines[(start + 1)..<end])
        return names.filter(found.contains)
    }

    /// Where agents are usually installed, for when the shell can't be
    /// asked. Finds a binary, never an alias.
    static func scan(names: [String], home: String = NSHomeDirectory(),
                     isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [String] {
        let directories = GitService.installDirectories + [
            "\(home)/.bun/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin", "\(home)/.opencode/bin",
        ]
        return names.filter { name in directories.contains { isExecutable("\($0)/\(name)") } }
    }

    /// The agents found: the shell's answer, or the folder scan when the
    /// shell gave none in time.
    static func find(names: [String] = AgentCommands.offered) async -> [String] {
        let path = ShellSpawn.loginShell()
        if let script = script(for: ShellSpawn.Shell(path: path), names: names) {
            // Login and interactive, so the files that set PATH and define
            // aliases are read, as they are for a session's shell.
            let result = await GitService.runTool(
                [path, "-l", "-i", "-c", script], environment: ProcessInfo.processInfo.environment,
                in: NSHomeDirectory(), timeout: 3)
            if let found = parse(result.stdout, names: names) { return found }
        }
        return scan(names: names)
    }
}
