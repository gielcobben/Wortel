import SwiftUI

/// The branch switcher's popover: `BranchOptionList` wired to the repository.
///
/// The chip that opens it is the branch in `RepoHeader`, at the top of the
/// Changes and History tabs. Which folder the panes show is the chip beside
/// it; this list says which folder each *branch* is in (see `branches`).
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
    @State private var isBringing = false
    @State private var bringError: String?

    var body: some View {
        branches
            .frame(width: 320)
            // Who has what changes, for the Other Folders rows. Not awaited
            // before opening: on a big repo it's a `git status` per worktree,
            // read now because someone is looking, and stopped if they stop.
            .task { await panel.readCheckoutCounts() }
    }

    /// Git lets a branch be checked out in one folder at a time, so a list that
    /// draws every branch alike offers clicks that can only fail (it did, with
    /// git's `fatal: … already used by worktree`). So the list says which kind
    /// each branch is before you click, in the order you'd look:
    ///
    /// - **This folder**: the branch you're on;
    /// - **In other folders**: checked out in another worktree, most likely an
    ///   agent's. A click shows that folder here (looking only, as the folder
    ///   chip does, and what Tower, GitKraken, lazygit and VS Code all do), and
    ///   "Bring Here" switches this folder to it when that's safe (`bringHere`);
    /// - **Switch to**: free, and the only rows a click checks out;
    /// - **Remote**.
    private var branches: some View {
        let local = matching(repo.branches.filter { !$0.isRemote })
        return BranchOptionList(
            query: $query,
            sections: [
                .init(title: "This folder", branches: local.filter(\.isCurrent)),
                .init(title: "In other folders", branches: local.filter(isElsewhere)),
                .init(title: "Switch to", branches: local.filter { !$0.isCurrent && !isElsewhere($0) }),
                .init(title: "Remote", branches: matching(repo.branches.filter(\.isRemote))),
            ],
            selection: $selection,
            // The switcher loads both halves in one call before it opens, so
            // there is never a half-loaded list to caption.
            isLoadingRemote: false,
            hasAnyBranch: !repo.branches.isEmpty,
            error: bringError ?? repo.checkoutError,
            isDisabled: repo.isCheckingOut || isBringing,
            // Nothing here reads arrows or Return, so the highlight is only ever
            // "the pointer is on this" and must go when the pointer does.
            hoverSelects: false,
            style: style,
            // Branches only: which worktree the panes show has its own chip
            // in the header (RepoHeader.worktreeChip). The two in one list
            // looked alike and did very different things: one only changes
            // what you look at, the other changes the files on disk.
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

    /// Checked out in a folder other than the one shown.
    private func isElsewhere(_ branch: GitBranch) -> Bool {
        guard let path = branch.worktreePath else { return false }
        return !WorktreeCleanup.samePath(path, repo.root)
    }

    /// The local branch a row stands for in another folder: itself, or for a
    /// remote one, the local branch a checkout of it would land on (clicking
    /// `origin/x` checks out `x`, and fails the same way if `x` is elsewhere).
    private func elsewhere(_ branch: GitBranch) -> GitBranch? {
        if !branch.isRemote { return isElsewhere(branch) ? branch : nil }
        let local = GitService.localName(forRemote: branch.name)
        return repo.branches.first { !$0.isRemote && $0.name == local && isElsewhere($0) }
    }

    private func style(_ branch: GitBranch) -> OptionRow.Style {
        if branch.isCurrent {
            var style = OptionRow.Style.standard(for: branch)
            let ahead = repo.status.ahead, behind = repo.status.behind
            if ahead > 0 || behind > 0 {
                style.detail = [ahead > 0 ? "\u{2191}\(ahead)" : nil,
                                behind > 0 ? "\u{2193}\(behind)" : nil]
                    .compactMap { $0 }.joined(separator: " ")
            }
            return style
        }
        guard !branch.isRemote, let path = branch.worktreePath, isElsewhere(branch) else {
            return .standard(for: branch)
        }
        let checkout = panel.checkouts.first { WorktreeCleanup.samePath($0.path, path) }
        // Where it is, by the session working there (the row already says
        // the branch), else the folder.
        let place = panel.placeTitle(of: path, branch: nil, isPrimary: checkout?.isPrimary ?? false)
        var style = OptionRow.Style(
            glyph: "rectangle.stack",
            detail: place,
            help: "Checked out in \(path). Click to show that folder here: nothing is switched.")
        style.actions = [.init(title: "Show") { show(path) }]
        // Offered only when it can work; the full check runs on the click
        // (what's running there isn't known until then).
        if checkout?.isPrimary == true {
            style.hoverDetail = "main folder"
        } else if let changes = checkout?.changes, changes > 0 {
            style.hoverDetail = "\(changes) change\(changes == 1 ? "" : "s") there"
        } else {
            style.actions.append(.init(title: "Bring Here") { bringHere(branch) })
        }
        return style
    }

    private func activate(_ branch: GitBranch) {
        if let other = elsewhere(branch), let path = other.worktreePath {
            show(path)
            return
        }
        bringError = nil
        Task {
            await repo.checkout(branch)
            // Only close when it took. On a refusal the popover stays so the
            // message underneath is readable.
            if repo.checkoutError == nil { dismiss() }
        }
    }

    private func show(_ path: String) {
        panel.showCheckout(path)
        dismiss()
    }

    private func bringHere(_ branch: GitBranch) {
        bringError = nil
        isBringing = true
        Task {
            let error = await panel.bringHere(branch)
            isBringing = false
            if let error { bringError = error } else { dismiss() }
        }
    }
}
