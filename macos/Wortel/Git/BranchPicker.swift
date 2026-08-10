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
    private let button = ChooserButton(frame: .zero, pullsDown: true)
    private let popover = NSPopover()
    private let model: BranchPickerModel
    /// Kept in front of the value in the button's title ("From: main"), so the
    /// row says what it is without a label beside it — which the compact centred
    /// alert has nowhere to put.
    private let prefix: String
    /// What the button reads before anything is chosen.
    private let placeholder: String

    /// The branch to open: whatever was picked, or typed into the filter.
    var branch: String? { model.chosen ?? model.newBranch }

    /// Field, divider, and eight rows: enough to browse without the popover
    /// becoming the tallest thing on screen.
    static let popoverHeight: CGFloat = 248
    /// What a dialog falls back to if it has no buttons to measure against.
    /// Nothing reaches it — an NSAlert always has at least one.
    private static let defaultWidth: CGFloat = 240

    /// The width an accessory has to be to line up with the dialog's buttons.
    ///
    /// The button row is the one part of an NSAlert that sizes *itself* — from
    /// its titles, not from the alert — so it's the thing everything else has to
    /// match rather than the other way round. A fixed 240 was 12pt wider than
    /// `Cancel` + `Create` come to, which is why the chooser overhung them and
    /// sat 6pt to their left.
    ///
    /// Call it once the buttons are added and before the accessory is set: the
    /// row's width doesn't depend on the accessory, so measuring first and
    /// building the chooser to fit converges immediately, where resizing
    /// afterwards means laying the alert out twice.
    static func alignedWidth(for alert: NSAlert) -> CGFloat {
        alert.layout()
        let frames = alert.buttons.map(\.frame)
        guard let minX = frames.map(\.minX).min(),
              let maxX = frames.map(\.maxX).max(), maxX > minX
        else { return defaultWidth }
        return maxX - minX
    }

    /// Whether what's chosen is a branch that already exists, which is the one
    /// thing the dialog needs to know beyond the name: an existing branch is
    /// checked out as it is, so it has no base to fork from.
    var isExistingBranch: Bool {
        guard let branch else { return false }
        return model.branches.contains { $0.caseInsensitiveCompare(branch) == .orderedSame }
    }

    /// Called when the selection changes, so a dialog holding more than one of
    /// these can react — the base row greys out once the branch is a real one.
    var onChange: (() -> Void)?

    init(
        branches: [String], withWorktree: Set<String>, width: CGFloat,
        placeholder: String = "Choose a branch\u{2026}", prefix: String = "",
        initial: String? = nil
    ) {
        model = BranchPickerModel(branches: branches, withWorktree: withWorktree)
        self.prefix = prefix
        self.placeholder = placeholder
        model.chosen = initial
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))

        // A real pull-down button, for its shape and its metrics — the pill, the
        // chevron at the trailing edge, the system's own materials. What it must
        // *not* do is open a menu, which is why the click is intercepted rather
        // than actioned: NSPopUpButton eats mouseDown to show its own menu, so a
        // target/action never fires and the button looked dead.
        button.frame = bounds
        button.controlSize = .large
        button.autoenablesItems = false
        button.addItem(withTitle: "")
        button.onClick = { [weak self] in self?.toggle() }
        addSubview(button)
        refreshTitle()

        popover.behavior = .transient
        let host = NSHostingController(
            rootView: BranchPicker(model: model, width: width) { [weak self] branch in
                self?.select(branch)
            })
        // **Sized explicitly, and to the button's width.** A SwiftUI ScrollView
        // reports no height of its own, so an unsized hosting controller
        // stretches to whatever the popover will give it — which is where the
        // half-screen of empty space under six branches came from. Matching the
        // button's width is what makes the two line up instead of the popover
        // overhanging it by ten points on each side.
        host.preferredContentSize = NSSize(width: width, height: Self.popoverHeight)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: width, height: Self.popoverHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func toggle() {
        guard !popover.isShown else { return popover.performClose(nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func select(_ branch: String) {
        model.chosen = branch
        refreshTitle()
        popover.performClose(nil)
        onChange?()
    }

    /// An NSPopUpButton shows the title of its selected item, so the one item is
    /// the title — there is no separate label to set.
    private func refreshTitle() {
        button.item(at: 0)?.title = branch.map { prefix + $0 } ?? placeholder
        button.synchronizeTitleAndSelectedItem()
    }

    /// Greyed when the dialog has nothing to ask here. Disabling the *button*
    /// rather than removing the row keeps the dialog one height: a row that comes
    /// and goes as you type would shift whatever sits under it, and the branch
    /// field is what sits above.
    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }
}

/// The branch row: a combo box, so the field is ready to type into.
///
/// The name you want usually doesn't exist yet — that's what opening a session
/// on a branch is *for* — and a pull-down makes the common case cost a click
/// before the first character. `completes` gives the other half back: typing
/// `up` fills in `update-website` with the completion selected, so an existing
/// branch is a few keys rather than a hunt. Tower and Fork both land here.
@MainActor
final class BranchNameField: NSComboBox {
    /// Trimmed, and nil when empty — "  " is not a branch name.
    var branch: String? {
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    init(branches: [String], width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        addItems(withObjectValues: branches)
        // Inline completion, which is the whole reason this is a combo box and
        // not a text field beside a menu.
        completes = true
        isEditable = true
        placeholderString = "Branch name"
        // Matches the base row's pull-down: both controls come out at 28pt here
        // and at different heights at every other control size, and two rows of
        // visibly different height read as two unrelated things.
        controlSize = .large
        font = .systemFont(ofSize: NSFont.systemFontSize)
        // The list is the repository's branches, so it's as long as it is —
        // scrolling beats a menu tall enough to cover the dialog that owns it.
        numberOfVisibleItems = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// The dialog's accessory: which branch to open, what a new one forks from, and
/// one line saying what's about to happen.
///
/// The branch comes first because it's the field you always fill and the one
/// that takes focus; the base is the field you usually accept. Both rows are
/// *always shown* — a row that appears as you type would shift whatever sits
/// under it, and the status line is reserved rather than inserted for the same
/// reason. Tower's dialog earns its explanation with a paragraph; this one is an
/// alert, so it gets a line.
@MainActor
final class BranchDialogAccessory: NSView, NSComboBoxDelegate {
    private let nameField: BranchNameField
    private let baseChooser: BranchChooser
    private let status = NSTextField(labelWithString: "")
    private let existing: Set<String>
    private let withWorktree: Set<String>

    /// The branch to open — nil when nothing was typed or chosen.
    var branch: String? { nameField.branch }
    /// What a new branch forks from. nil for a branch that already exists, which
    /// is checked out as it is, and nil when the repository named no default.
    var base: String? { isExistingBranch ? nil : baseChooser.branch }

    /// Whether there is anything to create. Tower greys its "Create Worktree"
    /// until the revision names something; ours used to accept the click and
    /// then quietly do nothing, which is the same answer delivered worse.
    var isValid: Bool { branch != nil }
    /// Fired whenever `isValid` might have changed, so the dialog's default
    /// button can follow it.
    var onValidityChange: ((Bool) -> Void)?

    /// Focus belongs on the branch row: it's the answer the dialog is asking for.
    var initialResponder: NSView { nameField }

    private var isExistingBranch: Bool {
        guard let branch else { return false }
        return existing.contains { $0.caseInsensitiveCompare(branch) == .orderedSame }
    }

    /// Both rows' controls report exactly this at `.large`, so neither is
    /// stretched or squashed into its slot.
    static let rowHeight: CGFloat = 28
    static let rowGap: CGFloat = 8
    static let statusHeight: CGFloat = 16

    init(branches: [String], withWorktree: Set<String>, defaultBase: String?, width: CGFloat) {
        existing = Set(branches)
        self.withWorktree = withWorktree
        nameField = BranchNameField(branches: branches, width: width)
        baseChooser = BranchChooser(
            branches: branches, withWorktree: withWorktree, width: width,
            placeholder: "From: current branch", prefix: "From: ", initial: defaultBase)
        let height = Self.rowHeight * 2 + Self.rowGap * 2 + Self.statusHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // AppKit's origin is bottom-left, so the topmost row has the largest y.
        nameField.frame = NSRect(
            x: 0, y: Self.rowHeight + Self.rowGap * 2 + Self.statusHeight,
            width: width, height: Self.rowHeight)
        baseChooser.frame = NSRect(
            x: 0, y: Self.statusHeight + Self.rowGap, width: width, height: Self.rowHeight)
        status.frame = NSRect(x: 0, y: 0, width: width, height: Self.statusHeight)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(nameField)
        addSubview(baseChooser)
        addSubview(status)

        nameField.delegate = self
        baseChooser.onChange = { [weak self] in self?.sync() }
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // Typing, and picking from the dropdown. The selection notification arrives
    // *before* the field's string value is updated, so that one is read on the
    // next turn of the run loop rather than immediately.
    func controlTextDidChange(_ obj: Notification) { sync() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    /// One place where every consequence of the branch name is worked out: what
    /// the base row is for, what the status line says, and whether there is
    /// anything to create at all.
    private func sync() {
        // An existing branch has its own history; there is nothing to fork it
        // from, so the row greys rather than sitting there looking answerable.
        baseChooser.isEnabled = !isExistingBranch
        status.stringValue = statusText()
        onValidityChange?(isValid)
    }

    /// What the click is about to do — the thing the popover's row labels used to
    /// say, moved somewhere it can be read without opening anything.
    private func statusText() -> String {
        guard let branch else { return "" }
        if withWorktree.contains(branch) {
            return "\u{201c}\(branch)\u{201d} already has a worktree. This opens it."
        }
        if isExistingBranch {
            return "Checks out \u{201c}\(branch)\u{201d} in a new worktree."
        }
        guard let base = baseChooser.branch else {
            return "Creates \u{201c}\(branch)\u{201d} in a new worktree."
        }
        return "Creates \u{201c}\(branch)\u{201d} from \u{201c}\(base)\u{201d}."
    }
}

/// A pull-down button that opens something other than a menu.
private final class ChooserButton: NSPopUpButton {
    var onClick: (() -> Void)?

    /// Deliberately no `super` call: that's what shows the menu, and the menu is
    /// the one thing this button doesn't have.
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// Space and Return should do what a click does, for the same reason.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onClick?() } else { super.keyDown(with: event) }
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
    let width: CGFloat
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
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(width: width)
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
