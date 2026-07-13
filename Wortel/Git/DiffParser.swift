import Foundation

/// Turns unified `git diff` text into renderable `DiffLine`s. Header noise
/// (`diff --git`, `index`, `---`, `+++`, mode/rename lines) is dropped; hunk
/// headers are kept as their own kind and drive the running line counters.
enum DiffParser {
    static func parse(_ raw: String) -> DiffResult {
        var lines: [DiffLine] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        var isBinary = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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
        return DiffResult(lines: lines, isBinary: isBinary)
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
