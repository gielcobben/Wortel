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
/// A session can show another worktree of the repo than its terminal's (an
/// agent working in one): chosen from the worktree chip, from a branch in
/// another folder in the branch list, or from a clean Changes pane that points
/// at work elsewhere, and undone from the same chip or the "Back" that appears while it's in effect. Looking at one
/// runs no git command; switching a branch is the branch chip's alone, and
/// only in your own folder.
struct RepoHeader: View {
    @Bindable var repo: GitRepoModel
    @Bindable var panel: GitPanelModel
    @State private var showsBranches = false
    @State private var moreOpen = false
    @State private var moreAnchor = MenuAnchor.Anchor()
    @State private var showsWorktrees = false
    /// Says the list under the header is being re-read: the repo changed while
    /// it wasn't the one shown, so a switch put its old list up at once rather
    /// than a blank pane for as long as a big repo's `git status` takes. Only
    /// for that catch-up, never for the scans a build triggers while you watch
    /// (the list is current then, just about to change), and only after a
    /// beat, so a repo that answers quickly never flashes it. Not mounted when
    /// idle: a hidden `ProgressView` still animates.
    @State private var showsCatchUp = false

    /// Looking at another worktree than the terminal's: the header gets a faint
    /// fill and a "Back", and the branch can't be switched from here.
    private var isAway: Bool { panel.pinnedCheckout != nil }

    /// A worktree is named for its folder: that's the "desk", and the branch
    /// chip beside it already says which branch is on it.
    private static func folderName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            // The same two chips whether you're in your own folder or looking
            // at another worktree: what changes is the name in the first, the
            // second going quiet, and a faint fill.
            if panel.checkouts.count > 1 || isAway {
                worktreeChip
            }
            branchChip
            if let state = shownPullRequest {
                pullRequestButton(state)
            }

            // Work in another folder isn't said here: beside the branch chip,
            // "web-next: 16 changes" read as being about this branch. It's in
            // the two lists, on the folder it belongs to, and in a clean
            // Changes pane (SourceControlPanel), where it's the news.
            Spacer(minLength: 4)

            if isAway {
                // Said in words as well as by the dropdown: the clearest way
                // out of "I'm looking at someone else's folder".
                Button {
                    panel.showCheckout(nil)
                } label: {
                    Text("Back")
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderButtonStyle())
                .fixedSize()
                .help("Show your own folder again")
            }

