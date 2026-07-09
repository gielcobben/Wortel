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
            // No List(selection:): we draw an accent "pill" ourselves so the
            // selection stays accent-colored regardless of focus (the sidebar
            // never holds keyboard focus — the terminal does). A single tap
            // selects.
            List {
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
                    .contentShape(Rectangle())
                    .onTapGesture { manager.selectedID = session.id }
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
                .navigationTitle(manager.selected?.name ?? "Vellum")
                .navigationSubtitle(manager.selected?.abbreviatedPath ?? "")
        }
    }

    /// Native-looking accent selection pill for the selected row — but not
    /// while it's being renamed (the inline edit field wants a normal
    /// background, like Finder).
    @ViewBuilder
    private func selectionPill(for session: Session) -> some View {
        if manager.selectedID == session.id, manager.editingID != session.id {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        } else {
            Color.clear
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

    // White on the accent pill; standard colors otherwise and while editing
    // (the edit field sits on a normal background, not the accent pill).
    private var onAccent: Bool { isSelected && !isEditing }
    private var primaryColor: Color { onAccent ? .white : .primary }
    private var secondaryColor: Color { onAccent ? .white.opacity(0.75) : .secondary }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(secondaryColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .foregroundStyle(primaryColor)
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
                        .foregroundStyle(primaryColor)
                }
                if !session.abbreviatedPath.isEmpty {
                    Text(session.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if session.hasBell {
                Circle()
                    .fill(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 3)
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
