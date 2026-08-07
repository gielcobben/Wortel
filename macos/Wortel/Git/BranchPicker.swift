import SwiftUI

extension Notification.Name {
    /// Posted by a folder's context menu, which has no anchor of its own to hang
    /// a popover from — the sidebar catches it and opens the picker on the +
    /// button, remembering which folder asked.
    static let wortelOpenBranchPicker = Notification.Name("wortel.openBranchPicker")
}

/// What the picker needs, loaded before it appears.
///
/// Presented only once the branches are in: a popover that opens empty and fills
/// in a moment later reads as a glitch, and the load is two fast git calls.
@Observable
@MainActor
final class BranchPickerState {
    var isPresented = false
    private(set) var branches: [String] = []
    private(set) var withWorktree: Set<String> = []
    /// The folder the new session should land in, when a folder's menu asked.
    private(set) var folder: String?

    func open(_ manager: SessionManager, folder: String? = nil) {
        self.folder = folder
        Task {
            branches = await manager.localBranches()
            withWorktree = await manager.branchesWithWorktrees()
            isPresented = true
        }
    }
}

/// Pick a branch to open a session on, or type a new one.
///
/// The same shape as `BranchList` — a filter over a list — because it answers
/// the same question and should read as the same thing. What it adds is the
/// second half: one field both filters what exists *and* names what doesn't, and
/// a "Create" row appears the moment what you typed isn't already a branch.
///
/// That combination is why this replaced a dialog. Both answers are legitimate
/// here, and every control that tries to serve them at once in an alert is
/// worse: an `NSComboBox`'s dropdown is unstyled legacy AppKit, and a field with
/// a menu button beside it pops a menu outside the alert's own frame. A popover
/// is what the app already uses for exactly this question, one screenshot away
/// in the toolbar.
struct BranchPicker: View {
    let branches: [String]
    /// Branches that already have a worktree — opening one of those *goes* to it
    /// rather than making a second, and saying so before the click is cheaper
    /// than explaining it afterwards.
    let withWorktree: Set<String>
    let choose: (String) -> Void

    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var matches: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// What you typed, when it isn't already a branch. Trimmed, because a
    /// trailing space is never part of a branch name you meant.
    private var newBranch: String? {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty,
              !branches.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame })
        else { return nil }
        return query
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Branch name", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                // Return takes the obvious answer: the branch you're typing if
                // it's new, otherwise the one match left standing.
                .onSubmit {
                    if let newBranch { choose(newBranch) }
                    else if let only = matches.first, matches.count == 1 { choose(only) }
                }
                .padding(8)

            Divider()

            if let newBranch {
                row(newBranch, systemImage: "plus", label: "Create branch",
                    action: { choose(newBranch) })
                if !matches.isEmpty { Divider().padding(.vertical, 2) }
            }

            if matches.isEmpty && newBranch == nil {
                Text(branches.isEmpty ? "No branches" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if !matches.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { branch in
                            row(branch,
                                systemImage: "arrow.triangle.branch",
                                label: withWorktree.contains(branch) ? "Has a worktree" : nil,
                                action: { choose(branch) })
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 240)
            }
        }
        .frame(width: 280)
        .onAppear { filterFocused = true }
    }

    private func row(
        _ name: String, systemImage: String, label: String?, action: @escaping () -> Void
    ) -> some View {
        BranchPickerRow(name: name, systemImage: systemImage, label: label, action: action)
    }
}

/// Deliberately the same metrics as `BranchList`'s row — the two popovers answer
/// the same question and a difference here would read as a different feature.
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