            if showsCatchUp {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                    .help("Updating the changes")
            }

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
        // Away from your own folder: a faint fill, enough to tell it from
        // your own changes without shouting.
        .background(isAway ? Color.primary.opacity(0.05) : Color.clear)
        // Kept fresh while it's on screen, so what the lists and a clean pane
        // say about other folders follows the work (a read is a `git status`
        // per checkout, and only when stale).
        .task(id: CatchUpKey(root: repo.root, stale: repo.isStale)) {
            guard repo.isStale else {
                showsCatchUp = false
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { showsCatchUp = true }
        }
        .task(id: repo.root) {
            while !Task.isCancelled {
                // Runs git only for a worktree whose watch fired (or a list a
                // minute old), and nothing while Wortel isn't in front.
                if NSApp.isActive { await panel.refreshCheckoutsIfStale() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // The branch's pull request: looked up when the branch or its upstream
        // changes (a push publishes it), and again while this is on screen and
        // Wortel in front, at most every five minutes (`refreshPullRequest`),
        // so one an agent opens shows up without a click.
        .task(id: PullRequestKey(root: repo.root, branch: repo.status.branch,
                                 upstream: repo.status.upstream)) {
            while !Task.isCancelled {
                if NSApp.isActive { await repo.refreshPullRequest() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// The branch, and the switcher behind it: branches only. Locked while
    /// you look at another worktree: switching the branch of a folder you're
    /// only looking at changes the files under whoever works there, most
    /// likely an agent.
    @ViewBuilder
    private var branchChip: some View {
        if isAway {
            // A label, not a disabled button: macOS shows no tooltip on a
            // disabled control, and the tooltip is the explanation.
            branchLabel
                .padding(.horizontal, 6)
                .frame(height: 24)
                .help("Branches can't be switched in a worktree you're only looking at: an agent may be working there")
        } else {
            branchButton
        }
    }

    private var branchLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(repo.status.branch ?? "detached")
                .font(.system(size: 13))
                .foregroundStyle(isAway ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            if !isAway {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var branchButton: some View {
        Button {
            Task {
                // Loaded before the popover opens so it sizes for the list
                // it will show. A `for-each-ref`: the click still feels
                // immediate.
                await repo.loadBranches()
                showsBranches = true
            }
        } label: {
            branchLabel
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        // Lit while its list is open, so it's clear what the list hangs from.
        .buttonStyle(HeaderButtonStyle(isActive: showsBranches))
        .help("Switch this folder to another branch")
        .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
            BranchList(repo: repo, panel: panel, dismiss: { showsBranches = false })
        }
    }

    /// The branch's pull request as the header offers it: only for the branch
    /// on screen, never one looked up for the branch before.
    private var shownPullRequest: PullRequestState? {
        guard let state = repo.pullRequest, state.branch == repo.status.branch else { return nil }
        return state
    }

    /// One label for the button and the "…" item, so the two never say
    /// different things: "PR #1234", or "Create PR" when `gh` found none.
    private static func title(_ state: PullRequestState) -> String {
        switch state {
        case .open(let pr): return "PR #\(pr.number)"
        case .none: return "Create PR"
        }
    }

    private func perform(_ state: PullRequestState) {
        switch state {
        case .open(let pr): NSWorkspace.shared.open(pr.url)
        case .none: Task { await repo.createPullRequest() }
        }
    }

    /// The pull request, in words. (An icon alone was the pull-request glyph,
    /// which reads as a merge to anyone who doesn't already know it.) Never
    /// shortened: the branch beside it gives way first.
    private func pullRequestButton(_ state: PullRequestState) -> some View {
        Button {
            perform(state)
        } label: {
            Text(verbatim: Self.title(state))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderButtonStyle())
        .fixedSize()
        .help(Self.help(state))
    }

    private static func help(_ state: PullRequestState) -> String {
        switch state {
        case .open(let pr):
            return pr.isDraft ? "Open draft pull request #\(pr.number) in your browser"
                              : "Open pull request #\(pr.number) in your browser"
        case .none:
            return "Start a pull request for this branch in your browser"
        }
    }

    /// Which worktree the panes show, and the menu to show another or go back
    /// to yours. Looking only: picking one runs no git command and changes no
    /// files.
    private var worktreeChip: some View {
        Button {
            Task {
                // Read before it opens, so the list sizes for what it shows.
                await panel.loadCheckouts()
                showsWorktrees = true
            }
        } label: {
            HStack(spacing: 5) {
                // A stack: one of several copies of the repo, which is what a
                // worktree is.
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: Self.folderName(repo.root))
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
        .buttonStyle(HeaderButtonStyle(isActive: showsWorktrees))
        .help(isAway ? "Looking at another worktree: \(repo.root)" : "Your folder: \(repo.root)")
        .popover(isPresented: $showsWorktrees, arrowEdge: .bottom) {
            WorktreeList(panel: panel, shown: repo.root,
                         dismiss: { showsWorktrees = false })
        }
    }

    private var busy: Bool { repo.isFetching || repo.isPulling || repo.isPushing }

    private func showMore() {
        guard let view = moreAnchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, glyph: String, enabled: Bool, _ action: @escaping () async -> Void) {
            let item = ClosureMenuItem(title: title) { Task { await action() } }
            item.isEnabled = enabled
            // Glyphs as every other menu here has them.
            item.setGlyph(glyph)
            menu.addItem(item)
        }
        // The header's PR button, said the same way, and only when it's shown.
        if let state = shownPullRequest {
            item(Self.title(state), glyph: "arrow.triangle.pull", enabled: true) { perform(state) }
            menu.addItem(.separator())
        }
        item(fetchTitle, glyph: "arrow.triangle.2.circlepath", enabled: !busy && repo.canFetch) {
            await repo.fetch()
        }
        item(pullTitle, glyph: "arrow.down", enabled: !busy && repo.canPull) { await repo.pull() }
        item(pushTitle, glyph: "arrow.up", enabled: !busy && repo.canPush) { await repo.push() }
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

/// The worktree chip's list: yours first, then the others, each with what's in
/// it, and a tick on the one shown. The same rows as the branch list beside it.
/// Looking only: picking one runs no git command and changes no files.
private struct WorktreeList: View {
    let panel: GitPanelModel
    /// The worktree the panes show now.
    let shown: String
    let dismiss: () -> Void

    @State private var hovered: String?

    private static let width: CGFloat = 300
    // The branch list's measured metrics (BranchOptionList).
    private static let rowHeight: CGFloat = 23
    private static let headerHeight: CGFloat = 21
    private static let listPadding: CGFloat = 8
    private static let maxListHeight: CGFloat = 260

    private var yours: GitPanelModel.Checkout? {
        panel.checkouts.first { $0.path == panel.terminalCheckout }
    }

    private var others: [GitPanelModel.Checkout] {
        panel.checkouts.filter { $0.path != panel.terminalCheckout }
    }

    private var listHeight: CGFloat {
        var height = Self.listPadding + CGFloat(panel.checkouts.count) * Self.rowHeight
        if !others.isEmpty { height += Self.headerHeight }
        return min(height, Self.maxListHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let yours {
                        row(yours, detail: "yours \u{00B7} " + GitPanelModel.summary(of: yours))
                    }
                    if !others.isEmpty {
                        Text("Other worktrees")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        ForEach(others) { checkout in
                            row(checkout, detail: GitPanelModel.summary(of: checkout))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: listHeight)

            Divider()
            Text("Looking only. Nothing is switched.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: Self.width)
    }

    private func row(_ checkout: GitPanelModel.Checkout, detail: String) -> some View {
        OptionRow(glyph: checkout.path == shown ? "checkmark" : "rectangle.stack",
                  title: (checkout.path as NSString).lastPathComponent,
                  isCurrent: checkout.path == shown,
                  trailing: detail,
                  style: OptionRow.Style(help: checkout.path),
                  isSelected: hovered == checkout.path,
                  action: {
                      panel.showCheckout(checkout.path)
                      dismiss()
                  },
                  hover: { inside in
                      if inside { hovered = checkout.path } else if hovered == checkout.path { hovered = nil }
                  })
    }
}

private struct PullRequestKey: Equatable {
    let root: String
    let branch: String?
    let upstream: String?
}

private struct CatchUpKey: Equatable {
    let root: String
    let stale: Bool
}
