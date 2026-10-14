import AppKit

/// What the sheet was told: a branch (and what a new one forks from), or a
/// pull request to check out.
enum BranchChoice: Equatable {
    case branch(String, base: String?)
    case pullRequest(PullRequestRef)
}

/// "New Session on Branch": a name, and the ref it forks from. Or a pull
/// request, by `#123` or its URL, typed into the same field.
///
/// Two inputs, a line saying what the button will do, and the two buttons. The
/// "From" control opens the branch list right under itself; there is no menu in
/// between and nothing else to navigate.
///
/// The layout is the standard AppKit form: an `NSGridView` with trailing-aligned
/// labels in the first column, controls in the second, and first-baseline row
/// alignment so a label sits on the same line as the control it names.
@MainActor
final class BranchSheet: NSViewController, NSTextFieldDelegate {
    private let catalog: BranchCatalog
    private let nameField = NSTextField()
    private let baseChooser: BranchChooser
    private let status = NSTextField(labelWithString: "")
    private var createButton: NSButton!

    /// Where the answer goes. Called exactly once, with nil for Cancel.
    private var finish: ((BranchChoice?) -> Void)?

    /// What we put in the field, kept so we can tell "still ours" from "typed
    /// over" when the remote branches land.
    private var suggested = ""

    /// A name you can simply accept, so the common case is: open the sheet,
    /// press Return.
    ///
    /// Herdr's scheme, because it had the right idea and there is nothing to
    /// improve on: `worktree/brave-river-1a2f`. An adjective and a noun make it
    /// sayable and tellable apart in a sidebar, where a timestamp is just a
    /// number you have to read carefully; the hex tail keeps it unique; and the
    /// `worktree/` prefix groups every branch the app made under one heading in
    /// `git branch`, which matters when they are disposable and you will want
    /// to sweep them later. See `worktree.rs:generated_branch_slug` in
    /// ogulcancelik/herdr, whose word lists these are.
    private static let slugAdjectives = [
        "brave", "calm", "clear", "green", "lucky", "quiet", "rapid", "silver",
    ]
    private static let slugNouns = [
        "river", "cloud", "field", "forest", "harbor", "meadow", "stone", "valley",
    ]

    private static func slug(seed: UInt64) -> String {
        let adjective = slugAdjectives[Int(seed % UInt64(slugAdjectives.count))]
        let noun = slugNouns[Int((seed / UInt64(slugAdjectives.count)) % UInt64(slugNouns.count))]
        return GitWorktree.branchNamespace
            + String(format: "%@-%@-%04x", adjective, noun, Int(seed & 0xffff))
    }

    /// Seeded from the clock, then walked until the name is free. A name that
    /// already exists is not a new branch, it is a checkout of somebody's work,
    /// and offering that by default is a quiet way to land in the wrong place.
    private static func suggestedName(in catalog: BranchCatalog, now: Date = Date()) -> String {
        var seed = UInt64(max(0, now.timeIntervalSince1970) * 1_000_000)
        // Bounded: 64 collisions in a row means something is wrong with the
        // catalogue, not with the name, and a loop is not the place to find out.
        for _ in 0..<64 {
            let candidate = slug(seed: seed)
            if !catalog.hasLocal(candidate), catalog.remotes(carrying: candidate).isEmpty {
                return candidate
            }
            seed &+= 1
        }
        return slug(seed: seed)
    }

    /// Wide enough for a real branch name (`feature/the-thing-i-am-doing`) and
    /// for the status line under it, which is the longest thing here and the
    /// one that decides this number: at 380 it comes to about 290pt against the
    /// 321 the grid leaves it.
    private static let contentWidth: CGFloat = 380
    private static let margin: CGFloat = 20

    /// The branch to open, nil when nothing usable has been typed. As git will
    /// get it (`GitWorktree.branchName`), so the line under the field names
    /// the branch that will exist: "Creates “worktree/Jump-to” from “main”."
    var branch: String? {
        let name = GitWorktree.branchName(from: nameField.stringValue)
        return name.isEmpty ? nil : name
    }

