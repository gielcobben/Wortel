import AppKit
import SwiftUI

/// Choosing a branch to open a session on: a filter field over the branches you
/// have, with a "Create" row the moment what you typed isn't one of them.
///
/// It lives **inside** the dialog rather than in a popover hanging off a button
/// in it. Three attempts went the other way and each failed on the same thing: a
/// popover belongs to a control, a dialog belongs to the screen, and putting one
/// inside the other means the list opens over the dialog's own buttons and lines
/// up with nothing. A dialog that *is* the picker has nothing to align to but
/// itself.
///
/// One field serves both answers, which is what the combo box and the
/// button-plus-menu were each reaching for: type to narrow what exists, or type
/// something that doesn't exist and take it.
struct BranchPicker: View {
    @Bindable var model: BranchPickerModel
    /// Called when a row is clicked — the dialog treats that as its "Create".
    let choose: (String) -> Void
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Branch name", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { if let branch = model.effective { choose(branch) } }
                .padding(.bottom, 8)

            list
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                            in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor)))
        }
        .frame(width: 260)
        .onAppear { filterFocused = true }
    }

    @ViewBuilder
    private var list: some View {
        if model.matches.isEmpty && model.newBranch == nil {
            Text(model.branches.isEmpty ? "No branches yet" : "No matches")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let new = model.newBranch {
                        BranchPickerRow(name: new, systemImage: "plus",
                                        label: "New branch", action: { choose(new) })
                        if !model.matches.isEmpty { Divider().padding(.vertical, 2) }
                    }
                    ForEach(model.matches, id: \.self) { branch in
                        BranchPickerRow(
                            name: branch, systemImage: "arrow.triangle.branch",
                            // Choosing one of these *goes* to its worktree rather
                            // than making a second, which is worth saying before
                            // the click.
                            label: model.withWorktree.contains(branch) ? "Has a worktree" : nil,
                            action: { choose(branch) })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// What the list shows, and what the dialog reads back.
@Observable
@MainActor
final class BranchPickerModel {
    let branches: [String]
    let withWorktree: Set<String>
    var query = ""

    init(branches: [String], withWorktree: Set<String>) {
        self.branches = branches
        self.withWorktree = withWorktree
    }

    var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// What's been typed, when it isn't already a branch.
    var newBranch: String? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty,
              !branches.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame })
        else { return nil }
        return query
    }

    /// What the dialog's Create button means: what you typed, or the one match
    /// left standing if you narrowed it to one and didn't click.
    var effective: String? {
        let query = query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return query }
        return matches.count == 1 ? matches.first : nil
    }
}

/// Deliberately the same row as `BranchList`'s, the toolbar's branch switcher:
/// they answer the same question, and a difference would read as a different
/// feature.
private struct BranchPickerRow: View {
    let name: String
    let systemImage: String
    let label: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let label {
                    Text(label)
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
                if hovering {
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
