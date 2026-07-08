import AppKit

/// The session list, styled like a Finder sidebar: a vibrant source list
/// with a "Sessions" section header, SF Symbol row icons, and short
/// directory-name labels.
///
/// Deliberately dumb: no bindings, no diffable data source — the window
/// controller tells it exactly which rows changed. Nothing here observes
/// terminal state, so terminal output can never trigger sidebar work.
///
/// Row 0 is the non-selectable section header; session `i` lives at table
/// row `i + 1`. The offset is contained entirely within this file — the
/// window controller only ever speaks in session indices.
final class SidebarViewController: NSViewController {
    var onSelectRow: ((Int) -> Void)?
    var onAddSession: (() -> Void)?

    /// Row data is pulled on demand from this provider.
    var sessionProvider: (() -> [Session])?

    private let tableView = SidebarTableView()
    private let scrollView = NSScrollView()
    private var isSyncingSelection = false

    private static let headerRow = 0
    private func tableRow(forSession index: Int) -> Int { index + 1 }
    private func sessionIndex(forTableRow row: Int) -> Int? {
        row == Self.headerRow ? nil : row - 1
    }

    override func loadView() {
        tableView.style = .sourceList
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
        // The header bar provides the top space (for the traffic lights), so
        // the table doesn't add its own safe-area inset.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Finder-style top: a clean bar over the sidebar giving the traffic
        // lights their own space, with a hairline below. The terminal side
        // has no such bar and runs to the very top. This bar is also a drag
        // handle (isMovableByWindowBackground).
        let headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(hairline)

        // Native "add" affordance at the bottom of the sidebar (Mail /
        // Reminders / Xcode navigator). Keeps the terminal top clear.
        let addButton = NSButton()
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")
        addButton.imageScaling = .scaleProportionallyDown
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Session (⌘T)"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.refusesFirstResponder = true
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(addButton)

        let container = NSView()
        container.addSubview(headerBar)
        container.addSubview(scrollView)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            // Header bar: sits under the traffic lights, matches the window's
            // titlebar height (measured 32pt).
            headerBar.topAnchor.constraint(equalTo: container.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 38),

            hairline.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
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
        tableView.insertRows(at: IndexSet(integer: tableRow(forSession: index)), withAnimation: [])
    }

    func removeRow(at index: Int) {
        tableView.removeRows(at: IndexSet(integer: tableRow(forSession: index)), withAnimation: [])
    }

    func reloadRow(at index: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: tableRow(forSession: index)),
                             columnIndexes: IndexSet(integer: 0))
    }

    func selectRow(at index: Int) {
        isSyncingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: tableRow(forSession: index)),
                                   byExtendingSelection: false)
        isSyncingSelection = false
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        (sessionProvider?().count ?? 0) + 1 // +1 for the section header
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        row == Self.headerRow
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row != Self.headerRow
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == Self.headerRow ? 24 : 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == Self.headerRow {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                ?? SidebarHeaderView(identifier: id)
            (cell as? SidebarHeaderView)?.configure(title: "Sessions")
            return cell
        }

        guard let sessions = sessionProvider?(),
              let index = sessionIndex(forTableRow: row),
              sessions.indices.contains(index) else { return nil }
        let session = sessions[index]

        let id = NSUserInterfaceItemIdentifier("SessionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SessionCellView
            ?? SessionCellView(identifier: id)
        cell.configure(title: session.displayName, hasBell: session.hasBell)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        guard let index = sessionIndex(forTableRow: tableView.selectedRow) else { return }
        onSelectRow?(index)
    }
}

/// Table that never takes keyboard focus — clicking the sidebar must not
/// steal typing from the terminal.
private final class SidebarTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// A Finder-style section header row (small, uppercase, secondary color).
final class SidebarHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String) {
        label.stringValue = title
    }
}

/// One sidebar row: SF Symbol terminal icon + directory name + bell badge.
final class SessionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bellDot = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        imageView = icon

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        bellDot.wantsLayer = true
        bellDot.layer?.cornerRadius = 3
        bellDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        bellDot.isHidden = true
        bellDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bellDot)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bellDot.leadingAnchor, constant: -6),

            bellDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bellDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            bellDot.widthAnchor.constraint(equalToConstant: 6),
            bellDot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String, hasBell: Bool) {
        label.stringValue = title
        bellDot.isHidden = !hasBell
    }
}
