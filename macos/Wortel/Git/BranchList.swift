import SwiftUI

/// The branch switcher's popover: a filter over the local and remote branches,
/// with a refused checkout's reason surfaced beneath.
///
/// The chip that opens it is a real `NSButton` in the toolbar (see MainToolbar),
/// not a SwiftUI control — a hosted SwiftUI button only takes clicks on its
/// content, leaving the glass capsule's rim dead, whereas an NSButton *is* the
/// capsule and is clickable across its whole surface. So only the list lives
/// here in SwiftUI; the button and the popover presentation are AppKit's.
struct BranchList: View {
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
