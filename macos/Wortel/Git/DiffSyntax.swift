import Foundation

/// The pure, tree-sitter-free half of diff syntax highlighting: the token model,
/// the per-hunk reconstruction that feeds tree-sitter, and the mapping of parsed
/// captures back onto individual diff lines. It's Foundation-only so it compiles
/// into `WortelTests` (the actual grammar parsing in `DiffHighlighter` cannot —
/// it drags in ~20 C grammars — but the fiddly offset math, which is where bugs
/// hide, is all here and unit-tested).

/// A coarse syntactic category a run of code maps to. tree-sitter capture names
/// are far more granular (`function.method.builtin`); we fold them down to this
/// small set the diff theme colours, which also lets one theme serve every
/// grammar. Resolution is in `from(capture:)`.
enum HighlightToken: String, Sendable, CaseIterable {
    case keyword, function, type, string, comment, number
    case constant, variable, property, punctuation, `operator`
    case attribute, tag, constructor, module, label, escape

    /// The recognised capture names, keyed by their most specific form. Lookup
    /// (see `from(capture:)`) tries the full dotted name first, then drops
    /// trailing components — so `function.method` resolves via `function`, while
    /// `string.escape` gets its own, more specific mapping ahead of `string`.
    private static let map: [String: HighlightToken] = [
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword,
        "include": .keyword, "exception": .keyword,
        "function": .function, "method": .function, "constructor": .constructor,
        "type": .type, "namespace": .module, "module": .module,
        "string": .string, "character": .string, "string.escape": .escape,
        "escape": .escape, "comment": .comment,
        "number": .number, "float": .number, "boolean": .constant,
        "constant": .constant, "variable": .variable, "parameter": .variable,
        "property": .property, "field": .property,
        "operator": .operator, "punctuation": .punctuation, "delimiter": .punctuation,
        "attribute": .attribute, "annotation": .attribute,
        "tag": .tag, "label": .label,
    ]

    /// Fold a tree-sitter capture name to a token, most-specific first. Unknown
    /// captures return nil (the run is drawn in the default text colour).
    static func from(capture: String) -> HighlightToken? {
        var parts = capture.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if let token = map[parts.joined(separator: ".")] { return token }
            parts.removeLast()
        }
        return nil
    }
}

/// The diff-highlighting service `GitRepoModel` calls. Abstracted so the model
/// — which the unit tests compile directly — needn't link the ~20 tree-sitter
/// grammars the concrete `DiffHighlighter` (app target only) pulls in. Tests
/// construct the model with no highlighter and exercise the plain diff.
protocol DiffHighlighting: Sendable {
    func highlight(_ lines: [DiffLine]) async -> [Int: [HighlightSpan]]
}

/// A coloured run within one diff line's `text` (the sign column excluded).
/// `range` is a UTF-16 `NSRange`, matching both tree-sitter's output and the
/// `NSAttributedString` the cell draws.
struct HighlightSpan: Sendable, Equatable {
    let range: NSRange
    let token: HighlightToken
}

enum DiffSyntax {
    /// One contiguous side of one hunk — the real, consecutive source lines
    /// tree-sitter should see *together*, so multi-line constructs (block
    /// comments, here-docs) parse correctly. `lineStarts`/`lineIDs` map offsets
    /// in `text` back to individual `DiffLine`s. `ownedIDs` are the lines whose
    /// colour comes from THIS side: additions and context from the post-image,
    /// deletions from the pre-image. Context is present on both sides (it's
    /// needed for parsing) but owned only by the post-image, so it's coloured
    /// once.
    struct Segment {
        let path: String?
        let text: String
        let lineStarts: [Int]
        let lineIDs: [Int]
        let ownedIDs: Set<Int>
    }

