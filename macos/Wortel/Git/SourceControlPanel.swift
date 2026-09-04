import AppKit
import SwiftUI

/// The trailing source-control panel: the staged/unstaged
/// changes list, the diff of the selected file, and a commit box. Bound to
/// `GitPanelModel`, which points it at the selected session's repo.
struct SourceControlPanel: View {
    @Bindable var panel: GitPanelModel

    var body: some View {
        Group {
            switch panel.pane {
            case .changes:
                if let repo = panel.repo {
                    RepoView(repo: repo, focusRequest: panel.listFocusRequest)
                } else {
                    emptyState
                }
            case .history:
                if let repo = panel.repo {
                    HistoryView(repo: repo, focusRequest: panel.listFocusRequest)
                } else {
                    emptyState
                }
            case .files:
                // Unreachable: InspectorContainer routes the Files pane to
                // FileTreePanel and only builds this view for the two
                // source-control panes. Listed so the switch stays exhaustive
                // over the shared enum rather than swallowing a future case.
                EmptyView()
            }
        }
        // No background on purpose. As an inspector split item the system supplies
        // the material itself (Liquid Glass on macOS 26), and painting anything
        // opaque here — a tinted fill, or an NSVisualEffectView — sits on top of
        // that material and blocks it. Width now comes from .inspectorColumnWidth.
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
    /// Whether the native commit editor holds focus (drives its border). Driven
    /// by CommitMessageEditor's focus callback, not @FocusState — the editor is
    /// an NSTextView, outside SwiftUI's focus system.
    @State private var messageFocused = false
    /// Grow-to-fit height of the commit editor, and a tap-to-focus token.
    @State private var messageHeight: CGFloat = 52
    @State private var focusMessageRequest = 0
    @State private var lastHandledFocusRequest = 0
    /// What a confirmed Discard would throw away. One dialog for the pane rather
    /// than one per row: a bulk discard is asked about once, and the question has
    /// to be able to count the files it is asking about.
    @State private var discardCandidates: [GitFileChange] = []

    /// Persisted height of the changes list; the diff fills the rest. Replaces
    /// VSplitView (whose divider position SwiftUI never exposes) so the split
    /// survives hide/show and relaunch. Clamped against the live container
    /// height so the diff keeps a usable minimum. See DragDivider.
    @AppStorage("git.listHeight") private var listHeightStore: Double = 200
    private static let listMin: CGFloat = 80
    private static let diffMin: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            // No header, deliberately — see HistoryView. The list has to be the
            // pane's first view for it to run up under the titlebar and pick up
            // the system's blur; the branch chip moved to the toolbar (see
            // MainToolbar) to give it that back.
            //
            // Draggable split between the files list and the diff. The list gets
            // an explicit, persisted height; the diff takes whatever's left.
            GeometryReader { geo in
                let maxList = max(Self.listMin, geo.size.height - Self.diffMin)
                let listHeight = Binding(
                    get: { min(max(CGFloat(listHeightStore), Self.listMin), maxList) },
                    set: { listHeightStore = Double($0) }
                )
                VStack(spacing: 0) {
                    changesList
                        .frame(height: listHeight.wrappedValue)
                    DragDivider(axis: .vertical, length: listHeight, range: Self.listMin...maxList)
                    diffPane
                        .frame(maxHeight: .infinity)
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
        .confirmationDialog(
            discardTitle,
            isPresented: Binding(
                get: { !discardCandidates.isEmpty },
                set: { if !$0 { discardCandidates = [] } }),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                let changes = discardCandidates
                discardCandidates = []
                Task { await repo.discard(changes) }
            }
            Button("Cancel", role: .cancel) { discardCandidates = [] }
        } message: {
            Text(discardMessage)
        }
    }

    // MARK: Discard confirmation

    private var discardTitle: String {
        if discardCandidates.count == 1, let only = discardCandidates.first {
            return "Discard changes to “\(only.fileName)”?"
        }
        return "Discard changes to \(discardCandidates.count) files?"
    }

    /// The message has to say when files will be *deleted* rather than reverted,
    /// and a selection can be both at once: untracked files have no earlier
    /// version to go back to, so discarding one removes it. Counting them
    /// separately is the difference between "you'll lose today's edits" and
    /// "that new file will be gone".
    private var discardMessage: String {
        let untracked = discardCandidates.filter(\.untracked).count
        let tracked = discardCandidates.count - untracked
        switch (tracked, untracked) {
        case (0, 1):
            return "This deletes the untracked file. This cannot be undone."
        case (0, let new):
            return "This deletes \(new) untracked files. This cannot be undone."
        case (1, 0):
            return "Your changes to this file will be permanently lost."
        case (let edited, 0):
            return "Your changes to \(edited) files will be permanently lost."
        case (let edited, let new):
            let files = edited == 1 ? "file" : "files"
            let newFiles = new == 1 ? "untracked file" : "untracked files"
            return "Your changes to \(edited) \(files) will be permanently lost, "
                + "and \(new) \(newFiles) will be deleted."
        }
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

    // MARK: Changes list

    @ViewBuilder
    private var changesList: some View {
        // A clean work tree has nothing to scroll, so it isn't a list with one
        // line at the top of it — it's an empty state, and it sits in the middle
        // of its pane like the diff's does. Sharing `centered` is the point: the
        // two halves of this panel are empty at the same moments, and they
        // should say so the same way.
        if repo.status.isClean {
            centered("No changes")
        } else {
            populatedChangesList
        }
    }

    private var populatedChangesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    changeSection(
                        title: "Staged Changes",
                        changes: repo.status.stagedChanges,
                        actionIcon: "minus",
                        sectionAction: repo.status.stagedChanges.isEmpty ? nil : { Task { await repo.unstageAll() } },
                        sectionActionHelp: "Unstage All",
                        rowAction: { change in Task { await repo.unstage([change]) } })
                    changeSection(
                        title: "Changes",
                        changes: repo.status.unstagedChanges,
                        actionIcon: "plus",
                        sectionAction: repo.status.unstagedChanges.isEmpty ? nil : { Task { await repo.stageAll() } },
                        sectionActionHelp: "Stage All",
                        rowAction: { change in Task { await repo.stage([change]) } })
                }
                .padding(.vertical, 4)
            }
            // Reveal on ↑/↓ only, and only as far as needed. A clicked row is
            // already visible; scrolling it anyway slides it out from under the
            // pointer, which is how the second click of a double-click misses.
            .onChange(of: repo.revealRequest) { _, _ in
                guard let id = repo.selectedChangeID else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
        // While focused, ↑/↓ walk the changes and load each diff, ⇧↑/⇧↓ drag the
        // selection along with them, and ⌘A takes the lot.
        .keyboardNavigableList(
            focused: $listFocused,
            move: { repo.selectAdjacent($0) },
            extendMove: { repo.selectAdjacent($0, extending: true) },
            selectAll: { repo.selectAllChanges() })
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
                    repo: repo,
                    isSelected: repo.selection.contains(change.id),
                    isLead: repo.selectedChangeID == change.id,
                    actionIcon: actionIcon,
                    // Clicking a file both selects it and gives the list keyboard
                    // focus, so ↑/↓ work immediately afterward. Which *kind* of
                    // selection it is comes from the modifiers, the way a list
                    // behaves everywhere else on the platform: ⌘ toggles one row,
                    // ⇧ takes the run from the anchor, neither replaces.
                    select: { modifiers in
                        if modifiers.contains(.command) {
                            repo.toggleSelection(change.id)
                        } else if modifiers.contains(.shift) {
                            repo.extendSelection(to: change.id)
                        } else {
                            repo.select(change.id)
                        }
                        listFocused = true
                    },
                    // Double-click opens the file in its own window, showing
                    // *this* row's diff — the staged or unstaged side, as
                    // clicked, because the pane separates them and a window that
                    // showed the other one would contradict the list.
                    open: {
                        repo.openPreview(for: change)
                    },
                    action: { rowAction(change) },
                    requestDiscard: { discardCandidates = $0 })
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
                VStack(spacing: 0) {
                    DiffView(lines: diff.lines, highlights: diff.highlights, fontSize: 12)
                    if diff.truncated { TruncatedDiffNotice() }
                }
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
                    .textSelection(.enabled)
            }
            // Message field with the commit action as a circular button tucked
            // into the bottom-trailing corner, like a chat composer's send. The
            // whole filled box focuses the field, not just the glyphs.
            HStack(alignment: .bottom, spacing: 6) {
                CommitMessageEditor(
                    text: $repo.commitMessage,
                    height: $messageHeight,
                    placeholder: "Message (⌘⏎ to commit)",
                    minHeight: 52,
                    maxHeight: 160,
                    onFocusChange: { messageFocused = $0 },
                    onCommit: { Task { await repo.commit() } },
                    focusRequest: focusMessageRequest)
                    .frame(height: messageHeight)
                if repo.canGenerateMessage || repo.isGeneratingMessage {
                    generateButton
                }
                commitButton
            }
            .padding(8)
            .background(
                // Tap target sits behind the field/button, so clicking anywhere
                // in the padding focuses the message without stealing their taps.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { focusMessageRequest += 1 })
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(messageFocused ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
        }
        .padding(12)
    }

    /// On-device (Apple Intelligence) commit-message drafter. Only shown when
    /// the model is available and something is staged.
    private var generateButton: some View {
        Button {
            Task { await repo.generateCommitMessage() }
        } label: {
            Group {
                if repo.isGeneratingMessage {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!repo.canGenerateMessage)
        .help("Draft a message from staged changes (on-device)")
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
    let repo: GitRepoModel
    let isSelected: Bool
    /// The one selected row the diff pane is showing. With a single selection
    /// this is the same thing as `isSelected`.
    let isLead: Bool
    let actionIcon: String
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    let action: () -> Void
    /// Hand a set of changes to the pane's one confirmation dialog.
    let requestDiscard: ([GitFileChange]) -> Void

    @State private var hovering = false

    /// Selected rows are drawn on the accent, so everything on them has to come
    /// off it — same rule as the History pane's rows.
    private var onAccent: Bool { isSelected }

    var body: some View {
        HStack(spacing: 8) {
            Text(String(change.statusCode))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(statusColor))
                .frame(width: 12)
            Text(change.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.caption)
                    .foregroundStyle(
                        onAccent ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: action) {
                    Image(systemName: actionIcon)
                        .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
            }
        }
        // Inner padding is the pill's; the outer keeps it off the pane's edges.
        // The two together preserve where the text sat before.
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background {
            // A solid accent pill, matching History. The faint tint this replaces
            // read as a hover state rather than a selection, and running it edge
            // to edge made it a band across the pane instead of a row.
            //
            // Every selected row gets the pill, and the lead gets it at full
            // strength: the diff below is showing exactly one of these files, and
            // with five identical pills there is nothing on screen that says
            // which. The gap is small on purpose — this is a lead marker, not a
            // second kind of selection, and a bulk action takes all of them.
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(isLead ? 1 : 0.55))
            }
        }
        .padding(.horizontal, 4)
        // Dragging a selected row drags the whole selection into the terminal
        // (it joins the paths with spaces); dragging an unselected one is just
        // that file, because the drag never claimed to be about the selection.
        .overlay(RowClickCatcher(onClick: select, onDoubleClick: open, urls: dragURLs))
        .onHover { hovering = $0 }
        // Native right-click: an AppKit overlay that selects the row (so the
        // diff follows) and pops the menu. SwiftUI's own `.contextMenu` can't be
        // used to also select — its content closure is rebuilt on every render,
        // so any selection side effect there fires for every row and thrashes.
        .overlay(RightClickCatcher(onRightClick: rightClickSelect, makeMenu: makeContextMenu))
    }

    // MARK: Context menu

    private var fileURL: URL { repo.absoluteURL(for: change) }

    /// Whether the row's file is present on disk (deleted rows and staged
    /// deletions have nothing to open or reveal).
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Select the row when it's right-clicked, so the diff pane follows it.
    ///
    /// A right-click **inside** an existing selection leaves it alone, so the
    /// menu that follows can act on all of it; one outside collapses the
    /// selection onto this row first. That is the Finder's rule, and it's the
    /// only one that keeps a destructive menu item honest: what the menu is
    /// about is always what is highlighted behind it.
    private func rightClickSelect() {
        if !isSelected { select([]) }
    }

    /// What the menu acts on: the whole selection when this row is part of it
    /// (which `rightClickSelect` has just guaranteed), otherwise this row.
    private var targets: [GitFileChange] {
        let selected = repo.selectedChanges
        return selected.contains(where: { $0.id == change.id }) ? selected : [change]
    }

    /// The files a drag carries out of this row. Same rule as the menu.
    private func dragURLs() -> [URL] {
        targets.map(repo.absoluteURL(for:))
    }

    /// Build the native right-click menu, freshly each time it opens.
    ///
    /// Bulk items say how many files they will touch. A count in the title is
    /// the last thing standing between a ⇧-click that ran further than the
    /// reader meant and an irreversible discard, and it is the reason these
    /// titles are built rather than constant.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        // Respect our explicit isEnabled flags rather than AppKit's validation.
        menu.autoenablesItems = false

        let targets = self.targets
        let many = targets.count > 1
        let suffix = many ? " \(targets.count) Files" : ""

        // Open and Edit are about *a* file, so a multi-row selection doesn't get
        // them: twelve preview windows is not what anyone means by opening a
        // selection. Show in Finder does generalise (it reveals them all), so it
        // stays either way.
        if !many {
            // Open *is* the preview window: the same thing this row's
            // double-click gives you, showing this row's side of the diff.
            // Editing is a separate intent and gets its own group below.
            let open = ClosureMenuItem(title: "Open") { repo.openPreview(for: change) }
            open.isEnabled = fileExists
            menu.addItem(open)
            menu.addItem(.separator())
            menu.addEditItems(for: fileURL, exists: fileExists)
        }

        let urls = targets.map(repo.absoluteURL(for:))
        menu.addItem(ClosureMenuItem(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })

        menu.addItem(.separator())

        // Staging is per row, and a selection spanning both sections has rows
        // that want opposite things — so offer whichever halves are actually
        // there, each acting only on its own half. One item that did "the right
        // thing per row" would be a single click with two meanings.
        let unstaged = targets.filter { !$0.staged }
        let staged = targets.filter(\.staged)
        if !unstaged.isEmpty {
            let title = unstaged.count > 1 ? "Stage \(unstaged.count) Files" : "Stage"
            menu.addItem(ClosureMenuItem(title: title) { Task { await repo.stage(unstaged) } })
        }
        if !staged.isEmpty {
            let title = staged.count > 1 ? "Unstage \(staged.count) Files" : "Unstage"
            menu.addItem(ClosureMenuItem(title: title) { Task { await repo.unstage(staged) } })
        }

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Discard Changes\(suffix)…") {
            requestDiscard(targets)
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Ignore\(suffix)") {
            Task { await repo.ignore(targets) }
        })
        menu.addItem(ClosureMenuItem(title: many ? "Copy Paths" : "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                urls.map(\.path).joined(separator: "\n"), forType: .string)
        })

        return menu
    }

    /// Shared with the file tree so the two panes can't disagree about what
    /// "modified" looks like. See GitStatusStyle.
    private var statusColor: Color { GitStatusStyle.color(for: change.statusCode) }
}

// `RightClickCatcher` (the native right-click overlay) and `ClosureMenuItem`
// live in UI/RightClickCatcher.swift — shared with the sidebar rows.

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
