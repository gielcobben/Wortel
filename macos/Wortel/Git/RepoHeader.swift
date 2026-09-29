import AppKit
import SwiftUI

/// The strip at the top of the Changes and History tabs: which branch you're
/// on (and the switcher behind it), and the repository's remote actions.
///
/// These lived in the toolbar while the column was three panes behind one
/// segmented control. With the column a strip of tabs, the titlebar above it is
/// the tabs' own row, and controls that only mean something on a source-control
/// tab belong inside that tab: the same place the ChatGPT app puts a browser
/// tab's address bar. It costs the list its run up under the titlebar, which the
/// tab strip would have covered anyway.
struct RepoHeader: View {
    @Bindable var repo: GitRepoModel
    @State private var showsBranches = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task {
                    // Loaded before the popover opens so it sizes for the list
                    // it will show. A `for-each-ref`: the click still feels
                    // immediate.
                    await repo.loadBranches()
                    showsBranches = true
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(repo.status.branch ?? "detached")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(HeaderButtonStyle())
            .help(repo.status.branch ?? "Switch branch")
            .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
                BranchList(repo: repo, dismiss: { showsBranches = false })
            }

            Spacer(minLength: 4)

            Menu {
                Button(fetchTitle) { Task { await repo.fetch() } }
                    .disabled(busy || !repo.canFetch)
                Button(pullTitle) { Task { await repo.pull() } }
                    .disabled(busy || !repo.canPull)
                Button(pushTitle) { Task { await repo.push() } }
                    .disabled(busy || !repo.canPush)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Fetch, pull, push")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var busy: Bool { repo.isFetching || repo.isPulling || repo.isPushing }

    private var fetchTitle: String { repo.isFetching ? "Fetching\u{2026}" : "Fetch" }

    /// With the count when the last fetch already found commits waiting.
    private var pullTitle: String {
        if repo.isPulling { return "Pulling\u{2026}" }
        let behind = repo.status.behind
        return behind > 0 ? "Pull \(behind) Commit\(behind == 1 ? "" : "s")" : "Pull"
    }

    /// Names what push will actually do: publish a fresh branch, or push a
    /// known number of commits.
    private var pushTitle: String {
        if repo.isPushing { return "Pushing\u{2026}" }
        if repo.status.upstream == nil { return "Publish Branch" }
        let ahead = repo.status.ahead
        return ahead > 0 ? "Push \(ahead) Commit\(ahead == 1 ? "" : "s")" : "Push"
    }
}

/// Borderless until hovered or pressed: a light fill, the way the rest of the
/// quiet chrome answers the pointer.
private struct HeaderButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }
}
