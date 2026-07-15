import Foundation

/// Topological ordering of a window of commits, done here rather than by git.
///
/// The lane layout needs one guarantee from its input: a commit must appear
/// before its parents. Git offers that via `--topo-order`/`--date-order`, but
/// both make it a property of the *whole history* — git has to walk every commit
/// in the repo to compute it, and `--max-count` doesn't bound that work. Measured
/// on a 200k-commit repo: ~870ms for either flag versus ~20ms for git's default
/// order, whatever the limit. A commit-graph file collapses that to ~20ms, but
/// most repos don't have one (it's written by `git gc`, not on clone or fetch),
/// so relying on it would make the panel fast on some machines and slow on the
/// rest.
///
/// So: take git's cheap default order (newest-first by committer date), then sort
/// that window here. The window is a few hundred commits, so this is a rounding
/// error, and the guarantee ends up stronger than what git's default gives —
/// which is only "usually" parents-last, and skews on rebased or clock-skewed
/// history.
enum CommitOrder {
    /// Reorder so every commit precedes its parents, following each chain down
    /// before starting another so branches read as runs rather than interleaving.
    ///
    /// Kahn's algorithm over the window: a commit is emitted once every child of
    /// it *within the window* already has been. Parents outside the window (below
    /// the limit, or in a shallow clone) simply don't count — their lanes run off
    /// the bottom edge, which is what the reader should see anyway.
    ///
    /// `settled` freezes the first N entries in the order they're already in, and
    /// sorts only what follows. That's what makes paging usable: sorting the
    /// grown window from scratch is *more* faithful to what git would print, but
    /// it moves rows that are already on screen — measured at 118 of the first
    /// 300 rows shifting when page two arrives, starting from row 182, well above
    /// where the reader is scrolling. Rows that have been read stay put instead.
    /// The frozen prefix is still a valid ordering, since loading older commits
    /// can't add children to anything already emitted.
    static func topological(_ commits: [GitCommit], settled: Int = 0) -> [GitCommit] {
        guard commits.count > 1 else { return commits }

        // Last writer wins on the (pathological) duplicate SHA, rather than
        // trapping the way an uniqueKeysWithValues init would.
        var bySHA: [String: GitCommit] = Dictionary(minimumCapacity: commits.count)
        for commit in commits { bySHA[commit.sha] = commit }

        // How many children each commit has *inside* the window.
        var pending: [String: Int] = Dictionary(minimumCapacity: commits.count)
        for commit in commits {
            for parent in commit.parents where bySHA[parent] != nil {
                pending[parent, default: 0] += 1
            }
        }

        var result: [GitCommit] = []
        result.reserveCapacity(commits.count)
        var emitted = Set<String>(minimumCapacity: commits.count)

        // Replay the already-ordered rows verbatim, decrementing as we go, so the
        // tail's seeds come out as if we'd walked to them normally.
        for commit in commits.prefix(settled) where emitted.insert(commit.sha).inserted {
            result.append(commit)
            for parent in commit.parents where pending[parent] != nil {
                pending[parent]! -= 1
            }
        }

        // Seed with the tips of what's left — commits nothing un-emitted descends
        // from — keeping git's date order among them. Reversed because we pop off
        // the end, and the newest tip should come out first.
        var stack = commits.dropFirst(settled)
            .filter { !emitted.contains($0.sha) && pending[$0.sha, default: 0] <= 0 }
            .reversed().map { $0 }

        while let commit = stack.popLast() {
            guard emitted.insert(commit.sha).inserted else { continue }
            result.append(commit)
            // Pushed first-parent-first so the *last* parent ends up on top and
            // pops first: at a merge, that walks the merged-in branch before
            // resuming the trunk, which retires the branch's lane within a few
            // rows instead of holding a column open until the trunk drains. It's
            // also the order git's own --topo-order emits.
            for parent in commit.parents {
                guard let next = bySHA[parent], let count = pending[parent] else { continue }
                let remaining = count - 1
                pending[parent] = remaining
                if remaining <= 0 { stack.append(next) }
            }
        }

        // A cycle can't happen in a git DAG, but a corrupt or grafted repo could
        // still strand commits here, and dropping rows would be a worse failure
        // than showing them slightly out of order.
        if result.count != commits.count {
            for commit in commits where !emitted.contains(commit.sha) { result.append(commit) }
        }
        return result
    }
}
