import SwiftUI

/// The branch chip both panes wear in their header: which branch you're on, how
/// far it's drifted from its upstream, and — on click — the switcher.
///
/// A popover rather than a `Menu`, for one reason: `Menu` gives no hook for
/// "the user opened it", and the branch list is deliberately lazy (a monorepo
/// carries thousands of remote refs that nothing on screen needs until asked).
/// A popover's content has a real lifecycle, so `.task` is exactly "on open".
/// It also leaves somewhere to put a refused checkout's reason, which a menu
/// has no room for.
struct BranchSwitcher: View {
    @Bindable var repo: GitRepoModel
    @State private var showing = false

    var body: some View {
        Button {
            // Load *before* presenting, not from the popover's own `.task`. An
            // NSPopover takes its size from the content it's given at
            // presentation: opened while the list is still empty, it sizes itself
            // to the spinner and keeps that height when the branches land. The
            // read is a `for-each-ref` — fast enough that the click still feels
            // immediate, and the popover arrives at its real height first time.
            Task {
                await repo.loadBranches()
                showing = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(repo.status.branch ?? "detached")
                    .fontWeight(.medium)
                    .lineLimit(1)
                if repo.status.ahead > 0 {
                    Label("\(repo.status.ahead)", systemImage: "arrow.up")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if repo.status.behind > 0 {
                    Label("\(repo.status.behind)", systemImage: "arrow.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch branch")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BranchList(repo: repo, dismiss: { showing = false })
        }
    }
}

/// The switcher's contents: local branches, then remote ones.
private struct BranchList: View {
    @Bindable var repo: GitRepoModel
    let dismiss: () -> Void
    @State private var filter = ""

    private var local: [GitBranch] { matching(repo.branches.filter { !$0.isRemote }) }
    private var remote: [GitBranch] { matching(repo.branches.filter(\.isRemote)) }

    private func matching(_ branches: [GitBranch]) -> [GitBranch] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            Divider()

            if repo.isLoadingBranches && repo.branches.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if local.isEmpty && remote.isEmpty {
                Text(repo.branches.isEmpty ? "No branches" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Local", local)
                        section("Remote", remote)
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
            }

            // A refused checkout keeps the popover up rather than closing over the
            // reason: git refuses precisely when it would have to throw away local
            // changes, and naming the files is the whole value of the message.
            if let error = repo.checkoutError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func section(_ title: String, _ branches: [GitBranch]) -> some View {
        if !branches.isEmpty {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(branches) { branch in
                BranchRow(branch: branch) {
                    Task {
                        await repo.checkout(branch)
                        // Only close when it took. On a refusal the popover stays
                        // so the message above is readable.
                        if repo.checkoutError == nil { dismiss() }
                    }
                }
                .disabled(repo.isCheckingOut)
            }
        }
    }
}

private struct BranchRow: View {
    let branch: GitBranch
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(branch.isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 12)
                Text(branch.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(branch.isCurrent ? .medium : .regular)
                Spacer(minLength: 4)
                if let upstream = branch.upstream {
                    Text(upstream)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if hovering && !branch.isCurrent {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
