import SwiftUI

/// The window shell, mirroring Opslan: a NavigationSplitView with the session
/// list in the sidebar and the terminal in the detail. `.navigationTitle` /
/// `.navigationSubtitle` put the session name + path in the content area next
/// to the sidebar, and the sidebar gets the system's native floating panel —
/// all for free, the way SwiftUI intends.
struct ContentView: View {
    let runtime: GhosttyRuntime
    @Bindable var manager: SessionManager

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
                    .contextMenu {
                        Button("Rename") { manager.editingID = session.id }
                        Button("Close Session") { manager.requestClose(session) }
                    }
                }
                .onMove { manager.move(fromOffsets: $0, toOffset: $1) }
            }
            .background(SidebarSelectionStyler())
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
            TerminalContainer(runtime: runtime, session: manager.selected)
                .navigationTitle(manager.selected?.name ?? "Wortel")
                .navigationSubtitle(manager.selected?.abbreviatedPath ?? "")
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

/// Turns off the AppKit selection highlight on the List backing the sidebar so
/// our always-accent pill is the only selection visual, while List keeps native
/// click-select, keyboard nav, drag-reorder, and accessibility (selection state
/// still updates; only the system highlight is suppressed). If SwiftUI's view
/// tree ever changes shape this finds nothing and the native highlight returns —
/// no crash.
private struct SidebarSelectionStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        disableHighlight(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        disableHighlight(from: nsView) // re-apply; SwiftUI can reset it
    }

    private func disableHighlight(from view: NSView) {
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            for table in root.tableViews() where table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
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
                        .onSubmit { commit(draft) }
                        .onExitCommand { cancel() }
                        .onChange(of: fieldFocused) { _, focused in
                            // Commit when focus leaves the field (click away).
                            if !focused { commit(draft) }
                        }
                        .task {
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
