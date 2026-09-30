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
///
/// A session can show another checkout of the repo than its terminal's (an
/// agent working in a worktree): chosen in the branch menu, and undone by the
/// arrow that appears beside the branch while it's in effect.
struct RepoHeader: View {
    @Bindable var repo: GitRepoModel
    @Bindable var panel: GitPanelModel
    @State private var showsBranches = false
    @State private var moreOpen = false
    @State private var moreAnchor = MenuAnchor.Anchor()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task {
                    // Loaded before the popover opens so it sizes for the list
                    // it will show. A `for-each-ref`: the click still feels
                    // immediate.
                    await repo.loadBranches()
                    await panel.loadCheckouts()
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
            // Lit while its list is open, so it's clear what the list hangs from.
            .buttonStyle(HeaderButtonStyle(isActive: showsBranches))
            .help(panel.pinnedCheckout.map { "Showing \($0)" } ?? repo.status.branch ?? "Switch branch")
            .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
                BranchList(repo: repo, panel: panel, dismiss: { showsBranches = false })
            }

            if panel.pinnedCheckout != nil {
                Button {
                    panel.showCheckout(nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderButtonStyle())
                .help("Back to the terminal's checkout")
            }

            Spacer(minLength: 4)

            // A native menu rather than a SwiftUI one, for two things SwiftUI's
            // can't do: open with its right edge on the button's (into the
            // pane, as the titlebar's and the sidebar's "…" do), and say it's
            // open, so the button stays lit as the branch chip does.
            Button(action: showMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HeaderButtonStyle(isActive: moreOpen))
            .background(MenuAnchor(anchor: moreAnchor))
            .help("Fetch, pull, push")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var busy: Bool { repo.isFetching || repo.isPulling || repo.isPushing }

    private func showMore() {
        guard let view = moreAnchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, enabled: Bool, _ action: @escaping () async -> Void) {
            let item = ClosureMenuItem(title: title) { Task { await action() } }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        item(fetchTitle, enabled: !busy && repo.canFetch) { await repo.fetch() }
        item(pullTitle, enabled: !busy && repo.canPull) { await repo.pull() }
        item(pushTitle, enabled: !busy && repo.canPush) { await repo.push() }
        moreOpen = true
        // A turn later, so the button is drawn lit before the menu's tracking
        // takes the run loop.
        DispatchQueue.main.async {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: view.bounds.width - menu.size.width, y: view.bounds.maxY + 4),
                       in: view)
            moreOpen = false
        }
    }

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
    /// What it opens is open: filled as when pressed.
    var isActive = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed || isActive ? 0.10
                                                : hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }
}

/// The AppKit view under a SwiftUI button, for an NSMenu to open from.
private struct MenuAnchor: NSViewRepresentable {
    final class Anchor {
        weak var view: NSView?
    }

    let anchor: Anchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    /// Flipped, so "below it" is its bounds' maxY, as for the other menus.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
