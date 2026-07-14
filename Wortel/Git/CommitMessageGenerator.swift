import FoundationModels

/// Drafts a commit message from a staged diff using Apple's on-device
/// Foundation Model (Apple Intelligence). No key, no network, fully private.
/// Requires macOS 26+ on Apple-Intelligence-capable hardware; callers gate on
/// `isAvailable` and hide the affordance when it's false.
@available(macOS 26.0, *)
enum CommitMessageGenerator {
    /// The on-device model is present, enabled, and ready right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The model's context is small, so we cap the diff we feed it.
    private static let maxDiffCharacters = 6000

    static func generate(diff: String) async throws -> String {
        let trimmedDiff = diff.count > maxDiffCharacters
            ? String(diff.prefix(maxDiffCharacters)) + "\n… (diff truncated)"
            : diff

        let session = LanguageModelSession(instructions: """
        You write concise git commit messages from a staged diff.
        Reply with ONLY the commit message — no quotes, no backticks, no preamble.
        First line: an imperative summary under ~60 characters (e.g. "Add …", \
        "Fix …", "Refactor …"). If the change is non-trivial, add a blank line \
        then 1–3 short lines of detail. Describe what changed and why, not the \
        mechanics of the diff.
        """)

        let response = try await session.respond(to: "Staged diff:\n\n\(trimmedDiff)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
