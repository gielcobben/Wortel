import AppKit
import SwiftUI

/// Renders `[MarkdownBlock]` natively — one styled SwiftUI view per block, with
/// inline markdown (bold/italic/code/links) handled by Foundation's
/// `AttributedString` and fenced code coloured by tree-sitter (see
/// `CodeBlockView`). No WebView, no markdown library.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// Multiplies the whole type scale — text, headings, code, and the gaps
    /// between blocks — so ⌘+/⌘− move a rendered document the way they move
    /// source. A ratio rather than a point size because a document has a *scale*,
    /// not one font: scaling it keeps the proportions the design chose. 1 is the
    /// designed size.
    var scale: CGFloat = 1

    var body: some View {
        ScrollView {
            // Spacing is per-block (see `topGap`) rather than a uniform stack
            // gap: consecutive list items sit tight, headings get air above, and
            // prose keeps a comfortable rhythm — the difference between "rendered"
            // and "typeset".
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockView(block)
                        .padding(.top, Self.topGap(
                            previous: index > 0 ? blocks[index - 1].kind : nil,
                            current: block.kind) * scale)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(4)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
    }

    /// The space above a block, given what precedes it. First block: none.
    /// Consecutive list items: tight. Into a heading: generous, so sections
    /// read as sections. Otherwise a steady paragraph rhythm.
    private static func topGap(previous: MarkdownBlock.Kind?, current: MarkdownBlock.Kind) -> CGFloat {
        guard let previous else { return 0 }
        if isListItem(current) {
            return isListItem(previous) ? 4 : 10
        }
        switch current {
        case .heading(let level): return level <= 2 ? 24 : 18
        case .rule: return 18
        default: return 12
        }
    }

    private static func isListItem(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .bullet, .ordered, .task: return true
        default: return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(Self.inline(block.text))
                .font(headingFont(level))
        case .paragraph:
            Text(Self.inline(block.text))
                .font(.system(size: bodySize))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent):
            listRow(marker: "•", text: block.text, indent: indent)
        case .ordered(let indent, let marker):
            listRow(marker: marker, text: block.text, indent: indent)
        case .task(let indent, let checked):
            taskRow(checked: checked, text: block.text, indent: indent)
        case .quote:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(Self.inline(block.text))
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 2)
        case .code(let language):
            CodeBlockView(code: block.text, language: language, scale: scale)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    private func listRow(marker: String, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker)
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(Self.inline(text))
                .font(.system(size: bodySize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(indent, 5)) * 16)
    }

    /// A task-list row: a real checkbox glyph (filled + accent when done) and the
    /// item text. Read-only — the preview renders the file, it doesn't edit it.
    private func taskRow(checked: Bool, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: bodySize))
                .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(minWidth: 18, alignment: .trailing)
            Text(Self.inline(text))
                .font(.system(size: bodySize))
                .foregroundStyle(checked ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(indent, 5)) * 16)
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(Self.inline(column < header.count ? header[column] : ""))
                            .font(.system(size: bodySize, weight: .semibold))
                    }
                }
                Divider().gridCellColumns(columns)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(Self.inline(column < rows[row].count ? rows[row][column] : ""))
                                .font(.system(size: bodySize))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Base reading size for body text; the rest of the type scale derives from
    /// it. Larger than the system `.body` (~13pt) — this is a document you read,
    /// not chrome.
    static let baseBodySize: CGFloat = 14

    /// The reading size after `scale`. Every other size in the sheet is either
    /// this or a fixed multiple of the base, so one ratio moves the document.
    var bodySize: CGFloat { Self.baseBodySize * scale }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 28 * scale, weight: .bold)
        case 2: return .system(size: 22 * scale, weight: .bold)
        case 3: return .system(size: 18 * scale, weight: .semibold)
        case 4: return .system(size: 16 * scale, weight: .semibold)
        default: return .system(size: bodySize, weight: .semibold)
        }
    }

    // MARK: - Inline markdown

    /// Foundation's inline markdown (bold/italic/code-span/links), preserving
    /// whitespace, plus bare-URL linkification the inline parser skips.
    static func inline(_ markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var result = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        linkifyBareURLs(in: &result)
        return result
    }

    /// Shared once; constructing an `NSDataDetector` per call is measurable.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkifyBareURLs(in text: inout AttributedString) {
        let plain = String(text.characters)
        guard let detector = linkDetector, !plain.isEmpty else { return }
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in detector.matches(in: plain, range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain),
                  let attrRange = Range(stringRange, in: text) else { continue }
            if text[attrRange].link == nil {
                text[attrRange].link = url
            }
        }
    }
}

// MARK: - Code block

/// A fenced code block: monospaced, tree-sitter–coloured with the GitHub palette
/// (the same `DiffSyntaxTheme` the diff view uses), in a rounded card that
/// scrolls horizontally for long lines. Highlighting runs off-main; until it
/// lands (or when the language is unknown) the plain monospaced text shows.
private struct CodeBlockView: View {
    let code: String
    let language: String?
    /// Same ratio the surrounding document uses, so code keeps its relationship
    /// to the prose around it at every size.
    var scale: CGFloat = 1

    @State private var highlighted: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(verbatim: language.uppercased())
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted ?? Self.plain(code, size: MarkdownView.baseBodySize * scale))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.trailing, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor)))
        .task(id: code) { await highlight() }
    }

    private static func plain(_ code: String, size: CGFloat) -> AttributedString {
        var attr = AttributedString(code.isEmpty ? " " : code)
        attr.font = .system(size: size, design: .monospaced)
        return attr
    }

    private func highlight() async {
        highlighted = nil
        guard let language, let grammar = Grammar(fence: language) else { return }
        let spans = await MarkdownCodeHighlighter.shared.spans(for: code, grammar: grammar)
        guard !spans.isEmpty else { return }
        highlighted = Self.colored(code: code, spans: spans, size: MarkdownView.baseBodySize * scale)
    }

    /// Apply the tree-sitter spans in a single forward pass. Mapping each span's
    /// UTF-16 range to an AttributedString index on its own is O(n) per span (a
    /// walk from the start), which is quadratic over a large block; instead walk
    /// the string once, recording the index at every span boundary, then colour
    /// by lookup. Boundaries that fall mid-grapheme simply aren't recorded, so
    /// that span is skipped rather than mis-placed.
    private static func colored(code: String, spans: [(range: NSRange, token: HighlightToken)],
                                size: CGFloat) -> AttributedString {
        var attr = plain(code, size: size)

        var boundaries: Set<Int> = []
        for (range, _) in spans {
            boundaries.insert(range.location)
            boundaries.insert(range.location + range.length)
        }

        var indexAt: [Int: AttributedString.Index] = [:]
        var index = attr.startIndex
        var utf16 = 0
        if boundaries.contains(0) { indexAt[0] = index }
        for character in code {
            utf16 += character.utf16.count
            index = attr.characters.index(after: index)
            if boundaries.contains(utf16) { indexAt[utf16] = index }
        }

        let theme = DiffSyntaxTheme()
        for (range, token) in spans {
            guard let lo = indexAt[range.location],
                  let hi = indexAt[range.location + range.length], lo < hi else { continue }
            attr[lo..<hi].foregroundColor = Color(nsColor: theme.color(for: token))
        }
        return attr
    }
}
