import Foundation
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterCSS
import TreeSitterPython
import TreeSitterBash
import TreeSitterHTML
import TreeSitterYAML
import TreeSitterZig
import TreeSitterGo
import TreeSitterRust
import TreeSitterC
import TreeSitterCPP
import TreeSitterRuby
import TreeSitterJava
import TreeSitterTOML

/// Off-main-thread tree-sitter highlighting for diffs.
///
/// An `actor` so its `Parser` and the per-language `LanguageConfiguration`s —
/// expensive to build (they compile the grammar's `highlights.scm`), so built
/// once and cached forever — are only ever touched serially on a background
/// executor, never the main thread the terminal renders on. One diff is
/// highlighted at a time, which is all the UI needs: a new file selection
/// supersedes the previous request.
///
/// Highlighting parses the *reconstructed* per-hunk text (see `DiffSyntax`),
/// never the file on disk — so it's purely in-memory, bounded by `DiffParser`'s
/// existing caps, and can't drift from the diff being shown.
actor DiffHighlighter: DiffHighlighting {
    static let shared = DiffHighlighter()

    private let parser = Parser()
    /// nil value = this grammar failed to load once; don't keep retrying it.
    private var configs: [Grammar: LanguageConfiguration?] = [:]

    /// Map every highlightable diff line to its coloured runs, keyed by
    /// `DiffLine.id`. Lines in a language we don't support (or can't parse) are
    /// simply absent — the cell draws them in the default colour.
    /// Above this many diff lines, leave the patch plain. Tokenising is off-main
    /// and colour is optional, but a huge single-file rewrite would still spend a
    /// noticeable fraction of a second in tree-sitter's match resolution — and
    /// nobody reads six thousand lines of diff by their syntax colours. Keeps the
    /// panel's cost bounded, in the spirit of "cost tracks the window on screen."
    /// Real diffs are far smaller; this only trips on generated/rewritten files.
    static let maxHighlightLines = 6_000

    func highlight(_ lines: [DiffLine]) -> [Int: [HighlightSpan]] {
        guard lines.count <= Self.maxHighlightLines else { return [:] }
        var spans: [Int: [HighlightSpan]] = [:]
        for segment in DiffSyntax.segments(lines) {
            guard let grammar = segment.path.flatMap(Grammar.init(path:)),
                  let config = configuration(for: grammar),
                  let query = config.queries[.highlights] else { continue }
            guard (try? parser.setLanguage(config.language)) != nil,
                  let tree = parser.parse(segment.text) else { continue }

            let captures = query.execute(in: tree)
                .resolve(with: .init(string: segment.text))
                .highlights()
                .compactMap { named -> (range: NSRange, token: HighlightToken)? in
                    HighlightToken.from(capture: named.name).map { (named.range, $0) }
                }
            spans.merge(DiffSyntax.distribute(captures, over: segment)) { $0 + $1 }
        }
        return spans
    }

    private func configuration(for grammar: Grammar) -> LanguageConfiguration? {
        if let cached = configs[grammar] { return cached }
        let config = try? grammar.makeConfiguration()
        configs[grammar] = config
        return config
    }
}

