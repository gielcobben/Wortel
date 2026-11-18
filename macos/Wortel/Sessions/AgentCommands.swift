import Foundation

/// The agents Wortel knows by the name of their command.
///
/// One list in Swift. The shell integration has the same names six times
/// over (two classifiers in each of zsh, bash and fish, which cannot share a
/// file), and `AgentCommandsTests` reads all six and fails when one drifts.
///
/// Knowing a name is never required: detection works for an agent Wortel has
/// not heard of, and Settings' field takes any command. The list is only
/// what the field's pull-down can offer without being asked.
enum AgentCommands {
    /// In the shell integration's own order.
    static let detected = [
        "claude", "pi", "aider", "codex", "cursor-agent", "gemini", "opencode",
        "goose", "cline", "ollama", "llm", "crush", "amp",
    ]

    /// What the pull-down may offer when found on the Mac. `ollama` and `llm`
    /// are left out: typed bare they print their usage and exit, so neither
    /// is something a new session could start with.
    static let offered = detected.filter { !["ollama", "llm"].contains($0) }
}
