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
            List(selection: $manager.selectedID) {
                ForEach(manager.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                }
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
}

/// One sidebar row: terminal icon, session name, and the path below it.
private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                if !session.abbreviatedPath.isEmpty {
                    Text(session.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if session.hasBell {
                Circle()
                    .fill(Color.accentColor)
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
