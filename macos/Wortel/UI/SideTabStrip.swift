import AppKit

/// A row of tabs: the side column's, the main area's, the bottom strip's.
///
/// Modelled on the ChatGPT app's workspace tabs, measured from its bundle and
/// its screen: the tab in front is a raised pill in the content's own colour
/// (white on the grey band, so it reads as the top of the page under it), with
/// a hairline edge and a soft shadow; the rest are just a glyph and grey text
/// that fill lightly on hover. A close button shows on the tab in front and the
/// one under the pointer. Each tab is as wide as its title wants, between
/// `minTabWidth` and `maxTabWidth`.
///
/// When they don't fit, they shrink together down to `minTabWidth` and then the
/// row **scrolls**, as ChatGPT's does: sideways, with the edge faded on the side
/// there's more, the tab in front always scrolled into view, and the "+" pinned
/// just past the visible end. Squeezing every tab to a sliver instead was the
/// row that read as a mess with six files open.
@MainActor
final class SideTabStrip: NSView {
    struct Item: Equatable {
        let tab: SideTab
        let title: String
        let symbol: String
        /// The session's own tab: never closed, no menu. It can still be dragged
        /// within its row.
        var pinned = false
        /// Where the tab is, for its hover card: a path, an address, a folder.
        var detail: String? = nil
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
    /// A glimpse of what's in a tab, for its hover card. Asked when the card
    /// opens.
    var preview: (SideTab) -> TabPreview? = { _ in nil }

    static let tabHeight: CGFloat = Chrome.controlSize
    /// How far a long title's tab gives way when the row is short of room:
    /// about a dozen characters of it still showing. A tab whose whole title
    /// fits in less (Files, History) is never widened to it or cut below its
    /// own width; past that, the row scrolls rather than shrinking tabs into
    /// initials.
    static let minTabWidth: CGFloat = 130
    static let maxTabWidth: CGFloat = 240
    private static let gap: CGFloat = 4
    private static let fade: CGFloat = 20

