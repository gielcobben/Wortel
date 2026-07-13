import SwiftUI

/// The window shell, mirroring Opslan: a NavigationSplitView with the session
/// list in the sidebar and the terminal in the detail. `.navigationTitle` /
/// `.navigationSubtitle` put the session name + path in the content area next
/// to the sidebar, and the sidebar gets the system's native floating panel —
/// all for free, the way SwiftUI intends.
struct ContentView: View {
    let runtime: GhosttyRuntime
    @Bindable var manager: SessionManager
    @Bindable var git: GitPanelModel

    var body: some View {
        NavigationSplitView {
            // Native list: List(selection:) gives click-select, keyboard nav,
            // drag-reorder (.onMove), a11y, and the system owns all row spacing.
            // The one override: the native highlight greys out when the sidebar
            // isn't the focused column (the terminal always is). We don't want
            // that here — the selection marks "the session you're viewing," not
            // "where the keyboard is" — so SidebarSelectionStyler turns the
            // system highlight off and we draw an always-accent pill behind the
            // row instead. Spacing stays fully native.
            List(selection: $manager.selectedID) {
                ForEach(manager.sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: manager.selectedID == session.id,
                        isEditing: manager.editingID == session.id,
                        commit: { newName in
                            manager.rename(session, to: newName)
                            manager.editingID = nil
                        },
                        cancel: { manager.editingID = nil })
                    .listRowBackground(selectionPill(for: session))
                    // NB: no SwiftUI double-tap gesture here. A `.onTapGesture(
                    // count: 2)` on the row makes SwiftUI hold every single click
                    // for the double-click interval before letting List's native
                    // selection through, so clicking sessions feels laggy.
                    // Double-click-to-rename is wired natively on the backing
                    // NSTableView instead (SidebarSelectionStyler), which leaves
                    // single-click selection fully native and instant.
                    .contextMenu {
                        Button("Rename") { manager.editingID = session.id }
                        Button("Close Session") { manager.requestClose(session) }
                    }
                }
                .onMove { manager.move(fromOffsets: $0, toOffset: $1) }
            }
            .background(SidebarSelectionStyler(onRowDoubleClick: { row in
                guard row >= 0, row < manager.sessions.count else { return }
                let session = manager.sessions[row]
                manager.selectedID = session.id
                manager.editingID = session.id
            }))
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        manager.newSession()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("New Session (⌘N)")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        } detail: {
            DetailView(runtime: runtime, manager: manager, git: git)
        }
    }

    /// Always-accent selection fill, matched to the native selection pill:
    /// inset 10pt from the row edges (the native highlight is turned off by
    /// SidebarSelectionStyler). Suppressed while renaming so the inline edit
    /// field sits on a normal background.
    @ViewBuilder
    private func selectionPill(for session: Session) -> some View {
        if manager.selectedID == session.id, manager.editingID != session.id {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 10)
        } else {
            Color.clear
        }
    }
}

/// Reaches into the NSTableView backing the sidebar List to do two things
/// SwiftUI can't express cleanly:
///
///  1. Turn off the AppKit selection highlight, so our always-accent pill is the
///     only selection visual (the native highlight greys out when the sidebar
///     isn't the focused column — but the terminal always is).
///  2. Wire double-click-to-rename on the table's native `doubleAction`, rather
///     than a SwiftUI `.onTapGesture(count: 2)` on each row. The gesture form
///     forces every single click to wait out the double-click interval before
///     List's native selection registers, which makes switching sessions by
///     click feel laggy; the native doubleAction leaves single-click selection
///     untouched and instant.
///
/// List keeps native click-select, keyboard nav, drag-reorder, and a11y. If
/// SwiftUI's view tree ever changes shape this finds nothing and both effects
/// simply no-op — no crash.
private struct SidebarSelectionStyler: NSViewRepresentable {
    /// Called with the clicked row index on a native double-click.
    let onRowDoubleClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRowDoubleClick: onRowDoubleClick) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRowDoubleClick = onRowDoubleClick
        context.coordinator.apply(from: nsView) // re-apply; SwiftUI can reset it
    }

    @MainActor
    final class Coordinator: NSObject {
        var onRowDoubleClick: (Int) -> Void

        init(onRowDoubleClick: @escaping (Int) -> Void) {
            self.onRowDoubleClick = onRowDoubleClick
        }

        func apply(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let root = view?.window?.contentView else { return }
                for table in root.tableViews() {
                    // The git diff view is also an NSTableView living in this
                    // same window — never treat it as the session list.
                    if table.identifier == DiffView.tableIdentifier { continue }
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    // (Re-)assert our double-click handler; SwiftUI may reset it.
                    if table.target !== self || table.doubleAction != #selector(self.handleDoubleClick(_:)) {
                        table.target = self
                        table.doubleAction = #selector(self.handleDoubleClick(_:))
                    }
                }
            }
        }

        @objc private func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0 else { return }
            onRowDoubleClick(row)
        }
    }
}

