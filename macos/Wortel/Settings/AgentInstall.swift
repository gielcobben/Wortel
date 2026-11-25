import Foundation

/// The agents Wortel offers to help install on a Mac that has none, and the
/// one line each of their own sites gives for it.
///
/// **Wortel installs nothing.** The line is put on a terminal's prompt,
/// unsent, and the person reads it and presses Return: it runs in their own
/// shell, as if they had copied it from the agent's page, and it is that
/// agent's installer that does the work. Nothing is written into the agent
/// afterwards either (`docs/product.md`, "The agent is a guest").
///
/// Three, not thirteen: the ones people start (`agent_started`), and only
/// with an installer that needs nothing a new Mac lacks. A line that begins
/// with `npm` or `brew` is two more installs on such a Mac, which is the
/// chain this is here to shorten.
///
/// Each line was read off the agent's own page on 2026-11-23, and has to be
/// read again there before it is changed:
/// - Claude Code, "Native Install (Recommended)": code.claude.com/docs/en/setup
/// - Codex, "Run the following on Mac or Linux": github.com/openai/codex
/// - Pi, "Install the command-line interface": github.com/earendil-works/pi
enum AgentInstall {
    struct Agent: Equatable, Identifiable {
        /// What starts it, and what `AgentCommands` knows it by.
        let command: String
        /// What it is called in a menu.
        let name: String
        /// Its own installer, as one line, with no newline: typed, not run.
        let line: String

        var id: String { command }
    }

    static let offered = [
        Agent(command: "claude", name: "Claude Code",
              line: "curl -fsSL https://claude.ai/install.sh | bash"),
        Agent(command: "codex", name: "Codex",
              line: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"),
        Agent(command: "pi", name: "Pi",
              line: "curl -fsSL https://pi.dev/install.sh | sh"),
    ]
}