/// The tree-sitter grammars we bundle, and how a file path picks one. Adding a
/// language is a package in `project.yml`, its module in the imports above, and
/// a case here (plus its extensions). Grammars whose scanner needs vendoring
/// are noted in `Grammars/README.md`.
enum Grammar: Hashable {
    case swift, typescript, tsx, javascript, json, css, python, bash
    case html, yaml, zig, go, rust, c, cpp, ruby, java, toml

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": self = .swift
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "json": self = .json
        case "css": self = .css
        case "py", "pyi": self = .python
        case "sh", "bash", "zsh": self = .bash
        case "html", "htm": self = .html
        case "yaml", "yml": self = .yaml
        case "zig": self = .zig
        case "go": self = .go
        case "rs": self = .rust
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx": self = .cpp
        case "rb": self = .ruby
        case "java": self = .java
        case "toml": self = .toml
        default: return nil
        }
    }

    /// Build the grammar's configuration, loading its bundled `highlights.scm`.
    /// `name` must match the module suffix `TreeSitter<name>` so the derived
    /// query-bundle name (`TreeSitter<name>_TreeSitter<name>`) resolves — hence
    /// `CPP`, not `C++`. TSX lives in the TypeScript package, so its bundle is
    /// named explicitly.
    func makeConfiguration() throws -> LanguageConfiguration {
        switch self {
        case .swift:      return try LanguageConfiguration(tree_sitter_swift(), name: "Swift")
        // TypeScript/TSX ship only their delta over JavaScript, and C++ its delta
        // over C — SwiftTreeSitter doesn't resolve that inheritance, so we
        // concatenate the base grammar's highlights.scm ourselves (the child is a
        // superset, so the base patterns compile against it).
        case .typescript: return try Self.combined(tree_sitter_typescript(), name: "TypeScript",
                                                   bundles: [Self.jsBundle, "TreeSitterTypeScript_TreeSitterTypeScript"])
        case .tsx:        return try Self.combined(tree_sitter_tsx(), name: "TSX",
                                                   bundles: [Self.jsBundle, "TreeSitterTypeScript_TreeSitterTSX"])
        case .cpp:        return try Self.combined(tree_sitter_cpp(), name: "CPP",
                                                   bundles: ["TreeSitterC_TreeSitterC", "TreeSitterCPP_TreeSitterCPP"])
        case .javascript: return try LanguageConfiguration(tree_sitter_javascript(), name: "JavaScript")
        case .json:       return try LanguageConfiguration(tree_sitter_json(), name: "JSON")
        case .css:        return try LanguageConfiguration(tree_sitter_css(), name: "CSS")
        case .python:     return try LanguageConfiguration(tree_sitter_python(), name: "Python")
        case .bash:       return try LanguageConfiguration(tree_sitter_bash(), name: "Bash")
        case .html:       return try LanguageConfiguration(tree_sitter_html(), name: "HTML")
        case .yaml:       return try LanguageConfiguration(tree_sitter_yaml(), name: "YAML")
        case .zig:        return try LanguageConfiguration(tree_sitter_zig(), name: "Zig")
        case .go:         return try LanguageConfiguration(tree_sitter_go(), name: "Go")
        case .rust:       return try LanguageConfiguration(tree_sitter_rust(), name: "Rust")
        case .c:          return try LanguageConfiguration(tree_sitter_c(), name: "C")
        case .ruby:       return try LanguageConfiguration(tree_sitter_ruby(), name: "Ruby")
        case .java:       return try LanguageConfiguration(tree_sitter_java(), name: "Java")
        case .toml:       return try LanguageConfiguration(tree_sitter_toml(), name: "TOML")
        }
    }

    private static let jsBundle = "TreeSitterJavaScript_TreeSitterJavaScript"

    /// A configuration whose highlights query is several bundles' `highlights.scm`
    /// concatenated (base grammars first, so the child's rules can override).
    /// Falls back to the child bundle alone if the combined query won't compile.
    private static func combined(_ ptr: OpaquePointer, name: String, bundles: [String]) throws -> LanguageConfiguration {
        let language = Language(ptr)
        let scm = bundles.compactMap(highlightsSCM(bundle:)).joined(separator: "\n")
        if !scm.isEmpty, let data = scm.data(using: .utf8),
           let query = try? Query(language: language, data: data) {
            return LanguageConfiguration(language, name: name, queries: [.highlights: query])
        }
        return try LanguageConfiguration(ptr, name: name, bundleName: bundles.last!)
    }

    /// The text of a grammar bundle's `highlights.scm`, found in the app bundle.
    private static func highlightsSCM(bundle bundleName: String) -> String? {
        guard let url = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
              let bundle = Bundle(url: url),
              let scm = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries")
        else { return nil }
        return try? String(contentsOf: scm, encoding: .utf8)
    }
}