    /// A control that follows the last tab, as ChatGPT's "+" does: after the
    /// row rather than at the far edge, so it reads as "one more of these", and
    /// pinned at the visible end once the row scrolls.
    var trailingAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let trailingAccessory {
                trailingAccessory.translatesAutoresizingMaskIntoConstraints = true
                addSubview(trailingAccessory)
            }
            needsLayout = true
        }
    }

    /// Internal rather than private for TabStripTests, which check it never
    /// insets itself under the titlebar or scrolls vertically.
    let scroll = TabScrollView()
    private let content = FlippedView()
    private var items: [Item] = []
    private var active: SideTab?
    private var tabViews: [SideTabView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        // **Off, and it's the whole difference between a row that works and one
        // that doesn't.** A scroll view in a transparent titlebar reads the
        // titlebar as content it's scrolled under and insets itself by the
        // titlebar's height (40pt: the row's entire height). The tabs still
        // drew, but every click on them landed on the scroll view's own edge
        // effect instead: nothing selected, closed or dragged, the press moved
        // the window, and the row scrolled up and down by those 40pt.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = content
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Not itself a drag handle for the window: a click on empty strip is
    /// passed up to the titlebar row, which moves the window itself (see
    /// ChromeBarView).
    override var mouseDownCanMoveWindow: Bool { false }

    func update(items: [Item], active: SideTab?) {
        guard items != self.items || active != self.active else { return }
        let orderChanged = items.map(\.tab) != self.items.map(\.tab)
        let activeChanged = active != self.active
        let hadTabs = !tabViews.isEmpty && window != nil
        var inserted: [SideTabView] = []
        if orderChanged {
            // Reuse each tab's view by identity, so a reorder, an insert or a
            // close can slide the rest into place rather than redraw the row.
            var existing = Dictionary(tabViews.map { ($0.tab, $0) }, uniquingKeysWith: { a, _ in a })
            tabViews = items.map { item in
                if let view = existing.removeValue(forKey: item.tab) { return view }
                let view = makeView(for: item)
                inserted.append(view)
                return view
            }
            existing.values.forEach { $0.removeFromSuperview() }
        }
        self.items = items
        self.active = active
        for (view, item) in zip(tabViews, items) {
            view.configure(title: item.title, symbol: item.symbol, detail: item.detail,
                           isActive: item.tab == active)
        }
        // A divider between two quiet tabs only; the raised one is its own edge.
        for (index, view) in tabViews.enumerated() {
            let next = index + 1 < items.count ? items[index + 1].tab : nil
            view.showsTrailingDivider = next != nil && items[index].tab != active && next != active
        }
        if orderChanged, hadTabs {
            slideIntoPlace(fadingIn: inserted)
        } else {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        if orderChanged || activeChanged { revealActive(animated: hadTabs) }
    }

    /// A tab as it looks in front of a row on the band, for a drag that
    /// didn't start in a row: a preview window dragged back in by its own row
    /// (TabDragController.handleDock). Drawn by a real tab, put in `window`
    /// out of sight for the moment it takes, so it has the window's
    /// appearance and is the same picture a dragged tab's ghost is.
    static func picture(of item: Item, in window: NSWindow) -> NSImage? {
        guard let host = window.contentView else { return nil }
        let view = SideTabView(tab: item.tab, pinned: item.pinned)
        view.configure(title: item.title, symbol: item.symbol, detail: nil, isActive: true)
        let width = min(max(view.fittingWidth, minTabWidth), maxTabWidth)
        view.frame = NSRect(x: -10_000, y: 0, width: width, height: tabHeight)
        host.addSubview(view)
        defer { view.removeFromSuperview() }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return view.snapshot()
    }

    private func makeView(for item: Item) -> SideTabView {
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
        view.preview = { [weak self] in self?.preview(item.tab) }
        content.addSubview(view)
        return view
    }

    // MARK: Layout

    /// Everything the row needs for its current width: each tab's frame in the
    /// scrolling content, how wide the content and its visible window are, and
    /// where the "+" goes.
    private struct Plan {
        var tabs: [NSRect]
        var contentWidth: CGFloat
        var visibleWidth: CGFloat
        var accessory: NSRect?
    }

    private func plan() -> Plan {
        // Measured once: a fitting size is an Auto Layout solve.
        let accessorySize = trailingAccessory?.fittingSize
        let room = max(0, bounds.width - (accessorySize.map { $0.width + Self.gap * 2 } ?? 0))
        let gaps = Self.gap * CGFloat(max(tabViews.count - 1, 0))
        // Each tab as wide as its title, up to the maximum, and never
        // narrower than that title or the readable minimum, whichever is less.
        let natural = tabViews.map { min(ceil($0.fittingWidth), Self.maxTabWidth) }
        let floors = natural.map { min($0, Self.minTabWidth) }
        var widths = natural
        // Short of room, the tabs that can give way shrink together; one that
        // reaches its floor stays there and the rest take up the difference.
        // Once they're all at their floors, the row scrolls.
        let available = max(0, room - gaps)
        for _ in widths.indices where widths.reduce(0, +) > available {
            let giving = widths.indices.filter { widths[$0] > floors[$0] }
            let fixed = widths.indices.filter { widths[$0] <= floors[$0] }.map { widths[$0] }.reduce(0, +)
            let flexible = giving.map { widths[$0] }.reduce(0, +)
            guard flexible > 0 else { break }
            let scale = max(0, available - fixed) / flexible
            for i in giving { widths[i] = max(floors[i], (widths[i] * scale).rounded(.down)) }
        }
        var x: CGFloat = 0
        let y = ((bounds.height - Self.tabHeight) / 2).rounded()
        let frames = widths.map { width -> NSRect in
            defer { x += width + Self.gap }
            return NSRect(x: x, y: y, width: width, height: Self.tabHeight)
        }
        let contentWidth = (frames.last?.maxX ?? 0)
        let visibleWidth = min(contentWidth, room)
        var accessory: NSRect?
        if let size = accessorySize {
            accessory = NSRect(x: visibleWidth + Self.gap * 2, y: ((bounds.height - size.height) / 2).rounded(),
                               width: size.width, height: size.height)
        }
        return Plan(tabs: frames, contentWidth: contentWidth, visibleWidth: visibleWidth, accessory: accessory)
    }

    /// The width the row was last laid out at: narrowing it (a divider drag,
    /// a window resize) can put the tab in front out of view.
    private var laidOutWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let plan = plan()
        defer {
            if bounds.width != laidOutWidth {
                laidOutWidth = bounds.width
                revealActive(animated: false)
            }
        }
        scroll.frame = NSRect(x: 0, y: 0, width: plan.visibleWidth, height: bounds.height)
        content.frame = NSRect(x: 0, y: 0, width: max(plan.contentWidth, plan.visibleWidth),
                               height: bounds.height)
        for (view, frame) in zip(tabViews, plan.tabs) { view.frame = frame }
        if let frame = plan.accessory { trailingAccessory?.frame = frame }
        updateFade()
    }

    /// Tabs glide to their new places and new ones fade in, on the panes'
    /// curve: ChatGPT's tabs do the same over 150 to 180ms.
    private func slideIntoPlace(fadingIn inserted: [SideTabView]) {
        let plan = plan()
        content.frame.size.width = max(plan.contentWidth, plan.visibleWidth, content.frame.width)
        for (view, frame) in zip(tabViews, plan.tabs) where inserted.contains(where: { $0 === view }) {
            view.frame = frame
            view.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.tabs
            context.timingFunction = Motion.curve
            context.allowsImplicitAnimation = true
            for (view, frame) in zip(tabViews, plan.tabs) {
                if inserted.contains(where: { $0 === view }) {
                    view.animator().alphaValue = 1
                } else {
                    view.animator().frame = frame
                }
            }
            scroll.animator().frame = NSRect(x: 0, y: 0, width: plan.visibleWidth, height: bounds.height)
            if let frame = plan.accessory { trailingAccessory?.animator().frame = frame }
        } completionHandler: {
            MainActor.assumeIsolated { self.needsLayout = true }
        }
    }

    // MARK: Scrolling

    /// Scroll so the tab in front is in view, with a little room beside it.
    private func revealActive(animated: Bool) {
        guard let view = tabViews.first(where: { $0.tab == active }) else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        let wanted = view.frame.insetBy(dx: -Self.fade, dy: 0)
        var x = visible.origin.x
        if wanted.minX < visible.minX {
            x = wanted.minX
        } else if wanted.maxX > visible.maxX {
            x = wanted.maxX - visible.width
        }
        x = min(max(0, x), max(0, content.frame.width - visible.width))
        guard abs(x - visible.origin.x) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.tabs
                context.timingFunction = Motion.curve
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: x, y: 0))
        }
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled(_ notification: Notification) { updateFade() }

    /// Fade the edge the row continues past, so a cut-off tab reads as "more
    /// this way" rather than as a tab drawn wrong.
    private func updateFade() {
        let clip = scroll.contentView.bounds
        let hiddenLeading = clip.minX > 0.5
        let hiddenTrailing = clip.maxX < content.frame.width - 0.5
        guard hiddenLeading || hiddenTrailing, scroll.bounds.width > Self.fade * 2 else {
            scroll.layer?.mask = nil
            return
        }
        let mask = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        let edge = Self.fade / scroll.bounds.width
        let solid = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [hiddenLeading ? clear : solid, solid, solid, hiddenTrailing ? clear : solid]
        mask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        mask.frame = scroll.bounds
        scroll.layer?.mask = mask
        CATransaction.commit()
    }

    // MARK: Drops

    /// Where a tab dropped at `x` (window coordinates) would go: the insertion
    /// index among this strip's tabs, decided by which side of a tab's middle
    /// the pointer is on, and the x (window coordinates) to draw the marker at.
    func insertion(atWindowX x: CGFloat) -> (index: Int, markerX: CGFloat) {
        let local = content.convert(NSPoint(x: x, y: 0), from: nil).x
        for (index, view) in tabViews.enumerated() where local < view.frame.midX {
            let gapX = view.frame.minX - Self.gap / 2
            return (index, content.convert(NSPoint(x: gapX, y: 0), to: nil).x)
        }
        let end = (tabViews.last?.frame.maxX ?? 0) + Self.gap / 2
        return (tabViews.count, content.convert(NSPoint(x: end, y: 0), to: nil).x)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
}

