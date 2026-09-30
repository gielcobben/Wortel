import Foundation

/// What ⌘P finds a session by, and in what order.
///
/// Pure, so the ranking has tests of its own (SessionSwitcherMatchTests):
/// a switcher is only as good as its first row, and "the one I meant was
/// third" is a failure nothing else would catch.
enum SessionSwitcherMatch {
    struct Candidate: Equatable {
        let id: UUID
        /// The session's own name, without its folder.
        let name: String
        let folder: String?
        let branch: String?
        /// Its directory, tilde-abbreviated.
        let path: String
    }

    /// The candidates `query` matches, best first.
    ///
    /// Every word of the query has to match somewhere (the name, the folder,
    /// the branch or the path), and where it matches sets the score: the start
    /// of the name beats the start of a word in it, which beats anywhere in
    /// it, which beats the folder, then the branch, then the path, then the
    /// name's letters in order ("wadu" for "Wortel app design and UX"). Ties
    /// go to the most recently used.
    ///
    /// With nothing typed: every session, most recently used first, the one
    /// you're in last, so ⌘P then Return takes you back where you were.
    static func rank(_ query: String, _ candidates: [Candidate], recent: [UUID], current: UUID?) -> [Candidate] {
        let recency = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        func recencyRank(_ candidate: Candidate) -> Int {
            if candidate.id == current { return Int.max }
            return recency[candidate.id] ?? Int.max - 1
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return candidates.enumerated().sorted { a, b in
                let (ra, rb) = (recencyRank(a.element), recencyRank(b.element))
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }
        let scored: [(Candidate, Int)] = candidates.compactMap { candidate in
            var total = 0
            for word in words {
                guard let score = score(word, candidate) else { return nil }
                total += score
            }
            return (candidate, total)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return recencyRank(a.0) < recencyRank(b.0)
        }.map(\.0)
    }

    /// How well one lowercased word matches a candidate, or nil if it doesn't.
    static func score(_ word: String, _ candidate: Candidate) -> Int? {
        let name = candidate.name.lowercased()
        if name.hasPrefix(word) { return 100 }
        if startsAWord(word, in: name) { return 80 }
        if name.contains(word) { return 60 }
        if let folder = candidate.folder?.lowercased(), folder.contains(word) {
            return folder.hasPrefix(word) ? 45 : 40
        }
        if let branch = candidate.branch?.lowercased(), branch.contains(word) { return 35 }
        if candidate.path.lowercased().contains(word) { return 20 }
        if isSubsequence(word, of: name) { return 10 }
        return nil
    }

    /// Whether `word` starts one of the words in `text`: after a space, a
    /// dash, a slash, a dot or an underscore.
    private static func startsAWord(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: range.lowerBound)]
            if " -/._".contains(before) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var remaining = word[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
