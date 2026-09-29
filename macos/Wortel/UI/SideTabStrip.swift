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
        /// Full view's session tab: always first, never closed or dragged.
        var pinned = false
    }

    enum DragPhase { case began, moved, ended, cancelled }

    /// Which region this strip is the tabs of. Decides what "Move to…" offers.
    var region: TabRegion = .side
    var onSelect: (SideTab) -> Void = { _ in }
    var onClose: (SideTab) -> Void = { _ in }
    var onCloseOthers: (SideTab) -> Void = { _ in }
    var onMove: (SideTab, TabRegion) -> Void = { _, _ in }
    /// A tab is being dragged; `point` is in window coordinates. The drag is
    /// resolved by whoever knows every strip and drop zone (TabDragController).
    var onDrag: (DragPhase, SideTab, NSView, NSPoint) -> Void = { _, _, _, _ in }

    static let tabHeight: CGFloat = 28
    static let minTabWidth: CGFloat = 90
    static let maxTabWidth: CGFloat = 240
    private static let gap: CGFloat = 4

    private var items: [Item] = []
    private var active: SideTab?
    private var tabViews: [SideTabView] = []

    override var isFlipped: Bool { true }

    /// Not itself a drag handle for the window: a click on empty strip is
    /// passed up to the titlebar row, which moves the window itself (see
    /// ChromeBarView). Saying yes here marked the tabs' own area as draggable.
    override var mouseDownCanMoveWindow: Bool { false }

    func update(items: [Item], active: SideTab?) {
        guard items != self.items || active != self.active else { return }
        if items.map(\.tab) != self.items.map(\.tab) {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = items.map { item in
                let view = SideTabView(tab: item.tab, pinned: item.pinned)
                view.onSelect = { [weak self] in self?.onSelect(item.tab) }
                view.onClose = { [weak self] in self?.onClose(item.tab) }
                view.onCloseOthers = { [weak self] in self?.onCloseOthers(item.tab) }
                view.onMove = { [weak self] region in self?.onMove(item.tab, region) }
                view.onDrag = { [weak self, weak view] phase, point in
                    guard let self, let view else { return }
                    self.onDrag(phase, item.tab, view, point)
                }
                view.stripRegion = { [weak self] in self?.region ?? .side }
                addSubview(view)
                return view
            }
        }
        self.items = items
        self.active = active
        for (view, item) in zip(tabViews, items) {
            view.configure(title: item.title, symbol: item.symbol, isActive: item.tab == active)
            view.needsLayout = true
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

    /// Where a tab dropped at `x` (window coordinates) would go: the insertion
    /// index among this strip's tabs, decided by which side of a tab's middle
    /// the pointer is on, and the x (window coordinates) to draw the marker at.
    func insertion(atWindowX x: CGFloat) -> (index: Int, markerX: CGFloat) {
        // Over the tabs that can move: a pinned tab holds its place and isn't
        // counted, so the index is one into the column's own list.
        let movable = tabViews.filter { !$0.pinned }
        let local = convert(NSPoint(x: x, y: 0), from: nil).x
        for (index, view) in movable.enumerated() where local < view.frame.midX {
            let gapX = view.frame.minX - Self.gap / 2
            return (index, convert(NSPoint(x: gapX, y: 0), to: nil).x)
        }
        let end = (tabViews.last?.frame.maxX ?? 0) + Self.gap / 2
        return (movable.count, convert(NSPoint(x: end, y: 0), to: nil).x)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
}

/// One tab: glyph, title, and the close button that appears on the tab in
/// front and on hover. Layer-drawn so the raised tab's shadow can fall outside
/// its bounds.
///
/// An NSControl, not a plain view, and that is the fix for dragging it. In a
/// transparent titlebar the window server moves the window from anywhere that
/// isn't a control (buttons are, which is why the titlebar's own buttons always
/// worked); `mouseDownCanMoveWindow` only speaks for AppKit's half of that
/// decision, so a plain view that says no still let the window take the drag.
@MainActor
private final class SideTabView: NSControl {
    let tab: SideTab
    let pinned: Bool
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onCloseOthers: () -> Void = {}
    var onMove: (TabRegion) -> Void = { _ in }
    var onDrag: (SideTabStrip.DragPhase, NSPoint) -> Void = { _, _ in }
    var stripRegion: () -> TabRegion = { .side }
    var showsTrailingDivider = false {
        didSet { divider.isHidden = !showsTrailingDivider }
    }

    private let icon = StationaryImageView()
    private let label = StationaryLabel(labelWithString: "")
    private let closeButton = HoverFillButton()
    private let divider = FilledView(color: Chrome.hairlineStrong)
    private var isActive = false
    private var hovering = false {
        didSet { if hovering != oldValue { applyState() } }
    }

    init(tab: SideTab, pinned: Bool = false) {
        self.tab = tab
        self.pinned = pinned
        super.init(frame: .zero)
        // A tab takes clicks, never the keyboard: that stays in the terminal.
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
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

    /// ChatGPT's tab metrics: 10pt in, a 14pt glyph, 8pt to the title, and a
    /// 20pt close button 4pt from the end, room kept for it on every tab so
    /// hovering never moves a title.
    private static let inset: CGFloat = 10
    private static let glyph: CGFloat = 14
    private static let glyphGap: CGFloat = 8
    private static let closeSize: CGFloat = 20
    private static let closeGap: CGFloat = 4
    private static let endInset: CGFloat = 4

    /// The title's width as it will actually draw. Measured through the cell,
    /// which knows the label's own padding; the text's bare width is a few
    /// points short of it, and a label given only that truncates what fits.
    private var titleWidth: CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width
             ?? label.intrinsicContentSize.width)
    }

    /// What the tab would like to be: inset, glyph, title, close button.
    var fittingWidth: CGFloat {
        Self.inset + Self.glyph + Self.glyphGap + titleWidth
            + Self.closeGap + Self.closeSize + Self.endInset
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
        icon.frame = NSRect(x: Self.inset, y: (h - 16) / 2, width: Self.glyph, height: 16)
        let closeX = bounds.width - Self.endInset - Self.closeSize
        closeButton.frame = NSRect(x: closeX, y: (h - Self.closeSize) / 2,
                                   width: Self.closeSize, height: Self.closeSize)
        let labelX = Self.inset + Self.glyph + Self.glyphGap
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: labelX, y: ((h - labelHeight) / 2).rounded(),
                             width: max(0, closeX - Self.closeGap - labelX), height: labelHeight)
        divider.frame = NSRect(x: bounds.width + 1.5, y: (h - 14) / 2, width: 1, height: 14)
    }

    private func applyState() {
        closeButton.isHidden = pinned || !(isActive || hovering)
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

    /// Select on mouse-down, as tabs do: a tab is picked, not clicked. Then
    /// track the mouse ourselves: past 6pt it's a drag (ChatGPT's threshold),
    /// handed on as it goes; released before that, it was just the pick.
    override func mouseDown(with event: NSEvent) {
        onSelect()
        guard !pinned, let window else { return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = next.locationInWindow
            if next.type == .leftMouseUp {
                if dragging { onDrag(.ended, point) }
                return
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 6 {
                dragging = true
                onDrag(.began, start)
            }
            if dragging { onDrag(.moved, point) }
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { super.otherMouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !pinned else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Close Tab") { [weak self] in self?.onClose() })
        menu.addItem(ClosureMenuItem(title: "Close Other Tabs") { [weak self] in self?.onCloseOthers() })
        // The other region, if this tab is allowed there.
        let other: TabRegion = stripRegion() == .side ? .bottom : .side
        if tab.fits(other) {
            menu.addItem(.separator())
            let title = other == .bottom ? "Move to Bottom" : "Move to Side Column"
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.onMove(other) })
        }
        return menu
    }

    /// A tab is a control, not titlebar: dragging it must not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole tab is one target, except its close button. In the titlebar
    /// the window moves when the view under a click allows it, and a label or
    /// an image view allows it by default: grabbing a tab by its title dragged
    /// the window instead of the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
        return self
    }

    @objc private func closePressed() { onClose() }
}

/// A label and an image view that never move the window. Both allow it by
/// default (they're not opaque), and in the titlebar that made a tab's title
/// and glyph handles for dragging the window rather than the tab.
private final class StationaryLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class StationaryImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { false }
}
