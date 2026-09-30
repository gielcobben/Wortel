import SwiftUI

/// The branch switcher's popover: `BranchOptionList` wired to the repository.
///
/// The chip that opens it is the branch in `RepoHeader`, at the top of the
/// Changes and History tabs; the repo's checkouts, when it has more than one,
/// are the list's first section, drawn as the branch sections are. (They were
/// a block of two-line rows above the filter, which read as a second design.)
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
        branches
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
            checkouts: checkouts,
            chooseCheckout: { checkout in
                panel.showCheckout(checkout.id)
                dismiss()
            },
            activate: activate)
            .overlay {
                if repo.isLoadingBranches && repo.branches.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
    }

    /// Which checkout the panes show, which is the terminal's, and what's in
    /// each. Choosing one shows it here without touching the terminal or
    /// anyone's branch. Filtered with the branches.
    private var checkouts: [BranchOptionList.CheckoutOption] {
        guard panel.checkouts.count > 1 else { return [] }
        let query = query.trimmingCharacters(in: .whitespaces)
        return panel.checkouts
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { checkout in
                let summary = GitPanelModel.summary(of: checkout)
                return .init(id: checkout.path, name: checkout.name,
                             detail: checkout.path == panel.terminalCheckout ? "terminal \u{00B7} \(summary)" : summary,
                             isShown: checkout.path == repo.root)
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
