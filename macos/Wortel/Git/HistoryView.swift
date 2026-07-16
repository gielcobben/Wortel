import SwiftUI

/// The History pane: the commit log over the selected commit's diff, split by the
/// same persisted DragDivider arrangement the Changes pane uses.
///
/// Deliberately read-only. Everything destructive a log invites — revert, reset,
/// cherry-pick, amend — is a footgun in a panel that sits next to a live terminal
/// where the same repo is being worked on, and the terminal is right there for it.
struct HistoryView: View {
    @Bindable var repo: GitRepoModel
    /// Monotonic focus-request token from GitPanelModel (⌘⌥L). A change means
    /// "put keyboard focus in this pane's list." Only one pane is mounted at a
    /// time, so both panes can read the same token.
    let focusRequest: Int
    @FocusState private var listFocused: Bool
    @State private var lastHandledFocusRequest = 0

    /// Height of the commit list; the diff takes the rest. Separate key from the
    /// Changes pane's split — the panes are read differently, so their splits
    /// shouldn't drag each other around.
    @AppStorage("git.historyListHeight") private var listHeightStore: Double = 220
    private static let listMin: CGFloat = 80
    private static let diffMin: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            header
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
        // ⌘⌥L focus request. Handled both on change (pane already open) and on
        // appear (the request is what revealed the panel, or switched to this
        // pane, so this view didn't exist when the token moved).
        .onChange(of: focusRequest) { _, req in applyFocusRequest(req) }
        .onAppear { applyFocusRequest(focusRequest) }
    }

    /// Move keyboard focus into the commit list for an unseen focus request.
    private func applyFocusRequest(_ req: Int) {
        guard req != lastHandledFocusRequest else { return }
        lastHandledFocusRequest = req
        // Give ↑/↓ a starting point if nothing is selected yet. The log may still
        // be loading on a first open, in which case the list is empty and this
        // no-ops — focus still lands, and the first ↑/↓ picks up the top commit.
        if repo.selectedCommitID == nil { repo.selectAdjacentCommit(1) }
        DispatchQueue.main.async { listFocused = true }
    }

    // MARK: Header

    /// Which branch you're on, and the way back to it.
    ///
    /// The Changes pane has had this since the panel shipped; History — the pane
    /// that's actually *about* branches — never showed it, because it reads
    /// `repo.commits` and never touched `repo.status`. Same chip, so switching
    /// panes doesn't move it.
    private var header: some View {
        HStack(spacing: 6) {
            BranchSwitcher(repo: repo)
            Spacer()
            Button {
                Task { await repo.jumpToHead() }
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            .help("Jump to the commit you're on")
            .disabled(repo.status.head == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Commit list

    /// The row whose appearance pulls in the next page — a little short of the
    /// end, so the next page is usually already there by the time you reach it.
    private var loadMoreTriggerID: String? {
        guard repo.canLoadMoreHistory else { return nil }
        let lead = 20
        let index = max(0, repo.commits.count - lead)
        return repo.commits.indices.contains(index) ? repo.commits[index].id : nil
    }

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
                            isSelected: repo.selectedCommitID == commit.id,
                            isUnpushed: repo.unpushed.contains(commit.sha))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                listFocused = true
                                Task { await repo.selectCommit(commit.id) }
                            }
                            .id(commit.id)
                            // Page in more history a little before the reader
                            // reaches the end. Compared against one precomputed
                            // id rather than looking each row up — this fires on
                            // every row that scrolls into view, and the list can
                            // be thousands long.
                            .onAppear {
                                if commit.id == loadMoreTriggerID {
                                    Task { await repo.loadMoreHistory() }
                                }
                            }
                    }
                    if repo.isLoadingMoreHistory {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: repo.selectedCommitID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        // While focused, ↑/↓ walk the log and load each commit's diff.
        .keyboardNavigableList(focused: $listFocused) { repo.selectAdjacentCommit($0) }
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
                VStack(spacing: 0) {
                    DiffView(lines: diff.lines, fontSize: 12)
                    if diff.truncated { TruncatedDiffNotice() }
                }
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

/// Footer for a patch that was cut short. Says so explicitly — a diff that just
/// stops looks identical to a file that ends, and the terminal is right there
/// for the full patch.
struct TruncatedDiffNotice: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "scissors")
            Text("Diff truncated — too large to display in full")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary)
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
    /// Not yet on the remote — draws the leading dot.
    let isUnpushed: Bool

    /// Uniform, unlike the intrinsic height this row used to take. Each row draws
    /// its own slice of the graph against its own height, so rows of differing
    /// heights would bend the same merge at visibly different angles.
    static let height: CGFloat = 22

    private static let authorWidth: CGFloat = 64
    private static let shaWidth: CGFloat = 52
    private static let ageWidth: CGFloat = 26
    /// The dot's own column, ahead of the gutter. Fixed and always present, so
    /// the graph starts at the same x on every row whether or not it's dotted.
    private static let dotWidth: CGFloat = 10

    private var onAccent: Bool { isSelected }
    private var subtleColor: Color { onAccent ? .white.opacity(0.85) : .secondary }

    var body: some View {
        HStack(spacing: 0) {
            // Outside the selection pill and outside the graph Canvas, both
            // deliberately: on the pill it would be blue-on-blue, and inside the
            // gutter it would read as a lane node — which is a different claim
            // entirely (that's topology; this is sync state).
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .opacity(isUnpushed ? 1 : 0)
                .frame(width: Self.dotWidth, height: Self.height)
                .help("Not pushed yet")
            CommitGraphGutter(row: row, lanes: lanes, isMerge: commit.isMerge)
                .frame(width: CommitGraphGutter.width(forLanes: lanes), height: Self.height)
            HStack(spacing: 6) {
                ForEach(commit.refs, id: \.self) { ref in
                    RefChip(ref: ref, onAccent: onAccent)
                }
                Text(commit.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 4)
                Text(commit.author)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.authorWidth, alignment: .leading)
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

/// A branch or tag name sitting on the commit it points at.
///
/// This is what makes a HEAD-only log legible as *branches*: the list walks one
/// ancestry, so without chips there's nothing to say where `main` or
/// `origin/main` have got to relative to where you are. Colour carries the kind
/// — local, remote, tag — since the name alone can't (`main` and `origin/main`
/// differ only by a prefix you stop reading after the tenth row).
private struct RefChip: View {
    let ref: GitRef
    /// Sitting on the selection pill, where the accent has taken the background.
    let onAccent: Bool

    private var tint: Color {
        switch ref.kind {
        case .localBranch, .detachedHead: return .accentColor
        case .remoteBranch: return .purple
        case .tag: return .orange
        }
    }

    var body: some View {
        Text(ref.name)
            .font(.system(size: 10, weight: ref.isHead ? .bold : .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(onAccent ? Color.white.opacity(0.25) : tint.opacity(0.15))
            }
            .overlay {
                // The branch you're on gets an outline as well as bold: on a busy
                // row the weight alone is easy to miss.
                if ref.isHead {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            onAccent ? Color.white.opacity(0.5) : tint.opacity(0.5),
                            lineWidth: 1)
                }
            }
            .layoutPriority(1)
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

            // History that leaves the window: a stub that stops short of the row
            // edge. The gap matters — a retired column can be reused by the very
            // next row, and a full-height line would read as one continuous
            // branch joining two unrelated commits.
            if row.continuesBelow {
                context.stroke(
                    line(
                        from: CGPoint(x: x(row.lane), y: middle),
                        to: CGPoint(x: x(row.lane), y: middle + (size.height - middle) * 0.55)),
                    with: .color(color(row.lane).opacity(0.5)), lineWidth: Self.lineWidth)
            }

            // Merges are the same solid dot, just larger — a ring reads as a
            // different kind of thing entirely, when it's only a commit with two
            // parents and the lanes converging on it already say so.
            let radius = isMerge ? Self.dotRadius + 1.5 : Self.dotRadius
            let centre = CGPoint(x: x(row.lane), y: middle)
            let dot = Path(
                ellipseIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(color(row.lane)))
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
