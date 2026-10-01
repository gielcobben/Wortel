import SwiftUI

/// **The** branch list: a filter field and the branches under it, in Local and
/// Remote sections. Type to filter, point at a row to highlight it, click to
/// take it.
///
/// Arrows and Return are the *caller's* to provide, and only the "From" chooser
/// does (see `BranchChooser.watchKeys`, which has to intercept them before the
/// focused filter field swallows them). That is what `hoverSelects` is about:
/// a list with keyboard navigation wants the pointer to move the same selection
/// the keyboard moves, and a list without one wants the highlight gone the
/// moment the pointer leaves.
///
/// Used by the repo header's branch switcher and by the "From" control in the
/// new-session sheet. They answer the same question and used to answer it with
/// two copies of the same code that had drifted apart in the one way that
/// mattered: only one of them listed remote branches.
struct BranchOptionList: View {
    @Binding var query: String
    let local: [GitBranch]
    let remote: [GitBranch]
    /// Index into `local + remote`. -1 for nothing selected, which is what a
    /// mouse-only caller passes.
    @Binding var selection: Int
    let isLoadingRemote: Bool
    let hasAnyBranch: Bool
    var note: (GitBranch) -> String? = { _ in nil }
    var error: String? = nil
    var isDisabled: Bool = false
    /// Whether the pointer moving over a row also moves the *selection* — that
    /// is, whether Return after a hover acts on the row under the pointer.
    ///
    /// True where there is a keyboard selection for it to keep in step with (the
    /// "From" chooser, which reads arrows and Return). False where the highlight
    /// is only ever a hover: the switcher has no keyboard navigation, so a
    /// selection left behind by the pointer is a row that stays lit after you
    /// have moved away from it, next to the checkmark on the branch that is
    /// actually current.
    var hoverSelects: Bool = true
    let activate: (GitBranch) -> Void

    @FocusState private var filterFocused: Bool
    /// The row under the pointer, which is a *different* thing from the
    /// selection and outlives it by nothing: it clears on exit. Drawn in
    /// preference to the selection while it lasts, so the pointer wins over the
    /// keyboard for as long as it is actually over a row.
    @State private var hovered: Int?

    /// Roughly eight rows. Tall enough to browse, short enough not to become
    /// the tallest thing on screen.
    static let maxListHeight: CGFloat = 260

    /// **Measured, not guessed**, and the list has to state them because a
    /// SwiftUI `ScrollView` reports no height of its own: whatever hosts this
    /// then has nothing to size to, and the list collapses to the filter field
    /// with one clipped row under it, which is exactly what it did.
    ///
    /// `scratchpad/rowprobe.swift` prints these from real hosting views; its
    /// check that the parts add up (a header plus six rows plus padding)
    /// predicted 167.00 against a measured 167.00. If a row's font or padding
    /// changes, that probe is how to get these right again.
    private static let rowHeight: CGFloat = 23
    private static let headerHeight: CGFloat = 21
    private static let listPadding: CGFloat = 8

    private var rows: [GitBranch] { local + remote }

    /// What the rows come to, capped. Definite, so the stack around it has an
    /// intrinsic height and the popover hosting it can be sized from it.
    private var listHeight: CGFloat {
        var height = Self.listPadding
        if !local.isEmpty {
            height += Self.headerHeight + CGFloat(local.count) * Self.rowHeight
        }
        if !remote.isEmpty {
            height += Self.headerHeight + CGFloat(remote.count) * Self.rowHeight
        }
        return min(height, Self.maxListHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .padding(8)

            Divider()

            if rows.isEmpty {
                Text(hasAnyBranch ? "No matches" : "No branches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Local", local, from: 0)
                        section("Remote", remote, from: local.count)
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: listHeight)
            }

            // Said rather than spun, and said at the bottom: the local branches
            // above are already usable, and a spinner over the whole list would
            // hide the answer while claiming to look for it.
            if isLoadingRemote {
                Divider()
                Text("Loading remote branches\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }

            // A refused checkout keeps the list up rather than closing over the
            // reason: git refuses precisely when it would have to throw away
            // local changes, and naming the files is the whole value of it.
            if let error {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
        .onAppear { filterFocused = true }
        // Arrowing with the pointer parked over a row would otherwise move a
        // selection nobody can see, because the stale hover keeps drawing the
        // highlight where the pointer is. The keyboard moving the selection
        // means the keyboard has it.
        .onChange(of: selection) { hovered = nil }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func section(_ title: String, _ branches: [GitBranch], from start: Int) -> some View {
        if !branches.isEmpty {
            heading(title)
            ForEach(Array(branches.enumerated()), id: \.element.id) { offset, branch in
                let row = start + offset
                OptionRow(
                    glyph: branch.isCurrent ? "checkmark" : "arrow.triangle.branch",
                    title: branch.name, isCurrent: branch.isCurrent,
                    trailing: note(branch) ?? branch.upstream,
                    isSelected: row == (hovered ?? selection),
                    action: { activate(branch) },
                    hover: { inside in
                        if inside {
                            hovered = row
                            // The pointer moving is a selection too where there
                            // is one, so Return after a hover does what the
                            // highlight says it will.
                            if hoverSelects { selection = row }
                        } else if hovered == row {
                            // Only if it is still ours: the enter for the next
                            // row arrives before this row's exit, and clearing
                            // unconditionally would blank the highlight as the
                            // pointer slides down the list.
                            hovered = nil
                        }
                    })
                    .disabled(isDisabled)
            }
        }
    }
}

/// One row of the switcher lists. The metrics here are what the two branch
/// lists used to keep in step by hand, and what the repo header's worktree
/// list shares, so the two chips beside each other open lists that match.
struct OptionRow: View {
    let glyph: String
    let title: String
    let isCurrent: Bool
    let trailing: String?
    let isSelected: Bool
    let action: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(isCurrent ? .medium : .regular)
                    // The name is the row. Without this SwiftUI splits the
                    // width between the two labels and shortens both, so
                    // `copy-and-docs` came out `c…cs` next to an `origi…` that
                    // told you nothing either. The note gives way first.
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                    : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .font(.callout)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor)
                        .padding(.horizontal, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover($0) }
    }
}
