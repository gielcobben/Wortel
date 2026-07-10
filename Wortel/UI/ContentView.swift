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
            // List(selection:) drives selection and gives the native sidebar
            // highlight plus native drag-to-reorder (the insertion-line drag
            // that fires `.onMove`) for free. The highlight greys out when the
            // sidebar isn't the focused column (the terminal usually holds
            // focus) — that's standard macOS source-list behavior.
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
                    .contextMenu {
                        Button("Rename") { manager.editingID = session.id }
                        Button("Close Session") { manager.requestClose(session) }
                    }
                }
                .onMove { manager.move(fromOffsets: $0, toOffset: $1) }
            }
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
}

/// One sidebar row: terminal icon, session name (double-click to rename), and
/// the path below it.
private struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let isEditing: Bool
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
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
                }
                if !session.abbreviatedPath.isEmpty {
                    Text(session.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            activityIndicator
        }
        .padding(.vertical, 3)
    }

    /// Trailing status glyph. Attention (bell / notification / long command
    /// done while unselected) wins over busy — once you select the session the
    /// attention clears and the spinner shows if a command is still running.
    @ViewBuilder
    private var activityIndicator: some View {
        if session.needsAttention {
            Circle()
                .fill(isSelected ? Color.white : Color.orange)
                .frame(width: 7, height: 7)
        } else if session.isBusy {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .tint(isSelected ? .white : .secondary)
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
