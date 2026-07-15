import SwiftUI

/// The History pane: the commit log over the selected commit's diff, split by the
/// same persisted DragDivider arrangement the Changes pane uses.
///
/// Deliberately read-only. Everything destructive a log invites — revert, reset,
/// cherry-pick, amend — is a footgun in a panel that sits next to a live terminal
/// where the same repo is being worked on, and the terminal is right there for it.
struct HistoryView: View {
    @Bindable var repo: GitRepoModel

    /// Height of the commit list; the diff takes the rest. Separate key from the
    /// Changes pane's split — the panes are read differently, so their splits
    /// shouldn't drag each other around.
    @AppStorage("git.historyListHeight") private var listHeightStore: Double = 220
    private static let listMin: CGFloat = 80
    private static let diffMin: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let maxList = max(Self.listMin, geo.size.height - Self.diffMin)
                let listHeight = Binding(
                    get: { min(max(CGFloat(listHeightStore), Self.listMin), maxList) },
                    set: { listHeightStore = Double($0) }
                )
                VStack(spacing: 0) {
                    commitList
                        .frame(height: listHeight.wrappedValue)
                    DragDivider(axis: .vertical, length: listHeight, range: Self.listMin...maxList)
                    diffPane
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .task {
            // Lazy: the log is only read the first time History is actually shown,
            // so opening the panel on Changes costs nothing.
            if !repo.loadedHistory { await repo.loadHistory() }
        }
    }

    // MARK: Commit list

    private var commitList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if repo.commits.isEmpty && repo.loadedHistory {
                        Text("No commits yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(repo.commits) { commit in
                        CommitRow(
                            commit: commit,
                            row: repo.graph.row(for: commit.sha),
                            lanes: repo.graph.width,
                            isSelected: repo.selectedCommitID == commit.id)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await repo.selectCommit(commit.id) } }
                            .id(commit.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: repo.selectedCommitID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Diff

    @ViewBuilder
    private var diffPane: some View {
        if let diff = repo.commitDiff {
            if diff.isBinary {
                centered("Binary changes")
            } else if diff.lines.isEmpty {
                centered("No textual changes")
            } else {
                DiffView(lines: diff.lines, fontSize: 12)
            }
        } else if repo.selectedCommitID != nil {
            centered("Loading…")
        } else {
            centered("Select a commit to view its diff")
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One commit row: the graph gutter, then the subject with author, SHA and age
/// as trailing columns. Mirrors the changes list's always-accent selection pill.
///
/// Single-line and tight rather than stacking the metadata under the subject —
/// a log is read by scanning down it, and the denser the rows the more of the
/// history a glance covers. The metadata columns are fixed-width so they line up
/// into columns down the pane instead of ragging along each subject's end.
///
/// The pill stops at the gutter rather than spanning the row: lane colours are
/// picked to read against the panel background, and filling underneath them with
/// the accent would leave the graph illegible on exactly the row being read.
private struct CommitRow: View {
    let commit: GitCommit
    let row: CommitGraph.Row?
    let lanes: Int
    let isSelected: Bool

    /// Uniform, unlike the intrinsic height this row used to take. Each row draws
    /// its own slice of the graph against its own height, so rows of differing
    /// heights would bend the same merge at visibly different angles.
    static let height: CGFloat = 22

    private static let authorWidth: CGFloat = 64
    private static let shaWidth: CGFloat = 52
    private static let ageWidth: CGFloat = 26

    private var onAccent: Bool { isSelected }
    private var subtleColor: Color { onAccent ? .white.opacity(0.85) : .secondary }

    var body: some View {
        HStack(spacing: 0) {
            CommitGraphGutter(row: row, lanes: lanes, isMerge: commit.isMerge)
                .frame(width: CommitGraphGutter.width(forLanes: lanes), height: Self.height)
            HStack(spacing: 6) {
                Text(commit.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 4)
                Text(commit.author)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.authorWidth, alignment: .trailing)
                Text(commit.shortSHA)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: Self.shaWidth, alignment: .trailing)
                Text(commit.age())
                    .frame(width: Self.ageWidth, alignment: .trailing)
            }
            .font(.callout)
            .foregroundStyle(subtleColor)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor)
                }
            }
            .padding(.trailing, 4)
        }
    }
}

