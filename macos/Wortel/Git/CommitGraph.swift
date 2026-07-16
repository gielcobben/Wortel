import Foundation

/// Lane layout for the History pane's graph gutter: turns a flat, topo-ordered
/// commit list into per-row columns, dots and edges.
///
/// A pure value-type pass over `[GitCommit]`, like GitStatusParser and
/// DiffParser — no git, no views, no main-actor state. Built once per history
/// load (microseconds over a few hundred commits), then read per row.
///
/// The model is a walk from newest to oldest carrying a set of *active lanes*,
/// each holding the SHA it is still waiting to see. A commit claims the lane
/// waiting for it, then hands that lane to its first parent; extra parents
/// either join a lane already expecting them (that's a merge edge) or open a
/// new lane. Every row records only its own slice — the edges crossing it and
/// its dot's column — so a row can draw itself with no knowledge of its
/// neighbours, which is what lets the pane stay a LazyVStack.
struct CommitGraph {
    /// One line segment through a row, in lane columns. `from` is the column at
    /// the segment's start, `to` at its end; equal columns draw straight.
    struct Edge: Hashable {
        let from: Int
        let to: Int
    }

    /// One commit's slice of the graph.
    struct Row {
        /// Column of this commit's dot.
        var lane: Int
        /// Children arriving from the row above, ending at the dot. Drawn from
        /// the top edge to the dot's centre.
        var incoming: [Edge] = []
        /// Parents leaving toward the row below, starting at the dot. Drawn from
        /// the dot's centre to the bottom edge. Empty for a root commit.
        var outgoing: [Edge] = []
        /// Lanes passing this row untouched, drawn top edge to bottom edge.
        var passThrough: [Int] = []
        /// This commit has parents, but none of them were loaded — its history
        /// leaves the window here. Drawn as a short stub below the dot.
        var continuesBelow: Bool = false
    }

    /// Keyed by SHA rather than parallel to the commit array: the view iterates
    /// commits, and an index-parallel array would silently mis-draw if the two
    /// ever fell out of step.
    private(set) var rows: [String: Row] = [:]
    /// Widest column reached by any row. Rows size their own gutters (see
    /// `Row.columnCount`); this is the window-wide figure the tests pin against
    /// `git log --graph`'s own width.
    private(set) var width: Int = 0

    static let empty = CommitGraph()

    func row(for sha: String) -> Row? { rows[sha] }

    static func build(_ commits: [GitCommit]) -> CommitGraph {
        var graph = CommitGraph()

        // The window is finite, so some parents — below the limit, or on the far
        // side of a shallow clone — will never show up. Knowing that up front is
        // what keeps the gutter narrow: a lane waiting on a commit that isn't
        // coming would otherwise stay open to the bottom of the list, and a busy
        // repo merges long-lived branches often enough that those dead lanes
        // accumulate into a wall. Measured on a 500k-commit repo with 25 branches
        // in flight: 26 lanes at the bottom of a 1000-commit window, versus 4
        // once they retire properly.
        let loaded = Set(commits.map(\.sha))

        // Each slot is the SHA that lane is waiting for; nil is a free column
        // held open so lanes either side of it keep their horizontal position.
        var lanes: [String?] = []

        func allocate() -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            // Every lane waiting on this commit converges here. More than one
            // means the commit has several children in view — each is an edge in.
            let claiming = lanes.indices.filter { lanes[$0] == commit.sha }
            let lane = claiming.first ?? allocate()

            var row = Row(lane: lane)
            row.incoming = claiming.map { Edge(from: $0, to: lane) }
            // The converged lanes are done; only `lane` continues downward.
            for extra in claiming.dropFirst() { lanes[extra] = nil }

            lanes[lane] = nil
            row.passThrough = lanes.indices.filter { lanes[$0] != nil }

            // Unloaded parents get no lane at all — that's what retires the
            // column here instead of holding it to the bottom of the list.
            var placedFirst = false
            for parent in commit.parents where loaded.contains(parent) {
                if !placedFirst {
                    placedFirst = true
                    // A lane to our left is already waiting for this very commit,
                    // so our column is redundant — fold into it. This is git's
                    // "|/", and it's what keeps a busy repo narrow: when twenty
                    // branches fork from one commit, they converge as they reach
                    // it rather than running twenty columns to the same place.
                    // Only leftward, so a trunk never gets dragged sideways by a
                    // branch that happens to share its parent; the two just both
                    // wait, and meet at that commit's row.
                    if let existing = lanes.firstIndex(where: { $0 == parent }),
                        existing < lane {
                        row.outgoing.append(Edge(from: lane, to: existing))
                    } else {
                        // Otherwise this parent inherits the lane, keeping trunks
                        // straight.
                        lanes[lane] = parent
                        row.outgoing.append(Edge(from: lane, to: lane))
                    }
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    row.outgoing.append(Edge(from: lane, to: existing))
                } else {
                    let target = allocate()
                    lanes[target] = parent
                    row.outgoing.append(Edge(from: lane, to: target))
                }
            }
            // Nothing leaves the dot, yet the commit has parents: they're all
            // outside the window. Say so, rather than ending the line as if this
            // were a root commit.
            row.continuesBelow = !commit.parents.isEmpty && row.outgoing.isEmpty

            // Keep the array from growing forever as branches retire, so a repo
            // with lots of short-lived branches doesn't drift ever wider.
            while let last = lanes.last, last == nil { lanes.removeLast() }

            graph.rows[commit.sha] = row
            graph.width = max(graph.width, row.columnCount)
        }

        return graph
    }
}

extension CommitGraph.Row {
    /// Columns this row actually occupies — the width its gutter needs.
    ///
    /// Read by the row itself, not just by `build`: each row's gutter is sized to
    /// this rather than to the window's widest, so a subject indents to the graph
    /// beside it and one busy merge doesn't push every line in the pane right.
    var columnCount: Int {
        var maximum = lane
        for edge in incoming { maximum = max(maximum, edge.from) }
        for edge in outgoing { maximum = max(maximum, edge.to) }
        for column in passThrough { maximum = max(maximum, column) }
        return maximum + 1
    }
}
