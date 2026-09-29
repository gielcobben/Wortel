import AppKit

/// The side column's tabs, drawn in the column's own titlebar row.
///
/// Modelled on the ChatGPT app's workspace tabs, measured from its bundle and
/// its screen: the tab in front is a raised pill in the content's own colour
/// (white on the grey band, so it reads as the top of the page under it), with
/// a hairline edge and a soft shadow; the rest are just a glyph and grey text
/// that fill lightly on hover. A close button shows on the tab in front and the
/// one under the pointer. Each tab is as wide as its title wants, between
/// `minTabWidth` and `maxTabWidth`, and when the row runs out of room they
/// shrink together rather than one of them disappearing.
///
/// The "+" is not part of the strip: it sits at the row's trailing end, where
/// ChatGPT keeps it, so it doesn't move as tabs open and close.
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

    static let tabHeight: CGFloat = 28
    static let minTabWidth: CGFloat = 90
    static let maxTabWidth: CGFloat = 240
    private static let gap: CGFloat = 4

    private var items: [Item] = []
    private var active: SideTab?
    private var tabViews: [SideTabView] = []

    override var isFlipped: Bool { true }

    /// Empty space in the strip is titlebar: it drags the window.
    override var mouseDownCanMoveWindow: Bool { true }

    func update(items: [Item], active: SideTab?) {
        guard items != self.items || active != self.active else { return }
        if items.map(\.tab) != self.items.map(\.tab) {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = items.map { item in
                let view = SideTabView(tab: item.tab)
                view.onSelect = { [weak self] in self?.onSelect(item.tab) }
                view.onClose = { [weak self] in self?.onClose(item.tab) }
                view.onCloseOthers = { [weak self] in self?.onCloseOthers(item.tab) }
                addSubview(view)
                return view
            }
        }
        self.items = items
        self.active = active
        for (view, item) in zip(tabViews, items) {
            view.configure(title: item.title, symbol: item.symbol, isActive: item.tab == active)
        }
        // A divider between two quiet tabs only; the raised one is its own edge.
        for (index, view) in tabViews.enumerated() {
            let next = index + 1 < items.count ? items[index + 1].tab : nil
            view.showsTrailingDivider = next != nil && items[index].tab != active && next != active
        }
        needsLayout = true
    }

    /// Each tab's width: what its title wants, clamped, then shrunk evenly when
    /// the row would run past the strip.
    private func tabWidths() -> [CGFloat] {
        let wanted = tabViews.map { min(max($0.fittingWidth, Self.minTabWidth), Self.maxTabWidth) }
        let room = bounds.width - Self.gap * CGFloat(max(tabViews.count - 1, 0))
        let total = wanted.reduce(0, +)
        guard total > room, !wanted.isEmpty, room > 0 else { return wanted }
        let floor: CGFloat = 44
        let scale = room / total
        return wanted.map { max(floor, ($0 * scale).rounded(.down)) }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let y = ((bounds.height - Self.tabHeight) / 2).rounded()
        for (view, width) in zip(tabViews, tabWidths()) {
            view.frame = NSRect(x: x, y: y, width: width, height: Self.tabHeight)
            x += width + Self.gap
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
}

/// One tab: glyph, title, and the close button that appears on the tab in
/// front and on hover. Layer-drawn so the raised tab's shadow can fall outside
/// its bounds.
@MainActor
private final class SideTabView: NSView {
    let tab: SideTab
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onCloseOthers: () -> Void = {}
    var showsTrailingDivider = false {
        didSet { divider.isHidden = !showsTrailingDivider }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = HoverFillButton()
    private let divider = FilledView(color: Chrome.hairlineStrong)
    private var isActive = false
    private var hovering = false {
        didSet { if hovering != oldValue { applyState() } }
    }

    init(tab: SideTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.toolTip = "Close Tab"
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        divider.isHidden = true
        [icon, label, closeButton, divider].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// What the tab would like to be: inset, glyph, title, close button.
    var fittingWidth: CGFloat {
        12 + 16 + 7 + ceil(label.intrinsicContentSize.width) + 6 + 18 + 6
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
        icon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        let closeX = bounds.width - 6 - 18
        closeButton.frame = NSRect(x: closeX, y: (h - 18) / 2, width: 18, height: 18)
        let labelX: CGFloat = 12 + 16 + 7
        let labelHeight = ceil(label.intrinsicContentSize.height)
        // The title keeps the close button's room whether or not it shows, so
        // hovering a tab never moves its text.
        label.frame = NSRect(x: labelX, y: ((h - labelHeight) / 2).rounded(),
                             width: max(0, closeX - 6 - labelX), height: labelHeight)
        divider.frame = NSRect(x: bounds.width + 1.5, y: (h - 14) / 2, width: 1, height: 14)
    }

    private func applyState() {
        closeButton.isHidden = !(isActive || hovering)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        icon.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isActive {
                layer.backgroundColor = Chrome.raised.cgColor
                layer.borderWidth = 0.5
                layer.borderColor = Chrome.hairlineStrong.cgColor
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = 0.06
                layer.shadowRadius = 1.5
                layer.shadowOffset = CGSize(width: 0, height: -1)
            } else {
                layer.backgroundColor = hovering ? Chrome.hoverFill.cgColor : nil
                layer.borderWidth = 0
                layer.shadowOpacity = 0
            }
        }
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

    /// A tab is a control, not titlebar: dragging it must not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closePressed() { onClose() }
}
