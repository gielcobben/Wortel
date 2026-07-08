import AppKit

/// The session list. Deliberately dumb: no bindings, no diffable data
/// source — the window controller tells it exactly which rows changed.
/// Nothing here observes terminal state, so terminal output can never
/// trigger sidebar work.
final class SidebarViewController: NSViewController {
    var onSelectRow: ((Int) -> Void)?

    /// Row data is pulled on demand from this provider.
    var sessionProvider: (() -> [Session])?

    private let tableView = SidebarTableView()
    private let scrollView = NSScrollView()
    private var isSyncingSelection = false

    override func loadView() {
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.refusesFirstResponder = true
        tableView.focusRingType = .none

        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        view = scrollView
    }

    // MARK: - Row updates (driven by the window controller)

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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let sessions = sessionProvider?(), sessions.indices.contains(row) else { return nil }
        let session = sessions[row]

        let identifier = NSUserInterfaceItemIdentifier("SessionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SessionCellView
            ?? SessionCellView(identifier: identifier)
        cell.configure(title: session.title, hasBell: session.hasBell)
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

/// One sidebar row: title + bell badge dot.
final class SessionCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let bellDot = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        bellDot.wantsLayer = true
        bellDot.layer?.cornerRadius = 3
        bellDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        bellDot.isHidden = true
        bellDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bellDot)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
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
