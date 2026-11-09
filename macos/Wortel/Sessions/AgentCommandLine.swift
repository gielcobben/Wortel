import Foundation

/// What an agent's launch line tells a resume: how the agent was started, and
/// the flags that set how it runs.
///
/// A resume used to be the bare agent and its resume flag, so
/// `claude --dangerously-skip-permissions --model opus` came back as
/// `claude --resume <id>`: the same conversation, asking for permission at
/// every step on another model. And `CLAUDE_CONFIG_DIR=… claude` or
/// `devx pi` came back without what put the agent on its feet, which either
/// failed to start or opened the wrong account's conversations.
///
/// The line is the one the shell integration recorded (`argv=` in the
/// marker): one line, as typed with aliases expanded, never evaluated. So
/// only what can be carried **without a shell reading it** is carried: plain
/// words, no quotes, no expansions. Anything else is left out rather than
/// guessed at, and the resume is still the right conversation.
enum AgentCommandLine {
    /// The words of the agent's own command, split on spaces as the marker
    /// stores it, up to the first `;`, `&&`, `||`, `|` or `&`. The marker
    /// records the line from the agent to its end, so in `claude; codex -m x`
    /// the `-m x` is codex's, and must not become claude's on a resume.
    static func words(_ argv: String?) -> [String] {
        var words: [String] = []
        for word in argv?.split(separator: " ") ?? [] {
            if separators.contains(String(word)) { break }
            if word.hasSuffix(";") {
                if word.count > 1 { words.append(String(word.dropLast())) }
                break
            }
            words.append(String(word))
        }
        return words
    }

    private static let separators: Set<String> = [";", "&&", "||", "|", "&", "|&"]

    /// A word a shell reads back as itself: nothing to expand, quote or split.
    static func isPlain(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { plain.contains($0) }
    }

    private static let plain = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_./:@%+=,~-"))

    /// Whether a command line is one simple command, safe to run again as
    /// typed. `ollama run x; rm -rf build` is not: re-running it re-runs the
    /// `rm`. Nor is a heredoc, which the marker flattened onto one line.
    static func isSimple(_ argv: String) -> Bool {
        !argv.unicodeScalars.contains { unsafe.contains($0) }
    }

    private static let unsafe = CharacterSet(charactersIn: ";&|<>`$(){}\n\\")

    /// The words that start the agent, as typed: leading `NAME=value`
    /// assignments and any wrapper (`devx`, `nohup`, a path), up to and
    /// including the agent's own name. nil when the agent isn't named by a
    /// plain word of its own (`npx @anthropic-ai/claude-code`), or something in
    /// front of it needs a shell to read; the caller then uses the bare name.
    ///
    /// `exec` is dropped: typed into a fresh shell it would replace that shell
    /// with the agent, which is how the session was started, but not a thing a
    /// resume should do on the user's behalf.
    static func launcher(agent: String, argv: String?) -> [String]? {
        let words = words(argv)
        guard let index = words.firstIndex(where: { names(agent, $0) }) else { return nil }
        let front = words[...index].filter { $0 != "exec" }
        guard front.allSatisfy(isPlain) else { return nil }
        return Array(front)
    }

    /// Whether `word` is the agent: its name, or a path ending in it.
    private static func names(_ agent: String, _ word: String) -> Bool {
        word == agent || word.hasSuffix("/" + agent)
    }

    /// The flags on the line that set how `agent` runs, in the order typed,
    /// ready to go on a resume. Only flags known to mean the same on a resume
    /// (`flagTable`), and only with a plain value; the conversation flags
    /// (`--resume`, `--continue`, `--session`), one-shot modes and prompts are
    /// never carried, because the resume names its own conversation.
    static func carriedFlags(agent: String, argv: String?) -> [String] {
        guard let table = flagTable[agent] else { return [] }
        let words = words(argv)
        guard let start = words.firstIndex(where: { names(agent, $0) }) else { return [] }
        var carried: [String] = []
        var index = start + 1
        while index < words.count {
            let word = words[index]
            index += 1
            if table.bare.contains(word) {
                carried.append(word)
            } else if let equals = word.firstIndex(of: "="), word.hasPrefix("-"),
                      table.valued.contains(String(word[..<equals])) {
                if isPlain(String(word[word.index(after: equals)...])) { carried.append(word) }
            } else if table.valued.contains(word), index < words.count, !words[index].hasPrefix("-") {
                let value = words[index]
                index += 1
                if isPlain(value) { carried += [word, value] }
            }
        }
        return carried
    }

    /// The resume to type: how the agent was started, then `resume` (the
    /// agent's own words for "this conversation"), then the carried flags.
    /// Codex takes its options after its `resume` and `fork` subcommands, so
    /// they go between it and the conversation. `excluding` drops flags that
    /// would be wrong where it's typed (Codex's `--cd`, which names the
    /// folder it ran in).
    static func command(agent: String, argv: String?, resume: [String],
                        excluding: Set<String> = []) -> String {
        let launcher = launcher(agent: agent, argv: argv) ?? [agent]
        let flags = without(excluding, carriedFlags(agent: agent, argv: argv))
        let tail: [String]
        if let first = resume.first, first == "resume" || first == "fork" {
            tail = [first] + flags + resume.dropFirst()
        } else {
            tail = resume + flags
        }
        return (launcher + tail).joined(separator: " ")
    }