/// The row's scroll view: a vertical wheel scrolls it sideways, since a row of
/// tabs has no other direction to go. A trackpad's sideways swipe already does.
@MainActor
final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        let room = document.frame.width - clip.bounds.width
        guard room > 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let x = min(max(0, clip.bounds.origin.x - step), room)
        clip.setBoundsOrigin(NSPoint(x: x, y: 0))
        reflectScrolledClipView(clip)
    }

    /// Titlebar, not a control: presses on its empty space move the window.
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A plain container with a top-left origin, for the tabs inside the scroll view.
@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
private final class SideTabView: NSControl, TabTitleProviding {
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
        layer?.cornerRadius = Chrome.controlRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        icon.symbolConfiguration = Chrome.glyph
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

    /// ChatGPT's tab metrics: 10pt in, a 16pt glyph box, 8pt to the title, and a
    /// 20pt close button 4pt from the end, room kept for it on every tab so
    /// hovering never moves a title.
    private static let inset: CGFloat = 10
    private static let glyph: CGFloat = 16
    private static let glyphGap: CGFloat = 8
    private static let closeSize: CGFloat = 20
    private static let closeGap: CGFloat = 4
    private static let endInset: CGFloat = 4

    /// The title's width as it will actually draw. Measured through the cell,
    /// which knows the label's own padding; the text's bare width is a few
    /// points short of it, and a label given only that truncates what fits.
    /// Measured when the title changes, not on every layout pass: every
    /// tab's width is asked for on each frame of a resize.
    private var titleWidth: CGFloat = 0

