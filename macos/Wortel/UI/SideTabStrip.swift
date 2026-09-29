import AppKit

/// The side column's tabs, drawn in the titlebar over the column.
///
/// Modelled on the ChatGPT app's workspace tabs, measured from its bundle: the
/// tab in front is a raised surface with a hairline edge, the rest are bare text
/// in a quieter grey that fills on hover, a close button shows only on the tab in
/// front and the one under the pointer, and a "+" ends the row. Tabs share the
/// room there is: each fits its title up to `maxTabWidth`, and when the row is
/// too long they shrink together towards `minTabWidth` rather than one of them
/// disappearing.
///
/// AppKit rather than a hosted SwiftUI view because it lives in a toolbar item,
/// where a hosting view's hit testing and sizing both fight the toolbar, and
/// because middle-click and right-click want real events.
@MainActor
final class SideTabStrip: NSView {
    struct Item: Equatable {
        let tab: SideTab
        let title: String
        let symbol: String
    }

    var onSelect: (SideTab) -> Void = { _ in }
    var onClose: (SideTab) -> Void = { _ in }
    var onCloseOthers: (SideTab) -> Void = { _ in }
    /// The "+" was pressed; show the new-tab menu from this view.
    var onAdd: (NSView) -> Void = { _ in }

    static let tabHeight: CGFloat = 28
    static let minTabWidth: CGFloat = 76
    static let maxTabWidth: CGFloat = 200
    private static let gap: CGFloat = 2
    private static let addSize: CGFloat = 28

    private var items: [Item] = []
    private var active: SideTab?
    private var tabViews: [SideTabView] = []
    private let addButton = SideTabStrip.makeAddButton()
    /// The widest the strip may draw, which the toolbar learns from the column.
    private var availableWidth: CGFloat = 400

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addButton.target = self
        addButton.action = #selector(addPressed)
        addSubview(addButton)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(items: [Item], active: SideTab?, availableWidth: CGFloat) {
        let widthChanged = abs(availableWidth - self.availableWidth) > 0.5
        guard items != self.items || active != self.active || widthChanged else { return }
        self.availableWidth = availableWidth
        if items.map(\.tab) != self.items.map(\.tab) {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = items.map { item in
                let view = SideTabView(tab: item.tab)
                view.onSelect = { [weak self] in self?.onSelect(item.tab) }
                view.onClose = { [weak self] in self?.onClose(item.tab) }
                view.onCloseOthers = { [weak self] in self?.onCloseOthers(item.tab) }
                addSubview(view, positioned: .below, relativeTo: addButton)
                return view
            }
        }
        self.items = items
        self.active = active
        for (view, item) in zip(tabViews, items) {
            view.configure(title: item.title, symbol: item.symbol, isActive: item.tab == active)
        }
        // The tab to the left of the one in front, and the one in front, draw no
        // divider: the raised tab is its own edge.
        for (index, view) in tabViews.enumerated() {
            let next = index + 1 < items.count ? items[index + 1].tab : nil
            view.showsTrailingDivider = next != nil && items[index].tab != active && next != active
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Each tab's width: what its title wants, clamped, then shrunk evenly when
    /// the row would run past what the column has room for.
    private func tabWidths() -> [CGFloat] {
        let wanted = tabViews.map { min(max($0.fittingWidth, Self.minTabWidth), Self.maxTabWidth) }
        let room = availableWidth - Self.addSize - Self.gap * CGFloat(tabViews.count)
        let total = wanted.reduce(0, +)
        guard total > room, !wanted.isEmpty else { return wanted }
        let scale = max(room, Self.minTabWidth * CGFloat(wanted.count)) / total
        return wanted.map { max(Self.minTabWidth, ($0 * scale).rounded(.down)) }
    }

    override var intrinsicContentSize: NSSize {
        let widths = tabWidths()
        let width = widths.reduce(0, +) + Self.gap * CGFloat(widths.count) + Self.addSize
        return NSSize(width: min(width, max(availableWidth, Self.addSize)), height: Self.tabHeight)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let y = (bounds.height - Self.tabHeight) / 2
        for (view, width) in zip(tabViews, tabWidths()) {
            view.frame = NSRect(x: x, y: y, width: width, height: Self.tabHeight)
            x += width + Self.gap
        }
        addButton.frame = NSRect(x: x, y: y, width: Self.addSize, height: Self.addSize)
    }

    @objc private func addPressed() { onAdd(addButton) }

    private static func makeAddButton() -> NSButton {
        let button = HoverFillButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.toolTip = "New Tab"
        return button
    }
}

/// One tab: symbol, title, and the close button that appears on the tab in
/// front and on hover.
@MainActor
private final class SideTabView: NSView {
    let tab: SideTab
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onCloseOthers: () -> Void = {}
    var showsTrailingDivider = false {
        didSet { if showsTrailingDivider != oldValue { needsDisplay = true } }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = HoverFillButton()
    private var isActive = false
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyState()
        }
    }

    init(tab: SideTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.toolTip = "Close Tab"
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        [icon, label, closeButton].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// What the tab would like to be: padding, symbol, title, close button.
    var fittingWidth: CGFloat {
        10 + 16 + 6 + ceil(label.attributedStringValue.size().width) + 4 + 18 + 6
    }

    func configure(title: String, symbol: String, isActive: Bool) {
        label.stringValue = title
        toolTip = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.isActive = isActive
        applyState()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        let closeX = bounds.width - 6 - 18
        closeButton.frame = NSRect(x: closeX, y: (h - 18) / 2, width: 18, height: 18)
        let labelX: CGFloat = 10 + 16 + 6
        let labelHeight = ceil(label.intrinsicContentSize.height)
        // The title keeps the close button's room whether or not it shows, so
        // hovering a tab never moves its text.
        label.frame = NSRect(x: labelX, y: (h - labelHeight) / 2,
                             width: max(0, closeX - 4 - labelX), height: labelHeight)
    }

    private func applyState() {
        closeButton.isHidden = !(isActive || hovering)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        icon.contentTintColor = isActive ? .secondaryLabelColor : .tertiaryLabelColor
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        if isActive {
            // A raised surface with a hairline edge: the tab in front reads as the
            // top of the page underneath it.
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            Self.activeFill.setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.10).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        } else if showsTrailingDivider {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSRect(x: rect.maxX - 1, y: rect.midY - 6, width: 1, height: 12).fill()
        }
    }

    /// White in light mode, a lifted grey in dark: the elevated surface.
    private static let activeFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.92)
    }

    // MARK: Mouse

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Select on mouse-down, as tabs do: a tab is picked, not clicked.
    override func mouseDown(with event: NSEvent) { onSelect() }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { super.otherMouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Close Tab") { [weak self] in self?.onClose() })
        menu.addItem(ClosureMenuItem(title: "Close Other Tabs") { [weak self] in self?.onCloseOthers() })
        return menu
    }

    /// The toolbar would otherwise read a drag on the tab as a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closePressed() { onClose() }
}

/// A borderless icon button that fills lightly under the pointer.
@MainActor
final class HoverFillButton: NSButton {
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        refusesFirstResponder = true
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.06).setFill()
            let radius = min(bounds.width, bounds.height) / 2 > 10 ? 7 : bounds.height / 2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        super.draw(dirtyRect)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
