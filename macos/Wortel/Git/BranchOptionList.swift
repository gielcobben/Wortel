import SwiftUI

/// **The** branch list: a filter field and the branches under it, in sections
/// the caller names (the "From" chooser's Local and Remote, the switcher's
/// This folder, In other folders, Switch to and Remote: see `BranchList`). Type to filter, point at
/// a row to highlight it, click to take it.
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
    struct Section {
        let title: String
        let branches: [GitBranch]
    }

    @Binding var query: String
    let sections: [Section]
    /// Index into the sections' branches, in order. -1 for nothing selected,
    /// which is what a mouse-only caller passes.
    @Binding var selection: Int
    let isLoadingRemote: Bool
    let hasAnyBranch: Bool
    let error: String?
    let isDisabled: Bool
    /// Whether the pointer moving over a row also moves the *selection* — that
    /// is, whether Return after a hover acts on the row under the pointer.
    ///
    /// True where there is a keyboard selection for it to keep in step with (the
    /// "From" chooser, which reads arrows and Return). False where the highlight
    /// is only ever a hover: the switcher has no keyboard navigation, so a
    /// selection left behind by the pointer is a row that stays lit after you
    /// have moved away from it, next to the checkmark on the branch that is
    /// actually current.
    let hoverSelects: Bool
    /// How a row looks beyond its name. The default says how old the branch
    /// is, and what it tracks in the tooltip.
    let style: (GitBranch) -> OptionRow.Style
    let activate: (GitBranch) -> Void

    init(query: Binding<String>, sections: [Section], selection: Binding<Int>,
         isLoadingRemote: Bool, hasAnyBranch: Bool, error: String? = nil,
         isDisabled: Bool = false, hoverSelects: Bool = true,
         style: @escaping (GitBranch) -> OptionRow.Style = { OptionRow.Style.standard(for: $0) },
         activate: @escaping (GitBranch) -> Void) {
        _query = query
        self.sections = sections
        _selection = selection
        self.isLoadingRemote = isLoadingRemote
        self.hasAnyBranch = hasAnyBranch
        self.error = error
        self.isDisabled = isDisabled
        self.hoverSelects = hoverSelects
        self.style = style
        self.activate = activate
    }

    /// Local and Remote, the "From" chooser's two sections.
    init(query: Binding<String>, local: [GitBranch], remote: [GitBranch], selection: Binding<Int>,
         isLoadingRemote: Bool, hasAnyBranch: Bool, activate: @escaping (GitBranch) -> Void) {
        self.init(query: query,
                  sections: [Section(title: "Local", branches: local),
                             Section(title: "Remote", branches: remote)],
                  selection: selection, isLoadingRemote: isLoadingRemote,
                  hasAnyBranch: hasAnyBranch, activate: activate)
    }

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

    private var rows: [GitBranch] { sections.flatMap(\.branches) }

    /// What the rows come to, capped. Definite, so the stack around it has an
    /// intrinsic height and the popover hosting it can be sized from it.
    private var listHeight: CGFloat {
        var height = Self.listPadding
        for section in sections where !section.branches.isEmpty {
            height += Self.headerHeight + CGFloat(section.branches.count) * Self.rowHeight
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
                        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                            self.section(section.title, section.branches,
                                         from: sections[..<index].reduce(0) { $0 + $1.branches.count })
                        }
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
                GitNotice(message: error)
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
                let style = style(branch)
                OptionRow(
                    glyph: style.glyph ?? (branch.isCurrent ? "checkmark" : "arrow.triangle.branch"),
                    title: branch.name, isCurrent: branch.isCurrent,
                    trailing: style.detail,
                    style: style,
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
    /// What a row carries beyond its name.
    struct Style {
        /// In place of the branch glyph (and the current branch's tick).
        var glyph: String? = nil
        /// The grey text on the right.
        var detail: String? = nil
        var help: String? = nil
        /// Buttons in place of `detail` while the pointer is on the row: what
        /// a click on the row does, said, and anything else it offers.
        var actions: [Action] = []
        /// Said beside the actions while the pointer is on the row: why one
        /// that's missing isn't offered.
        var hoverDetail: String? = nil

        struct Action {
            let title: String
            let run: () -> Void
        }

        /// How old the branch is on the right, and what it tracks in the
        /// tooltip. (The upstream used to be the right-hand text: truncated,
        /// `…ode-toolbar-clean` read as *where* the branch was.)
        static func standard(for branch: GitBranch) -> Style {
            Style(detail: branch.date.map(age),
                  help: branch.upstream.map { "Tracks \($0)" })
        }

        /// "now", "12m", "3h", "2d", "5w", "4mo", "2y": the age of the last
        /// commit, as compact as a list's right edge wants.
        static func age(_ date: Date) -> String {
            let seconds = max(0, Date().timeIntervalSince(date))
            let minute = 60.0, hour = 3600.0, day = 86400.0
            switch seconds {
            case ..<minute: return "now"
            case ..<hour: return "\(Int(seconds / minute))m"
            case ..<day: return "\(Int(seconds / hour))h"
            case ..<(14 * day): return "\(Int(seconds / day))d"
            case ..<(60 * day): return "\(Int(seconds / (7 * day)))w"
            case ..<(365 * day): return "\(Int(seconds / (30 * day)))mo"
            default: return "\(Int(seconds / (365 * day)))y"
            }
        }
    }

    let glyph: String
    let title: String
    let isCurrent: Bool
    let trailing: String?
    var style = Style()
    let isSelected: Bool
    let action: () -> Void
    let hover: (Bool) -> Void

    init(glyph: String, title: String, isCurrent: Bool, trailing: String?, style: Style = Style(),
         isSelected: Bool, action: @escaping () -> Void, hover: @escaping (Bool) -> Void) {
        self.glyph = glyph
        self.title = title
        self.isCurrent = isCurrent
        self.trailing = trailing
        self.style = style
        self.isSelected = isSelected
        self.action = action
        self.hover = hover
    }

    /// The pointer is on it and it has something to say for that.
    private var showsHoverContent: Bool {
        isSelected && (!style.actions.isEmpty || style.hoverDetail != nil)
    }

    private var showsActions: Bool { isSelected && !style.actions.isEmpty }

    var body: some View {
        // The actions sit beside the row's own button, not inside it: a button
        // inside a button gives the click to whichever SwiftUI picks.
        HStack(spacing: 6) {
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
                    if showsHoverContent {
                        if let hoverDetail = style.hoverDetail {
                            Text(hoverDetail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    } else if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                        : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                // The padding inside the button, so a click anywhere on the
                // row still takes it; on the right only while no action
                // buttons sit there.
                .padding(.leading, 10)
                .padding(.trailing, showsActions ? 0 : 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsActions {
                ForEach(Array(style.actions.enumerated()), id: \.offset) { _, action in
                    Button(action: action.run) {
                        Text(action.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.22)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }
        .padding(.trailing, showsActions ? 10 : 0)
        .font(.callout)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .help(style.help ?? "")
        .onHover { hover($0) }
    }
}
