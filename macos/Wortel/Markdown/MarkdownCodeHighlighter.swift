import Foundation
import SwiftTreeSitter

/// Off-main-thread tree-sitter highlighting for fenced code blocks in the
/// Markdown preview. The diff view's `DiffHighlighter` does the same job for
/// diffs but works on reconstructed per-hunk `[DiffLine]`; a code block is just
/// a whole string in one language, so this is the simpler sibling: tokenize the
/// string, hand back spans. It reuses the shared `Grammar` (grammar loading) and
/// `HighlightToken` (capture folding) from the git diff stack, so a code block
/// is coloured with the exact same GitHub palette as a diff.
///
/// An `actor` for the same reason `DiffHighlighter` is: the `Parser` and the
/// compiled `LanguageConfiguration`s are expensive to build and must only be
/// touched serially, off the terminal's render thread.
actor MarkdownCodeHighlighter {
    static let shared = MarkdownCodeHighlighter()

    private let parser = Parser()
    /// nil value = this grammar failed to load once; don't keep retrying it.
    private var configs: [Grammar: LanguageConfiguration?] = [:]

    /// Above this many characters, skip highlighting — a giant embedded blob
    /// isn't read by its colours and would stall the parse. Real code blocks in
    /// notes are far smaller.
    static let maxHighlightBytes = 200_000

    /// Tokenize `code` in `grammar`, returning coloured runs as UTF-16 ranges
    /// over the string. Empty when the grammar can't load or the code is too big.
    func spans(for code: String, grammar: Grammar) -> [(range: NSRange, token: HighlightToken)] {
        guard (code as NSString).length <= Self.maxHighlightBytes,
              let config = configuration(for: grammar),
              let query = config.queries[.highlights],
              (try? parser.setLanguage(config.language)) != nil,
              let tree = parser.parse(code) else { return [] }

        return query.execute(in: tree)
            .resolve(with: .init(string: code))
            .highlights()
            .compactMap { named in
                HighlightToken.from(capture: named.name).map { (named.range, $0) }
            }
    }

    private func configuration(for grammar: Grammar) -> LanguageConfiguration? {
        if let cached = configs[grammar] { return cached }
        let config = try? grammar.makeConfiguration()
        configs[grammar] = config
        return config
    }
}

extension Grammar {
    /// Resolve a fenced code block's info string (```` ```swift ````, ```` ```ts ````,
    /// ```` ```python ````) to a grammar. Fence tokens are usually the language
    /// name, sometimes the extension — try the common names first, then fall back
    /// to treating the token as an extension via `init(path:)`.
    init?(fence: String) {
        switch fence.lowercased() {
        case "swift": self = .swift
        case "typescript", "ts": self = .typescript
        case "tsx": self = .tsx
        case "javascript", "js", "node": self = .javascript
        case "json", "jsonc": self = .json
        case "css": self = .css
        case "python", "py", "python3": self = .python
        case "bash", "sh", "shell", "zsh", "console": self = .bash
        case "html", "xml": self = .html
        case "yaml", "yml": self = .yaml
        case "zig": self = .zig
        case "go", "golang": self = .go
        case "rust", "rs": self = .rust
        case "c": self = .c
        case "cpp", "c++", "cc", "cxx": self = .cpp
        case "ruby", "rb": self = .ruby
        case "java": self = .java
        case "toml": self = .toml
        default:
            // Many fence tokens double as file extensions (`rs`, `py`, `sh`);
            // reuse the extension mapping for anything not named above.
            guard let grammar = Grammar(path: "x.\(fence.lowercased())") else { return nil }
            self = grammar
        }
    }
}
