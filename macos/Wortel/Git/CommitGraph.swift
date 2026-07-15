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
    }

    /// Keyed by SHA rather than parallel to the commit array: the view iterates
    /// commits, and an index-parallel array would silently mis-draw if the two
    /// ever fell out of step.
    private(set) var rows: [String: Row] = [:]
    /// Widest column reached by any row, so every row's gutter is the same width
    /// and the subject text lines up.
    private(set) var width: Int = 0

    static let empty = CommitGraph()

    func row(for sha: String) -> Row? { rows[sha] }

    static func build(_ commits: [GitCommit]) -> CommitGraph {
        var graph = CommitGraph()

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

            for (index, parent) in commit.parents.enumerated() {
                if index == 0 {
                    // First parent inherits the lane, keeping trunks straight.
                    lanes[lane] = parent
                    row.outgoing.append(Edge(from: lane, to: lane))
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    row.outgoing.append(Edge(from: lane, to: existing))
                } else {
                    let target = allocate()
                    lanes[target] = parent
                    row.outgoing.append(Edge(from: lane, to: target))
                }
            }

            // Keep the array from growing forever as branches retire, so a repo
            // with lots of short-lived branches doesn't drift ever wider.
            while let last = lanes.last, last == nil { lanes.removeLast() }

            graph.rows[commit.sha] = row
            graph.width = max(graph.width, row.columnCount)
        }

        return graph
    }
}

private extension CommitGraph.Row {
    /// Columns this row actually occupies — the width its gutter needs.
    var columnCount: Int {
        var maximum = lane
        for edge in incoming { maximum = max(maximum, edge.from) }
        for edge in outgoing { maximum = max(maximum, edge.to) }
        for column in passThrough { maximum = max(maximum, column) }
        return maximum + 1
    }
}
