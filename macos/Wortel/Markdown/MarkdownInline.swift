import Foundation

/// Inline markdown — bold, italic, code spans, links — parsed by Foundation,
/// plus the bare-URL linkification its inline parser skips.
///
/// Separate from the renderer because it's pure Foundation and worth pinning: a
/// code span that loses its intent stops being a chip, and a bare URL that isn't
/// linkified is just grey text that looks clickable and isn't.
enum MarkdownInline {
    static func parse(_ markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        // Preserving whitespace matters: the block parser has already decided
        // where the line breaks are (see `joinSoftWrapped`), and re-flowing them
        // here would undo that.
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

    static func linkifyBareURLs(in text: inout AttributedString) {
        let plain = String(text.characters)
        guard let detector = linkDetector, !plain.isEmpty else { return }
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in detector.matches(in: plain, range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain),
                  let attrRange = Range(stringRange, in: text) else { continue }
            // An explicit [text](url) already has one, and it wins.
            if text[attrRange].link == nil {
                text[attrRange].link = url
            }
        }
    }
}
