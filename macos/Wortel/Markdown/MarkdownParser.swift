import Foundation

/// One document-level Markdown block, structure preserved so the view can lay
/// each out with its own type style. Inline markdown (bold/italic/code/links)
/// is *not* parsed here — it stays in `text` and is rendered per-block with
/// Foundation's `AttributedString(markdown:)`. Only block structure lives here,
/// which is the fiddly, bug-prone part, so it's pure Foundation and unit-tested
/// (it compiles into `WortelTests` without dragging in the tree-sitter grammars
/// the code-block highlighter needs).
///
/// Modeled on cmux's native renderer (a line-based parser rather than a full
/// CommonMark engine): coding agents emit headings, lists and fences in nearly
/// every reply, and this covers those plus GitHub tables — enough for reading a
/// file an agent just wrote, without a markdown dependency.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        /// ATX heading, `level` 1...6.
        case heading(level: Int)
        /// A paragraph of running text (soft line breaks preserved).
        case paragraph
        /// A bullet list item at `indent` depth (0-based, 2 spaces per level).
        case bullet(indent: Int)
        /// A GitHub task-list item (`- [ ]` / `- [x]`) — a bullet whose marker is
        /// a checkbox.
        case task(indent: Int, checked: Bool)
        /// An ordered list item showing `marker` (e.g. "1.") at `indent`.
        case ordered(indent: Int, marker: String)
        /// A block quote (consecutive `>` lines coalesced).
        case quote
        /// A horizontal rule (`---`, `***`, `___`).
        case rule
        /// A fenced code block; `language` is the fence's info string.
        case code(language: String?)
        /// A GitHub-style table, already split into header + body cells.
        case table(header: [String], rows: [[String]])
    }

    let id: Int
    let kind: Kind
    /// Inline-markdown text for text-bearing blocks; the raw code for `.code`;
    /// empty for `.rule` and `.table` (whose data rides in the kind).
    let text: String
}

/// Parses a Markdown string into `[MarkdownBlock]`. Pure and synchronous.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for segment in segments(from: source) {
            switch segment {
            case .code(let language, let code):
                blocks.append(MarkdownBlock(id: blocks.count, kind: .code(language: language), text: code))
            case .text(let run):
                for (kind, text) in textBlocks(from: run) {
                    blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: text))
                }
            }
        }
        return blocks
    }

    // MARK: - Fenced-code segmentation

    private enum Segment {
        case text(String)
        case code(language: String?, code: String)
    }

    /// Splits `source` on ``` fences into text runs and code blocks. An
    /// unterminated fence swallows the rest as code, so a file being written
    /// still renders sensibly mid-stream.
    private static func segments(from source: String) -> [Segment] {
        var segments: [Segment] = []
        var textLines: [Substring] = []
        var codeLines: [Substring] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            let joined = textLines.joined(separator: "\n")
            textLines = []
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.text(joined))
        }
        func flushCode() {
            segments.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
            codeLines = []
            codeLanguage = nil
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") {
                if inCode {
                    inCode = false
                    flushCode()
                } else {
                    inCode = true
                    flushText()
                    let language = stripped.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }
            if inCode { codeLines.append(line) } else { textLines.append(line) }
        }
        if inCode { flushCode() } else { flushText() }
        return segments
    }

    // MARK: - Block-level parsing of a text run

    private static func textBlocks(from run: String) -> [(kind: MarkdownBlock.Kind, text: String)] {
        var blocks: [(MarkdownBlock.Kind, String)] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            blocks.append((.paragraph, joined))
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append((.quote, quote.joined(separator: "\n")))
            quote = []
        }

        let lines = run.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                index += 1
                continue
            }

            // Block quote: consecutive `>` lines coalesce, markers stripped.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var q = trimmed.dropFirst()
                if q.hasPrefix(" ") { q = q.dropFirst() }
                quote.append(String(q))
                index += 1
                continue
            }
            flushQuote()

            // GitHub table: a row line followed by a `---|---` separator.
            if index + 1 < lines.count,
               let header = tableRow(from: line),
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count, let cells = tableRow(from: lines[cursor]) {
                    rows.append(cells)
                    cursor += 1
                }
                blocks.append((.table(header: header, rows: rows), ""))
                index = cursor
                continue
            }

            if let structural = structuralBlock(from: line) {
                flushParagraph()
                blocks.append(structural)
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    /// A single structural line — heading / rule / bullet / ordered — or nil for
    /// plain prose. Order matters: rules are checked before bullets so `* * *`
    /// isn't read as a bullet.
    private static func structuralBlock(from line: String) -> (MarkdownBlock.Kind, String)? {
        let indentWidth = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = indentWidth / 2

        // ATX heading: 1-6 '#' then a space.
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes >= 1, hashes <= 6 {
                let rest = trimmed.dropFirst(hashes)
                if rest.hasPrefix(" ") {
                    return (.heading(level: hashes), rest.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // Horizontal rule: 3+ of a single marker (-, *, _), spaces allowed.
        let ruleChars = trimmed.filter { !$0.isWhitespace }
        if ruleChars.count >= 3,
           let marker = ruleChars.first, "-*_".contains(marker),
           ruleChars.allSatisfy({ $0 == marker }) {
            return (.rule, "")
        }

        // Bullet: -, *, or + then a space. A `[ ]` / `[x]` right after the
        // marker makes it a task-list item instead.
        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            if rest.hasPrefix(" ") {
                let item = rest.trimmingCharacters(in: .whitespaces)
                if let task = taskItem(from: item, indent: indent) { return task }
                return (.bullet(indent: indent), item)
            }
        }

        // Ordered: digits then '.' or ')' then a space.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                let rest = afterDigits.dropFirst()
                if rest.hasPrefix(" ") {
                    return (.ordered(indent: indent, marker: "\(digits)\(delimiter)"),
                            rest.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        return nil
    }

    /// A bullet's text that begins with a `[ ]` / `[x]` checkbox → a task item
    /// with the checkbox stripped. Case-insensitive on the mark; anything else
    /// inside the brackets isn't a task.
    private static func taskItem(from text: String, indent: Int) -> (MarkdownBlock.Kind, String)? {
        let chars = Array(text)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        let checked: Bool
        switch chars[1] {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        // The checkbox must be followed by a space or be the whole item.
        guard chars.count == 3 || chars[3] == " " else { return nil }
        let body = String(chars[3...]).trimmingCharacters(in: .whitespaces)
        return (.task(indent: indent, checked: checked), body)
    }

    // MARK: - Tables

    /// The cells of a table row, or nil when the line isn't one. Leading and
    /// trailing pipes are optional (GitHub allows both `a | b` and `| a | b |`).
    static func tableRow(from line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let cells = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    /// A `---|:--:|--:` separator row: every cell is dashes with optional edge
    /// colons (the alignment markers), at least one dash.
    static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableRow(from: line) else { return false }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }
}