    /// `flags` without the ones named in `excluded`, and without their values:
    /// `-C dir` and `--cd=dir` both go.
    private static func without(_ excluded: Set<String>, _ flags: [String]) -> [String] {
        guard !excluded.isEmpty else { return flags }
        var kept: [String] = []
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            index += 1
            if let equals = flag.firstIndex(of: "="), excluded.contains(String(flag[..<equals])) { continue }
            if excluded.contains(flag) {
                // A valued flag is always carried with its value (see
                // `carriedFlags`), so the next word is that value.
                if index < flags.count, !flags[index].hasPrefix("-") { index += 1 }
                continue
            }
            kept.append(flag)
        }
        return kept
    }

    /// The agent's own command (`words`) with every relative path in it made
    /// absolute against `directory`, where it was started: a relative launcher
    /// (`./bin/claude`), an assignment's value (`CLAUDE_CONFIG_DIR=./cfg`) and
    /// the values of the flags that name a file or a folder (`pathFlags`).
    ///
    /// For a resume typed somewhere else. Carried as it was, a
    /// relative `--add-dir ../shared` would name a different folder after the
    /// `cd`, or none, and the agent would start without what it had. Only
    /// what's already carried can change, so only plain words are touched.
    static func absolutized(agent: String, argv: String?, from directory: String) -> String? {
        let words = words(argv)
        guard !words.isEmpty else { return argv }
        let agentIndex = words.firstIndex(where: { names(agent, $0) })
        let pathFlags = pathFlags[agent] ?? []
        func absolute(_ path: String) -> String {
            guard isPlain(path), !path.hasPrefix("/"), !path.hasPrefix("~") else { return path }
            return URL(fileURLWithPath: directory).appendingPathComponent(path).standardizedFileURL.path
        }
        var rewritten: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            guard let agentIndex else { rewritten.append(word); continue }
            if index - 1 < agentIndex {
                // The launcher: `NAME=value` with a value that's a relative
                // path, or a relative path to the agent itself.
                if let equals = word.firstIndex(of: "="), !word.hasPrefix("-") {
                    let value = String(word[word.index(after: equals)...])
                    let relative = value.hasPrefix("./") || value.hasPrefix("../")
                    rewritten.append(relative ? String(word[...equals]) + absolute(value) : word)
                } else {
                    rewritten.append(word)
                }
            } else if index - 1 == agentIndex {
                rewritten.append(word.contains("/") ? absolute(word) : word)
            } else if let equals = word.firstIndex(of: "="), word.hasPrefix("-"),
                      pathFlags.contains(String(word[..<equals])) {
                rewritten.append(String(word[...equals]) + absolute(String(word[word.index(after: equals)...])))
            } else if pathFlags.contains(word), index < words.count, !words[index].hasPrefix("-") {
                rewritten += [word, absolute(words[index])]
                index += 1
            } else {
                rewritten.append(word)
            }
        }
        return rewritten.joined(separator: " ")
    }

    /// The carried flags (`flagTable`) whose value is a path, from each
    /// agent's `--help`. `--settings` and `--mcp-config` also take JSON, which
    /// is never plain and so never touched.
    private static let pathFlags: [String: Set<String>] = [
        "claude": ["--settings", "--add-dir", "--mcp-config", "--plugin-dir"],
        "pi": ["--extension", "-e", "--skill", "--session-dir", "--prompt-template", "--theme"],
        "codex": ["--cd", "-C", "--add-dir"],
    ]

    /// Whether `id` can be typed into a shell as it is: every exact resume
    /// puts a conversation id on a command line, and the ids come from files
    /// other programs wrote.
    static func isSafeID(_ id: String) -> Bool {
        id.count <= 128 && !id.hasPrefix("-") && id.unicodeScalars.allSatisfy { idCharacters.contains($0) }
    }

    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))

    private struct Flags {
        let bare: Set<String>
        let valued: Set<String>
    }

    /// Flags that set how an agent runs and mean the same on a resume, from
    /// each agent's own `--help` (Claude Code 2.1, Pi, Codex). Deliberately a
    /// list of what to keep rather than of what to drop: an unknown flag might
    /// take a value, and dropping the flag but keeping the value would turn it
    /// into a prompt.
    private static let flagTable: [String: Flags] = [
        "claude": Flags(
            bare: ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                   "--chrome", "--no-chrome", "--ide", "--verbose", "--bare",
                   "--disable-slash-commands", "--brief"],
            valued: ["--model", "--permission-mode", "--effort", "--fallback-model", "--agent",
                     "--settings", "--add-dir", "--mcp-config", "--plugin-dir", "--autocompact"]),
        "pi": Flags(
            bare: ["--no-tools", "-nt", "--no-builtin-tools", "-nbt", "--no-extensions", "-ne",
                   "--no-skills", "-ns", "--no-context-files", "-nc", "--approve", "-a",
                   "--no-approve", "-na", "--offline", "--no-themes", "--no-prompt-templates", "-np"],
            valued: ["--model", "--provider", "--thinking", "--models", "--tools", "-t",
                     "--exclude-tools", "-xt", "--extension", "-e", "--skill", "--session-dir",
                     "--prompt-template", "--theme"]),
        "codex": Flags(
            bare: ["--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--search", "--oss"],
            valued: ["--model", "-m", "--ask-for-approval", "-a", "--sandbox", "-s",
                     "--profile", "-p", "-c", "--config", "--cd", "-C", "--add-dir"]),
    ]
}
