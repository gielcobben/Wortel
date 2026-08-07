import AppKit
import SwiftUI

/// The branch control inside the "New Session on Branch" dialog: a button that
/// shows the chosen branch and opens a popover to choose another — Xcode's
/// scheme picker, which is the same problem (one value, a filterable list of
/// candidates, and the option of a new one).
///
/// The dialog stays a dialog: it's a decision you came to make, so it belongs in
/// front of you rather than pinned to whichever button opened it — which is how
/// the picker ended up in the bottom-left corner over the terminal. What hangs
/// off a control is the *list*, because that part is browsing.
@MainActor
final class BranchChooser: NSView {
    private let button = NSPopUpButton(frame: .zero, pullsDown: true)
    private let popover = NSPopover()
    private let model: BranchPickerModel

    /// The branch to open: whatever was picked, or typed into the filter.
    var branch: String? { model.chosen }

    init(branches: [String], withWorktree: Set<String>) {
        model = BranchPickerModel(branches: branches, withWorktree: withWorktree)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 26))

        // A pull-down button, because this opens a chooser rather than cycling a
        // value: its title is the current answer, not a menu item.
        button.frame = bounds
        button.autoenablesItems = false
        button.addItem(withTitle: "Choose a branch\u{2026}")
        button.target = self
        button.action = #selector(choose)
        addSubview(button)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: BranchPicker(model: model) { [weak self] branch in
                self?.select(branch)
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Open on click, and keep the button looking like a menu rather than
    /// actually being one — an NSPopUpButton would otherwise show its own empty
    /// menu on top of the popover.
    @objc private func choose() {
        guard !popover.isShown else { return popover.performClose(nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func select(_ branch: String) {
        model.chosen = branch
        button.item(at: 0)?.title = branch
        button.synchronizeTitleAndSelectedItem()
        popover.performClose(nil)
    }
}

/// What the popover shows, and what the dialog reads back.
@Observable
@MainActor
final class BranchPickerModel {
    let branches: [String]
    /// Branches that already have a worktree. Choosing one *goes* to it rather
    /// than making a second, which is worth saying before the click.
    let withWorktree: Set<String>
    var query = ""
    var chosen: String?

    init(branches: [String], withWorktree: Set<String>) {
        self.branches = branches
        self.withWorktree = withWorktree
    }

    var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// What's been typed, when it isn't already a branch — the "or make a new
    /// one" half, which is why one field can serve both answers.
    var newBranch: String? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty,
              !branches.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame })
        else { return nil }
        return query
    }
}

/// The popover: a filter over the branches, and a "Create" row for a name that
/// isn't one yet. Deliberately the same shape and row metrics as `BranchList`,
/// the toolbar's branch switcher — they answer the same question, and a
/// difference here would read as a different feature.
struct BranchPicker: View {
    @Bindable var model: BranchPickerModel
    let choose: (String) -> Void
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter or new branch", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit {
                    if let new = model.newBranch { choose(new) }
                    else if model.matches.count == 1, let only = model.matches.first {
                        choose(only)
                    }
                }
                .padding(8)

            Divider()

            if let new = model.newBranch {
                BranchPickerRow(name: new, systemImage: "plus",
                                label: "Create branch", action: { choose(new) })
                if !model.matches.isEmpty { Divider().padding(.vertical, 2) }
            }

            if model.matches.isEmpty && model.newBranch == nil {
                Text(model.branches.isEmpty ? "No branches" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if !model.matches.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.matches, id: \.self) { branch in
                            BranchPickerRow(
                                name: branch, systemImage: "arrow.triangle.branch",
                                label: model.withWorktree.contains(branch)
                                    ? "Has a worktree" : nil,
                                action: { choose(branch) })
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 240)
            }
        }
        .frame(width: 260)
        .onAppear { filterFocused = true }
    }
}

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
