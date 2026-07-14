import SwiftUI

/// Carries the changes list's intrinsic content height up so the panel can size
/// it to fit until it hits the 50% cap.
private struct ListContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The trailing source-control panel: branch header, the staged/unstaged
/// changes list, the diff of the selected file, and a commit box. Bound to
/// `GitPanelModel`, which points it at the selected session's repo.
struct SourceControlPanel: View {
    @Bindable var panel: GitPanelModel

    var body: some View {
        Group {
            if let repo = panel.repo {
                RepoView(repo: repo, focusRequest: panel.listFocusRequest)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: panel.resolvedNonRepo ? "folder" : "arrow.triangle.branch")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(panel.resolvedNonRepo ? "Not a git repository" : "No repository")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Repo view

private struct RepoView: View {
    @Bindable var repo: GitRepoModel
    /// Monotonic focus-request token from GitPanelModel (⌘⌥L). A change means
    /// "put keyboard focus in the changes list."
    let focusRequest: Int
    @FocusState private var listFocused: Bool
    @FocusState private var messageFocused: Bool
    @State private var lastHandledFocusRequest = 0
    /// Measured intrinsic height of the changes list content, used to size the
    /// list to fit until it would exceed half the panel.
    @State private var listContentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The changes list sizes to its content, but never grows past half
            // the available height — so a couple of files leave the diff most of
            // the room, while a long list caps at 50% and scrolls internally.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    changesList
                        .frame(height: listHeight(available: geo.size.height))
                    Divider()
                    diffPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            commitBar
        }
        // ⌘⌥L focus request. Handle it both when it changes (panel already open)
        // and on appear (the request revealed a previously-hidden panel, so this
        // view didn't exist when the token changed).
        .onChange(of: focusRequest) { _, req in applyFocusRequest(req) }
        .onAppear { applyFocusRequest(focusRequest) }
    }

    /// Move keyboard focus into the changes list for an unseen focus request.
    private func applyFocusRequest(_ req: Int) {
        guard req != lastHandledFocusRequest else { return }
        lastHandledFocusRequest = req
        // Give ↑/↓ a starting point if nothing is selected yet.
        if repo.selectedChangeID == nil { repo.selectAdjacent(1) }
        // Next runloop turn: the focusable list is reliably installed by then,
        // even when this request is what just revealed the panel.
        DispatchQueue.main.async { listFocused = true }
    }

    private func listHeight(available: CGFloat) -> CGFloat {
        // Cap at half the area; scroll past that. Give the list a little more
        // than exact fit-content (breathing room below the last row, and a
        // comfortable floor so a single file isn't cramped) — all still clamped
        // to the 50% cap.
        let cap = available * 0.5
        // Before the first measurement, fall back to the cap rather than
        // collapsing to zero.
        guard listContentHeight > 0 else { return cap }
        return min(max(listContentHeight + 20, 96), cap)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text(repo.status.branch ?? "detached")
                .fontWeight(.medium)
                .lineLimit(1)
            if repo.status.ahead > 0 {
                Label("\(repo.status.ahead)", systemImage: "arrow.up")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if repo.status.behind > 0 {
                Label("\(repo.status.behind)", systemImage: "arrow.down")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Spacer()
            Button {
                Task { await repo.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(repo.isRefreshing ? 0.3 : 1)
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(repo.isRefreshing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Changes list

    private var changesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Regular VStack (not Lazy) so its background GeometryReader
                // reports the *full* content height for the fit-to-content sizing
                // — the changes list is short; the heavy view is the diff, which
                // has its own virtualized NSTableView.
                VStack(alignment: .leading, spacing: 0) {
                    if repo.status.isClean {
                        Text("No changes")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    changeSection(
                        title: "Staged Changes",
                        changes: repo.status.stagedChanges,
                        actionIcon: "minus",
                        sectionAction: repo.status.stagedChanges.isEmpty ? nil : { Task { await repo.unstageAll() } },
                        sectionActionHelp: "Unstage All",
                        rowAction: { change in Task { await repo.unstage(change) } })
                    changeSection(
                        title: "Changes",
                        changes: repo.status.unstagedChanges,
                        actionIcon: "plus",
                        sectionAction: repo.status.unstagedChanges.isEmpty ? nil : { Task { await repo.stageAll() } },
                        sectionActionHelp: "Stage All",
                        rowAction: { change in Task { await repo.stage(change) } })
                }
                .padding(.vertical, 4)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ListContentHeightKey.self, value: proxy.size.height)
                })
            }
            // Keep the selected row visible as ↑/↓ (or a click) moves it.
            .onChange(of: repo.selectedChangeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .onPreferenceChange(ListContentHeightKey.self) { listContentHeight = $0 }
        // Focus management: the list only claims the keyboard once you click a
        // file (which sets listFocused), so the terminal keeps its arrow keys
        // until then. While focused, ↑/↓ walk the changes and load each diff.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { repo.selectAdjacent(-1); return .handled }
        .onKeyPress(.downArrow) { repo.selectAdjacent(1); return .handled }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(listFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
        .background(.clear)
    }

    @ViewBuilder
    private func changeSection(
        title: String,
        changes: [GitFileChange],
        actionIcon: String,
        sectionAction: (() -> Void)?,
        sectionActionHelp: String,
        rowAction: @escaping (GitFileChange) -> Void
    ) -> some View {
        if !changes.isEmpty {
            HStack {
                Text("\(title) (\(changes.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let sectionAction {
                    Button(action: sectionAction) {
                        Image(systemName: actionIcon)
                    }
                    .buttonStyle(.borderless)
                    .help(sectionActionHelp)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(changes) { change in
                ChangeRow(
                    change: change,
                    isSelected: repo.selectedChangeID == change.id,
                    actionIcon: actionIcon,
                    // Clicking a file both selects it and gives the list keyboard
                    // focus, so ↑/↓ work immediately afterward.
                    select: {
                        repo.select(change.id)
                        listFocused = true
                    },
                    action: { rowAction(change) })
                .id(change.id)
            }
        }
    }

    // MARK: Diff

    @ViewBuilder
    private var diffPane: some View {
        if let imageDiff = repo.imageDiff {
            ImageDiffView(imageDiff: imageDiff)
        } else if let diff = repo.diff {
            if diff.isBinary {
                centered("Binary file")
            } else if diff.lines.isEmpty {
                centered("No textual changes")
            } else {
                DiffView(lines: diff.lines, fontSize: 12)
            }
        } else {
            centered("Select a file to view its diff")
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Commit

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = repo.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            // Message field with the commit action as a circular button tucked
            // into the bottom-trailing corner, like a chat composer's send. The
            // whole filled box focuses the field, not just the glyphs.
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message (⌘⏎ to commit)", text: $repo.commitMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($messageFocused)
                    .lineLimit(3...8)
                    .frame(minHeight: 52, alignment: .topLeading)
                commitButton
            }
            .padding(8)
            .background(
                // Tap target sits behind the field/button, so clicking anywhere
                // in the padding focuses the message without stealing their taps.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { messageFocused = true })
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(messageFocused ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
        }
        .padding(12)
    }

    private var commitButton: some View {
        Button {
            Task { await repo.commit() }
        } label: {
            Group {
                if repo.isCommitting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(repo.canCommit ? Color.white : Color.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(repo.canCommit ? Color.accentColor : Color.gray.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!repo.canCommit)
        .help("Commit staged changes (⌘⏎)")
    }
}

// MARK: - Change row

private struct ChangeRow: View {
    let change: GitFileChange
    let isSelected: Bool
    let actionIcon: String
    let select: () -> Void
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(change.statusCode))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(change.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: action) {
                    Image(systemName: actionIcon)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private var statusColor: Color {
        switch change.statusCode {
        case "M", "T": return .orange
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        case "?": return .green
        case "U": return .red
        default: return .secondary
        }
    }
}

// MARK: - Image diff

/// Renders an image change visually instead of "Binary file". Sides are stacked
/// (old above new) so each gets the panel's full width in this narrow inspector;
/// a newly added or deleted image shows just the one side it has.
private struct ImageDiffView: View {
    let imageDiff: ImageDiff

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if imageDiff.old == nil && imageDiff.new == nil {
                    Text("Image unavailable")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 24)
                }
                if let old = imageDiff.old {
                    imageColumn(label: imageDiff.new == nil ? "Deleted" : "Before", image: old)
                }
                if let new = imageDiff.new {
                    imageColumn(label: imageDiff.old == nil ? "Added" : "After", image: new)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    private func imageColumn(label: String, image: NSImage) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 320)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor)))
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
