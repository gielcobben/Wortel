import AppKit
import SwiftUI

/// The trailing source-control panel: branch header, the staged/unstaged
/// changes list, the diff of the selected file, and a commit box. Bound to
/// `GitPanelModel`, which points it at the selected session's repo.
struct SourceControlPanel: View {
    @Bindable var panel: GitPanelModel

    var body: some View {
        Group {
            if let repo = panel.repo {
                switch panel.pane {
                case .changes:
                    RepoView(repo: repo, focusRequest: panel.listFocusRequest)
                case .history:
                    HistoryView(repo: repo, focusRequest: panel.listFocusRequest)
                }
            } else {
                emptyState
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

    /// Persisted height of the changes list; the diff fills the rest. Replaces
    /// VSplitView (whose divider position SwiftUI never exposes) so the split
    /// survives hide/show and relaunch. Clamped against the live container
    /// height so the diff keeps a usable minimum. See DragDivider.
    @AppStorage("git.listHeight") private var listHeightStore: Double = 200
    private static let listMin: CGFloat = 80
    private static let diffMin: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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

    // MARK: Header

    private var pushHelp: String {
        let n = repo.status.ahead
        return n > 0 ? "Push \(n) commit\(n == 1 ? "" : "s")" : "Push"
    }

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
            if repo.canPush {
                Button {
                    Task { await repo.push() }
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .opacity(repo.isPushing ? 0.3 : 1)
                }
                .buttonStyle(.borderless)
                .help(pushHelp)
                .disabled(repo.isPushing)
            }
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
                LazyVStack(alignment: .leading, spacing: 0) {
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
            }
            // Keep the selected row visible as ↑/↓ (or a click) moves it.
            .onChange(of: repo.selectedChangeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        // While focused, ↑/↓ walk the changes and load each diff.
        .keyboardNavigableList(focused: $listFocused) { repo.selectAdjacent($0) }
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
                VStack(spacing: 0) {
                    DiffView(lines: diff.lines, fontSize: 12)
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
    let actionIcon: String
    let select: () -> Void
    let action: () -> Void

    @State private var hovering = false
    @State private var confirmingDiscard = false

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
        // Native right-click: an AppKit overlay that selects the row (so the
        // diff follows) and pops the menu. SwiftUI's own `.contextMenu` can't be
        // used to also select — its content closure is rebuilt on every render,
        // so any selection side effect there fires for every row and thrashes.
        .overlay(RightClickCatcher(onRightClick: rightClickSelect, makeMenu: makeContextMenu))
        .confirmationDialog(
            "Discard changes to “\(change.fileName)”?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                Task { await repo.discard(change) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(change.untracked
                ? "This deletes the untracked file. This cannot be undone."
                : "Your changes to this file will be permanently lost.")
        }
    }

    // MARK: Context menu

    private var fileURL: URL { repo.absoluteURL(for: change) }

    /// Whether the row's file is present on disk (deleted rows and staged
    /// deletions have nothing to open or reveal).
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Applications the Launch Services database offers for this file.
    private var openerApps: [URL] {
        guard fileExists else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
    }

    /// Select the row when it's right-clicked, so the diff pane follows it.
    private func rightClickSelect() {
        if !isSelected { select() }
    }

    /// Build the native right-click menu, freshly each time it opens.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        // Respect our explicit isEnabled flags rather than AppKit's validation.
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

        menu.addItem(ClosureMenuItem(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Discard Changes…") { confirmingDiscard = true })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Ignore") { Task { await repo.ignore(change) } })
        menu.addItem(ClosureMenuItem(title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fileURL.path, forType: .string)
        })

        return menu
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

// MARK: - Native right-click

/// A transparent AppKit overlay that owns the row's right-click: it selects the
/// row and pops a freshly-built menu. It's invisible to every other event —
/// `hitTest` only claims right-mouse events, so SwiftUI keeps left-clicks and
/// hover. This avoids SwiftUI's `.contextMenu`, whose content is rebuilt on
/// every render (making it impossible to select a row without thrashing).
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
        view.makeMenu = makeMenu
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void = {}
        var makeMenu: () -> NSMenu = { NSMenu() }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick()
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        }

        // Participate only in right-clicks; let clicks and hover fall through to
        // the SwiftUI content beneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? self : nil
        }
    }
}

/// An `NSMenuItem` that runs a closure when chosen, so the menu can be built
/// inline without a separate target/selector object.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
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
