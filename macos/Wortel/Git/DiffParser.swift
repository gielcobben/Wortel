import Foundation

/// Turns unified `git diff` text into renderable `DiffLine`s. Header noise
/// (`diff --git`, `index`, `---`, `+++`, mode/rename lines) is dropped; hunk
/// headers are kept as their own kind and drive the running line counters.
enum DiffParser {
    /// Ceilings on what one file's patch may cost. A regenerated lock file or a
    /// minified bundle produces a patch nobody reads by scrolling — the measured
    /// case was a 400k-line `yarn.lock`, whose 51MB / 600k-line diff took 1.2s
    /// just to parse. Past these limits the tail is dropped and the result marked
    /// `truncated`; the byte cap is what matters, since splitting the full string
    /// costs the same whether or not we keep the lines.
    static let maxBytes = 2_000_000
    static let maxLines = 20_000

    static func parse(_ raw: String) -> DiffResult {
        var lines: [DiffLine] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        var isBinary = false
        var truncated = false

        var text = raw
        if text.utf8.count > maxBytes {
            // Cut to the byte ceiling, then back up to the last newline so the
            // final line is whole (and any half-eaten UTF-8 goes with it).
            let cut = String(decoding: text.utf8.prefix(maxBytes), as: UTF8.self)
            text = String(cut[..<(cut.lastIndex(of: "\n") ?? cut.endIndex)])
            truncated = true
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if lines.count >= maxLines {
                truncated = true
                break
            }
            if rawLine.hasPrefix("Binary files") || rawLine.hasPrefix("GIT binary patch") {
                isBinary = true
                continue
            }
            // File-level headers carry no content worth showing in the pane.
            if isHeaderLine(rawLine) { continue }

            if rawLine.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(rawLine) {
                    oldNo = o
                    newNo = n
                }
                id += 1
                lines.append(DiffLine(id: id, kind: .hunkHeader, text: rawLine, oldLine: nil, newLine: nil))
                continue
            }

            // Content line: first column is the +/-/space marker.
            let kind: DiffLineKind
            var old: Int? = nil
            var new: Int? = nil
            let body: String

            if rawLine.hasPrefix("+") {
                kind = .addition
                new = newNo; newNo += 1
                body = String(rawLine.dropFirst())
            } else if rawLine.hasPrefix("-") {
                kind = .deletion
                old = oldNo; oldNo += 1
                body = String(rawLine.dropFirst())
            } else {
                // Context (leading space) or the final empty split element.
                kind = .context
                old = oldNo; oldNo += 1
                new = newNo; newNo += 1
                body = rawLine.isEmpty ? "" : String(rawLine.dropFirst())
            }
            id += 1
            lines.append(DiffLine(id: id, kind: kind, text: body, oldLine: old, newLine: new))
        }

        // A single trailing empty context line is the split's tail, not content.
        if let last = lines.last, last.kind == .context, last.text.isEmpty {
            lines.removeLast()
        }
        return DiffResult(lines: lines, isBinary: isBinary, truncated: truncated)
    }

    private static func isHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("diff --git")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode")
            || line.hasPrefix("old mode")
            || line.hasPrefix("new mode")
            || line.hasPrefix("similarity index")
            || line.hasPrefix("dissimilarity index")
            || line.hasPrefix("rename from")
            || line.hasPrefix("rename to")
            || line.hasPrefix("copy from")
            || line.hasPrefix("copy to")
            || line.hasPrefix("\\ No newline")
    }

    /// "@@ -a,b +c,d @@ ctx" → (a, c). Counts default to the token's number.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let fields = line.split(separator: " ")
        guard fields.count >= 3 else { return nil }
        func leadingInt(_ token: Substring) -> Int? {
            // token like "-12,7" or "+12" — drop the sign, take the number.
            let digits = token.dropFirst().prefix { $0.isNumber }
            return Int(digits)
        }
        guard let a = leadingInt(fields[1]), let c = leadingInt(fields[2]) else { return nil }
        return (a, c)
    }
}
