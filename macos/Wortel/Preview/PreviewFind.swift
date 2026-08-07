import Foundation
import Observation

/// ⌘F over whatever the window is currently showing.
///
/// Hand-rolled because the thing being searched is an `NSTableView` of
/// hand-drawn rows, not text: `NSTextFinder` has nothing to attach to. That
/// bounds the feature honestly — it finds *lines*, moves the selection to them
/// and counts them, which is what you want in a file you're reading rather than
/// editing. Matching a substring inside the line would mean teaching the cell to
/// draw a second kind of highlight, and that can wait until it's missed.
@Observable
@MainActor
final class PreviewFind {
    var isPresented = false
    var query = "" {
        didSet { if query != oldValue { recompute() } }
    }
    /// Indices into the lines currently on screen.
    private(set) var matches: [Int] = []
    private(set) var current = 0

    @ObservationIgnored private var lines: [DiffLine] = []

    /// The line the table should scroll to and select, or nil when there's
    /// nothing to point at.
    var focusedLine: Int? {
        matches.indices.contains(current) ? matches[current] : nil
    }

    var summary: String {
        if query.isEmpty { return "" }
        return matches.isEmpty ? "No matches" : "\(current + 1) of \(matches.count)"
    }

    /// The content changed under the search — a mode switch, or the file being
    /// rewritten while the bar is open. Re-run against what's there now rather
    /// than leaving matches pointing at lines that have moved.
    func update(lines: [DiffLine]) {
        guard lines.count != self.lines.count
                || zip(lines, self.lines).contains(where: { $0.text != $1.text })
        else { return }
        self.lines = lines
        recompute()
    }

    func next() {
        guard !matches.isEmpty else { return }
        current = (current + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        current = (current - 1 + matches.count) % matches.count
    }

    func dismiss() {
        isPresented = false
        query = ""
    }

    private func recompute() {
        guard !query.isEmpty else {
            matches = []
            current = 0
            return
        }
        let needle = query.lowercased()
        var found: [Int] = []
        for (index, line) in lines.enumerated() where line.text.lowercased().contains(needle) {
            found.append(index)
        }
        matches = found
        // Keep the reader near where they were rather than snapping to the top
        // of the file on every keystroke.
        current = min(current, max(0, found.count - 1))
    }
}