/// One row's slice of the commit graph: the lanes crossing it, the edges
/// converging on or leaving its commit, and the dot itself.
///
/// Everything is drawn relative to this row's own bounds — top edge, centre,
/// bottom edge — which is what lets the list stay lazy: no row needs to know
/// where its neighbours ended up.
private struct CommitGraphGutter: View {
    let row: CommitGraph.Row?
    let lanes: Int
    let isMerge: Bool

    /// Distance between lane centres.
    private static let laneSpacing: CGFloat = 12
    private static let inset: CGFloat = 5
    private static let lineWidth: CGFloat = 1.5
    private static let dotRadius: CGFloat = 2.5
    /// Lanes past this fold onto the last column. Repos do exceed it, but a
    /// gutter wide enough to show them would crowd out the subject line, which is
    /// what the pane is actually for.
    private static let maxLanes = 6

    /// Same for every row so the subjects line up into a column.
    static func width(forLanes lanes: Int) -> CGFloat {
        CGFloat(min(max(lanes, 1), maxLanes)) * laneSpacing + inset
    }

    /// Lane colours cycle. They aren't stable across reloads for a given branch —
    /// a lane is a column, not an identity — but they do keep adjacent lanes
    /// distinguishable, which is all the gutter is asking of them.
    private static let palette: [Color] = [
        .orange, .blue, .purple, .green, .pink, .teal,
    ]

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let middle = size.height / 2

            for lane in row.passThrough {
                context.stroke(
                    line(from: CGPoint(x: x(lane), y: 0), to: CGPoint(x: x(lane), y: size.height)),
                    with: .color(color(lane)), lineWidth: Self.lineWidth)
            }
            // Coloured by the far end in both cases — the lane the line travels
            // in, not the commit it meets — so a branch keeps one colour along
            // its whole length and its merge curve matches it.
            for edge in row.incoming {
                context.stroke(
                    line(from: CGPoint(x: x(edge.from), y: 0), to: CGPoint(x: x(edge.to), y: middle)),
                    with: .color(color(edge.from)), lineWidth: Self.lineWidth)
            }
            for edge in row.outgoing {
                context.stroke(
                    line(
                        from: CGPoint(x: x(edge.from), y: middle),
                        to: CGPoint(x: x(edge.to), y: size.height)),
                    with: .color(color(edge.to)), lineWidth: Self.lineWidth)
            }

            // Merges read as a ring, plain commits as a solid dot. Both edges stop
            // at the centre, so the ring's middle stays clear.
            let radius = isMerge ? Self.dotRadius + 1.5 : Self.dotRadius
            let centre = CGPoint(x: x(row.lane), y: middle)
            let dot = Path(
                ellipseIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2))
            if isMerge {
                context.stroke(dot, with: .color(color(row.lane)), lineWidth: Self.lineWidth)
            } else {
                context.fill(dot, with: .color(color(row.lane)))
            }
        }
    }

    private func x(_ lane: Int) -> CGFloat {
        (CGFloat(min(lane, Self.maxLanes - 1)) + 0.5) * Self.laneSpacing + Self.inset
    }

    private func color(_ lane: Int) -> Color {
        Self.palette[min(lane, Self.maxLanes - 1) % Self.palette.count]
    }

    /// Straight within a lane; an S-curve when the line changes column, bending
    /// across the middle of its span so it leaves and arrives vertically and
    /// meets the next row's segment without a kink.
    private func line(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        if start.x == end.x {
            path.addLine(to: end)
        } else {
            let midY = (start.y + end.y) / 2
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x, y: midY),
                control2: CGPoint(x: end.x, y: midY))
        }
        return path
    }
}
