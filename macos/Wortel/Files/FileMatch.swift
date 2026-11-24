import Foundation

/// What ⌘P finds a file by, and in what order.
///
/// fzf's scoring (its v2 algorithm: the best placement of the query's letters,
/// not the first), over raw bytes, on every core:
///
/// - Each word of the query has to match, its letters in order. Spaces mean
///   "and", as in the rest of ⌘P.
/// - A letter scores more at the start of a word (after `/`, `_`, `-`, `.`,
///   a space, or a lower-to-upper case change) and in a run of letters.
/// - A word found in the file name beats a word found only across folders,
///   as in VS Code and Zed: "core" finds `core.c` before `core/main.c`. A
///   word with a `/` in it is matched against the whole path.
/// - Then `boosts` (files changed here, files opened lately), then the
///   shorter path.
///
/// Pure and `Sendable`, so the ranking has tests of its own
/// (FileMatchTests). Measured on the Linux tree copied ten times (973k
/// paths): see the timing test there.
enum FileMatch {
    struct Match: Equatable, Sendable {
        let index: Int32
        let score: Int32
    }

    struct Result: Sendable {
        /// Best first, at most `limit`.
        let matches: [Match]
        /// Every path the query's letters appear in, in order, scored or not:
        /// what a longer query (this one with more typed) can only narrow.
        let survivors: [Int32]
    }

    /// The query as matched: lowercased words, and the letters they need.
    struct Query: Sendable {
        let words: [[UInt8]]
        let mask: UInt64
        /// Only file names are scored: one or two letters match nearly every
        /// path somewhere, and nobody means a folder by them.
        let namesOnly: Bool

        init(_ text: String) {
            // Folded as the paths are, A to Z only: `String.lowercased()`
            // would turn `Ü` into `ü`, and `Übersicht.md` would never match.
            words = text.split(whereSeparator: \.isWhitespace).map { $0.utf8.map(FileMatch.lowered) }
            mask = words.reduce(0) { $0 | FileIndex.mask($1) }
            namesOnly = words.reduce(0) { $0 + $1.count } <= 2
        }

        var isEmpty: Bool { words.isEmpty }
    }

    /// A word found in the file name is a tier above any found only in the
    /// path: far more than a path's letters can score.
    static let nameTier: Int32 = 4096

    /// The paths of `index` that `query` matches, best first.
    ///
    /// `among`: only these (a shorter query's `survivors`), else all.
    /// `boosts`: added to a path's score by its index, for the files the
    /// person is likely after (changed here, opened lately). Small next to
    /// the fuzzy score: they settle near-ties, they don't overrule a name.
    static func rank(_ query: Query, in index: FileIndex, among candidates: [Int32]? = nil,
                     limit: Int = 50, boosts: [Int32: Int32] = [:],
                     isCancelled: @Sendable () -> Bool = { false }) -> Result {
        guard !query.isEmpty, index.count > 0 else { return Result(matches: [], survivors: []) }
        let total = candidates?.count ?? index.count
        let chunkSize = 16_384
        let chunks = max(1, (total + chunkSize - 1) / chunkSize)
        // Kept per chunk before the boosts are added: enough that a boost
        // can lift a near-tie into the shown rows.
        let keep = limit * 2
        let longest = Int(index.lengths.max() ?? 0)

        final class Box: @unchecked Sendable {
            var tops: [[Match]]
            var survivors: [[Int32]]
            init(_ count: Int) {
                tops = Array(repeating: [], count: count)
                survivors = Array(repeating: [], count: count)
            }
        }
        let box = Box(chunks)

        index.bytes.withUnsafeBufferPointer { bytes in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                if isCancelled() { return }
                let lower = chunk * chunkSize, upper = min(total, lower + chunkSize)
                var scorer = Scorer(capacity: longest)
                defer { scorer.deallocate() }
                var top = TopK(limit: keep)
                var survivors: [Int32] = []
                for position in lower..<upper {
                    let path = candidates.map { Int($0[position]) } ?? position
                    if index.masks[path] & query.mask != query.mask { continue }
                    let start = Int(index.starts[path])
                    let length = Int(index.lengths[path])
                    let name = Int(index.nameStarts[path])
                    let text = UnsafeBufferPointer(rebasing: bytes[start..<start + length])
                    guard query.words.allSatisfy({ inOrder($0, in: text, from: 0) }) else { continue }
                    survivors.append(Int32(path))
                    var total: Int32 = 0
                    var matched = true
                    for word in query.words {
                        if !word.contains(UInt8(ascii: "/")), inOrder(word, in: text, from: name),
                           let score = scorer.score(word, in: text, from: name) {
                            // The shorter the name around it, the closer to
                            // what was typed: `core.c` before `coredump.c`.
                            total += score + nameTier - Int32(min(length - name - word.count, 32))
                        } else if query.namesOnly {
                            matched = false
                            break
                        } else if top.isFull, top.floor >= nameTier, query.words.count == 1 {
                            // Only a file name can make it in now.
                            matched = false
                            break
                        } else if let score = scorer.score(word, in: text, from: 0) {
                            total += score
                        } else {
                            matched = false
                            break
                        }
                    }
                    if matched { top.insert(Match(index: Int32(path), score: total)) }
                }
                box.tops[chunk] = top.items
                box.survivors[chunk] = survivors
            }
        }
        if isCancelled() { return Result(matches: [], survivors: []) }

