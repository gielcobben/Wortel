import Foundation
import os

/// Which known agents this Mac has, for the pull-down in Settings and for
/// the Setup section of the permissions popover (`Permissions.lookForAgent`).
///
/// **Asked of the person's own shell**, because nothing else knows. An app
/// opened from the Dock has launchd's PATH; an agent installed through nvm,
/// fnm, mise or bun, or one that is an alias or a function, exists only once
/// the login shell has read its files. And the command Settings holds is
/// typed into that same shell, so "the shell can run it" is exactly the
/// question.
///
/// **And of that shell as a session has it.** A session's shell has
/// `~/.local/bin` on its PATH whatever its files say, because the shell
/// integration puts it there (it is where Claude Code's installer leaves
/// `claude`, and a new Mac's PATH doesn't have it). The shell asked here
/// has no integration, so the question adds that folder itself, or Settings
/// would say an agent that runs in every session isn't installed.
///
/// Run when the Settings window opens, and at launch and when the
/// permissions popover opens on a Mac where no agent has been seen yet
/// (`Permissions.lookForAgent`: once one has, that asks nothing again).
/// Always off the main thread, one shell at a time.
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
            return "PATH=\"$PATH:$HOME/.local/bin\"; echo \(opening); for c in \(list); do command -v \"$c\" >/dev/null 2>&1 && echo \"$c\"; done; echo \(closing)"
        case .fish:
            return "set PATH $PATH \"$HOME/.local/bin\"; echo \(opening); for c in \(list); type -q $c; and echo $c; end; echo \(closing)"
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
    /// shell gave none.
    @MainActor
    static func find(names: [String] = AgentCommands.offered) async -> [String] {
        await ask(names: names) ?? scan(names: names)
    }

    /// The shell's own answer, and nil when it gave none: it took too long,
    /// it is a shell Wortel can't ask, or another question is still out.
    /// An empty answer is the shell saying it can run none of them, which
    /// is the only "no" worth telling anyone (`Permissions.lookForAgent`).
    ///
    /// The shell gets four seconds, counted here and not left to the command
    /// runner: that waits for the shell's output to close, and a startup
    /// file that leaves something running in the background keeps it open
    /// long after the shell itself has gone. An answer that comes later is
    /// dropped, and while one is still outstanding no second shell is
    /// started behind it.
    @MainActor
    static func ask(names: [String] = AgentCommands.offered) async -> [String]? {
        let path = ShellSpawn.loginShell()
        guard !probing, let script = script(for: ShellSpawn.Shell(path: path), names: names) else {
            return nil
        }
        probing = true
        return await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLock<CheckedContinuation<[String]?, Never>?>(initialState: continuation)
            let finish = { @Sendable (found: [String]?) in
                once.withLock { waiting in
                    waiting?.resume(returning: found)
                    waiting = nil
                }
            }
            Task.detached {
                // Login and interactive, so the files that set PATH and
                // define aliases are read, as they are for a session's shell.
                let result = await GitService.runTool(
                    [path, "-l", "-i", "-c", script], environment: ProcessInfo.processInfo.environment,
                    in: NSHomeDirectory(), timeout: 3)
                await MainActor.run { probing = false }
                finish(parse(result.stdout, names: names))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(4))
                finish(nil)
            }
        }
    }

    /// A shell is out answering. Main thread only.
    @MainActor private static var probing = false
}
