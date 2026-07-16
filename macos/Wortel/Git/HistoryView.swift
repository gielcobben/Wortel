import AppKit
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
            // No header, deliberately. `commitList` being the pane's first view is
            // what lets the log run up under the titlebar and pick up the system's
            // blur; a strip of chrome here would sit under the toolbar opaquely
            // and there'd be nothing scrolling beneath it to blur. The branch chip
            // and this pane's actions live in the toolbar instead — see
            // GitToolbarControls.
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
                // Keeps the graph off the pane's leading edge and the pill off
                // its trailing one — the log is dense enough that running it into
                // the walls makes it feel wedged in.
                .padding(.horizontal, 6)
            }
            .onChange(of: repo.selectedCommitID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        // While focused, ↑/↓ walk the log and load each commit's diff.
        .keyboardNavigableList(focused: $listFocused) { repo.selectAdjacentCommit($0) }
    }

    // MARK: Files

    @ViewBuilder
    private var diffPane: some View {
        if repo.selectedCommitID == nil {
            centered("Select a commit to view its changes")
        } else if repo.isLoadingCommitFiles {
            centered("Loading…")
        } else if repo.commitFiles.isEmpty {
            centered("No file changes")
        } else {
            CommitFilesList(repo: repo)
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

// MARK: - Commit files accordion

/// The selected commit's changed files, GitHub-style: a summary header then one
/// collapsible row per file whose disclosure reveals that file's diff inline.
/// Replaces the old single concatenated commit patch — each file's diff loads
/// lazily on expand (see GitRepoModel.toggleCommitFile), so a big commit opens
/// on a numstat rather than parsing every patch up front.
private struct CommitFilesList: View {
    @Bindable var repo: GitRepoModel

    /// Whole-commit totals for the header. Binary rows (count -1) don't add in.
    private var additions: Int { repo.commitFiles.reduce(0) { $0 + max(0, $1.additions) } }
    private var deletions: Int { repo.commitFiles.reduce(0) { $0 + max(0, $1.deletions) } }

    var body: some View {
        VStack(spacing: 0) {
            // The summary banner is fixed above the scroll — always visible.
            header
                .background(.bar)
            Divider()
            ScrollView {
                // Each file is a section whose header (the file row) pins to the
                // top while its diff scrolls, so the banner and the current file's
                // row are both sticky. Pinned rows carry a material background or
                // the diff's tinted lines would show through them.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(repo.commitFiles) { file in
                        Section {
                            if repo.expandedCommitFiles.contains(file.path) {
                                expandedDiff(for: file)
                                Divider()
                            }
                        } header: {
                            VStack(spacing: 0) {
                                CommitFileRow(
                                    file: file,
                                    repo: repo,
                                    isExpanded: repo.expandedCommitFiles.contains(file.path))
                                Divider()
                            }
                            .background(.bar)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if repo.allCommitFilesExpanded { repo.collapseAllCommitFiles() }
                    else { await repo.expandAllCommitFiles() }
                }
            } label: {
                Text(repo.allCommitFilesExpanded ? "Collapse All" : "Expand All")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Spacer(minLength: 4)
            Text("\(repo.commitFiles.count) \(repo.commitFiles.count == 1 ? "file" : "files")")
                .foregroundStyle(.secondary)
            if additions > 0 { Text("+\(additions)").foregroundStyle(.green) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(.red) }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func expandedDiff(for file: CommitFileChange) -> some View {
        if file.isImage {
            if let images = repo.commitFileImages[file.path] {
                CommitImageDiffView(imageDiff: images)
            } else {
                fileNotice("Loading…")
            }
        } else if file.isBinary {
            fileNotice("Binary file not shown")
        } else if let diff = repo.commitFileDiffs[file.path] {
            if diff.lines.isEmpty {
                fileNotice("No textual changes")
            } else {
                // Show every line at full height — no inner scroller — so the
                // accordion's ScrollView is the one and only scroll. A very large
                // file is cut off inline (the whole table would realize all its
                // rows at once) and the notice says so; the terminal has the rest.
                let shown = min(diff.lines.count, Self.maxInlineDiffLines)
                VStack(spacing: 0) {
                    DiffView(
                        lines: Array(diff.lines.prefix(shown)),
                        highlights: diff.highlights, fontSize: 12)
                        .frame(height: diffHeight(shown))
                    if diff.truncated || shown < diff.lines.count { TruncatedDiffNotice() }
                }
            }
        } else {
            fileNotice("Loading…")
        }
    }

    /// Beyond this the inline diff is cut off — a static, full-height table
    /// realizes every row it holds (nothing scrolls it to recycle them), so an
    /// enormous patch would otherwise build tens of thousands of cells on expand.
    private static let maxInlineDiffLines = 2000

    /// The inline diff's full content height (plus a hair, so rounding never
    /// leaves the inner table a sliver to scroll and steal the wheel). The
    /// accordion's own ScrollView does all the scrolling.
    private func diffHeight(_ lineCount: Int) -> CGFloat {
        CGFloat(lineCount) * DiffView.rowHeight(forFontSize: 12) + 4
    }

    private func fileNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// One file in the accordion: a disclosure chevron, the status badge, the name
/// with its dimmed directory, and the file's +/− counts. A click toggles the
/// diff; a right-click opens the same Open / Show in Finder / Copy Path menu the
/// Changes pane's rows carry (see SourceControlPanel's ChangeRow).
private struct CommitFileRow: View {
    let file: CommitFileChange
    let repo: GitRepoModel
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Text(String(file.statusCode))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(file.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            counts
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { Task { await repo.toggleCommitFile(file) } }
        // Right-click only — the catcher claims nothing else, so the tap above
        // still toggles. No selection side effect: unlike the changes list, a
        // file row here has no "selected" state to move.
        .overlay(RightClickCatcher(onRightClick: {}, makeMenu: makeContextMenu))
    }

    @ViewBuilder
    private var counts: some View {
        if file.isBinary {
            Text("bin").font(.caption2).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 5) {
                if file.additions > 0 {
                    Text("+\(file.additions)").foregroundStyle(.green)
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)").foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var statusColor: Color {
        switch file.statusCode {
        case "M", "T": return .orange
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .secondary
        }
    }

    // MARK: Context menu

    private var fileURL: URL { repo.absoluteURL(forPath: file.path) }

    /// Whether the file is present on disk now. A historical commit may reference
    /// a path that was later deleted or renamed away, so Open/Reveal are gated.
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    private var openerApps: [URL] {
        fileExists ? NSWorkspace.shared.urlsForApplications(toOpen: fileURL) : []
    }

    /// Build the native right-click menu, freshly each time it opens — the same
    /// Open / Open With / Show in Finder / Copy Path set the Changes rows use,
    /// minus the working-tree actions (stage/discard/ignore) that a committed
    /// file can't take.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = ClosureMenuItem(title: "Open") { NSWorkspace.shared.open(fileURL) }
        open.isEnabled = fileExists
        menu.addItem(open)

        let apps = openerApps
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.isEnabled = !apps.isEmpty
        if !apps.isEmpty {
            let submenu = NSMenu()
            for app in apps {
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                let item = ClosureMenuItem(title: FileManager.default.displayName(atPath: app.path)) {
                    NSWorkspace.shared.open(
                        [fileURL], withApplicationAt: app,
                        configuration: NSWorkspace.OpenConfiguration())
                }
                item.image = icon
                submenu.addItem(item)
            }
            openWith.submenu = submenu
        }
        menu.addItem(openWith)

        let reveal = ClosureMenuItem(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        reveal.isEnabled = fileExists
        menu.addItem(reveal)

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fileURL.path, forType: .string)
        })

        return menu
    }
}

/// Inline before/after (or added/deleted) image preview for an expanded image
/// row — the History counterpart to the Changes pane's ImageDiffView, but with
/// no ScrollView of its own so it flows in the accordion's scroll. Sides stack
/// (each gets the narrow pane's full width), and a side is omitted when it
/// doesn't exist (a freshly added or deleted image).
private struct CommitImageDiffView: View {
    let imageDiff: ImageDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if imageDiff.old == nil && imageDiff.new == nil {
                Text("Image unavailable")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let old = imageDiff.old {
                column(label: imageDiff.new == nil ? "Deleted" : "Before", image: old)
            }
            if let new = imageDiff.new {
                column(label: imageDiff.old == nil ? "Added" : "After", image: new)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Cap on displayed height; width is further bounded by the pane. An image is
    /// never drawn larger than these or its own pixels — a 54×54 icon shows at
    /// 54×54, not blown up to fill the pane.
    private static let maxImageHeight: CGFloat = 320

    private func column(label: String, image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // Bounded by the image's own size (so it never upscales), the cap,
                // and — because the outer frame only ever offers the pane's width —
                // the pane. `.padding` wraps the image, then the full-width frame
                // centers that padded image inside the backing box.
                .frame(
                    maxWidth: image.size.width,
                    maxHeight: min(image.size.height, Self.maxImageHeight))
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor)))
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
    let isSelected: Bool
    /// Not yet on the remote — draws the dot after the gutter.
    let isUnpushed: Bool

    /// This row's own gutter width. A row with no graph slice still reserves one
    /// column, so a log with no merges doesn't sit flush against the edge.
    private var rowColumns: Int { row?.columnCount ?? 1 }

    /// Uniform, unlike the intrinsic height this row used to take. Each row draws
    /// its own slice of the graph against its own height, so rows of differing
    /// heights would bend the same merge at visibly different angles.
    static let height: CGFloat = 22

    private static let authorWidth: CGFloat = 64
    private static let shaWidth: CGFloat = 52
    private static let ageWidth: CGFloat = 26
    /// Gap on each side of the unpushed dot — after the graph, and before the
    /// content. The row's content is deliberately *not* aligned across rows: a
    /// dotted row is indented by the dot it carries.
    private static let dotGap: CGFloat = 4
    /// The pill's inner padding, and so the distance from the dot to the text.
    /// Tight: the graph, the dot and the subject are one line of information read
    /// left to right, and gaps between them read as separation they don't have.
    private static let contentPad: CGFloat = 5
    /// Fixed rather than `Color.accentColor`: "not pushed" is not a selection or
    /// an action, and under a non-blue system accent the accent would also be
    /// what paints the selection pill this dot sits beside.
    private static let unpushedBlue = Color(red: 0.24, green: 0.51, blue: 0.96)

    private var onAccent: Bool { isSelected }
    private var subtleColor: Color { onAccent ? .white.opacity(0.85) : .secondary }

    /// Chips take the colour of the lane their commit sits on, which is what ties
    /// `toolbar-pane-buttons` to the line it's the tip of. Lanes are columns
    /// rather than identities, so this is only stable within a render — but the
    /// chip and its dot are drawn from the same lane in that render, which is the
    /// whole claim being made.
    private var laneTint: Color {
        CommitGraphGutter.laneColor(row?.lane ?? 0)
    }

    /// Fork bolds the part before the first colon — the "Toolbar:" or "Sidebar:"
    /// scope — which is what makes a log skimmable by area at a glance. Only a
    /// short prefix qualifies: a subject that merely contains a colon halfway
    /// through a sentence isn't scoped, and bolding half a line reads as noise.
    private var subject: some View {
        let text: Text
        if let colon = commit.subject.firstIndex(of: ":"),
           commit.subject.distance(from: commit.subject.startIndex, to: colon) <= 24 {
            let scope = String(commit.subject[..<colon])
            let rest = String(commit.subject[colon...])
            text = Text(scope).fontWeight(.semibold) + Text(rest)
        } else {
            text = Text(commit.subject)
        }
        return text
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sized to *this* row's columns, not the window's widest. Everything
            // after it — dot, chips, subject — therefore indents to the graph
            // beside it, so a single merge somewhere in the window no longer
            // indents every subject in the pane past it.
            CommitGraphGutter(row: row, lanes: rowColumns, isMerge: commit.isMerge)
                .frame(width: CommitGraphGutter.width(forLanes: rowColumns), height: Self.height)
            // Always: separates the graph from the row's content.
            Spacer().frame(width: Self.dotGap)
            // The dot's column collapses when there's no dot, rather than sitting
            // empty — so an undotted row's text starts exactly where a dotted
            // row's dot does, and only rows that need the space take it. Fork
            // does the same, and it's why its pushed commits sit left.
            if isUnpushed {
                Circle()
                    .fill(Self.unpushedBlue)
                    // The same size as a lane node, taken from the gutter rather
                    // than restated: the two sit side by side on every row, and a
                    // dot a pixel off its neighbour reads as a mistake.
                    .frame(width: CommitGraphGutter.nodeDiameter,
                           height: CommitGraphGutter.nodeDiameter)
                    .help("Not pushed yet")
                Spacer().frame(width: Self.dotGap)
            }
            HStack(spacing: 6) {
                ForEach(commit.refs, id: \.self) { ref in
                    RefChip(ref: ref, tint: laneTint, onAccent: onAccent)
                }
                subject
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
            .padding(.horizontal, Self.contentPad)
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
    /// The colour of the lane this ref's commit sits on, so a branch's chip and
    /// its line are the same colour. Tags opt out — a tag isn't a line.
    let tint: Color
    /// Sitting on the selection pill, where the accent has taken the background.
    let onAccent: Bool

    /// A tag names a point, not a branch, so it doesn't borrow a lane's colour —
    /// it would claim to be the tip of a line it has nothing to do with.
    private var color: Color { ref.kind == .tag ? .orange : tint }

    /// Remotes get a mark rather than relying on the "origin/" prefix, which is
    /// the first thing you stop reading. Deliberately generic: which host it is
    /// (GitHub, in Fork's case) isn't something a ref name can answer.
    private var icon: String? {
        switch ref.kind {
        case .remoteBranch: return "cloud"
        case .tag: return "tag"
        case .localBranch, .detachedHead: return ref.isHead ? "checkmark" : nil
        }
    }

    /// The checked-out branch is filled and white rather than merely outlined:
    /// on a row with three chips, weight alone doesn't say which one you're on.
    private var foreground: Color {
        if onAccent { return .white }
        return ref.isHead ? .white : color
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(ref.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10, weight: ref.isHead ? .bold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(onAccent ? Color.white.opacity(0.6) : color, lineWidth: 1)
        }
        .layoutPriority(1)
    }

    /// Dark inside the border, as Fork has it — the chip reads as an outline with
    /// a name in it, so a row of them doesn't fight the subject beside them.
    private var fill: Color {
        if onAccent { return .white.opacity(0.2) }
        return ref.isHead ? color.opacity(0.55) : color.opacity(0.12)
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
    /// Leading pad before the first lane's centre. It shifts the whole gutter,
    /// and with it everything the row draws after — the graph's trailing gap is
    /// half a lane's spacing, not this.
    private static let inset: CGFloat = 3
    private static let lineWidth: CGFloat = 1.5
    private static let dotRadius: CGFloat = 2.5
    /// How tightly a line turns when it changes column. Fork's lines are
    /// orthogonal with a rounded corner rather than a curve spread across the
    /// row: the line reads as "this column, then that one", and a branch running
    /// down five rows draws one straight line instead of five shallow diagonals.
    private static let cornerRadius: CGFloat = 5

    /// Diameter of a lane node, so things drawn outside the Canvas — the unpushed
    /// dot — can be the same size as the dots in the graph beside them.
    static var nodeDiameter: CGFloat { dotRadius * 2 }
    /// Lanes past this fold onto the last column. Repos do exceed it, but a
    /// gutter wide enough to show them would crowd out the subject line, which is
    /// what the pane is actually for.
    private static let maxLanes = 6

    /// Width for a given number of columns. Called per row with that row's own
    /// count, so subjects indent to the graph beside them and rag down the pane
    /// rather than all clearing the window's widest merge.
    static func width(forLanes lanes: Int) -> CGFloat {
        CGFloat(min(max(lanes, 1), maxLanes)) * laneSpacing + inset
    }

    /// Lane colours cycle. They aren't stable across reloads for a given branch —
    /// a lane is a column, not an identity — but they do keep adjacent lanes
    /// distinguishable, which is all the gutter is asking of them.
    private static let palette: [Color] = [
        .orange, .blue, .purple, .green, .pink, .teal,
    ]

    /// The colour of a lane, for anything outside the Canvas that needs to agree
    /// with it — the ref chips, which take the colour of the lane they sit on.
    /// Same folding as `color(_:)` so a chip past `maxLanes` matches the column
    /// its dot actually got folded into.
    static func laneColor(_ lane: Int) -> Color {
        palette[min(lane, maxLanes - 1) % palette.count]
    }

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let middle = size.height / 2

            for lane in row.passThrough {
                context.stroke(
                    line(from: CGPoint(x: x(lane), y: 0), to: CGPoint(x: x(lane), y: size.height)),
                    with: .color(color(lane)), lineWidth: Self.lineWidth)
            }
            // Every line is coloured by the lane it *travels* in rather than by
            // the commit at its end, so a branch keeps one colour down its whole
            // length: `from` for a line arriving or folding away, `to` for one
            // branching out into a fresh column.
            //
            // Where a line turns is what shapes the graph. A line arriving turns
            // at the dot it lands on; a line branching out turns at the dot it
            // leaves. Everything else is vertical, so a branch spanning ten rows
            // draws one straight line and not ten shallow diagonals.
            for edge in row.incoming {
                context.stroke(
                    verticalThenAcross(
                        column: x(edge.from), fromY: 0,
                        to: CGPoint(x: x(edge.to), y: middle)),
                    with: .color(color(edge.from)), lineWidth: Self.lineWidth)
            }
            for edge in row.outgoing {
                if edge.to > edge.from {
                    // Branching out to a new column: turn at the dot, so the line
                    // leaves the commit that spawned it and is vertical for the
                    // rest of the row.
                    context.stroke(
                        acrossThenVertical(
                            from: CGPoint(x: x(edge.from), y: middle),
                            column: x(edge.to), toY: size.height),
                        with: .color(color(edge.to)), lineWidth: Self.lineWidth)
                } else {
                    // Folding back into a column to our left (git's "|/"). Turn as
                    // late as possible instead of at the dot: the branch stays in
                    // its own column past its own tip, which is what makes it read
                    // as one line running down to the commit it forked from rather
                    // than as a rung between two rows.
                    context.stroke(
                        verticalThenAcross(
                            column: x(edge.from), fromY: middle,
                            to: CGPoint(x: x(edge.to), y: size.height)),
                        with: .color(color(edge.from)), lineWidth: Self.lineWidth)
                }
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

    /// A plain segment, for lines that don't change column.
    private func line(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    /// Down `column` from `fromY`, then a rounded corner into `end` — how a line
    /// arrives at a dot from a different column.
    private func verticalThenAcross(column: CGFloat, fromY: CGFloat, to end: CGPoint) -> Path {
        var path = Path()
        let start = CGPoint(x: column, y: fromY)
        path.move(to: start)
        guard column != end.x else {
            path.addLine(to: end)
            return path
        }
        // The corner sits at (column, end.y): the line comes down to the dot's
        // height and turns there.
        path.addArc(
            tangent1End: CGPoint(x: column, y: end.y),
            tangent2End: end,
            radius: radius(dx: end.x - column, dy: end.y - fromY))
        path.addLine(to: end)
        return path
    }

    /// Out of a dot, then a rounded corner into `column` and down to `toY` — how a
    /// line leaves a dot for a different column.
    private func acrossThenVertical(from start: CGPoint, column: CGFloat, toY: CGFloat) -> Path {
        var path = Path()
        path.move(to: start)
        let end = CGPoint(x: column, y: toY)
        guard column != start.x else {
            path.addLine(to: end)
            return path
        }
        path.addArc(
            tangent1End: CGPoint(x: column, y: start.y),
            tangent2End: end,
            radius: radius(dx: column - start.x, dy: toY - start.y))
        path.addLine(to: end)
        return path
    }

    /// Never round more than the space there is: half a lane's width, or half the
    /// run's height. A corner bigger than its own legs draws an arc that overshoots
    /// the point it's supposed to turn at.
    private func radius(dx: CGFloat, dy: CGFloat) -> CGFloat {
        min(Self.cornerRadius, abs(dx) / 2, abs(dy) / 2)
    }
}
