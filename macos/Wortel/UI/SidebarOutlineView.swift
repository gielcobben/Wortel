import AppKit
import Observation
import SwiftUI

/// Row view that draws the neutral selection pill at the *row* level, so
/// it spans the full sidebar width — across the chevron gutter and indentation
/// — like Mail's and Icon Composer's selection, instead of hugging the cell.
final class SidebarPillRowView: NSTableRowView, ContextMenuHost {
    /// How far the pill is inset from the row. Also what the close button keeps
    /// clear of the pill's edges, so its padding reads the same on all three
    /// sides it touches.
    static let pillInset = NSSize(width: 10, height: 1)
    /// The pill's corners: a tab's and a titlebar button's.
    static let pillRadius: CGFloat = 8
    /// A session row without a branch line (see `heightOfRowByItem`). The
    /// trailing slot's right clearance is measured on it, for every row.
    static let oneLineRowHeight: CGFloat = 30
    /// The room between two sections, under an open section's last row
    /// (`gapBelow`).
    static let sectionGap: CGFloat = 14
    /// The selected row's fill, and the hover's, over the sidebar material. The
    /// hover has to stay visibly lighter than the selection it isn't.
    static let pillAlpha: CGFloat = 0.08
    private static let hoverAlpha: CGFloat = 0.04
    /// The rest of a selection of several: the lead's grey at three quarters.
    /// The git panel's grey selection draws its other rows at 0.6 of the
    /// lead, but here that would land on the hover (0.04), and a row you
    /// ⌘-click must visibly change from how it looked under the pointer the
    /// moment before. So: plainly more than a hover, plainly less than the
    /// session on screen, and the same grey, because it is the same selection.
    private static let alsoSelectedAlpha: CGFloat = 0.06

    var showsPill = false {
        didSet {
            guard showsPill != oldValue else { return }
            needsDisplay = true
        }
    }
    /// Selected along with the session on screen (⌘-click, ⇧-click): the
    /// lighter pill. See `alsoSelectedAlpha`.
    var showsAlsoSelected = false {
        didSet { if showsAlsoSelected != oldValue { needsDisplay = true } }
    }
    /// Its name is being edited: the pill, with a thin accent edge, and the
    /// field transparent on it (SidebarRowContent). Not a white text box
    /// dropped into the list.
    var showsEditing = false {
        didSet { if showsEditing != oldValue { needsDisplay = true } }
    }
    /// A dragged session is hovering this folder header (drop-on: first in it).
    var showsDropHighlight = false {
        didSet { if showsDropHighlight != oldValue { needsDisplay = true } }
    }
    /// The pointer is over this row. Drawn as a very light fill in the pill's
    /// shape — enough to say *this* is the row the “×” would close, without
    /// competing with the pill of the selected one.
    private var showsHover = false {
        didSet { if showsHover != oldValue { needsDisplay = true } }
    }
    /// Its menu is open (right-click or "…"): lit as under the pointer, the
    /// header included, so it's clear which row the menu is about.
    private var showsMenuOpen = false {
        didSet { if showsMenuOpen != oldValue { needsDisplay = true } }
    }

