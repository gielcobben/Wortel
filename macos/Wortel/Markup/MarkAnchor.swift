import Foundation

/// How a mark on a file knows its line or block again after the file is
/// rewritten: by what it held, and by what was around it.
///
/// What a row holds is not enough to know it by. Code is full of lines that
/// read the same (a blank one, a closing brace, `return nil`), and the
/// nearest line that reads the same is as often a neighbour as the one that
/// was marked. Measured 2026-11-25 over a Swift file of short functions:
/// three lines added above two marks put both five rows above their own
/// lines, and two functions removed above put them twelve and fourteen rows
/// below. So a mark also remembers the rows either side of its own, and of
/// the rows that read the same the one whose neighbours agree most is its
/// row.
struct MarkAnchor: Equatable {
    /// The row or block the mark is on.
    private(set) var index: Int
    /// What it held. Nil where there is nothing to tell rows by: the mark
    /// then stays on its index.
    let key: Int?
    /// What the rows around it held, from `span` before to `span` after,
    /// its own left out. Nil for a row past either end.
    private(set) var around: [Int?]

    /// How many rows either side are remembered. A function's last lines
    /// (`return`, a brace, a blank) repeat three at a time, and the fourth
    /// is what tells one function's from the next.
    static let span = 4

    init(at index: Int, keyAt: (Int) -> Int?) {
        self.index = index
        key = keyAt(index)
        around = Self.surroundings(of: index, keyAt: keyAt)
    }

    private static var offsets: [Int] { (-span...span).filter { $0 != 0 } }

    private static func surroundings(of index: Int, keyAt: (Int) -> Int?) -> [Int?] {
        offsets.map { keyAt(index + $0) }
    }

    /// Look for the mark's row within `reach` either side of where it was,
    /// and move to it. False when it is gone: the mark has no place, and
    /// keeps what it knew, so it is found if its row comes back.
    ///
    /// Of the rows that hold what the mark's did, the one with the most
    /// neighbours as they were; then the nearest; then the one above.
    /// Where several hold it and none has a single neighbour left, any of
    /// them would be a guess, and a mark on the wrong line is worse than
    /// one that is not drawn.
    mutating func find(within reach: Int, keyAt: (Int) -> Int?) -> Bool {
        guard let key else { return true }
        var known: [Int: Int?] = [:]
        func held(_ row: Int) -> Int? {
            if let seen = known[row] { return seen }
            let value = row < 0 ? nil : keyAt(row)
            known[row] = value
            return value
        }
        // Nothing around it changed, which is nearly every time this is
        // asked (Markdown asks whenever a block is built): no other row
        // can be a better one, so none is looked at.
        if held(index) == key, zip(Self.offsets, around).allSatisfy({ held(index + $0) == $1 }) { return true }
        var best: (row: Int, agree: Int)?
        var holding = 0
        for distance in 0...max(reach, 0) {
            for row in distance == 0 ? [index] : [index - distance, index + distance] where row >= 0 && held(row) == key {
                holding += 1
                var agree = 0
                for (offset, was) in zip(Self.offsets, around) where held(row + offset) == was { agree += 1 }
                // Nearer rows come first, so only a better one takes over.
                if agree > (best?.agree ?? -1) { best = (row, agree) }
            }
        }
        guard let best, holding == 1 || best.agree > 0 else { return false }
        index = best.row
        // What is around it now is what it is known by next time, but only
        // when half of what was around it is still there. A file caught
        // half written can hold one row that reads the same, somewhere
        // else, and must not teach the mark that row's surroundings: when
        // the rest of the file arrives the mark would stay on it.
        if best.agree >= Self.span { around = Self.surroundings(of: index, keyAt: held) }
        return true
    }
}
