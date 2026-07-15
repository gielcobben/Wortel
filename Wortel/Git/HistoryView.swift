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
                        CommitRow(commit: commit, isSelected: repo.selectedCommitID == commit.id)
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

/// One commit row: subject over author + age, with the short SHA trailing.
/// Mirrors the changes list's always-accent selection pill.
private struct CommitRow: View {
    let commit: GitCommit
    let isSelected: Bool

    private var onAccent: Bool { isSelected }
    private var subtleColor: Color { onAccent ? .white.opacity(0.85) : .secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                HStack(spacing: 4) {
                    Text(commit.author)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                    Text(commit.age())
                }
                .font(.caption)
                .foregroundStyle(subtleColor)
            }
            Spacer(minLength: 4)
            Text(commit.shortSHA)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(subtleColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor)
                    .padding(.horizontal, 4)
            }
        }
    }
}
