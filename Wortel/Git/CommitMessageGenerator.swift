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

    Rules:
    - Reply with ONLY the commit message. No quotes, no backticks, no preamble \
    like "Here is".
    - First line: an imperative summary under ~60 characters \
    (e.g. "Add push button to the git panel").
    - Capture the SINGLE overall intent of the whole change. Do NOT enumerate \
    files, functions, or hunks. Never write "Add method for X. Add method for \
    Y." — collapse related edits into one theme.
    - Only if the change is large or its purpose isn't obvious from the summary, \
    add a blank line then 1–2 short sentences on what changed and why. \
    Otherwise write just the one summary line.
    """

    static func generate(stat: String, patch: String) async throws -> String {
        var lastError: Error?
        for budget in diffBudgets {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0.3)
                let prompt = condensed(stat: stat, patch: patch, budget: budget)
                let response = try await session.respond(to: prompt, options: options)
                let text = sanitized(response.content)
                if !text.isEmpty { return text }
            } catch {
                // Most likely an "exceeded context window" error on a big diff —
                // drop to the next, smaller budget and try again.
                lastError = error
            }
        }
        throw lastError ?? CommitMessageError.emptyResponse
    }

    /// Build the model prompt within `budget` characters. The stat (which names
    /// every file and its size) is always kept whole; the remaining budget is
    /// split **evenly across files** so a big first file can't crowd the rest
    /// out — the failure mode of a plain `prefix(budget)`, which would show only
    /// the first file and leave the model blind to the actual change.
    private static func condensed(stat: String, patch: String, budget: Int) -> String {
        let header = "Files changed:\n\(stat)\n"
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

    /// Strip wrapping quotes/backticks and a stray leading label the model
    /// sometimes adds despite the instructions.
    private static func sanitized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Commit message:", "Message:"] where s.lowercased().hasPrefix(prefix.lowercased()) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("```"), let end = s.range(of: "```", options: .backwards), end.lowerBound != s.startIndex {
            s = String(s[s.index(s.startIndex, offsetBy: 3)..<end.lowerBound])
            // Drop a leading language tag line if present (```text\n…).
            if let nl = s.firstIndex(of: "\n"), !s[..<nl].contains(" ") {
                s = String(s[s.index(after: nl)...])
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.first == "\"", s.last == "\"" {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CommitMessageError: Error { case emptyResponse }
}
