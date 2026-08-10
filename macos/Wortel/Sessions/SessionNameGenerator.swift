import AppKit
import FoundationModels

/// Summarises what's happening in a session's terminal into a short sidebar
/// name, using Apple's on-device Foundation Model — the same engine
/// `CommitMessageGenerator` uses. No key, no network, fully private; requires
/// macOS 26+ on Apple-Intelligence-capable hardware. Callers gate on
/// `isAvailable` and simply skip auto-naming when it's false.
///
/// The input is a screen scrape (`SurfaceView.readScreenText`), not an agent
/// transcript: it works for any program — a shell, a build, an agent — with no
/// per-tool coupling, at the cost of seeing an agent's TUI as drawn rather than
/// a clean conversation. `distill` cleans and bounds that scrape first.
@available(macOS 26.0, *)
enum SessionNameGenerator {
    /// The on-device model is present, enabled, and ready right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private static let instructions = """
    You name terminal sessions in a developer's sidebar. Given a snapshot of \
    what's currently on screen in ONE terminal, output ONLY a short title for \
    that session.

    Guidelines:
    - 2 to 4 words, in the same language as the content, no quotes, no dashes, \
    no trailing punctuation.
    - Name it after the concrete task or topic, meaning what the developer is \
    doing (e.g. "Fix quiesce race", "Postgres migration", "Reading Vite docs"). \
    Never just a tool or shell name like "Claude", "zsh", or "npm".
    - If a current title is given and it still fits what's on screen, reply with \
    that exact title unchanged.
    """

    /// Guided generation guarantees the shape, so there's no freeform parsing —
    /// only light sanitising of the one field.
    @Generable
    struct Name {
        @Guide(description: "A 2 to 4 word session title, no quotes, no dashes, no trailing punctuation.")
        var title: String
    }

    /// Summarise `screenText` (already distilled) into a session name. Returns
    /// the sanitised title, or empty if the model produced nothing usable.
    static func generate(screenText: String, cwd: String?, currentName: String?) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.3)
        let prompt = buildPrompt(screenText: screenText, cwd: cwd, currentName: currentName)
        let response = try await session.respond(to: prompt, generating: Name.self, options: options)
        return sanitize(response.content.title)
    }

    /// Turn a raw viewport scrape into a compact, chrome-free tail worth
    /// summarising: drop blank lines and lines that are mostly box-drawing or
    /// spinner glyphs (an agent TUI's borders), then keep the last ~40 lines —
    /// the tail is the current topic. Exposed so the caller can also gate on the
    /// result's length and detect "nothing changed since last time".
    static func distill(_ raw: String) -> String {
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let ink = trimmed.unicodeScalars.filter { $0 != " " }
            guard !ink.isEmpty else { return nil }
            let chrome = ink.reduce(0) { $0 + (isChrome($1) ? 1 : 0) }
            // Mostly borders/spinner → chrome, not content.
            return Double(chrome) / Double(ink.count) < 0.5 ? trimmed : nil
        }
        return kept.suffix(40).joined(separator: "\n")
    }

    /// Box-drawing (U+2500–259F), the braille spinner agents animate
    /// (U+2800–28FF), and the handful of bullets/marks they decorate lines with.
    private static func isChrome(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2500...0x259F, 0x2800...0x28FF: return true
        // • ● ○ ◦ ✓ ✔ ✗ ✘ ✦ ✧ · ▪ ▸ ▹ ⏺
        case 0x2022, 0x25CF, 0x25CB, 0x25E6, 0x2713, 0x2714, 0x2717, 0x2718,
             0x2726, 0x2727, 0x00B7, 0x25AA, 0x25B8, 0x25B9, 0x23FA:
            return true
        default: return false
        }
    }

    /// Build the model prompt. The screen tail goes in verbatim (already
    /// distilled and bounded); the cwd and current title give the model context
    /// for "is the existing name still right".
    private static func buildPrompt(screenText: String, cwd: String?, currentName: String?) -> String {
        var header = ""
        if let cwd, !cwd.isEmpty {
            header += "Working directory: \((cwd as NSString).abbreviatingWithTildeInPath)\n"
        }
        if let currentName, !currentName.isEmpty {
            header += "Current title: \(currentName)\n"
        }
        let budget = 2000
        let text = screenText.count > budget ? String(screenText.suffix(budget)) : screenText
        return header + "\nWhat's on screen now:\n\(text)"
    }

    /// The model is guided but still occasionally wraps the title in quotes or
    /// adds punctuation; take the first line, strip that, and cap the length on
    /// a word boundary.
    private static func sanitize(_ raw: String) -> String {
        var s = (raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, let l = s.last, f == l, "\"'`".contains(f), s.count >= 2 {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        while let last = s.last, ".!,;:".contains(last) { s = String(s.dropLast()) }
        if s.count > 40 {
            let cut = s.prefix(40)
            s = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
