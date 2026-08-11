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
        /// A paragraph that is *nothing but* images — a screenshot on its own
        /// line, or a row of badges. Its own kind because an image is a picture
        /// rather than a run of text, and the two can't share a `Text`: inline
        /// images stay alt text (see `MarkdownImage`).
        case images([MarkdownImage])
    }

    let id: Int
    let kind: Kind
    /// Inline-markdown text for text-bearing blocks; the raw code for `.code`;
    /// empty for `.rule` and `.table` (whose data rides in the kind).
    let text: String
    /// A blank line came before this block. Only lists care: two lists in a row
    /// are separate lists, and without this they run together as one — the
    /// blank line is the *only* thing that distinguishes them.
    var afterBlank = false
    /// The 1-based line in the source this block starts on.
    ///
    /// It's what lets a preview window keep your place across a mode switch: the
    /// rendered document and the source are the same file seen two ways, and a
    /// line number is the only coordinate both of them share. Without it, ⌘2 to
    /// copy a paragraph means finding it again from the top.
    var line: Int = 1
}

/// One image in a document: where it comes from, what it says it is, and where
/// clicking it goes (a badge is an image inside a link).
///
/// `source` and `link` are kept as written — resolving them needs the file the
/// document was loaded from, which the parser deliberately doesn't know (see
/// `MarkdownLinkTarget`, which does the resolving for both links and images).
struct MarkdownImage: Equatable {
    let source: String
    let alt: String
    let link: String?
    /// The `<picture>` alternative for a dark appearance, if the document
    /// offered one. GitHub's idiom for a screenshot that has to work on both
    /// backgrounds, and a rendered document knows which one it is being read on
    /// — so this is one of the few places where a native renderer can be *more*
    /// right than the browser the file was written for.
    var darkSource: String?

