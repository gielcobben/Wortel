import SwiftUI

/// The branch switcher's popover: `BranchOptionList` wired to the repository.
///
/// The chip that opens it is a real `NSButton` in the toolbar (see MainToolbar),
/// not a SwiftUI control — a hosted SwiftUI button only takes clicks on its
/// content, leaving the glass capsule's rim dead, whereas an NSButton *is* the
/// capsule and is clickable across its whole surface. So only the list lives
/// here in SwiftUI; the button and the popover presentation are AppKit's.
///
/// Everything below the filter field is shared with the new-session picker.
/// What's left here is what is genuinely this switcher's: where the branches
/// come from, that choosing one is a checkout, and that a refusal keeps the
/// popover open. It offers no "create" row, because switching to a branch that
/// doesn't exist is not a thing you can do.
struct BranchList: View {
    @Bindable var repo: GitRepoModel
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = -1

    var body: some View {
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
            .frame(width: 300)
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
