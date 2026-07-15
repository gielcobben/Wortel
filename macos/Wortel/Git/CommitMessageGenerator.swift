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

    /// The on-device context window is only a few thousand tokens, and diffs are
    /// token-dense, so we feed a bounded slice and shrink it on overflow. Char
    /// budgets, largest first; the smallest is a safe floor that still carries
    /// the file stat. A smaller budget also *improves* quality — less raw patch
    /// means less for the model to parrot line-by-line.
    private static let diffBudgets = [3500, 2000, 1000]

    private static let instructions = """
    You are a senior engineer writing ONE git commit message from a staged diff.

    Guidelines:
    - Capture the SINGLE overall intent of the whole change. Do NOT enumerate \
    files, functions, or hunks. Never write "Add method for X. Add method for \
    Y." — collapse related edits into one theme.
    - The summary is an imperative sentence under ~60 characters \
    (e.g. "Add push button to the git panel"), with no trailing period.
    - Match the style, voice, and any area-prefix convention of the repo's \
    recent commit subjects shown in the prompt (e.g. a "Git panel: …" prefix). \
    Match their style, never their content.
    - Only write a body when the change is large or its purpose isn't obvious \
    from the summary — 1–2 short sentences on what changed and why. Otherwise \
    leave the body empty.
    """

    /// Structured draft — guided generation guarantees the shape, so no parsing
    /// or de-quoting of freeform text is needed.
    @Generable
    struct CommitDraft {
        @Guide(description: "Imperative summary of the whole change, under ~60 characters, no trailing period.")
        var summary: String
        @Guide(description: "1–2 sentence body on what changed and why, only when the summary alone isn't enough. Empty string otherwise.")
        var body: String
    }

    static func generate(
        stat: String, patch: String, branch: String?, recentSubjects: [String]
    ) async throws -> String {
        var lastError: Error?
        for budget in diffBudgets {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0.3)
                let prompt = condensed(
                    stat: stat, patch: patch, budget: budget,
                    branch: branch, recentSubjects: recentSubjects)
                let response = try await session.respond(
                    to: prompt, generating: CommitDraft.self, options: options)
                let text = assemble(response.content)
                if !text.isEmpty { return text }
            } catch {
                // Most likely an "exceeded context window" error on a big diff —
                // drop to the next, smaller budget and try again.
                lastError = error
            }
        }
        throw lastError ?? CommitMessageError.emptyResponse
    }

    /// Join the structured draft into a git message: summary, then a blank line
    /// and the body when one was written.
    private static func assemble(_ draft: CommitDraft) -> String {
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "" }
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? summary : summary + "\n\n" + body
    }

    /// Build the model prompt within `budget` characters. The stat (which names
    /// every file and its size) is always kept whole; the remaining budget is
    /// split **evenly across files** so a big first file can't crowd the rest
    /// out — the failure mode of a plain `prefix(budget)`, which would show only
    /// the first file and leave the model blind to the actual change.
    private static func condensed(
        stat: String, patch: String, budget: Int,
        branch: String?, recentSubjects: [String]
    ) -> String {
        var header = ""
        if let branch, !branch.isEmpty {
            header += "Branch: \(branch)\n"
        }
        if !recentSubjects.isEmpty {
            let examples = recentSubjects.prefix(15).map { "- \($0)" }.joined(separator: "\n")
            header += "Recent commit subjects in this repo (match this style, not their content):\n\(examples)\n\n"
        }
        header += "Files changed:\n\(stat)\n"
        let files = fileChunks(patch)
        let patchBudget = max(400, budget - header.count)

        if patch.count <= patchBudget || files.isEmpty {
            let body = patch.count > patchBudget
                ? String(patch.prefix(patchBudget)) + "\n…(truncated)"
                : patch
            return header + "Diff:\n\(body)"
        }

        let perFile = max(240, patchBudget / files.count)
        let body = files.map { chunk in
            chunk.count > perFile ? String(chunk.prefix(perFile)) + "\n…(file truncated)\n" : chunk
        }.joined()
        return header + "Diff (each file truncated for length):\n\(body)"
    }

    /// Split a unified patch into one chunk per file, each starting at its
    /// `diff --git` header.
    private static func fileChunks(_ patch: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    enum CommitMessageError: Error { case emptyResponse }
}
