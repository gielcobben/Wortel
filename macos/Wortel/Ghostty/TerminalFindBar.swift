import AppKit

/// ⌘F in a terminal: a small bar in its top-right corner that searches the
/// scrollback, the way a file tab's find bar searches the file.
///
/// The searching is libghostty's (`start_search`, `search:<needle>`,
/// `navigate_search`, `end_search`); it highlights the matches, scrolls to the
/// selected one and reports how many there are. This is only the field, the
/// count and the arrows.
///
/// libghostty draws the terminal into a layer it owns, so the bar can't be a
/// subview of the terminal: it's the terminal's sibling, pinned to its corner,
/// and moves with it when the terminal changes rows (`SurfaceView.findBar`).
@MainActor
final class TerminalFindBar: NSVisualEffectView, NSTextFieldDelegate {
    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = TerminalFindBar.button("chevron.up", "Previous Match")
    private let next = TerminalFindBar.button("chevron.down", "Next Match")
    private let close = TerminalFindBar.button("xmark", "Close")

    var onChange: (String) -> Void = { _ in }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onClose: () -> Void = {}

    /// Matches in all, and which one is selected (from 0), as libghostty
    /// reports them. nil: not known yet.
    var total: Int? { didSet { updateCount() } }
    var selected: Int? { didSet { updateCount() } }

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Find"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        count.font = .systemFont(ofSize: 12).withMonospacedDigits()
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        previous.target = self
        previous.action = #selector(previousPressed)
        next.target = self
        next.action = #selector(nextPressed)
        close.target = self
        close.action = #selector(closePressed)

        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 2
        stack.setCustomSpacing(8, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 300),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        updateCount()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A click on the bar is a click on the bar, not a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func updateCount() {
        let needle = field.stringValue
        switch (total, selected) {
        case _ where needle.isEmpty:
            count.stringValue = ""
        case (0?, _):
            count.stringValue = "No results"
        case (let total?, let selected?) where selected >= 0:
            count.stringValue = "\(selected + 1) of \(total)"
        case (let total?, _):
            count.stringValue = "\(total)"
        default:
            count.stringValue = ""
        }
        previous.isEnabled = (total ?? 0) > 0
        next.isEnabled = (total ?? 0) > 0
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) {
        total = nil
        selected = nil
        onChange(field.stringValue)
    }

    /// Return: the next match, ⇧Return the previous one; Escape closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious() } else { onNext() }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onPrevious()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }

    @objc private func previousPressed() { onPrevious() }
    @objc private func nextPressed() { onNext() }
    @objc private func closePressed() { onClose() }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }
}

private extension NSFont {
    func withMonospacedDigits() -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - The terminal's side

extension SurfaceView {
    /// Open the find bar over this terminal and put the keyboard in it. ⌘F.
    func startSearch() {
        let bar = findBar ?? makeFindBar()
        attachFindBar()
        bar.focusField()
        // libghostty's own start; it answers with START_SEARCH, which lands
        // in `searchStarted` and changes nothing that's already so.
        performBinding("start_search")
        if !bar.field.stringValue.isEmpty { performBinding("search:" + bar.field.stringValue) }
    }

    /// Close the bar, clear the highlights, and give the terminal back the
    /// keyboard.
    func endSearch() {
        performBinding("end_search")
        searchEnded()
        window?.makeFirstResponder(self)
    }

    // What libghostty reports (GhosttyRuntime).

    func searchStarted(needle: String?) {
        let bar = findBar ?? makeFindBar()
        attachFindBar()
        if let needle, !needle.isEmpty, bar.field.stringValue != needle {
            bar.field.stringValue = needle
        }
        bar.focusField()
    }

    func searchEnded() {
        findBar?.removeFromSuperview()
        findBar = nil
    }

    func searchTotal(_ total: Int?) { findBar?.total = total }
    func searchSelected(_ selected: Int?) { findBar?.selected = selected }

    // MARK: Placement

    private func makeFindBar() -> TerminalFindBar {
        let bar = TerminalFindBar()
        bar.onChange = { [weak self] needle in self?.performBinding("search:" + needle) }
        bar.onNext = { [weak self] in self?.performBinding("navigate_search:next") }
        bar.onPrevious = { [weak self] in self?.performBinding("navigate_search:previous") }
        bar.onClose = { [weak self] in self?.endSearch() }
        findBar = bar
        return bar
    }

    /// Pin the bar to this terminal's top-right corner, in whatever view
    /// holds the terminal now.
    func attachFindBar() {
        guard let bar = findBar else { return }
        guard let superview else {
            bar.removeFromSuperview()
            return
        }
        if bar.superview !== superview {
            bar.removeFromSuperview()
            superview.addSubview(bar, positioned: .above, relativeTo: self)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
        }
        bar.isHidden = isHidden
    }
}
