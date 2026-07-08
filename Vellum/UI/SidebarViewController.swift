import AppKit

/// The session list, styled like a Finder sidebar: a vibrant source list
/// with a "Sessions" section header, SF Symbol row icons, and short
/// directory-name labels.
///
/// Deliberately dumb: no bindings, no diffable data source — the window
/// controller tells it exactly which rows changed. Nothing here observes
/// terminal state, so terminal output can never trigger sidebar work.
final class SidebarViewController: NSViewController {
    var onSelectRow: ((Int) -> Void)?
    var onAddSession: (() -> Void)?

    /// Row data is pulled on demand from this provider.
    var sessionProvider: (() -> [Session])?

    private let tableView = SidebarTableView()
    private let scrollView = NSScrollView()
    private var isSyncingSelection = false

    // No section header: table rows map 1:1 to session indices.

    override func loadView() {
        tableView.style = .sourceList
        // The inset, rounded "floating pill" selection (Finder). Not applied
        // automatically here because the table isn't inside an
        // NSSplitViewController sidebar (we build the vibrancy by hand), so
        // set it explicitly.
        tableView.selectionHighlightStyle = .sourceList
        tableView.headerView = nil
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.refusesFirstResponder = true
        tableView.focusRingType = .none
        tableView.backgroundColor = .clear
        tableView.floatsGroupRows = false
        tableView.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // Manual top inset pushes "Sessions" below the floating traffic lights
        // (the sidebar runs to the very top, there's no toolbar to reserve it).
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Native "add" affordance at the bottom of the sidebar (Mail /
        // Reminders / Xcode navigator). Keeps the terminal top clear.
        let addButton = NSButton()
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")
        addButton.imageScaling = .scaleProportionallyDown
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Session (⌘N)"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.refusesFirstResponder = true
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(addButton)

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32),

            addButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            addButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        view = container
    }

    @objc private func addTapped() {
        onAddSession?()
    }

    // MARK: - Row updates (driven by the window controller, in session indices)

    func insertRow(at index: Int) {
        tableView.insertRows(at: IndexSet(integer: index), withAnimation: [])
    }

    func removeRow(at index: Int) {
        tableView.removeRows(at: IndexSet(integer: index), withAnimation: [])
    }

    func reloadRow(at index: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integer: 0))
    }

    func selectRow(at index: Int) {
        isSyncingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isSyncingSelection = false
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sessionProvider?().count ?? 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        48 // two lines: title + path
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let sessions = sessionProvider?(), sessions.indices.contains(row) else { return nil }
        let session = sessions[row]

        let id = NSUserInterfaceItemIdentifier("SessionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SessionCellView
            ?? SessionCellView(identifier: id)
        cell.configure(title: session.name, path: session.abbreviatedPath, hasBell: session.hasBell)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onSelectRow?(row)
    }
}

/// Table that never takes keyboard focus — clicking the sidebar must not
/// steal typing from the terminal.
private final class SidebarTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// One sidebar row: a leading terminal glyph and two lines (session name on
/// top, abbreviated path below), all centered vertically as one group.
final class SessionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let bellDot = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        imageView = icon

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        // Stack the two lines and center the pair vertically in the row.
        let textStack = NSStackView(views: [titleLabel, pathLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        textField = titleLabel

        bellDot.wantsLayer = true
        bellDot.layer?.cornerRadius = 3
        bellDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        bellDot.isHidden = true
        bellDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bellDot)

        NSLayoutConstraint.activate([
            // Icon aligns with the title line; the path sits below both.
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: bellDot.leadingAnchor, constant: -6),

            bellDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bellDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bellDot.widthAnchor.constraint(equalToConstant: 6),
            bellDot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String, path: String, hasBell: Bool) {
        titleLabel.stringValue = title
        pathLabel.stringValue = path
        pathLabel.isHidden = path.isEmpty
        bellDot.isHidden = !hasBell
    }
}