    /// A pull request, when that's what was typed: `#123`, its URL, or a bare
    /// number no branch is called.
    var pullRequest: PullRequestRef? {
        let raw = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let isBranchName = catalog.hasLocal(raw) || !catalog.remotes(carrying: raw).isEmpty
        return PullRequestRef.parse(raw, allowsBareNumber: !isBranchName)
    }

    /// What a new branch forks from. nil for a branch that already exists, which
    /// is checked out as it is rather than forked.
    var base: String? { existsAlready ? nil : baseChooser.branch }

    /// Whether the name already belongs to a branch — locally, or on exactly one
    /// remote, which git checks out just the same (see
    /// SessionManager.openSession). The remote half is only knowable once the
    /// catalogue has loaded it, so this can say "no" for a moment on a large
    /// repository; the *prediction* goes stale there, never the action, which
    /// re-asks git.
    private var existsAlready: Bool {
        guard let branch else { return false }
        return catalog.hasLocal(branch) || catalog.remotes(carrying: branch).count == 1
    }

    init(catalog: BranchCatalog, defaultBase: String?) {
        self.catalog = catalog
        baseChooser = BranchChooser(catalog: catalog, initial: defaultBase)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The remote half of the catalogue arrived. The list behind "From" gets it,
    /// and the status line is restated: a name that looked new a moment ago may
    /// now be a branch somebody else pushed.
    func catalogChanged() {
        baseChooser.catalogChanged()
        // The suggestion was made against the local branches alone, so a remote
        // one could have been carrying that name all along. Only re-rolled if
        // the field is still exactly what we put there: once you have typed,
        // the name is yours and the status line says what it will do.
        if nameField.stringValue == suggested,
           !catalog.remotes(carrying: suggested).isEmpty {
            suggested = Self.suggestedName(in: catalog)
            nameField.stringValue = suggested
            selectName()
        }
        sync()
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "New Session on Branch")
        title.font = .preferredFont(forTextStyle: .headline)

        nameField.placeholderString = "Branch name, or a pull request"
        suggested = Self.suggestedName(in: catalog)
        nameField.stringValue = suggested
        nameField.controlSize = .large
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        // Yields on both counts, so it can neither stretch the column it sits in
        // nor resist truncation inside it: it reports what the form is doing and
        // gets no say in the form's shape.
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let branchLabel = Self.label("Branch:")
        let fromLabel = Self.label("From:")
        let grid = NSGridView(views: [
            [branchLabel, nameField],
            [fromLabel, baseChooser],
            [NSGridCell.emptyContentView, status],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        // **The label column is pinned, and it has to be.** Sized to content, a
        // column is as wide as the widest thing in it, and the widest thing in
        // column 1 is the status line — whose text changes with every keystroke.
        // The leftover went to column 0, so the labels and both controls slid
        // sideways as you typed: 118pt between the resting hint and "Creates “x”
        // from “origin/main”." A form laid out by its own status text is a form
        // that moves while you use it.
        grid.column(at: 0).width = ceil(max(
            branchLabel.intrinsicContentSize.width, fromLabel.intrinsicContentSize.width))
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        // Help text belongs against the thing it explains, and the row spacing
        // plus the gap between a control's frame and a label's baseline already
        // puts more air there than it looks like on paper.
        grid.row(at: 2).topPadding = 0
        grid.row(at: 2).rowAlignment = .none

        createButton = NSButton(title: "Create", target: self, action: #selector(create))
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        // A visible way out, and Escape. Removing both is how a modal turns into
        // a lock-up, which is exactly what happened when it had neither.
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancel, createButton])
        buttons.spacing = 12

        let root = NSView()
        for child in [title, grid, buttons] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.margin),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor, constant: -Self.margin),

            grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.margin),

            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.margin),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.margin),

            root.widthAnchor.constraint(
                equalToConstant: Self.contentWidth + Self.margin * 2),
        ])
        view = root
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .labelColor
        return label
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        nameField.delegate = self
        baseChooser.onChange = { [weak self] in self?.sync() }
        sync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Focus belongs on the name: it's the answer the sheet is asking for,
        // and "From" is the one you usually accept.
        view.window?.makeFirstResponder(nameField)
        selectName()
    }

    func controlTextDidChange(_ obj: Notification) { sync() }

    /// The suggestion arrives selected, so it costs one keystroke to replace
    /// and none to accept. A prefilled field you have to clear first is worse
    /// than an empty one.
    private func selectName() { nameField.currentEditor()?.selectAll(nil) }

    /// One place where every consequence of the name is worked out: what the
    /// From row is for, what the status line says, and whether there is anything
    /// to create.
    private func sync() {
        // An existing branch has its own history; there is nothing to fork it
        // from, so the row greys rather than sitting there looking answerable.
        // A pull request has its own history too, so the same goes for it.
        baseChooser.isEnabled = !existsAlready && pullRequest == nil
        status.stringValue = statusText()
        // Nothing to create until the field names something. Accepting the click
        // and then quietly doing nothing is the same answer delivered worse.
        createButton.isEnabled = branch != nil || pullRequest != nil
    }

    /// Never empty. The line is reserved either way, because one that appeared
    /// as you typed would move the buttons out from under the pointer, and an
    /// empty reservation is just a hole in the sheet.
    private func statusText() -> String {
        if let pullRequest {
            return "Checks out pull request \(pullRequest.label) in a new worktree."
        }
        guard let branch else { return "Type a name to create a branch, or pick one that exists." }
        if catalog.withWorktree.contains(branch) {
            return "\u{201c}\(branch)\u{201d} already has a worktree. This opens it."
        }
        if catalog.hasLocal(branch) {
            return "Checks out \u{201c}\(branch)\u{201d} in a new worktree."
        }
        // A branch that exists only on a remote is checked out, not created, and
        // saying which remote is the point: it is the difference between
        // starting someone's work and starting a branch that shares its name.
        let remotes = catalog.remotes(carrying: branch)
        if remotes.count == 1, let remote = remotes.first {
            return "Checks out \u{201c}\(branch)\u{201d} from \(remote) in a new worktree."
        }
        if remotes.count > 1 {
            return "\u{201c}\(branch)\u{201d} is on \(remotes.joined(separator: " and ")). "
                + "Check out the one you want first."
        }
        guard let base = baseChooser.branch else {
            return "Creates \u{201c}\(branch)\u{201d} in a new worktree."
        }
        return "Creates \u{201c}\(branch)\u{201d} from \u{201c}\(base)\u{201d}."
    }

    @objc private func create() {
        if let pullRequest { return complete(.pullRequest(pullRequest)) }
        guard let branch else { return }
        complete(.branch(branch, base: base))
    }

    @objc private func cancel() { complete(nil) }

    private func complete(_ answer: BranchChoice?) {
        let finish = finish
        self.finish = nil
        // Answered *before* dismissing, and the order is load-bearing:
        // `endSheet` runs the completion handler `present` passed, which resumes
        // the same continuation with nil. Whichever gets there first wins, so
        // dismissing first would turn a Create into a Cancel on any macOS that
        // calls that handler synchronously.
        finish?(answer)
        view.window.map { $0.sheetParent?.endSheet($0) }
    }

    /// Run the sheet on `window` and return what it was told, or nil on Cancel.
    static func present(
        over window: NSWindow, catalog: BranchCatalog, defaultBase: String?,
        whileOpen: @escaping (BranchSheet) -> Void = { _ in }
    ) async -> BranchChoice? {
        // The window it belongs to comes forward first. A window-modal sheet on
        // a window that is behind another one is indistinguishable from a
        // lock-up: the blocked window is not the one you are looking at.
        window.makeKeyAndOrderFront(nil)
        let sheet = BranchSheet(catalog: catalog, defaultBase: defaultBase)
        return await withCheckedContinuation { continuation in
            var resumed = false
            sheet.finish = { answer in
                // `endSheet` and an explicit button can both arrive for one
                // sheet; a continuation resumed twice is a crash.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: answer)
            }
            let host = NSWindow(contentViewController: sheet)
            // Handed back so the caller can keep filling the catalogue while
            // this is up. The sheet outlives the call that opened it.
            whileOpen(sheet)
            window.beginSheet(host) { _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }
}
