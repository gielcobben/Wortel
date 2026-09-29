import SwiftUI

/// The branch switcher's popover: `BranchOptionList` wired to the repository.
///
/// The chip that opens it is the branch in `RepoHeader`, at the top of the
/// Changes and History tabs; above the branches, the repo's other checkouts
/// (`CheckoutList`) when it has any.
///
/// Everything below the filter field is shared with the new-session picker.
/// What's left here is what is genuinely this switcher's: where the branches
/// come from, that choosing one is a checkout, and that a refusal keeps the
/// popover open. It offers no "create" row, because switching to a branch that
/// doesn't exist is not a thing you can do.
struct BranchList: View {
    @Bindable var repo: GitRepoModel
    @Bindable var panel: GitPanelModel
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = -1

    var body: some View {
        VStack(spacing: 0) {
            if panel.checkouts.count > 1 {
                CheckoutList(panel: panel, shown: repo.root) { path in
                    panel.showCheckout(path)
                    dismiss()
                }
                Divider()
            }
            branches
        }
        .frame(width: 300)
    }

    private var branches: some View {
        BranchOptionList(
            query: $query,
            local: matching(repo.branches.filter { !$0.isRemote }),
            remote: matching(repo.branches.filter(\.isRemote)),
            selection: $selection,
            // The switcher loads both halves in one call before it opens, so
            // there is never a half-loaded list to caption.
            isLoadingRemote: false,
            hasAnyBranch: !repo.branches.isEmpty,
            error: repo.checkoutError,
            isDisabled: repo.isCheckingOut,
            // Nothing here reads arrows or Return, so the highlight is only ever
            // "the pointer is on this" and must go when the pointer does.
            hoverSelects: false,
            activate: activate)
            .overlay {
                if repo.isLoadingBranches && repo.branches.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
    }

    private func matching(_ branches: [GitBranch]) -> [GitBranch] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func activate(_ branch: GitBranch) {
        Task {
            await repo.checkout(branch)
            // Only close when it took. On a refusal the popover stays so the
            // message underneath is readable.
            if repo.checkoutError == nil { dismiss() }
        }
    }
}

/// Every checkout of the repo, above the branches: which one the panes show,
/// which is the terminal's, and what's in each. Choosing one shows it here
/// without touching the terminal or anyone's branch.
private struct CheckoutList: View {
    @Bindable var panel: GitPanelModel
    /// The root the panes are showing.
    let shown: String
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checkouts")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(panel.checkouts) { checkout in
                CheckoutRow(checkout: checkout, isShown: checkout.path == shown,
                            isTerminals: checkout.path == panel.terminalCheckout) {
                    choose(checkout.path)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }
}

private struct CheckoutRow: View {
    let checkout: GitPanelModel.Checkout
    let isShown: Bool
    let isTerminals: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isShown ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(checkout.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(isTerminals ? "Terminal · \(GitPanelModel.summary(of: checkout))"
                                     : GitPanelModel.summary(of: checkout))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(checkout.path)
    }
}