        let boosted = box.tops.joined().map { match in
            Match(index: match.index, score: match.score + (boosts[match.index] ?? 0))
        }
        let best = boosted.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let (la, lb) = (index.lengths[Int(a.index)], index.lengths[Int(b.index)])
            if la != lb { return la < lb }
            return a.index < b.index
        }
        return Result(matches: Array(best.prefix(limit)), survivors: Array(box.survivors.joined()))
    }

    /// Whether `word`'s letters appear in `text` in order, from `from`,
    /// case folded. The cheap check before any scoring.
    @inline(__always)
    static func inOrder(_ word: [UInt8], in text: UnsafeBufferPointer<UInt8>, from: Int) -> Bool {
        var next = 0
        var position = from
        while position < text.count, next < word.count {
            if lowered(text[position]) == word[next] { next += 1 }
            position += 1
        }
        return next == word.count
    }

    @inline(__always)
    static func lowered(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte | 0x20 : byte
    }

    // MARK: - fzf's scoring

    static let scoreMatch: Int32 = 16
    static let gapStart: Int32 = -3
    static let gapExtension: Int32 = -1
    static let bonusBoundary: Int32 = 8
    static let bonusNonWord: Int32 = 8
    static let bonusBoundaryDelimiter: Int32 = 9
    static let bonusBoundaryWhite: Int32 = 10
    static let bonusCamel: Int32 = 7
    static let bonusConsecutive: Int32 = 4
    static let firstCharMultiplier: Int32 = 2

    enum CharClass: UInt8 { case white, nonWord, delimiter, lower, upper, letter, number }

    @inline(__always)
    static func charClass(_ byte: UInt8) -> CharClass {
        switch byte {
        case 97...122: return .lower
        case 65...90: return .upper
        case 48...57: return .number
        case 32, 9, 10, 13: return .white
        case UInt8(ascii: "/"), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "|"):
            return .delimiter
        case 128...255: return .letter
        default: return .nonWord
        }
    }

    /// fzf's bonus for a letter of class `current` after one of `previous`.
    @inline(__always)
    static func bonus(_ previous: CharClass, _ current: CharClass) -> Int32 {
        if current.rawValue > CharClass.delimiter.rawValue {
            switch previous {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if previous == .lower && current == .upper { return bonusCamel }
        if previous != .number && current == .number { return bonusCamel }
        switch current {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// fzf v2's dynamic programme, one row at a time, in buffers allocated
    /// once per worker: no allocation per path.
    struct Scorer {
        private let capacity: Int
        private let bonuses: UnsafeMutablePointer<Int32>
        private let previousRow: UnsafeMutablePointer<Int32>
        private let currentRow: UnsafeMutablePointer<Int32>
        private let previousRun: UnsafeMutablePointer<Int32>
        private let currentRun: UnsafeMutablePointer<Int32>
        private let firsts: UnsafeMutablePointer<Int>

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
            bonuses = .allocate(capacity: self.capacity)
            previousRow = .allocate(capacity: self.capacity)
            currentRow = .allocate(capacity: self.capacity)
            previousRun = .allocate(capacity: self.capacity)
            currentRun = .allocate(capacity: self.capacity)
            firsts = .allocate(capacity: 256)
        }

        func deallocate() {
            bonuses.deallocate()
            previousRow.deallocate()
            currentRow.deallocate()
            previousRun.deallocate()
            currentRun.deallocate()
            firsts.deallocate()
        }

        /// The best score of `word` in `text` from `from` on, or nil when its
        /// letters aren't there in order. `from` past 0 is the file name: what
        /// comes before it counts as a `/`.
        mutating func score(_ word: [UInt8], in text: UnsafeBufferPointer<UInt8>, from: Int) -> Int32? {
            let m = word.count
            let n = text.count - from
            guard m > 0, m <= 256, n >= m, n <= capacity else { return nil }
            // Where each letter can first be: the greedy forward match. Row
            // `k` starts there, so every cell it reads from row `k - 1` is
            // one where that letter has been matched.
            var next = 0
            for column in 0..<n where next < m {
                if FileMatch.lowered(text[from + column]) == word[next] {
                    firsts[next] = column
                    next += 1
                }
            }
            guard next == m else { return nil }

            var previous = FileMatch.CharClass.delimiter
            for column in 0..<n {
                let current = FileMatch.charClass(text[from + column])
                bonuses[column] = FileMatch.bonus(previous, current)
                previous = current
            }

            var best: Int32 = 0
            for row in 0..<m {
                let letter = word[row]
                let first = firsts[row]
                var inGap = false
                for column in 0..<n {
                    if column < first {
                        currentRow[column] = 0
                        currentRun[column] = 0
                        continue
                    }
                    let left = column > first ? currentRow[column - 1] : 0
                    let gap = left + (inGap ? FileMatch.gapExtension : FileMatch.gapStart)
                    var matched: Int32 = 0
                    var run: Int32 = 0
                    if FileMatch.lowered(text[from + column]) == letter {
                        if row == 0 {
                            matched = FileMatch.scoreMatch + bonuses[column] * FileMatch.firstCharMultiplier
                            run = 1
                        } else if column > 0 {
                            matched = previousRow[column - 1] + FileMatch.scoreMatch
                            var bonus = bonuses[column]
                            run = previousRun[column - 1] + 1
                            if run > 1 {
                                let runStart = bonuses[column - Int(run) + 1]
                                if bonus >= FileMatch.bonusBoundary && bonus > runStart {
                                    run = 1
                                } else {
                                    bonus = max(bonus, max(FileMatch.bonusConsecutive, runStart))
                                }
                            }
                            if matched + bonus < gap {
                                matched += bonuses[column]
                                run = 0
                            } else {
                                matched += bonus
                            }
                        }
                    }
                    currentRun[column] = run
                    inGap = matched < gap
                    let score = max(matched, gap, 0)
                    currentRow[column] = score
                    if row == m - 1, score > best { best = score }
                }
                // This row becomes the one the next reads.
                for column in 0..<n {
                    previousRow[column] = currentRow[column]
                    previousRun[column] = currentRun[column]
                }
            }
            return best
        }
    }

    /// The best `limit` seen so far: a sorted array, small enough that
    /// inserting into it is cheaper than a heap's bookkeeping.
    struct TopK {
        let limit: Int
        private(set) var items: [Match] = []

        init(limit: Int) { self.limit = limit }

        var isFull: Bool { items.count >= limit }
        /// The lowest score kept, once full.
        var floor: Int32 { items.last?.score ?? .min }

        mutating func insert(_ match: Match) {
            if isFull, match.score <= floor { return }
            var low = 0, high = items.count
            while low < high {
                let mid = (low + high) / 2
                if items[mid].score >= match.score { low = mid + 1 } else { high = mid }
            }
            items.insert(match, at: low)
            if items.count > limit { items.removeLast() }
        }
    }
}