    /// Room below the last row of a section, so sections stand apart while
    /// the rows inside one sit close. Kept out of the pill and the hover.
    var gapBelow: CGFloat = 0 {
        didSet { if gapBelow != oldValue { needsLayout = true; needsDisplay = true } }
    }
    /// The content's height, held while the gap moves to or from this row in
    /// an animated re-sort (`moveGaps`): the row's height eases, and without
    /// this the pill would jump by the gap and ease back.
    var heldContentHeight: CGFloat? {
        didSet { if heldContentHeight != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// The row without its gap: where the pill is, and what the pointer hovers.
    var contentRect: NSRect {
        let height = min(bounds.height, heldContentHeight ?? bounds.height - gapBelow)
        var rect = bounds
        if !isFlipped { rect.origin.y = bounds.maxY - height }
        rect.size.height = height
        return rect
    }

    /// The pill, and the box the close button is laid out against.
    private var pillRect: NSRect {
        contentRect.insetBy(dx: Self.pillInset.width, dy: Self.pillInset.height)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let rect = pillRect
        if showsEditing {
            NSColor.labelColor.withAlphaComponent(Self.pillAlpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: Self.pillRadius - 0.5, yRadius: Self.pillRadius - 0.5)
            edge.lineWidth = 1
            edge.stroke()
        } else if showsPill {
            // Grey, not accent. The sidebar never holds focus, so this is the
            // same situation as an unfocused source list, and the accent pill was
            // the loudest thing in the window: it drowned out the attention dots,
            // which are the colour in this list that actually means something.
            NSColor.labelColor.withAlphaComponent(Self.pillAlpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
        } else if showsAlsoSelected {
            NSColor.labelColor.withAlphaComponent(Self.alsoSelectedAlpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
        } else if showsDropHighlight {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
        } else if showsHover || showsMenuOpen {
            NSColor.labelColor.withAlphaComponent(Self.hoverAlpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
        }
    }

    // MARK: - Close button
    //
    // It lives on the *row* rather than in the cell view because only the row
    // shares the pill's geometry: the source-list style insets cell views from
    // the row, so "12pt from the cell's trailing edge" stops well short of the
    // pill's right edge — and a cell can't be clicked outside its own bounds.

    private let closeButton = SidebarCloseButton()
    /// "…": the session's menu (Rename, Pin, Mark as Unread…), the one
    /// right-click opens, for when you don't think to right-click. Beside the
    /// ×, on hover, as the ChatGPT app's rows have theirs.
    private let moreButton = SidebarCloseButton(symbol: "ellipsis", label: "More", pointSize: 10)
    /// "+" on a folder header: a new session in that folder.
    private let addButton = SidebarCloseButton(symbol: "plus", label: "New Session in Folder", pointSize: 10)
    private var makeMoreMenu: (() -> NSMenu)?
    /// The pointer came onto the row or left it.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// The row view left the outline (hover may not have been reported off).
    var onRemoved: () -> Void = {}
    /// Whether this row is a folder header with a "+".
    private var addable = false
    /// Pinned and Sessions: no "+", but a press folds them. Sessions has a
    /// "…" (its Sort By), in the slot "+" has on a folder.
    private var foldable = false
    func setFoldable() { foldable = true }
    /// The status dot / spinner, hosted here rather than in the row's SwiftUI
    /// content so it can share the button's slot exactly. Trailing-aligning it
    /// inside the cell instead left it further from the pill's edge than the
    /// button, because the source-list style insets cell views from the row.
    private let statusHost = NonInteractiveHostingView<AnyView>(rootView: AnyView(EmptyView()))
    /// Whether this row has anything to close — false for folder headers, which
    /// therefore stay bare on hover.
    private var closable = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        statusHost.sizingOptions = []
        addSubview(statusHost)
        closeButton.isHidden = true
        addSubview(closeButton)
        moreButton.isHidden = true
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        addSubview(moreButton)
        addButton.isHidden = true
        addSubview(addButton)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What the close button does. Session rows set this; folder headers don't.
    func setCloseAction(_ handler: @escaping () -> Void) {
        closeButton.onClick = handler
        closable = true
    }

    /// The menu "…" opens: the session's, or a folder header's.
    func setMoreMenu(_ make: @escaping () -> NSMenu) {
        makeMoreMenu = make
        needsLayout = true
    }

    /// What "+" does, and where it starts the session. Folder headers set this.
    func setAddAction(directory: String?, _ handler: @escaping () -> Void) {
        addButton.onClick = handler
        addButton.toolTip = directory.map { "New Session in \($0)" } ?? "New Session in Folder"
        addable = true
    }

    private func showMoreMenu() {
        guard let menu = makeMoreMenu?() else { return }
        // Its right edge on the button's, opening into the sidebar rather than
        // off across the terminal, as the titlebar's menus do. But never past
        // the row's leading edge: wider than the room to the button's left,
        // it hung off the window, so then it starts where the row does and
        // reaches past the button instead.
        let leading = moreButton.convert(NSPoint(x: pillRect.minX, y: 0), from: self).x
        let x = max(leading, moreButton.bounds.width - menu.size.width)
        contextMenu(isOpen: true)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: moreButton.bounds.maxY + 4), in: moreButton)
        contextMenu(isOpen: false)
    }

    func contextMenu(isOpen: Bool) {
        showsMenuOpen = isOpen
        // The pointer may have left while the menu had it, and the row never
        // heard: settle the hover on where it is now.
        guard !isOpen, let window else { return }
        setRowHovered(contentRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    /// The SwiftUI status indicator for this row. Session rows set one; folder
    /// headers leave the slot empty.
    func setStatusContent(_ content: AnyView) { statusHost.rootView = content }

    override func layout() {
        super.layout()
        let pill = pillRect
        let size = SidebarCloseButton.size
        // Equal clearance top, bottom and right on a one-line row, so the glyph
        // reads as inset from the pill rather than floating in the row. The
        // right clearance is that one-line row's whatever the row's height: a
        // two-line (worktree) row's taller pill would otherwise push its glyph
        // 7pt further in, out of the column every other row's sits in.
        let gap = max(0, (Self.oneLineRowHeight - 2 * Self.pillInset.height - size) / 2)
        // Backing-aligned: the sidebar's width isn't always integral, and a
        // circle on a half-pixel origin draws visibly lopsided.
        let slot = backingAlignedRect(
            NSRect(x: pill.maxX - gap - size, y: pill.midY - size / 2,
                   width: size, height: size),
            options: .alignAllEdgesNearest)
        // One centre for both, so hovering swaps the glyph without moving it.
        closeButton.frame = slot
        // The indicator's box is wider than the button's, about the same
        // centre: a working session that's also unread shows its ring beside
        // the dots, wider together than the button. It reaches toward the
        // title, which keeps clear of this slot anyway.
        statusHost.frame = slot.insetBy(dx: -6, dy: 0)
        // Beside × or "+"; in their slot on a row that has neither (Sessions).
        moreButton.frame = closable || addable ? slot.offsetBy(dx: -(size + 2), dy: 0) : slot
        addButton.frame = slot
    }

    /// AppKit inserts the cell view after ours, which would bury them. Keep both
    /// in front — the button so it can take its own clicks, the indicator so it
    /// isn't drawn behind the row's content.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        let ours: [NSView] = [statusHost, closeButton, moreButton, addButton]
        guard !ours.contains(where: { $0 === subview }) else { return }
        for view in ours where view.superview === self {
            addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: - Row hover
    //
    // Tracked here rather than in SwiftUI so the area spans the whole row
    // *including* the button: moving the pointer onto the “×” must not read as
    // leaving the row and yank it out from under the click.

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.inVisibleRect` keeps the area right as the list scrolls, so the rect
        // passed here is ignored. Moves are tracked too: the gap under a
        // section's last row is in the area but hovers nothing (`pointerMoved`).
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { setRowHovered(false) }

    private var isRowHovered = false

    /// Settle the hover on where the pointer is now. A scroll slides rows
    /// under a pointer that hasn't moved, and AppKit doesn't reliably tell a
    /// row it left then: rows the pointer passed over stayed lit (and, being
    /// hovered, held the sidebar's sort still). The scroller calls this on
    /// every row it shows, each time it scrolls.
    /// `pointerOverWindow`: no other window is between the pointer and this
    /// one, so a row under a covering window isn't counted as hovered.
    func settleHover(pointerOverWindow: Bool) {
        guard let window else { return }
        let inside = NSApp.isActive && pointerOverWindow
            && contentRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside != isRowHovered { setRowHovered(inside) }
    }

    private func pointerMoved(_ event: NSEvent) {
        let hovered = contentRect.contains(convert(event.locationInWindow, from: nil))
        // Most rows have no gap, and a move within one changes nothing.
        if hovered != isRowHovered || event.type == .mouseEntered { setRowHovered(hovered) }
    }

    private func setRowHovered(_ hovered: Bool) {
        isRowHovered = hovered
        // Toggled straight from the event rather than through the observation
        // loop, so the highlight and button track the pointer without a runloop
        // turn of lag.
        onHoverChanged(hovered)
        // Headers light up like session rows: they're controls too (a press
        // folds them; a folder's has its "…" and "+"), and a header that
        // stayed flat under the pointer read as a label.
        showsHover = hovered && (closable || addable || foldable)
        addButton.isHidden = !(hovered && addable)
        if !hovered { addButton.setHovering(false) }
        let shows = hovered && closable
        moreButton.isHidden = !(hovered && (closable || addable || foldable)) || makeMoreMenu == nil
        if moreButton.isHidden { moreButton.setHovering(false) }
        guard closeButton.isHidden == shows else { return }
        closeButton.isHidden = !shows
        // The two share one rect, so the indicator has to give it up rather than
        // sit under the button.
        statusHost.isHidden = shows
        if !shows {
            closeButton.setHovering(false)
            moreButton.setHovering(false)
        }
    }
}

/// A hosting view that never takes a click. The row's status indicator is pure
/// decoration sitting on top of the row, and the outline underneath has to stay
/// clickable and draggable through it — including in the instant between a click
/// arriving and the hover that would have swapped it for the close button.
final class NonInteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The trailing “×” on the session row the pointer is over.
///
/// Deliberately AppKit rather than part of the hosted SwiftUI content:
/// NSTableView routes a click anywhere over a cell to *itself* — that's how row
/// selection and drag-to-reorder start — and only lets a hit view keep the click
/// if `validateProposedFirstResponder` says so, which it won't for the row's
/// `NSHostingView`. A real NSButton claims exactly its own box (see the override
/// in `SidebarOutline`) and leaves the rest of the row to the outline.
final class SidebarCloseButton: NSButton {
    /// Diameter of the glyph's hover disc, and so of the button itself.
    static let size: CGFloat = 18

    var onClick: () -> Void = {}

    private var hovering = false
    private var hoverArea: NSTrackingArea?

    /// A row's small round button: "×" by default; "…" and "+" too.
    init(symbol: String = "xmark", label: String = "Close Session", pointSize: CGFloat = 9) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold))
        contentTintColor = .secondaryLabelColor
        toolTip = label
        target = self
        action = #selector(fire)
        // The terminal owns keyboard focus; closing a session must not take it.
        refusesFirstResponder = true
        wantsLayer = true
        setAccessibilityLabel(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick() }

    /// Radius from the live bounds rather than a constant, so the hover
    /// background is a true circle whatever height the row hands us.
    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.inVisibleRect` keeps the area correct as the row scrolls, so the
        // passed rect is ignored.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    /// A faint disc behind the glyph once the pointer is on the button itself —
    /// the row-level hover only decides whether the “×” is there at all.
    func setHovering(_ hovering: Bool) {
        guard hovering != self.hovering else { return }
        self.hovering = hovering
        applyHover()
    }

    private func applyHover() {
        guard hovering else {
            layer?.backgroundColor = nil
            return
        }
        let tint = NSColor.labelColor.withAlphaComponent(0.12)
        // labelColor is appearance-dependent, and `cgColor` resolves against
        // whatever appearance is current — which during event handling isn't
        // necessarily this view's.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.cgColor
        }
    }
}

/// The cell view hosting one row's SwiftUI content. It's an NSTableCellView
/// (not a bare NSHostingView) specifically so it can override
/// `draggingImageComponents` — which is where AppKit gets the drag image. The
/// default snapshot of the transparent hosted content is a see-through ghost;
/// this composites the content over an opaque card instead.
final class SidebarCellView: NSTableCellView {
    private let hosting: NSHostingView<AnyView>
    /// What a header's drag image paints, and a session's if its snapshot
    /// fails — set per-row in viewForItem.
    var dragTitle = ""
    var dragIsHeader = false

    private var bottom: NSLayoutConstraint!
    /// The section gap under the last row of a section (see
    /// `SidebarPillRowView.gapBelow`): part of the row, so it folds away with
    /// the section's rows, but outside the content.
    /// Animated, it eases with the row's height in the same group.
    func setGapBelow(_ gap: CGFloat, animated: Bool = false) {
        (animated ? bottom.animator() : bottom).constant = -gap
    }

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        bottom = hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(content: AnyView) { hosting.rootView = content }

    /// The drag image. A session is the row itself: its content snapshotted
    /// (the name, the colour bar, the glyph, a second line if it has one) on
    /// the selected pill, made opaque, so what you drag is what you picked up.
    /// It used to be a hand-drawn card with the name and the folder path under
    /// it, two lines for a row that shows one. A header keeps its hand-drawn
    /// title.
    ///
    /// The snapshot is taken here, at the start of the drag, and only drawn
    /// later; `cacheDisplay` captures SwiftUI text and shapes (checked: an
    /// earlier note here said it came out transparent, which no longer holds).
    /// The pill is filled opaque because the sidebar behind it is vibrancy,
    /// which a drag image can't carry: the window's background stands in.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let size = hosting.frame.size
        guard size.width > 0, size.height > 0 else { return [] }
        let title = dragTitle, isHeader = dragIsHeader
        let appearance = effectiveAppearance
        var snapshot: NSBitmapImageRep?
        if !isHeader, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            snapshot = rep
        }

        let component = NSDraggingImageComponent(key: .icon)
        component.frame = hosting.frame
        component.contents = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                if isHeader {
                    let card = rect.insetBy(dx: 8, dy: 3)
                    NSColor.textBackgroundColor.setFill()
                    NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: Chrome.sectionHeader]
                    (title as NSString).draw(at: NSPoint(x: card.minX + 10, y: card.midY - 8), withAttributes: attrs)
                    return
                }
                // The row's pill, where the row view draws it.
                let inset = SidebarPillRowView.pillInset
                let radius = SidebarPillRowView.pillRadius
                let pill = NSBezierPath(roundedRect: rect.insetBy(dx: inset.width, dy: inset.height),
                                        xRadius: radius, yRadius: radius)
                NSColor.windowBackgroundColor.setFill()
                pill.fill()
                NSColor.labelColor.withAlphaComponent(SidebarPillRowView.pillAlpha).setFill()
                pill.fill()
                if let snapshot {
                    pill.addClip()
                    snapshot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                  respectFlipped: true, hints: nil)
                } else {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                    (title as NSString).draw(at: NSPoint(x: 20, y: rect.midY - 8), withAttributes: attrs)
                }
            }
            return true
        }
        return [component]
    }
}

/// Our own drop insertion indicator: an accent line whose leading inset encodes
/// the drop depth (top level vs inside a folder), drawn as a plain layer so it's
/// crisp and never clipped by the outline's row drawing.
final class SidebarInsertionLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }
}

/// NSOutlineView subclass that notifies the coordinator when a drag leaves or
/// ends over it, so a stale drop highlight gets cleared.
final class SidebarOutline: NSOutlineView {
    var onDragEnd: (() -> Void)?
    /// A rename in the list was ended by a press elsewhere in it: the
    /// keyboard goes back to the session, as it does from Return or Esc.
    var onRenameLeft: (() -> Void)?

    /// Never the keyboard: the terminal has it (`docs/architecture/window-and-sidebar.md`).
    /// A table takes it on any press its own code handles, and a press that
    /// switched sessions only kept it with the terminal because the switch
    /// handed it there first. Every other press (the session already on
    /// screen, a folder's header, ⌘- and ⇧-click) left it in the list, which
    /// shows nothing for it, so typing went nowhere until the terminal was
    /// clicked (measured 2026-11-19). A rename field in a row is its own
    /// control and still takes it.
    override var acceptsFirstResponder: Bool { false }