    /// The images in a paragraph that is only images, or nil if it is prose.
    ///
    /// A paragraph of running text with a picture in the middle of it is *not*
    /// this: it stays a paragraph and the image stays its alt text, because the
    /// alternative is breaking a sentence into three views to put a 16px badge
    /// in the gap. What this catches is what documents actually do — a
    /// screenshot on its own line, and a row of badges under the title.
    static func row(from text: String) -> [MarkdownImage]? {
        // A README's screenshot is as likely to be written in HTML as in
        // Markdown: `<picture>` is the only way to give a light and a dark one,
        // and `<img width=…>` the only way to size one. Both are ordinary text
        // to a Markdown parser, which is why the block renders as nothing at all
        // if this doesn't look.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return html(from: text)
        }
        var rest = Substring(text)
        var images: [MarkdownImage] = []
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { break }
            guard let scanned = scan(rest) else { return nil }
            images.append(scanned.image)
            rest = scanned.rest
        }
        return images.isEmpty ? nil : images
    }

    // MARK: - The HTML spellings

    /// The images in a run of HTML that contains *nothing but* images.
    ///
    /// Deliberately a tag scanner rather than an HTML parser, and it answers one
    /// question: is there anything here except pictures and the tags people wrap
    /// pictures in? Any text of its own and the answer is no, and the block stays
    /// the text it is — so a paragraph with an inline `<img>` in it is untouched,
    /// while `<p align="center"><a href><img></a></p>` and `<picture>` are read
    /// the way they look.
    private static func html(from text: String) -> [MarkdownImage]? {
        var images: [MarkdownImage] = []
        var link: String?
        var dark: String?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<" {
                guard let close = closingBracket(in: text, from: index) else { return nil }
                let tag = Tag(text[text.index(after: index)..<close])
                switch tag.name {
                case "img":
                    guard let source = tag["src"] else { return nil }
                    images.append(MarkdownImage(source: source,
                                                alt: tag["alt"] ?? "",
                                                link: link,
                                                darkSource: dark))
                    dark = nil
                case "source":
                    // Only the dark alternative is worth keeping: the light one
                    // is what `<img>` already carries as its fallback, which is
                    // exactly the role it plays in a browser.
                    if tag["media"]?.replacingOccurrences(of: " ", with: "")
                        .contains("prefers-color-scheme:dark") == true {
                        dark = tag["srcset"].map(firstCandidate)
                    }
                case "a":
                    link = tag["href"]
                case "/a":
                    link = nil
                case "/picture", "picture":
                    dark = nil
                default:
                    // Layout around a picture (`p`, `div`, `br`, `align`...) is
                    // not text and doesn't disqualify the block. A tag that
                    // *contains* text will be caught by the text below.
                    break
                }
                index = text.index(after: close)
                continue
            }
            // Anything that isn't inside a tag has to be nothing at all.
            guard character.isWhitespace else { return nil }
            index = text.index(after: index)
        }
        return images.isEmpty ? nil : images
    }

    /// The `>` that closes the tag opening at `start`, skipping quoted values —
    /// an `alt` is allowed to contain one.
    private static func closingBracket(in text: String, from start: String.Index) -> String.Index? {
        var index = text.index(after: start)
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// One HTML tag, reduced to its name and attributes.
    private struct Tag {
        let name: String
        private let attributes: [String: String]

        subscript(attribute: String) -> String? { attributes[attribute] }

        init(_ body: Substring) {
            var rest = body.drop { $0.isWhitespace }
            // A self-closing `<img ... />` ends in a slash that is not an
            // attribute.
            if rest.hasSuffix("/") { rest = rest.dropLast() }
            let name = rest.prefix { !$0.isWhitespace }
            self.name = name.lowercased()
            rest = rest.dropFirst(name.count)

            var attributes: [String: String] = [:]
            while true {
                rest = rest.drop { $0.isWhitespace }
                let key = rest.prefix { !$0.isWhitespace && $0 != "=" }
                if key.isEmpty { break }
                rest = rest.dropFirst(key.count).drop { $0.isWhitespace }
                guard rest.first == "=" else {
                    // A valueless attribute (`hidden`), which is still an
                    // attribute and must not stop the scan.
                    attributes[key.lowercased()] = ""
                    continue
                }
                rest = rest.dropFirst().drop { $0.isWhitespace }
                let value: Substring
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    rest = rest.dropFirst()
                    value = rest.prefix { $0 != quote }
                    rest = rest.dropFirst(value.count)
                    if !rest.isEmpty { rest = rest.dropFirst() }
                } else {
                    value = rest.prefix { !$0.isWhitespace }
                    rest = rest.dropFirst(value.count)
                }
                attributes[key.lowercased()] = String(value)
            }
            self.attributes = attributes
        }
    }

    /// The first URL in a `srcset`, which may list several with density
    /// descriptors after them.
    private static func firstCandidate(_ srcset: String) -> String {
        let first = srcset.split(separator: ",").first ?? Substring(srcset)
        return String(first.drop { $0.isWhitespace }.prefix { !$0.isWhitespace })
    }

    /// One `![alt](src)`, optionally wrapped in a `[...](href)` link.
    private static func scan(_ input: Substring) -> (image: MarkdownImage, rest: Substring)? {
        var rest = input
        let linked = rest.hasPrefix("[") && rest.dropFirst().hasPrefix("!")
        if linked { rest = rest.dropFirst() }
        guard rest.hasPrefix("!") else { return nil }
        rest = rest.dropFirst()
        guard let alt = balanced(rest, open: "[", close: "]"),
              let target = balanced(alt.rest, open: "(", close: ")") else { return nil }
        rest = target.rest
        var link: String?
        if linked {
            guard rest.hasPrefix("]"),
                  let href = balanced(rest.dropFirst(), open: "(", close: ")") else { return nil }
            rest = href.rest
            link = destination(href.inner)
        }
        return (MarkdownImage(source: destination(target.inner),
                              alt: String(alt.inner),
                              link: link), rest)
    }

    /// The contents of a `(...)`/`[...]` pair at the head of `input`, nesting
    /// counted — a URL is allowed to contain brackets, and a title after it is
    /// allowed to contain anything.
    private static func balanced(
        _ input: Substring, open: Character, close: Character
    ) -> (inner: Substring, rest: Substring)? {
        guard input.first == open else { return nil }
        var depth = 0
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 {
                    return (input[input.index(after: input.startIndex)..<index],
                            input[input.index(after: index)...])
                }
            }
            index = input.index(after: index)
        }
        return nil
    }

    /// The URL out of a link target: the part before the optional title, with
    /// the `<...>` spelling unwrapped.
    private static func destination(_ target: Substring) -> String {
        var url = target.drop { $0.isWhitespace }.prefix { !$0.isWhitespace }
        if url.hasPrefix("<"), url.hasSuffix(">") { url = url.dropFirst().dropLast() }
        return String(url)
    }
}