    private func measureTitle() {
        titleWidth = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width
                          ?? label.intrinsicContentSize.width)
    }

    private var symbol: String?

    /// What the tab would like to be: inset, glyph, title, close button.
    var fittingWidth: CGFloat {
        Self.inset + Self.glyph + Self.glyphGap + titleWidth
            + Self.closeGap + Self.closeSize + Self.endInset
    }

    /// Only what changed: a row is updated whole whenever any tab in it
    /// changes, and a terminal's title changes often.
    func configure(title: String, symbol: String, detail: String?, isActive: Bool) {
        if label.stringValue != title || titleWidth == 0 {
            label.stringValue = title
            measureTitle()
            needsLayout = true
        }
        if self.detail != detail {
            self.detail = detail
            setAccessibilityHelp(detail)
        }
        if self.symbol != symbol {
            self.symbol = symbol
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if self.isActive != isActive || !configured {
            self.isActive = isActive
            configured = true
            applyState()
        }
    }

    private var configured = false

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: Self.inset, y: (h - 18) / 2, width: Self.glyph, height: 18)
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
                // The strip's row is on the page; the main area's and the
                // column's are on the titlebar band, which is the window's
                // vibrancy.
                let fill = stripRegion() == .bottom ? Chrome.raised : Chrome.raisedOnBand
                layer.backgroundColor = fill.cgColor
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
    /// Where the tab is: the second line of its hover card.
    private var detail: String?
    var preview: () -> TabPreview? = { nil }

    var title: String { label.stringValue }
    /// Whether the title is cut short where it is.
    var isTitleTruncated: Bool { titleWidth > label.frame.width + 0.5 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        // The card decides when it opens whether it has anything the tab
        // doesn't already say.
        TabHoverCard.shared.enter(self, .init(title: label.stringValue, detail: detail, preview: preview))
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        TabHoverCard.shared.exit(self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { TabHoverCard.shared.exit(self) }
    }

    /// Select on mouse-down, as tabs do: a tab is picked, not clicked. Then
    /// track the mouse ourselves: past 6pt it's a drag (ChatGPT's threshold),
    /// handed on as it goes; released before that, it was just the pick.
    override func mouseDown(with event: NSEvent) {
        TabHoverCard.shared.dismiss(self)
        onSelect()
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        // Escape abandons a drag; the rest of it, to the mouse-up, is ignored.
        var cancelled = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            let point = next.locationInWindow
            if next.type == .keyDown {
                if next.keyCode == 53, dragging, !cancelled {
                    cancelled = true
                    onDrag(.cancelled, point)
                }
                continue
            }
            if next.type == .leftMouseUp {
                if dragging, !cancelled { onDrag(.ended, point) }
                return
            }
            if cancelled { continue }
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
        // Every other area this tab may go to.
        let destinations: [(TabRegion, String)] = [
            (.main, "Move to Main Area"), (.side, "Move to Side Column"), (.bottom, "Move to Bottom Strip"),
        ].filter { $0.0 != stripRegion() && tab.fits($0.0) }
        if !destinations.isEmpty { menu.addItem(.separator()) }
        for (region, title) in destinations {
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.onMove(region) })
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