    /// A row dragged out of this list: held over a window behind, that window
    /// comes forward (`SpringLoading`), so its sidebar can take the row.
    ///
    /// No `super`: NSTableView declares this (it is an NSDraggingSource) but
    /// doesn't implement it, so the call raised an unrecognized selector on
    /// every move, which AppKit swallows by ending the drag ("Ignoring
    /// exception raised by SidebarOutline during a dragging session").
    /// Session rows couldn't be dragged anywhere.
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        SpringLoading.hover(at: screenPoint)
    }

    /// Mouse-*down* on a folder header, outside the disclosure chevron.
    var onHeaderPressed: ((Any) -> Void)?
    /// Mouse-*down* on a session's row, a plain press: the switch happens
    /// here rather than on mouse-up (see `mouseDown`). Returns whether the
    /// press was taken as that: false for a header, or a row inside a
    /// selection of several, which wait for mouse-up.
    var onSessionPressed: ((Any) -> Bool)?

    /// Headers toggle on mouse-down, like the chevron beside them — which
    /// NSOutlineView drives from its own mouse-down tracking. The table's
    /// `action` fires only on mouse-up, after AppKit has ruled out a drag, so
    /// routing header clicks through it made the title lag the chevron.
    /// Clicks on the chevron itself are left to `super`.
    ///
    /// Every press toggles, `clickCount` regardless: headers have no
    /// double-click meaning, so filtering repeats would just make a fast second
    /// click on the title do nothing while the chevron kept toggling.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // A rename under way is ended by a press anywhere else in the list.
        // The list ended it by taking the keyboard, once; it refuses the
        // keyboard now, so the edit is ended here. Where the keyboard goes
        // after is decided below, once it is known what the press is.
        let editing = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        if editing { window?.makeFirstResponder(nil) }
        // The gap between two sections is no row's: a press there neither
        // selects the session above it nor starts a drag.
        if row >= 0, let rowView = rowView(atRow: row, makeIfNecessary: false) as? SidebarPillRowView,
           rowView.gapBelow > 0,
           !rowView.contentRect.contains(rowView.convert(point, from: self)) {
            if editing { onRenameLeft?() }
            return
        }
        // A press on a row's button ("+", "…", "×") is the button's, not a
        // header toggle.
        let onButton = window?.contentView?.hitTest(event.locationInWindow) is SidebarCloseButton
        if row >= 0, !onButton, let item = item(atRow: row),
           !frameOfOutlineCell(atRow: row).contains(point) {
            onHeaderPressed?(item)
        }
        // A plain press on a session switches to it now, as a click in
        // Finder's sidebar does. The table's `action` only fires on mouse-up,
        // once AppKit has ruled out a drag, which put however long the button
        // was held (115 ms a click on average, measured 2026-11-18) in front
        // of every switch. Dragging still works: the press selected the
        // session, and the drag takes it. ⌘ and ⇧ stay on mouse-up, as does
        // a second press. A press that ended a rename switches here too: the
        // edit is already over, and the switch puts the keyboard in the
        // session pressed, rather than in the one being left first.
        let plain = event.modifierFlags.intersection([.command, .shift, .control]).isEmpty
        var pressed = false
        if row >= 0, !onButton, plain, event.clickCount == 1, let item = item(atRow: row) {
            pressed = onSessionPressed?(item) ?? false
        }
        // A rename ended by anything else (a header, ⌘-click): back to the
        // session on screen.
        if editing, !pressed { onRenameLeft?() }
        super.mouseDown(with: event)
    }

    /// Let a row's close button keep its own clicks. NSTableView claims every
    /// click over a cell for selection and drag-to-reorder unless this says
    /// otherwise; the default answer for anything inside a cell view is no.
    /// No disclosure triangle on the left: the header draws its own chevron
    /// after the folder's name (SidebarHeaderContent), and a press anywhere on
    /// the header toggles it (`mouseDown`).
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// Every cell the full width of its row, so where text starts is the
    /// content's padding alone (SidebarRowContent, SidebarHeaderContent), not
    /// that plus the source list's inset plus the triangle's old gutter.
    /// Headers and rows then line up, as the ChatGPT app's do.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        rect(ofRow: row)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder,
                                                 for event: NSEvent?) -> Bool {
        if responder is SidebarCloseButton { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragEnd?()
    }

    /// No `super`: the SDK lets this compile as an override, but neither
    /// NSOutlineView, NSTableView nor NSView implements `draggingEnded:`
    /// (checked with `instancesRespond(to:)` on macOS 27, 2026-11-18). Calling
    /// up raised "unrecognized selector" at the end of every drag here, before
    /// `onDragEnd` could run.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragEnd?()
    }
}

/// The sidebar's scroller. While rows go on below its bottom edge, that edge
/// fades over 20pt into the bar under it (+ and ⓘ), as an overflowing tab row
/// fades (`SideTabStrip`): a row cut off hard there read as one drawn wrong,
/// a faded one as "more below". A list that fits keeps a crisp last row.
///
/// Kept current from the two places every change passes: `tile` (a resize,
/// rows added, folded or grown) and `reflectScrolledClipView` (a scroll),
/// which also settles each row's hover.
///
/// The mask takes away the vibrancy of everything under it: SwiftUI's
/// `.secondary`/`.tertiary` then draw as their raw vibrant grey, dark on the
/// dark glass. Greys in the list are NSColor's label colours for that reason.
final class SidebarScrollView: NSScrollView {
    static let fade: CGFloat = 20

    override func tile() {
        super.tile()
        updateFade()
    }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        updateFade()
        // Rows slid under a pointer that didn't move: see `settleHover`.
        guard let window, let outline = documentView as? NSOutlineView else { return }
        let over = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            == window.windowNumber
        outline.enumerateAvailableRowViews { rowView, _ in
            (rowView as? SidebarPillRowView)?.settleHover(pointerOverWindow: over)
        }
    }

    private func updateFade() {
        guard let document = documentView else { return }
        wantsLayer = true
        guard let layer else { return }
        let visible = contentView.documentVisibleRect
        // The outline is flipped: rows go on below while the visible rect
        // ends short of the document's height.
        let more = visible.maxY < document.frame.height - 0.5
        guard more, bounds.height > Self.fade * 2 else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        let edge = NSNumber(value: Double(Self.fade / bounds.height))
        let solid = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The bottom edge. AppKit lays a view's sublayers out in the view's
        // own coordinates (it sets the layer's `isGeometryFlipped` to undo
        // whatever its ancestors are), so this view's `isFlipped` decides.
        let bottom: CGFloat = isFlipped ? 1 : 0
        mask.startPoint = CGPoint(x: 0.5, y: bottom)
        mask.endPoint = CGPoint(x: 0.5, y: 1 - bottom)
        mask.colors = [clear, solid, solid]
        mask.locations = [0, edge, 1]
        mask.frame = layer.bounds
        layer.mask = mask
        CATransaction.commit()
    }
}

/// Identity snapshot of the sidebar's structure — which groups exist, in what
/// order, holding which sessions, and which of those are two lines tall. The
/// outline reloads only when this changes; everything visual (names, selection
/// pill, attention dots, inline rename) lives in the hosted SwiftUI row views
/// and updates live via Observation without touching the outline.
///
/// Height is the one visual fact that *can't* stay in the hosted view: the
/// outline asks for it per row and only re-asks on a reload. So the set of tall
/// rows is part of identity, and a session growing its branch line is a
/// structural change as far as the outline is concerned.
struct SidebarSnapshotGroup: Equatable {
    let folder: String?
    let sessionIDs: [UUID]
    let tallIDs: Set<UUID>
    /// The Pinned section (see `SidebarGroup.isPinned`).
    var isPinned = false
    /// `sessionIDs` in the section's Sort By order (`SessionManager.sortedOrder`),
    /// nil for Pinned and a Manual section. Only on the stored snapshot SwiftUI
    /// hands over: the coordinator draws by it, and the groups it draws carry
    /// none.
    var sortedIDs: [UUID]? = nil
}

/// The sidebar's session list as a native `NSOutlineView` — the same machinery
/// behind Mail's and Finder's sidebars — instead of a SwiftUI `List`.
///
/// Why: the sidebar needs *two-level* drag & drop — reorder sessions within a
/// group, refile them across groups, and rearrange whole folder sections — each
/// with a real insertion indicator, and with per-target validation (a folder
/// can only land between sections, never inside one). SwiftUI's List can't
/// express that; NSOutlineView does it natively via `validateDrop` retargeting.
///
/// Row content stays SwiftUI: each row hosts `SidebarRowContent` /
/// `SidebarHeaderContent` (ContentView.swift) in an `NSHostingView`, so the
/// selection pill, attention dots, and inline rename are the same views as before.
/// Which sections are folded. Passed in rather than only read from the manager
/// by the coordinator, so that a change to it alone (selecting into a folded
/// section unfolds it) updates the outline: SwiftUI only calls `updateNSView`
/// for state the view's own inputs depend on.
struct SidebarFolding: Equatable {
    let folders: Set<String>
    let pinned: Bool
    let loose: Bool
}