/// Parses a Markdown string into `[MarkdownBlock]`. Pure and synchronous.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for segment in segments(from: source) {
            switch segment {
            case .code(let language, let code, let line):
                blocks.append(MarkdownBlock(id: blocks.count, kind: .code(language: language),
                                            text: code, line: line))
            case .text(let run, let line):
                for block in textBlocks(from: run) {
                    blocks.append(MarkdownBlock(id: blocks.count, kind: block.kind,
                                                text: block.text, afterBlank: block.afterBlank,
                                                line: line + block.line))
                }
            }
        }
        return blocks
    }

    // MARK: - Fenced-code segmentation

    private enum Segment {
        /// `line` is the 1-based source line the segment starts on.
        case text(String, line: Int)
        case code(language: String?, code: String, line: Int)
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
        // 1-based, and tracked rather than derived: a fence's content starts on
        // the line after the fence, so counting afterwards gets it wrong.
        var lineNumber = 0
        var textStart = 1
        var codeStart = 1

        func flushText() {
            let joined = textLines.joined(separator: "\n")
            textLines = []
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.text(joined, line: textStart))
        }
        func flushCode() {
            segments.append(.code(language: codeLanguage,
                                  code: codeLines.joined(separator: "\n"), line: codeStart))
            codeLines = []
            codeLanguage = nil
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") {
                if inCode {
                    inCode = false
                    flushCode()
                } else {
                    inCode = true
                    flushText()
                    codeStart = lineNumber + 1
                    let language = stripped.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }
            if inCode {
                codeLines.append(line)
            } else {
                if textLines.isEmpty { textStart = lineNumber }
                textLines.append(line)
            }
        }
        if inCode { flushCode() } else { flushText() }
        return segments
    }

    // MARK: - Block-level parsing of a text run

    private static func textBlocks(
        from run: String
    ) -> [(kind: MarkdownBlock.Kind, text: String, afterBlank: Bool, line: Int)] {
        var blocks: [(MarkdownBlock.Kind, String, Bool, Int)] = []
        // Carried onto the next block emitted, then cleared.
        var afterBlank = false
        var paragraph: [String] = []
        var paragraphStart = 0
        var quote: [String] = []
        var quoteStart = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = joinSoftWrapped(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            // A paragraph that is only pictures is a picture, not a paragraph.
            let kind: MarkdownBlock.Kind = MarkdownImage.row(from: joined)
                .map(MarkdownBlock.Kind.images) ?? .paragraph
            blocks.append((kind, joined, afterBlank, paragraphStart))
            afterBlank = false
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append((.quote, joinSoftWrapped(quote), afterBlank, quoteStart))
            afterBlank = false
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
                afterBlank = true
                index += 1
                continue
            }

            // Block quote: consecutive `>` lines coalesce, markers stripped.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                if quote.isEmpty { quoteStart = index }
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
                blocks.append((.table(header: header, rows: rows), "", afterBlank, index))
                afterBlank = false
                index = cursor
                continue
            }

            // Setext heading: a line of `===` or `---` directly under a
            // paragraph underlines it rather than ruling the page — and it has to
            // be checked before the rule, since `---` is both. Common enough in
            // hand-written READMEs that missing it turns a document's title into
            // a stray paragraph with a line under it.
            if !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = joinSoftWrapped(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = paragraphStart
                paragraph = []
                if !text.isEmpty {
                    blocks.append((.heading(level: level), text, afterBlank, start))
                    afterBlank = false
                }
                index += 1
                continue
            }

            // A line indented under a list item *continues* it — CommonMark's
            // lazy continuation. Read as its own block instead, it renders as a
            // paragraph back at the left margin, which is the one place in a
            // document it visibly does not belong.
            if paragraph.isEmpty, quote.isEmpty, let last = blocks.indices.last,
               isListItem(blocks[last].0), line.hasPrefix("  "),
               structuralBlock(from: line) == nil {
                blocks[last].1 = joinSoftWrapped([blocks[last].1, trimmed])
                index += 1
                continue
            }

            if let structural = structuralBlock(from: line) {
                flushParagraph()
                blocks.append((structural.0, structural.1, afterBlank, index))
                afterBlank = false
            } else {
                if paragraph.isEmpty { paragraphStart = index }
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    /// Join a paragraph's source lines the way Markdown means them: a newline in
    /// the source is a *soft* break — the text re-flows to whatever width you're
    /// reading at, it doesn't break there. Only the explicit forms are hard
    /// breaks: two trailing spaces, or a trailing backslash.
    ///
    /// Keeping the source newlines instead is a quiet disaster, because SwiftUI's
    /// `Text` renders them literally: a README hard-wrapped at 80 columns came out
    /// as a ragged column down the left of a wide window, every line ending where
    /// the author's editor happened to end it.
    static func joinSoftWrapped(_ lines: [String]) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("\\") { text.removeLast() }
            out += text
            guard index < lines.count - 1 else { continue }
            out += hard ? "\n" : " "
        }
        return out
    }

    /// The heading level a `===` / `---` underline gives the paragraph above it,
    /// or nil when the line isn't one.
    private static func setextLevel(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isListItem(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .bullet, .ordered, .task: return true
        default: return false
        }
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