private extension NSView {
    /// Every NSTableView (incl. NSOutlineView) in this view's subtree.
    func tableViews() -> [NSTableView] {
        var found: [NSTableView] = []
        for sub in subviews {
            if let table = sub as? NSTableView { found.append(table) }
            found.append(contentsOf: sub.tableViews())
        }
        return found
    }
}

/// One sidebar row: session name with the path below it.
private struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let isEditing: Bool
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var draft = ""
    @State private var cancelling = false
    @FocusState private var fieldFocused: Bool

    // The selected row sits on an always-accent pill, so its content is white.
    // Not while editing: the rename field sits on a normal background.
    private var onAccent: Bool { isSelected && !isEditing }
    private var subtleColor: Color { onAccent ? .white.opacity(0.85) : .secondary }

    var body: some View {
        // Content padded inside an inset accent pill (~6pt from the cell edges,
        // so it's not edge-to-edge). The indicator is centered against the whole
        // row, not pinned to the title line.
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        // Route *every* way of ending an edit — Return, Escape,
                        // and clicking away — through one focus-resignation
                        // path. If the field is torn out of the tree (editingID
                        // = nil) while it's still first responder, AppKit's
                        // field editor is left dangling and the sidebar stops
                        // receiving clicks. Dropping focus first, then letting
                        // onChange commit/cancel, avoids that.
                        .onSubmit { fieldFocused = false }
                        .onExitCommand {
                            cancelling = true
                            fieldFocused = false
                        }
                        .onChange(of: fieldFocused) { _, focused in
                            guard !focused else { return }
                            if cancelling { cancel() } else { commit(draft) }
                        }
                        .task {
                            cancelling = false
                            draft = session.name
                            fieldFocused = true
                        }
                } else {
                    Text(session.name)
                        .foregroundStyle(onAccent ? .white : .primary)
                }
                if !session.abbreviatedPath.isEmpty {
                    Text(session.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(subtleColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            activityIndicator
        }
        .padding(.vertical, 6)
    }

    /// Trailing status glyph. Attention (bell / notification / long command
    /// done while unselected) wins over busy — once you select the session the
    /// attention clears and the spinner shows if a command is still running.
    @ViewBuilder
    private var activityIndicator: some View {
        if session.needsAttention {
            Circle()
                .fill(onAccent ? Color.white : Color.orange)
                .frame(width: 7, height: 7)
        } else if session.isBusy {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .tint(onAccent ? .white : .secondary)
        }
    }
}

/// The detail column: the terminal, with the source-control panel split in on
/// the trailing edge when shown. Extracted from ContentView's body so each
/// view stays small enough for the SwiftUI type-checker.
private struct DetailView: View {
    let runtime: GhosttyRuntime
    @Bindable var manager: SessionManager
    @Bindable var git: GitPanelModel

    var body: some View {
        HSplitView {
            TerminalContainer(runtime: runtime, session: manager.selected)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            if git.isVisible {
                SourceControlPanel(panel: git)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 640, maxHeight: .infinity)
            }
        }
        .navigationTitle(manager.selected?.name ?? "Wortel")
        .navigationSubtitle(manager.selected?.abbreviatedPath ?? "")
        .onChange(of: manager.selectedID) { _, _ in
            git.focus(cwd: manager.selected?.cwd)
        }
        .onChange(of: manager.selected?.cwd) { _, cwd in
            git.focus(cwd: cwd)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    git.toggle()
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .help("Source Control (⌘⌥G)")
            }
        }
    }
}

/// Hosts the terminal. Reuses TerminalHostViewController so every session's
/// SurfaceView stays alive across switches (no rebuild). SwiftUI updates the
/// existing controller — makeNSViewController runs once — so the host and its
/// live views persist.
private struct TerminalContainer: NSViewControllerRepresentable {
    let runtime: GhosttyRuntime
    let session: Session?

    func makeNSViewController(context: Context) -> TerminalHostViewController {
        TerminalHostViewController()
    }

    func updateNSViewController(_ controller: TerminalHostViewController, context: Context) {
        if let session {
            controller.show(session, runtime: runtime)
        }
    }
}