struct SidebarOutlineView: NSViewRepresentable {
    let manager: SessionManager
    /// The window this sidebar is in: its sessions are the rows, and its
    /// front session has the pill.
    let home: SessionWindow
    /// The sections in their stored (manual) order, each with its Sort By
    /// order. The coordinator decides the order they're drawn in (that, and
    /// `sortKeys` over it).
    let snapshot: [SidebarSnapshotGroup]
    let folding: SidebarFolding
    /// Where each unread session sorts while View ▸ Sort Unread First is on;
    /// nil while it's off. An input of its own so a dot coming or going
    /// reaches the outline.
    let sortKeys: [UUID: SidebarSort.Key]?

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager, home: home) }

    func makeNSView(context: Context) -> SidebarScrollView {
        let outline = SidebarOutline()
        outline.onDragEnd = { [weak coordinator = context.coordinator] in
            coordinator?.clearDropHighlight()
            coordinator?.hideInsertion()
            coordinator?.thawSoon()
        }
        outline.onHeaderPressed = { [weak coordinator = context.coordinator, weak outline] item in
            guard let outline else { return }
            coordinator?.headerPressed(item, in: outline)
        }
        outline.onSessionPressed = { [weak coordinator = context.coordinator] item in
            coordinator?.sessionPressed(item) ?? false
        }
        outline.onRenameLeft = { [weak manager] in manager?.returnKeyboardToSession() }
        outline.headerView = nil
        outline.focusRingType = .none
        outline.rowSizeStyle = .custom
        outline.style = .sourceList
        outline.usesAutomaticRowHeights = false
        outline.intercellSpacing = .zero
        outline.backgroundColor = .clear
        // Selection is drawn by the row view (the neutral pill), never by
        // AppKit — the native highlight changes with focus, and the sidebar
        // never has it: the terminal always does.
        outline.selectionHighlightStyle = .none
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.indentationPerLevel = 0
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false

        let column = NSTableColumn(identifier: .init("wortel.sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        // Single-click: select a session. Double-click: rename. Native
        // target/action, so clicks stay instant (no SwiftUI double-tap
        // disambiguation delay) — see wortel-sidebar-click-lag. Folder headers
        // don't come through here; they toggle on mouse-down (SidebarOutline).
        outline.action = #selector(Coordinator.rowClicked(_:))
        outline.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))

        // And folders from Finder, which open as ⌘O opens one.
        outline.registerForDraggedTypes([Coordinator.sessionDragType, Coordinator.folderDragType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // Nothing outside the app takes a session; let go out there, it gets
        // a window of its own (`draggingSession(_:endedAt:operation:)`).
        outline.setDraggingSourceOperationMask([], forLocal: false)
        // We draw our own insertion indicator (depth-aware, never clipped) —
        // see SidebarInsertionLine — so suppress AppKit's default drop feedback.
        outline.draggingDestinationFeedbackStyle = .none

        let insertion = SidebarInsertionLine()
        insertion.isHidden = true
        outline.addSubview(insertion)
        context.coordinator.insertionLine = insertion

        context.coordinator.outline = outline
        context.coordinator.observeSelection()
        context.coordinator.observeHover()

        let scroll = SidebarScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Tell the titlebar row whether rows are under it (SidebarBar).
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll] _ in
            MainActor.assumeIsolated {
                guard let scroll else { return }
                NotificationCenter.default.post(
                    name: SidebarBar.scrolledNotification, object: scroll.window,
                    userInfo: ["scrolled": scroll.documentVisibleRect.minY > 0.5])
            }
        }
        context.coordinator.apply(snapshot, sortKeys: sortKeys)
        return scroll
    }

    func updateNSView(_ nsView: SidebarScrollView, context: Context) {
        context.coordinator.apply(snapshot, sortKeys: sortKeys)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let sessionDragType = NSPasteboard.PasteboardType("com.gielcobben.wortel.session-drag")
        static let folderDragType = NSPasteboard.PasteboardType("com.gielcobben.wortel.folder-drag")

        /// Outline items need stable *object identity* across reloads (expansion
        /// state is tracked per item object), so both kinds are cached classes.
        final class FolderItem {
            let name: String
            init(name: String) { self.name = name }
        }
        /// The Pinned section's header: first at the root while anything is
        /// pinned. Folds like a folder; never dragged, no menu.
        final class PinnedItem {}
        /// The header over the sessions in no folder, so they read as a
        /// section of their own rather than stray rows under the last folder.
        /// There while any such session is, below the folders. Never dragged;
        /// its "…" holds its Sort By.
        /// It folds too, but its sessions are root rows rather than its
        /// children (every drop index at the root counts on that), so folding
        /// takes them out of the outline (`looseShown`) instead of collapsing.
        final class LooseHeaderItem {}

        final class SessionItem {
            let session: Session
            var id: Session.ID { session.id }
            init(session: Session) { self.session = session }
        }

        let manager: SessionManager
        let home: SessionWindow
        weak var outline: NSOutlineView?
        var scrollObserver: NSObjectProtocol?
        weak var insertionLine: SidebarInsertionLine?

        private var snapshot: [SidebarSnapshotGroup] = []
        private let pinnedItem = PinnedItem()
        private var pinnedItems: [SessionItem] = []
        private let looseHeader = LooseHeaderItem()
        /// The root level by index: Pinned's header, the folders, the
        /// Sessions header, the folderless rows (`SidebarRoot`). Every root
        /// index (a row's, a drop's, an insertion line's) goes through it.
        private var root: SidebarRoot {
            SidebarRoot(pinned: !pinnedItems.isEmpty, folders: folderItems.count,
                        loose: !looseItems.isEmpty, looseShown: shownLoose.count)
        }
        private var looseItems: [SessionItem] = []
        /// Whether the folderless sessions are in the outline: false while
        /// their section is folded. Every root index (rows, drops, the
        /// insertion line) counts `shownLoose`, the rows actually there.
        private var looseShown = true
        private var shownLoose: [SessionItem] { looseShown ? looseItems : [] }
        private var folderItems: [FolderItem] = []          // ordered, as rendered
        /// The sessions carrying a section gap (`gapBelow`): the last row of
        /// every section but the last. Rebuilt with the items.
        private var gapIDs: Set<Session.ID> = []
        /// Row views holding their content's height through a re-sort's
        /// animation (`moveGaps`).
        private var heldRows: [SidebarPillRowView] = []
        private var childrenByFolder: [String: [SessionItem]] = [:]
        private var folderCache: [String: FolderItem] = [:]
        private var sessionCache: [UUID: SessionItem] = [:]
        /// Suppresses expand/collapse persistence while *we* are the ones
        /// expanding items (reload/sync), so only user toggles are recorded.
        private var isSyncing = false
        /// The folder toggled by the last header press, kept until we know the
        /// press wasn't a drag. See `headerPressed`.
        private var pressedFolder: FolderItem?

        init(manager: SessionManager, home: SessionWindow) {
            self.manager = manager
            self.home = home
            super.init()
            // A hover left set as the app went to the back (the row never hears
            // the pointer leave while inactive) must not hold the order.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.thawSoon() }
            }
        }

        // MARK: Snapshot → outline

        /// The sections in their stored order, as SwiftUI last handed them over.
        private var manualSnapshot: [SidebarSnapshotGroup] = []
        /// Sort Unread First's keys, nil while it's off.
        private var sortKeys: [UUID: SidebarSort.Key]?
        /// What each section was last drawn as, keyed by `drawnKey`: what
        /// holds the selected row still, and the whole section while a click
        /// may be coming. Emptied when Sort Unread First is turned on or off,
        /// so turning it on sorts afresh rather than holding a row in a place
        /// it never had.
        private var drawnBefore: [String: SidebarSort.Drawn] = [:]
        private var unreadFirstWasOn = false
        /// The order was held (`isFrozen`) and may be behind: draw again once
        /// the pointer has gone.
        private var pendingThaw = false
        private var resignObserver: NSObjectProtocol?

        func apply(_ manual: [SidebarSnapshotGroup], sortKeys: [UUID: SidebarSort.Key]?) {
            manualSnapshot = manual
            self.sortKeys = sortKeys
            render()
        }

        /// A click may be on its way: the pointer is over a session row, or a
        /// button is down (a press, a drag). Rows must not move then, or the
        /// click lands on whatever slid under it. Only the sort waits; a row
        /// opening, closing or being dropped is drawn at once.
        private var isFrozen: Bool {
            (NSApp.isActive && manager.hoveredRowID != nil) || NSEvent.pressedMouseButtons != 0
        }

        private static func drawnKey(_ group: SidebarSnapshotGroup) -> String {
            group.isPinned ? "\u{1}pinned" : group.folder.map { "folder/" + $0 } ?? "\u{1}loose"
        }

        /// The sections in the order they're drawn: each by its Sort By
        /// choice, with Sort Unread First's band over it while that's on.
        private func drawnGroups() -> [SidebarSnapshotGroup] {
            if (sortKeys != nil) != unreadFirstWasOn {
                unreadFirstWasOn = sortKeys != nil
                drawnBefore = [:]
            }
            // Nothing sorted and no band: as stored, and nothing to hold.
            if sortKeys == nil, manualSnapshot.allSatisfy({ $0.sortedIDs == nil }) {
                drawnBefore = [:]
                return manualSnapshot
            }
            let keys = sortKeys ?? [:]
            let frozen = isFrozen
            if frozen { pendingThaw = true }
            var next: [String: SidebarSort.Drawn] = [:]
            let groups = manualSnapshot.map { group in
                let key = Self.drawnKey(group)
                let drawn = SidebarSort.draw(manual: group.sessionIDs, base: group.sortedIDs, keys: keys,
                                             previous: drawnBefore[key],
                                             holding: home.selectedID, frozen: frozen)
                next[key] = drawn
                return SidebarSnapshotGroup(folder: group.folder, sessionIDs: drawn.drawn,
                                            tallIDs: group.tallIDs, isPinned: group.isPinned)
            }
            drawnBefore = next
            return groups
        }

        /// Draw again after something that isn't SwiftUI's update (the
        /// selection moving, the pointer leaving). Skipped if the stored
        /// snapshot is behind the session list: SwiftUI's own update is then
        /// on its way, and drawing ids that have gone would misplace rows.
        private func redraw() {
            let live = Set(manager.sessions.map(\.id))
            guard manualSnapshot.allSatisfy({ $0.sessionIDs.allSatisfy(live.contains) }) else { return }
            render()
        }

        /// Once the pointer has been off the rows for a moment, catch up on
        /// whatever the sort held back. A moment, so crossing from one row to
        /// the next (out of one, into the other) doesn't count as leaving.
        func thawSoon() {
            guard pendingThaw else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.pendingThaw, !self.isFrozen else { return }
                self.pendingThaw = false
                self.redraw()
            }
        }

        func observeHover() {
            withObservationTracking {
                _ = manager.hoveredRowID
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.manager.hoveredRowID == nil { self.thawSoon() }
                    self.observeHover()
                }
            }
        }

        private func render() {
            guard let outline else { return }
            let new = drawnGroups()
            defer { publishRows() }
            // Only rows growing or shrinking a line (a session starting or
            // stopping waiting): ease the heights instead of reloading, so the
            // row opens and closes rather than the list jumping.
            if new != snapshot, Self.sameStructure(new, snapshot) {
                let changed = Set(new.flatMap(\.tallIDs)).symmetricDifference(snapshot.flatMap(\.tallIDs))
                snapshot = new
                let rows = IndexSet(changed.compactMap { id in
                    sessionCache[id].map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil }
                })
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.tabs
                    context.timingFunction = Motion.curve
                    outline.noteHeightOfRows(withIndexesChanged: rows)
                }
                syncExpansion()
                return
            }
            // The same sessions in each section, drawn in another order: the
            // sort moved them. Slide the rows, as the outline moves any row,
            // rather than reloading the lot.
            if new != snapshot, Self.sameMembers(new, snapshot) {
                reorder(to: new)
                syncExpansion()
                return
            }
            if new != snapshot {
                snapshot = new
                rebuildItems()
                isSyncing = true
                outline.reloadData()
                isSyncing = false
            }
            syncExpansion()
        }

        /// The same sections holding the same sessions, in any order.
        private static func sameMembers(_ a: [SidebarSnapshotGroup], _ b: [SidebarSnapshotGroup]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy {
                $0.folder == $1.folder && $0.isPinned == $1.isPinned
                    && $0.sessionIDs.count == $1.sessionIDs.count && Set($0.sessionIDs) == Set($1.sessionIDs)
            }
        }

        /// Move rows within their sections to the drawn order `new`, with the
        /// outline's own row-move animation, quick: the rows keep their views
        /// (and so their pills, dots and hover) and slide to their places.
        ///
        /// Each step brings the row that belongs at `i` up from below, so a
        /// move is always upward, where `moveItem`'s target index means the
        /// same before and after the removal.
        private func reorder(to new: [SidebarSnapshotGroup]) {
            guard let outline else { return }
            let old = snapshot
            let changedTall = Set(new.flatMap(\.tallIDs)).symmetricDifference(old.flatMap(\.tallIDs))
            let oldGaps = gapIDs
            snapshot = new
            rebuildItems(resetLoose: false)
            let changedGaps = oldGaps.symmetricDifference(gapIDs)
            var folded: [Any] = []
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.tabs
                context.timingFunction = Motion.curve
                outline.beginUpdates()
                for (before, after) in zip(old, new) where before.sessionIDs != after.sessionIDs {
                    let parent: Any?
                    let offset: Int
                    if after.isPinned {
                        guard outline.isItemExpanded(pinnedItem) else { folded.append(pinnedItem); continue }
                        parent = pinnedItem
                        offset = 0
                    } else if let name = after.folder, let folder = folderCache[name] {
                        guard outline.isItemExpanded(folder) else { folded.append(folder); continue }
                        parent = folder
                        offset = 0
                    } else {
                        // Folded Sessions: its rows aren't in the outline.
                        guard looseShown else { continue }
                        parent = nil
                        offset = root.firstLoose
                    }
                    var working = before.sessionIDs
                    for (i, id) in after.sessionIDs.enumerated() {
                        guard let j = working.firstIndex(of: id), j != i else { continue }
                        outline.moveItem(at: offset + j, inParent: parent, to: offset + i, inParent: parent)
                        working.insert(working.remove(at: j), at: i)
                    }
                }
                outline.endUpdates()
                if !changedTall.isEmpty || !changedGaps.isEmpty {
                    var rows = IndexSet(changedTall.compactMap { id in
                        sessionCache[id].map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil }
                    })
                    rows.formUnion(moveGaps(changedGaps, in: outline))
                    outline.noteHeightOfRows(withIndexesChanged: rows)
                }
            }, completionHandler: {
                MainActor.assumeIsolated {
                    for rowView in self.heldRows { rowView.heldContentHeight = nil }
                    self.heldRows = []
                }
            })
            // A folded section has no rows to slide: just let it re-read its
            // children for when it opens.
            isSyncing = true
            for item in folded { outline.reloadItem(item, reloadChildren: true) }
            isSyncing = false
        }

        /// Tell the manager which sessions are drawn, top to bottom: the rows a
        /// ⇧-click's range runs over, and the selection pruned to them.
        private func publishRows() {
            guard let outline else { return }
            var ids: [UUID] = []
            ids.reserveCapacity(outline.numberOfRows)
            for row in 0..<outline.numberOfRows {
                if let session = outline.item(atRow: row) as? SessionItem { ids.append(session.id) }
            }
            home.sidebarRowOrder = ids
            // A turn later: this runs inside SwiftUI's update, and the ⌘
            // numbers and the selection are observed state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.manager.noteDrawnRows(self.home.sidebarRowOrder, in: self.home)
                guard self.manager.sidebarSelection.isMultiple else { return }
                self.manager.pruneSidebarSelection(toDrawn: self.home.sidebarRowOrder, in: self.home)
            }
        }

        /// The same groups holding the same sessions in the same order: only
        /// which rows are two lines tall differs.
        private static func sameStructure(_ a: [SidebarSnapshotGroup], _ b: [SidebarSnapshotGroup]) -> Bool {
            // Pinned is a group with no folder, like the loose sessions: pinning
            // the only loose session changes nothing else, and must still reload.
            a.count == b.count && zip(a, b).allSatisfy {
                $0.folder == $1.folder && $0.isPinned == $1.isPinned && $0.sessionIDs == $1.sessionIDs
            }
        }

        private func rebuildItems(resetLoose: Bool = true) {
            let byID = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0) })
            pinnedItems = []
            looseItems = []
            folderItems = []
            childrenByFolder = [:]
            for group in snapshot {
                let items: [SessionItem] = group.sessionIDs.compactMap { id in
                    guard let session = byID[id] else { return nil }
                    if let cached = sessionCache[id] { return cached }
                    let item = SessionItem(session: session)
                    sessionCache[id] = item
                    return item
                }
                if group.isPinned {
                    pinnedItems = items
                } else if let folder = group.folder {
                    let item = folderCache[folder] ?? {
                        let item = FolderItem(name: folder)
                        folderCache[folder] = item
                        return item
                    }()
                    folderItems.append(item)
                    childrenByFolder[folder] = items
                } else {
                    looseItems = items
                }
            }
            let sections = (pinnedItems.isEmpty ? [] : [pinnedItems])
                + folderItems.map { childrenByFolder[$0.name] ?? [] }
                + (looseItems.isEmpty ? [] : [looseItems])
            gapIDs = Set(sections.dropLast().compactMap { $0.last?.id })
            if resetLoose { looseShown = !manager.looseCollapsed }
            let liveIDs = Set(snapshot.flatMap(\.sessionIDs))
            sessionCache = sessionCache.filter { liveIDs.contains($0.key) }
            let liveFolders = Set(snapshot.compactMap(\.folder))
            folderCache = folderCache.filter { liveFolders.contains($0.key) }
        }

        /// Bring the outline's expansion state in line with the manager's
        /// persisted collapsed set (after reloads, and when a move auto-expands
        /// its target folder).
        private func syncExpansion() {
            guard let outline else { return }
            isSyncing = true
            if !pinnedItems.isEmpty {
                let open = !manager.pinnedCollapsed
                if open, !outline.isItemExpanded(pinnedItem) { outline.expandItem(pinnedItem) }
                if !open, outline.isItemExpanded(pinnedItem) { outline.collapseItem(pinnedItem) }
            }
            setLooseShown(!manager.looseCollapsed, animated: false)
            for item in folderItems {
                let shouldBeExpanded = !manager.isFolderCollapsed(item.name)
                if shouldBeExpanded, !outline.isItemExpanded(item) {
                    outline.expandItem(item)
                } else if !shouldBeExpanded, outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                }
            }
            isSyncing = false
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return root.count }
            if item is PinnedItem { return pinnedItems.count }
            if let folder = item as? FolderItem { return childrenByFolder[folder.name]?.count ?? 0 }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                switch root.slot(at: index) {
                case .pinnedHeader: return pinnedItem
                case .folder(let i): return folderItems[i]
                case .looseHeader: return looseHeader
                case .loose(let i): return shownLoose[i]
                case nil: preconditionFailure("root index \(index) past \(root.count)")
                }
            }
            if item is PinnedItem { return pinnedItems[index] }
            let folder = item as! FolderItem
            return childrenByFolder[folder.name]![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is FolderItem || item is PinnedItem
        }


        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let content: AnyView
            let cell: SidebarCellView
            if let session = item as? SessionItem {
                content = AnyView(SidebarRowContent(manager: manager, session: session.session))
                cell = SidebarCellView(content: content)
                cell.dragTitle = session.session.leafName
                cell.setGapBelow(gapBelow(item))
            } else if item is PinnedItem || item is LooseHeaderItem {
                content = AnyView(SidebarSectionHeaderContent(manager: manager, isPinned: item is PinnedItem))
                cell = SidebarCellView(content: content)
                return cell
            } else if let folder = item as? FolderItem {
                content = AnyView(SidebarHeaderContent(manager: manager, folder: folder.name))
                cell = SidebarCellView(content: content)
                cell.dragTitle = folder.name
                cell.dragIsHeader = true
            } else {
                return nil
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            // A worktree session named for its task carries its branch on a
            // second line (see `Session.showsBranchLine`).
            // Roomier than a Finder list, as the ChatGPT app's is: a session
            // row is something you read and pick all day, not scan past.
            // Sections apart, rows close, as the ChatGPT app's are: the gap
            // goes under a section's last row, and a row's pill nearly
            // touches the next.
            let oneLine = SidebarPillRowView.oneLineRowHeight
            if let session = (item as? SessionItem)?.session, session.hasSecondLine { return 44 + gapBelow(item) }
            return oneLine + gapBelow(item)
        }

        /// The room under a section, carried by its last row: none under the
        /// last section, and none under a folded or empty one, whose rows
        /// aren't there to carry it. Folded sections stack as close as rows,
        /// and the gap folds in the same animation as the rows. (It was the
        /// room above the next header, which then had to change height beside
        /// the fold, and the two animations made the title jump.)
        private func gapBelow(_ item: Any?) -> CGFloat {
            guard let session = item as? SessionItem, gapIDs.contains(session.id) else { return 0 }
            return SidebarPillRowView.sectionGap
        }

        /// A row's rect without the gap it carries (the outline is flipped, so
        /// the gap is the bottom). Every drop and line goes by this, not by
        /// `rect(ofRow:)`, so the gap between sections belongs to no row.
        private func contentRect(ofRow row: Int) -> NSRect {
            guard let outline, row >= 0 else { return .zero }
            var rect = outline.rect(ofRow: row)
            rect.size.height -= gapBelow(outline.item(atRow: row))
            return rect
        }

        /// Where the section starting at header `row` begins for a line or a
        /// drop: right under the content above it, at the top of the gap.
        private func sectionTop(ofRow row: Int) -> CGFloat {
            guard let outline else { return 0 }
            return row > 0 ? contentRect(ofRow: row - 1).maxY : outline.rect(ofRow: row).minY
        }

        /// Rows that keep their views through a re-sort (`reorder`) and gained
        /// or lost a section's last place: their gap eases in the move's
        /// animation group, with their height (the rows returned).
        /// Their row views hold their content's height until the animation
        /// ends (`heldRows`, released by `reorder`).
        private func moveGaps(_ ids: Set<Session.ID>, in outline: NSOutlineView) -> IndexSet {
            var rows = IndexSet()
            for id in ids {
                guard let item = sessionCache[id] else { continue }
                let row = outline.row(forItem: item)
                guard row >= 0 else { continue }
                rows.insert(row)
                if let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarPillRowView {
                    rowView.heldContentHeight = rowView.contentRect.height
                    rowView.gapBelow = gapBelow(item)
                    heldRows.append(rowView)
                }
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView)?
                    .setGapBelow(gapBelow(item), animated: true)
            }
            return rows
        }

        /// Row views draw the selection pill (full row width, across the
        /// chevron gutter and indentation — Mail-style) and carry the hover close
        /// button, which needs that same full-width geometry. See
        /// SidebarPillRowView.
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let rowView = SidebarPillRowView()
            rowView.showsPill = showsPill(item)
            rowView.showsAlsoSelected = showsAlsoSelected(item)
            rowView.showsEditing = showsEditing(item)
            rowView.gapBelow = gapBelow(item)
            if item is PinnedItem || item is LooseHeaderItem { rowView.setFoldable() }
            if item is LooseHeaderItem {
                let manager = self.manager
                rowView.setMoreMenu { SectionSortMenu.menu(forFolder: nil, manager: manager) }
            }
            if let folder = item as? FolderItem {
                let manager = self.manager, name = folder.name
                let directory = manager.root(ofFolder: name).map { ($0 as NSString).abbreviatingWithTildeInPath }
                rowView.setAddAction(directory: directory) { manager.newSession(inFolder: name, starting: .preferred) }
                rowView.setMoreMenu { FolderActions.menu(for: name, manager: manager) }
            }
            guard let session = item as? SessionItem else { return rowView }

            let manager = self.manager, target = session.session
            rowView.setCloseAction { manager.requestClose(target) }
            rowView.setMoreMenu { SessionActions.menu(for: target, manager: manager) }
            let id = target.id
            rowView.onHoverChanged = { hovered in
                if target.isSidebarRowHovered != hovered { target.isSidebarRowHovered = hovered }
                if hovered {
                    if manager.hoveredRowID != id { manager.hoveredRowID = id }
                } else if manager.hoveredRowID == id {
                    manager.hoveredRowID = nil
                }
            }
            // A row view that goes away under the pointer never hears
            // mouseExited; see outlineView(_:didRemove:forRow:).
            rowView.onRemoved = { if target.isSidebarRowHovered { target.isSidebarRowHovered = false } }
            rowView.setStatusContent(
                AnyView(SessionStatusIndicator(manager: manager, session: target)))
            return rowView
        }

        /// Row views are made fresh for every item and never reused, so a flag
        /// can't carry over to another session. But one removed while hovered
        /// (reload, close, archive) gets no mouseExited, so settle its flag here.
        func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
            (rowView as? SidebarPillRowView)?.onRemoved()
        }

        private func showsPill(_ item: Any) -> Bool {
            guard let session = item as? SessionItem else { return false }
            // While renaming, the row draws its editing pill instead.
            return home.selectedID == session.id && manager.editingID != session.id
        }

        /// In a selection of several, and not the lead (which has the pill).
        private func showsAlsoSelected(_ item: Any) -> Bool {
            guard let session = item as? SessionItem, manager.sidebarSelection.isMultiple else { return false }
            return manager.sidebarSelection.ids.contains(session.id) && home.selectedID != session.id
                && manager.editingID != session.id
        }

        private func showsEditing(_ item: Any) -> Bool {
            guard let session = item as? SessionItem else { return false }
            return manager.editingID == session.id
        }

        /// Re-render the selection pill whenever selection or rename state
        /// changes. The hosted SwiftUI cells track Observation
        /// on their own; the AppKit row views need this explicit loop.
        func observeSelection() {
            withObservationTracking {
                _ = home.selectedID
                _ = manager.editingID
                _ = manager.sidebarSelection
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshSelection()
                    // Under the sort, which row holds still follows the
                    // selection: the one you left may move now.
                    if self.sortKeys != nil { self.redraw() }
                    self.observeSelection() // re-arm; tracking is one-shot
                }
            }
        }

        private func refreshSelection() {
            guard let outline else { return }
            for row in 0..<outline.numberOfRows {
                guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false)
                        as? SidebarPillRowView,
                      let item = outline.item(atRow: row) else { continue }
                rowView.showsPill = showsPill(item)
                rowView.showsAlsoSelected = showsAlsoSelected(item)
                rowView.showsEditing = showsEditing(item)
            }
        }

        // MARK: Clicks & selection

        /// The outline never *holds* a selection — a click just tells the
        /// manager, and the hosted row draws the accent pill from that state.
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            false
        }

        /// A plain press on a session's row: switch now, on mouse-down. Not
        /// when the row is part of a selection of several, as in Finder: the
        /// press may be the start of dragging them all, and mouse-up
        /// (`rowClicked`) narrows it to the one if it wasn't.
        func sessionPressed(_ item: Any) -> Bool {
            guard let item = item as? SessionItem,
                  !manager.isInMultipleSelection(item.session) else { return false }
            pressed(item.id)
            pressHandled = item.id
            return true
        }

        /// The session a mouse-down already acted on, so its mouse-up does
        /// not act again: a second hand-back of the keyboard is a second
        /// focus report to the program, or a waking terminal given it before
        /// it is shown.
        private var pressHandled: Session.ID?

        /// A plain press on a session: switch to it, or, if it is the one on
        /// screen already, back into its terminal. Nothing switches then, so
        /// nothing else would give the terminal the keyboard.
        private func pressed(_ id: Session.ID) {
            let switches = home.selectedID != id
            manager.clickSidebarRow(id, .plain)
            if !switches { manager.returnKeyboardToSession() }
        }

        @objc func rowClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            // Folders already toggled on mouse-down; doing it again here (on
            // mouse-up) would undo it.
            guard row >= 0 else { return }
            guard let session = sender.item(atRow: row) as? SessionItem else { return }
            let click = Self.click(NSApp.currentEvent?.modifierFlags ?? [])
            let handled = pressHandled == session.id
            pressHandled = nil
            // ⌘ toggles the row in or out of the selection, ⇧ takes the range
            // from the anchor over the rows as drawn; neither moves the
            // terminal (see `SessionSelection`). A plain click is one row,
            // already acted on at mouse-down unless it was inside a selection
            // of several.
            if click == .plain {
                if !handled { pressed(session.id) }
            } else {
                manager.clickSidebarRow(session.id, click)
            }
        }

        private static func click(_ modifiers: NSEvent.ModifierFlags) -> SessionManager.SidebarClick {
            if modifiers.contains(.command) { return .toggle }
            if modifiers.contains(.shift) { return .extend }
            return .plain
        }

        /// Whole-header press toggles the section, on mouse-down so it matches
        /// the chevron. If the press turns out to be the start of a drag,
        /// `draggingSession:willBeginAt:` undoes it.
        func headerPressed(_ item: Any, in outline: NSOutlineView) {
            if item is PinnedItem {
                if outline.isItemExpanded(pinnedItem) {
                    outline.animator().collapseItem(pinnedItem)
                } else {
                    outline.animator().expandItem(pinnedItem)
                }
                return
            }
            if item is LooseHeaderItem {
                manager.setLooseCollapsed(!manager.looseCollapsed)
                setLooseShown(!manager.looseCollapsed, animated: true)
                return
            }
            guard let folder = item as? FolderItem else { return }
            pressedFolder = folder
            toggle(folder, in: outline)
        }

        @objc func rowDoubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            // Sessions rename on double-click. Headers have no double-click
            // meaning at all — each press just toggles them, and rename lives in
            // their context menu.
            guard row >= 0, let session = sender.item(atRow: row) as? SessionItem
            else { return }
            // Two quick ⌘- or ⇧-clicks are two selection clicks, not a rename.
            guard Self.click(NSApp.currentEvent?.modifierFlags ?? []) == .plain else { return }
            manager.selectedID = session.id
            manager.editingID = session.id
        }

        /// Put the folderless sessions in the outline or take them out, sliding
        /// as a folder's rows do. Called on a press, and to follow the stored
        /// state after a reload.
        private func setLooseShown(_ show: Bool, animated: Bool) {
            guard looseShown != show else { return }
            looseShown = show
            guard let outline, !looseItems.isEmpty else { return }
            // Right after the Sessions header, the last thing at the root.
            let first = root.firstLoose
            let rows = IndexSet(integersIn: first..<(first + looseItems.count))
            if show {
                outline.insertItems(at: rows, inParent: nil, withAnimation: animated ? .slideDown : [])
            } else {
                outline.removeItems(at: rows, inParent: nil, withAnimation: animated ? .slideUp : [])
            }
            publishRows()
        }

        private func toggle(_ folder: FolderItem, in outline: NSOutlineView) {
            if outline.isItemExpanded(folder) {
                outline.animator().collapseItem(folder)
            } else {
                outline.animator().expandItem(folder)
            }
        }

        /// Persist user-driven expand/collapse (chevron or header click). The
        /// `isSyncing` guard keeps programmatic sync from echoing back.
        func outlineViewItemDidExpand(_ notification: Notification) {
            publishRows()
            guard !isSyncing else { return }
            if notification.userInfo?["NSObject"] is PinnedItem { manager.setPinnedCollapsed(false); return }
            guard let folder = notification.userInfo?["NSObject"] as? FolderItem else { return }
            manager.setFolder(folder.name, collapsed: false)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            // Rows folded out of sight leave the selection.
            publishRows()
            guard !isSyncing else { return }
            if notification.userInfo?["NSObject"] is PinnedItem { manager.setPinnedCollapsed(true); return }
            guard let folder = notification.userInfo?["NSObject"] as? FolderItem else { return }
            manager.setFolder(folder.name, collapsed: true)
        }

        // MARK: Drag source

        /// A header press turned out to be the start of a drag — undo the toggle
        /// it did on mouse-down, so reordering a section doesn't also collapse
        /// it. Unanimated: this is a correction, not a transition.
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            defer { pressedFolder = nil }
            guard let folder = pressedFolder,
                  draggedItems.contains(where: { ($0 as AnyObject) === folder }) else { return }
            if outlineView.isItemExpanded(folder) {
                outlineView.collapseItem(folder)
            } else {
                outlineView.expandItem(folder)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            let pb = NSPasteboardItem()
            if let session = item as? SessionItem {
                // A row in the selection drags the whole selection, in the
                // order drawn; any other row drags itself.
                let ids = manager.isInMultipleSelection(session.session)
                    ? manager.sidebarSelectedSessions.map(\.id) : [session.id]
                pb.setString(ids.map(\.uuidString).joined(separator: "\n"), forType: Self.sessionDragType)
                return pb
            }
            if let folder = item as? FolderItem {
                pb.setString(folder.name, forType: Self.folderDragType)
                return pb
            }
            return nil
        }

        /// Sessions let go of outside every Wortel window go to a new window
        /// there, as a tab torn out of Safari does. Let go over a window of
        /// ours (a drop refused, or back where it began) is not out.
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            SpringLoading.end()
            guard operation.isEmpty,
                  let ids = session.draggingPasteboard.string(forType: Self.sessionDragType).map(Self.ids),
                  !ids.isEmpty,
                  !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) })
            else { return }
            // A turn later: the drag is still unwinding, and a window made
            // inside it is ordered behind the one the drag began in.
            DispatchQueue.main.async { [manager] in
                if manager.moveSessions(ids, toWindow: nil, topLeft: screenPoint) != nil {
                    Telemetry.capture(.sessionMovedWindow(via: .dragOut))
                }
            }
        }

        // MARK: Drop validation
        //
        // Targets are computed from the pointer's Y, not AppKit's proposed
        // item/index — the proposal flip-flops between "on the header" and "in
        // the gap" right at section boundaries, which is what made the folder
        // indicator jitter. Position-based targeting is stable and smooth.

        /// The directories among the file URLs on a drag from outside.
        static func directories(on pasteboard: NSPasteboard) -> [String] {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }.map(\.path)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let outline else { return [] }
            let pb = info.draggingPasteboard
            let point = outline.convert(info.draggingLocation, from: nil)

            // Folders from Finder: no insertion line, they're filed where ⌘O
            // would file them.
            if !Self.directories(on: pb).isEmpty {
                clearDropHighlight()
                hideInsertion()
                outline.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            }

            // Reorder folder sections: insertion line always between sections.
            if pb.string(forType: Self.folderDragType) != nil {
                clearDropHighlight()
                let target = folderDropTarget(at: point)
                outline.setDropItem(nil, dropChildIndex: target)
                showInsertion(parent: nil, index: target)
                return .move
            }

            // Move / refile a session.
            if let dragged = pb.string(forType: Self.sessionDragType) {
                let drop = sessionDropTarget(at: point)
                // Into a section that sorts itself, from inside it: there is
                // no place to put it but the one it has.
                if drop.index == NSOutlineViewDropOnItemIndex || drop.onFolder != nil,
                   drop.parent == nil, sortsItself(drop.onFolder?.name),
                   Self.ids(dragged).allSatisfy({ id in
                       manager.sessions.first { $0.id == id }.map {
                           $0.folderPath == drop.onFolder?.name && !manager.isPinned($0)
                               && manager.window(of: $0) === home
                       } ?? true
                   }) {
                    hideInsertion()
                    clearDropHighlight()
                    return []
                }
                if let folder = drop.onFolder {
                    // Drop *onto* a folder header → first in it + highlight the row.
                    hideInsertion()
                    setDropHighlight(folder)
                    outline.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else if drop.parent == nil, drop.index == NSOutlineViewDropOnItemIndex {
                    // Into Sessions while it sorts itself: the header lights
                    // up as a folder's does, and there's no line.
                    hideInsertion()
                    setDropHighlight(looseHeader)
                    outline.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else if drop.parent is PinnedItem, drop.index == NSOutlineViewDropOnItemIndex {
                    // Onto a folded Pinned's header: AppKit marks the header.
                    hideInsertion()
                    clearDropHighlight()
                    outline.setDropItem(pinnedItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else {
                    clearDropHighlight()
                    outline.setDropItem(drop.parent, dropChildIndex: drop.index)
                    // Into the Sessions section: inset as in any section.
                    showInsertion(parent: drop.parent, index: drop.index,
                                  nested: drop.parent != nil || !looseItems.isEmpty)
                }
                return .move
            }
            return []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            clearDropHighlight()
            hideInsertion()
            let pb = info.draggingPasteboard

            let folders = Self.directories(on: pb)
            if !folders.isEmpty {
                folders.forEach { manager.openFolder($0, starting: .preferred) }
                return true
            }

            if let folder = pb.string(forType: Self.folderDragType) {
                guard item == nil else { return false }
                manager.moveFolder(folder, toFolderIndex: root.folderIndex(forDrop: index))
                return true
            }
            if let ids = pb.string(forType: Self.sessionDragType).map(Self.ids) {
                let byID = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0) })
                let moving = ids.compactMap { byID[$0] }
                guard !moving.isEmpty else { return false }
                let movingIDs = Set(moving.map(\.id))
                // From another window's sidebar: into this window first, the
                // terminals with them, then placed as any drop is.
                let foreign = moving.filter { manager.window(of: $0) !== home }
                if !foreign.isEmpty, manager.moveSessions(foreign.map(\.id), toWindow: home) != nil {
                    Telemetry.capture(.sessionMovedWindow(via: .drag))
                }
                // Where it lands is named by the row drawn just below the drop
                // line (not a dragged one), or nil for the end of the section.
                // An index would mean something else in the stored order than
                // on screen once Sort Unread First is on; the row below is the
                // same row in both. Dropping still writes the stored order.
                func below(_ index: Int, in items: [SessionItem]) -> Session.ID? {
                    guard index != NSOutlineViewDropOnItemIndex, index >= 0 else { return nil }
                    return items.dropFirst(index).first { !movingIDs.contains($0.id) }?.id
                }
                // Onto a section's header: first in it, where the eye already
                // is. First as stored, not as drawn: with Sort Unread First on,
                // the top row drawn can be anywhere in the stored order.
                func top(pinned: Bool, folder: String? = nil) -> Session.ID? {
                    manager.sidebarGroups(in: home)
                        .first { $0.isPinned == pinned && (pinned || $0.folder == folder) }?
                        .sessions.first { !movingIDs.contains($0.id) }?.id
                }
                // Into Pinned: pinned there, folders kept.
                if item is PinnedItem {
                    let before = index == NSOutlineViewDropOnItemIndex || overSectionHeader
                        ? top(pinned: true) : below(index, in: pinnedItems)
                    manager.setPinned(moving, true, before: before)
                    return true
                }
                // Anywhere else: out of Pinned, and where it was dropped.
                if let folder = item as? FolderItem {
                    let children = childrenByFolder[folder.name] ?? []
                    let before = index == NSOutlineViewDropOnItemIndex
                        ? top(pinned: false, folder: folder.name) : below(index, in: children)
                    manager.moveSessions(moving.map(\.id), toFolder: folder.name,
                                         before: before, unpin: true)
                } else if item == nil {
                    // Onto the Sessions header, folded or open: at the top,
                    // as a drop on a folder header lands. Into it while it
                    // sorts itself, the same: it is drawn by its sort anyway.
                    let before = looseShown && !overSectionHeader && index != NSOutlineViewDropOnItemIndex
                        ? below(root.looseIndex(forDrop: index), in: shownLoose) : top(pinned: false)
                    manager.moveSessions(moving.map(\.id), toFolder: nil, before: before, unpin: true)
                } else {
                    return false
                }
                return true
            }
            return false
        }

        /// The session ids a drag carries.
        static func ids(_ dragged: String) -> [UUID] {
            dragged.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
        }

        /// The section of `folder` (nil: Sessions) is drawn by its own sort,
        /// so a drop goes into it, not to a place in it.
        private func sortsItself(_ folder: String?) -> Bool {
            manager.sectionSort(ofFolder: folder) != .manual
        }

        /// Nearest gap between folder sections, as a root child index from
        /// the first folder's to just past the last one's. Folders sit between
        /// Pinned and Sessions, and a folder never goes above or below them.
        private func folderDropTarget(at point: NSPoint) -> Int {
            guard let outline else { return 0 }
            let root = self.root, folders = folderItems.count
            let end = root.rootIndex(ofFolder: folders)
            guard folders > 0 else { return end }
            var boundaries: [(y: CGFloat, target: Int)] = []
            for (i, item) in folderItems.enumerated() {
                let row = outline.row(forItem: item)
                if row >= 0 { boundaries.append((sectionTop(ofRow: row), root.rootIndex(ofFolder: i))) }
            }
            // Past the last folder: over the Sessions header, or under the
            // last row when there is none.
            let headerRow = root.looseHeader != nil ? outline.row(forItem: looseHeader) : -1
            if headerRow >= 0 {
                boundaries.append((sectionTop(ofRow: headerRow), end))
            } else if outline.numberOfRows > 0 {
                boundaries.append((outline.rect(ofRow: outline.numberOfRows - 1).maxY, end))
            }
            return boundaries.min { abs($0.y - point.y) < abs($1.y - point.y) }?.target ?? end
        }

        /// Where a dragged session should land. `onFolder` non-nil = drop onto
        /// that folder header (append); otherwise insert at (`parent`, `index`).
        /// Into Sessions while it sorts itself is (nil, `NSOutlineViewDropOnItemIndex`):
        /// a section with its own order has no places, only itself.
        /// Whether the drag is over the open Pinned or Sessions header, where a
        /// drop goes first as stored, as on a folder's. Their drop index is the
        /// same as above their first row, which goes by the row drawn below it.
        private var overSectionHeader = false

        private func sessionDropTarget(at point: NSPoint) -> (parent: Any?, index: Int, onFolder: FolderItem?) {
            overSectionHeader = false
            guard let outline, outline.numberOfRows > 0 else { return (nil, 0, nil) }
            let hovered = outline.row(at: point)
            let root = self.root
            let topLevelEnd = root.count
            // Below every row, with no folderless sessions yet: the empty
            // space under the list is where the Sessions section will be, so
            // a drop there takes the session out of its folder.
            if hovered < 0, looseItems.isEmpty, point.y > outline.rect(ofRow: outline.numberOfRows - 1).maxY {
                return (nil, topLevelEnd, nil)
            }
            // Otherwise below the last row → append after the last row's context.
            let row = hovered >= 0 ? hovered : outline.numberOfRows - 1
            guard let item = outline.item(atRow: row) else { return (nil, topLevelEnd, nil) }
            let content = contentRect(ofRow: row)
            let topHalf = hovered >= 0 && point.y < content.midY

            // With no folderless sessions, two more places take a session out
            // of its folder, both at the top, so they're there however long
            // the list is (the space under it is gone once it overflows): the
            // gap under Pinned's last row, and the top edge of the first
            // folder's header when nothing is open above it. The line is
            // drawn there, over the first folder (`root.firstFolder`).
            if looseItems.isEmpty, hovered >= 0 {
                if point.y >= content.maxY, let session = item as? SessionItem, session === pinnedItems.last {
                    return (nil, root.firstFolder, nil)
                }
                let rowsAbove = row > 0 && outline.item(atRow: row - 1) is SessionItem
                if let folder = item as? FolderItem, folder === folderItems.first, !rowsAbove,
                   point.y < outline.rect(ofRow: row).minY + outline.rect(ofRow: row).height * 0.34 {
                    return (nil, root.firstFolder, nil)
                }
            }

            // Onto a section's header: first in it, as onto a folder's. Pinned
            // folded, onto the header itself: there are no rows to put a line
            // between.
            if item is PinnedItem {
                overSectionHeader = true
                return outline.isItemExpanded(pinnedItem)
                    ? (pinnedItem, 0, nil)
                    : (pinnedItem, NSOutlineViewDropOnItemIndex, nil)
            }
            // Onto the Sessions header: out of any folder, first.
            if item is LooseHeaderItem {
                overSectionHeader = true
                if sortsItself(nil) { return (nil, NSOutlineViewDropOnItemIndex, nil) }
                return (nil, root.firstLoose, nil)
            }
            if let folder = item as? FolderItem {
                return (nil, 0, folder) // onto the header → first in the folder
            }
            if let session = item as? SessionItem,
               let i = pinnedItems.firstIndex(where: { $0 === session }) {
                return (pinnedItem, topHalf ? i : i + 1, nil)
            }
            if let session = item as? SessionItem {
                if let parent = session.session.folderPath, let parentItem = folderCache[parent] {
                    // A folder that sorts itself takes the drop as its header would.
                    if sortsItself(parent) { return (nil, 0, parentItem) }
                    let i = childrenByFolder[parent]?.firstIndex { $0 === session } ?? 0
                    return (parentItem, topHalf ? i : i + 1, nil)
                }
                if sortsItself(nil) { return (nil, NSOutlineViewDropOnItemIndex, nil) }
                let i = shownLoose.firstIndex { $0 === session } ?? 0
                return (nil, root.rootIndex(ofLoose: topHalf ? i : i + 1), nil)
            }
            return (nil, topLevelEnd, nil)
        }

        // MARK: Drop highlight

        /// The header lit up under a drag: a folder's, or Sessions' while it
        /// sorts itself.
        private var dropHighlight: AnyObject?

        private func setDropHighlight(_ header: AnyObject?) {
            guard dropHighlight !== header else { return }
            let previous = dropHighlight
            dropHighlight = header
            applyDropHighlight(previous)
            applyDropHighlight(header)
        }

        func clearDropHighlight() { setDropHighlight(nil) }

        // MARK: Insertion indicator

        /// Show the depth-aware insertion line for a drop at (`parent`, `index`).
        /// A `nil` parent is a top-level / between-sections drop (shallow inset);
        /// a folder parent is one level deep (extra inset), so the line makes the
        /// target level obvious.
        private func showInsertion(parent: Any?, index: Int, nested: Bool = false) {
            guard let outline, let line = insertionLine else { return }
            let leading: CGFloat = nested ? 28 : 12
            let width = max(0, outline.bounds.width - leading - 10)
            let height: CGFloat = 3
            // Clamp to at least y=1 so a top-of-list line is never clipped.
            let y = max(1, insertionY(parent: parent, index: index) - height / 2)
            line.frame = NSRect(x: leading, y: y, width: width, height: height)
            line.layer?.cornerRadius = height / 2 // fully rounded pill ends
            line.isHidden = false
            outline.addSubview(line) // keep it above the row views
        }

        func hideInsertion() { insertionLine?.isHidden = true }

        /// The y (top, flipped coords) of the gap where a drop at (`parent`,
        /// `index`) would land.
        private func insertionY(parent: Any?, index: Int) -> CGFloat {
            guard let outline else { return 0 }
            func topOfRow(_ row: Int) -> CGFloat { outline.rect(ofRow: row).minY }
            // Under the row, not under its gap: the line stays with the
            // section it drops into.
            func bottomOfRow(_ row: Int) -> CGFloat { contentRect(ofRow: row).maxY }

            if parent is PinnedItem {
                if index < pinnedItems.count { return topOfRow(outline.row(forItem: pinnedItems[index])) }
                if let last = pinnedItems.last { return bottomOfRow(outline.row(forItem: last)) }
                return bottomOfRow(outline.row(forItem: pinnedItem))
            }
            if let folder = parent as? FolderItem {
                let children = childrenByFolder[folder.name] ?? []
                if index < children.count {
                    return topOfRow(outline.row(forItem: children[index]))
                }
                if let last = children.last {
                    return bottomOfRow(outline.row(forItem: last))
                }
                return bottomOfRow(outline.row(forItem: folder)) // empty folder
            }
            // Top-level: root children are the Pinned header (when there is
            // one), the folders, the Sessions header, then the loose rows.
            let lastRow = outline.numberOfRows - 1
            switch root.slot(at: index) {
            case .folder(let i):
                return sectionTop(ofRow: outline.row(forItem: folderItems[i]))
            case .looseHeader:
                return sectionTop(ofRow: outline.row(forItem: looseHeader))
            case .loose(let i):
                return topOfRow(outline.row(forItem: shownLoose[i]))
            case .pinnedHeader, nil:
                return lastRow >= 0 ? bottomOfRow(lastRow) : 0
            }
        }

        private func applyDropHighlight(_ header: AnyObject?) {
            guard let outline, let header else { return }
            let row = outline.row(forItem: header)
            guard row >= 0,
                  let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarPillRowView
            else { return }
            rowView.showsDropHighlight = (header === dropHighlight)
        }
    }
}