    /// Reconstruct the pre- and post-image segment of every hunk in `lines`.
    /// A hunk header flushes the current hunk and (re)sets the file path, so a
    /// concatenated multi-file commit diff yields correctly-tagged segments.
    static func segments(_ lines: [DiffLine]) -> [Segment] {
        var out: [Segment] = []
        var postTexts: [String] = [], postIDs: [Int] = [], ownedPost: Set<Int> = []
        var preTexts: [String] = [], preIDs: [Int] = [], ownedPre: Set<Int> = []
        var path: String?

        func flush() {
            if !postIDs.isEmpty {
                out.append(make(path: path, texts: postTexts, ids: postIDs, owned: ownedPost))
            }
            // Only if it colours something. The pre-image exists to colour
            // deletions, and it carries the surrounding context purely so
            // multi-line constructs parse — `distribute` then throws away every
            // line the segment doesn't own. With no deletions in the hunk that
            // is the *whole* segment, so parsing it is a tree-sitter pass whose
            // entire output is discarded: twice the highlighting cost for a
            // hunk of pure additions, and for every file the preview window
            // shows as source, which is all context by construction.
            if !preIDs.isEmpty, !ownedPre.isEmpty {
                out.append(make(path: path, texts: preTexts, ids: preIDs, owned: ownedPre))
            }
            postTexts = []; postIDs = []; ownedPost = []
            preTexts = []; preIDs = []; ownedPre = []
        }

        for line in lines {
            // A patch announces each file in a hunk header, so that's where the
            // path normally comes from. A *whole file* handed over as
            // all-context — which is how the preview window shows source — has
            // no header to announce it, and without a path there's no grammar,
            // so nothing was highlighted at all. Every line carries its own file;
            // take it from the first one that does.
            if path == nil { path = line.path }
            switch line.kind {
            case .hunkHeader:
                flush()
                path = line.path
            case .context:
                postTexts.append(line.text); postIDs.append(line.id); ownedPost.insert(line.id)
                preTexts.append(line.text); preIDs.append(line.id)
            case .addition:
                postTexts.append(line.text); postIDs.append(line.id); ownedPost.insert(line.id)
            case .deletion:
                preTexts.append(line.text); preIDs.append(line.id); ownedPre.insert(line.id)
            }
        }
        flush()
        return out
    }

    private static func make(path: String?, texts: [String], ids: [Int], owned: Set<Int>) -> Segment {
        var starts: [Int] = []
        starts.reserveCapacity(texts.count)
        var offset = 0
        for t in texts {
            starts.append(offset)
            offset += (t as NSString).length + 1 // +1 for the "\n" the join inserts
        }
        return Segment(path: path, text: texts.joined(separator: "\n"),
                       lineStarts: starts, lineIDs: ids, ownedIDs: owned)
    }

    /// Map captures (ranges over `segment.text`) to per-line spans, clipping to
    /// line bounds and dropping lines this segment doesn't own. A capture that
    /// straddles a newline (a block comment, a multi-line string) is split into
    /// one span per line it covers.
    static func distribute(_ captures: [(range: NSRange, token: HighlightToken)],
                           over segment: Segment) -> [Int: [HighlightSpan]] {
        var result: [Int: [HighlightSpan]] = [:]
        let n = segment.lineIDs.count
        guard n > 0 else { return result }
        let textLen = (segment.text as NSString).length

        func lineEnd(_ i: Int) -> Int { i + 1 < n ? segment.lineStarts[i + 1] - 1 : textLen }

        // Largest line index whose start is <= `offset` (the line containing it).
        func lineContaining(_ offset: Int) -> Int {
            var lo = 0, hi = n // upper bound, then step back one
            while lo < hi {
                let mid = (lo + hi) / 2
                if segment.lineStarts[mid] <= offset { lo = mid + 1 } else { hi = mid }
            }
            return max(0, lo - 1)
        }

        for cap in captures {
            let capLo = cap.range.location
            let capHi = cap.range.location + cap.range.length
            guard capHi > capLo else { continue }
            var i = lineContaining(capLo)
            while i < n {
                let ls = segment.lineStarts[i]
                if ls >= capHi { break }
                let le = lineEnd(i)
                if le > capLo, segment.ownedIDs.contains(segment.lineIDs[i]) {
                    let lo = max(capLo, ls) - ls
                    let hi = min(capHi, le) - ls
                    if hi > lo {
                        result[segment.lineIDs[i], default: []]
                            .append(HighlightSpan(range: NSRange(location: lo, length: hi - lo), token: cap.token))
                    }
                }
                i += 1
            }
        }
        return result
    }
}
