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
    /// A dragged session is hovering this folder header (drop-on / append).
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

    /// Room above a section header, so sections stand apart while the rows
    /// inside one sit close. Kept out of the pill, the hover and the "+".
    var sectionGap: CGFloat = 0 {
        didSet { if sectionGap != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// The pill, and the box the close button is laid out against.
    private var pillRect: NSRect {
        var rect = bounds
        rect.size.height -= sectionGap
        if isFlipped { rect.origin.y += sectionGap }
        return rect.insetBy(dx: Self.pillInset.width, dy: Self.pillInset.height)
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
    /// "…": the session's menu (Rename, Move To, Mark as Unread…), the one
    /// right-click opens, for when you don't think to right-click. Beside the
    /// ×, on hover, as the ChatGPT app's rows have theirs.
    private let moreButton = SidebarCloseButton(symbol: "ellipsis", label: "More", pointSize: 10)
    /// "+" on a folder header: a new session in that folder.
    private let addButton = SidebarCloseButton(symbol: "plus", label: "New Session in Folder", pointSize: 10)
    private var makeMoreMenu: (() -> NSMenu)?
    /// The pointer came onto the row or left it.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// Whether this row is a folder header with a "+".
    private var addable = false
    /// Pinned and Sessions: no "+" or "…", but a press folds them.
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
    func setMoreMenu(_ make: @escaping () -> NSMenu) { makeMoreMenu = make }

    /// What "+" does, and where it starts the session. Folder headers set this.
    func setAddAction(directory: String?, _ handler: @escaping () -> Void) {
        addButton.onClick = handler
        addButton.toolTip = directory.map { "New Session in \($0)" } ?? "New Session in Folder"
        addable = true
    }

    private func showMoreMenu() {
        guard let menu = makeMoreMenu?() else { return }
        // Its right edge on the button's, opening into the sidebar rather than
        // off across the terminal, as the titlebar's menus do.
        let x = moreButton.bounds.width - menu.size.width
        contextMenu(isOpen: true)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: moreButton.bounds.maxY + 4), in: moreButton)
        contextMenu(isOpen: false)
    }

    func contextMenu(isOpen: Bool) {
        showsMenuOpen = isOpen
        // The pointer may have left while the menu had it, and the row never
        // heard: settle the hover on where it is now.
        guard !isOpen, let window else { return }
        setRowHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    /// The SwiftUI status indicator for this row. Session rows set one; folder
    /// headers leave the slot empty.
    func setStatusContent(_ content: AnyView) { statusHost.rootView = content }

    override func layout() {
        super.layout()
        let pill = pillRect
        let size = SidebarCloseButton.size
        // Equal clearance top, bottom and right, so the glyph reads as inset from
        // the pill rather than floating in the row.
        let gap = max(0, (pill.height - size) / 2)
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
        moreButton.frame = slot.offsetBy(dx: -(size + 2), dy: 0)
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
        // passed here is ignored.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setRowHovered(true) }
    override func mouseExited(with event: NSEvent) { setRowHovered(false) }

    private func setRowHovered(_ hovered: Bool) {
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
        moreButton.isHidden = !(hovered && (closable || addable)) || makeMoreMenu == nil
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

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return [] }
        let title = dragTitle, isHeader = dragIsHeader
        let appearance = effectiveAppearance
        var snapshot: NSBitmapImageRep?
        if !isHeader, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            snapshot = rep
        }

        let component = NSDraggingImageComponent(key: .icon)
        component.frame = NSRect(origin: .zero, size: size)
        component.contents = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                if isHeader {
                    let card = rect.insetBy(dx: 8, dy: 3)
                    NSColor.textBackgroundColor.setFill()
                    NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.tertiaryLabelColor]
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
    /// Mouse-*down* on a folder header, outside the disclosure chevron.
    var onHeaderPressed: ((Any) -> Void)?

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
        // A press on a row's button ("+", "…", "×") is the button's, not a
        // header toggle.
        let onButton = window?.contentView?.hitTest(event.locationInWindow) is SidebarCloseButton
        if row >= 0, !onButton, let item = item(atRow: row),
           !frameOfOutlineCell(atRow: row).contains(point) {
            onHeaderPressed?(item)
        }
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

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragEnd?()
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
    /// The sections in their stored (manual) order. The coordinator decides
    /// the order they're drawn in (`sortKeys`).
    let snapshot: [SidebarSnapshotGroup]
    let folding: SidebarFolding
    /// Where each unread session sorts while View ▸ Sort Unread First is on;
    /// nil while it's off. An input of its own so a dot coming or going
    /// reaches the outline.
    let sortKeys: [UUID: SidebarSort.Key]?

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

    func makeNSView(context: Context) -> NSScrollView {
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

        let scroll = NSScrollView()
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

    func updateNSView(_ nsView: NSScrollView, context: Context) {
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
        /// section of their own rather than stray rows between Pinned and the
        /// folders. There while any such session is. Never dragged, no menu.
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
        weak var outline: NSOutlineView?
        var scrollObserver: NSObjectProtocol?
        weak var insertionLine: SidebarInsertionLine?

        private var snapshot: [SidebarSnapshotGroup] = []
        private let pinnedItem = PinnedItem()
        private var pinnedItems: [SessionItem] = []
        private let looseHeader = LooseHeaderItem()
        /// The root starts with the Pinned header (while anything is pinned)
        /// and the Sessions header (while any session is in no folder), and
        /// every root index (a drop's, an insertion line's) is past them.
        private var rootOffset: Int { (pinnedItems.isEmpty ? 0 : 1) + (looseItems.isEmpty ? 0 : 1) }
        private var looseItems: [SessionItem] = []
        /// Whether the folderless sessions are in the outline: false while
        /// their section is folded. Every root index (rows, drops, the
        /// insertion line) counts `shownLoose`, the rows actually there.
        private var looseShown = true
        private var shownLoose: [SessionItem] { looseShown ? looseItems : [] }
        private var folderItems: [FolderItem] = []          // ordered, as rendered
        private var childrenByFolder: [String: [SessionItem]] = [:]
        private var folderCache: [String: FolderItem] = [:]
        private var sessionCache: [UUID: SessionItem] = [:]
        /// Suppresses expand/collapse persistence while *we* are the ones
        /// expanding items (reload/sync), so only user toggles are recorded.
        private var isSyncing = false
        /// The folder toggled by the last header press, kept until we know the
        /// press wasn't a drag. See `headerPressed`.
        private var pressedFolder: FolderItem?

        init(manager: SessionManager) {
            self.manager = manager
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
        /// What each section was last drawn as under the sort, keyed by
        /// `drawnKey`: what holds the selected row still, and the whole
        /// section while a click may be coming. Emptied while the sort is off,
        /// so turning it on sorts afresh rather than holding a row in a place
        /// it never had.
        private var drawnBefore: [String: SidebarSort.Drawn] = [:]
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

        /// The sections in the order they're drawn: as stored, or sorted.
        private func drawnGroups() -> [SidebarSnapshotGroup] {
            guard let keys = sortKeys else {
                drawnBefore = [:]
                return manualSnapshot
            }
            let frozen = isFrozen
            if frozen { pendingThaw = true }
            var next: [String: SidebarSort.Drawn] = [:]
            let groups = manualSnapshot.map { group in
                let key = Self.drawnKey(group)
                let drawn = SidebarSort.draw(manual: group.sessionIDs, keys: keys, previous: drawnBefore[key],
                                             holding: manager.selectedID, frozen: frozen)
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
            snapshot = new
            rebuildItems(resetLoose: false)
            var folded: [Any] = []
            NSAnimationContext.runAnimationGroup { context in
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
                        offset = rootOffset
                    }
                    var working = before.sessionIDs
                    for (i, id) in after.sessionIDs.enumerated() {
                        guard let j = working.firstIndex(of: id), j != i else { continue }
                        outline.moveItem(at: offset + j, inParent: parent, to: offset + i, inParent: parent)
                        working.insert(working.remove(at: j), at: i)
                    }
                }
                outline.endUpdates()
                if !changedTall.isEmpty {
                    let rows = IndexSet(changedTall.compactMap { id in
                        sessionCache[id].map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil }
                    })
                    outline.noteHeightOfRows(withIndexesChanged: rows)
                }
            }
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
            manager.sidebarRowOrder = ids
            // A turn later: this runs inside SwiftUI's update, and the
            // selection is observed state.
            guard manager.sidebarSelection.isMultiple else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.manager.pruneSidebarSelection(toDrawn: self.manager.sidebarRowOrder)
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
            if item == nil { return rootOffset + shownLoose.count + folderItems.count }
            if item is PinnedItem { return pinnedItems.count }
            if let folder = item as? FolderItem { return childrenByFolder[folder.name]?.count ?? 0 }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                if index < rootOffset { return index == 0 && !pinnedItems.isEmpty ? pinnedItem : looseHeader }
                let index = index - rootOffset
                return index < shownLoose.count
                    ? shownLoose[index]
                    : folderItems[index - shownLoose.count]
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
            } else if item is PinnedItem || item is LooseHeaderItem {
                content = AnyView(SidebarSectionHeaderContent(manager: manager, isPinned: item is PinnedItem)
                    .padding(.top, sectionGap(item)))
                cell = SidebarCellView(content: content)
                return cell
            } else if let folder = item as? FolderItem {
                content = AnyView(SidebarHeaderContent(manager: manager, folder: folder.name)
                    .padding(.top, sectionGap(item)))
                cell = SidebarCellView(content: content)
                cell.dragTitle = folder.name
                cell.dragIsHeader = true
            } else {
                return nil
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            // Header height includes the section's breathing room above the
            // title (content bottom-aligns, see SidebarHeaderContent). A
            // worktree session named for its task carries its branch on a
            // second line (see `Session.showsBranchLine`).
            // Roomier than a Finder list, as the ChatGPT app's is: a session
            // row is something you read and pick all day, not scan past.
            // Sections apart, rows close, as the ChatGPT app's are: the gap
            // goes above a header, and a row's pill nearly touches the next.
            if item is FolderItem || item is PinnedItem || item is LooseHeaderItem { return 30 + sectionGap(item) }
            if let session = (item as? SessionItem)?.session, session.hasSecondLine { return 44 }
            return 30
        }

        /// The room above a section header: none for the first, which the
        /// sidebar's own top margin already sets apart.
        private func sectionGap(_ item: Any) -> CGFloat {
            guard item is FolderItem || item is PinnedItem || item is LooseHeaderItem else { return 0 }
            let first: AnyObject?
            if !pinnedItems.isEmpty { first = pinnedItem }
            else if !looseItems.isEmpty { first = looseHeader }
            else { first = folderItems.first }
            return first === (item as AnyObject) ? 0 : 14
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
            rowView.sectionGap = sectionGap(item)
            if item is PinnedItem || item is LooseHeaderItem { rowView.setFoldable() }
            if let folder = item as? FolderItem {
                let manager = self.manager, name = folder.name
                let directory = manager.root(ofFolder: name).map { ($0 as NSString).abbreviatingWithTildeInPath }
                rowView.setAddAction(directory: directory) { manager.newSession(inFolder: name) }
                rowView.setMoreMenu { FolderActions.menu(for: name, manager: manager) }
            }
            guard let session = item as? SessionItem else { return rowView }

            let manager = self.manager, target = session.session
            rowView.setCloseAction { manager.requestClose(target) }
            rowView.setMoreMenu { SessionActions.menu(for: target, manager: manager) }
            let id = target.id
            rowView.onHoverChanged = { hovered in
                if hovered {
                    if manager.hoveredRowID != id { manager.hoveredRowID = id }
                } else if manager.hoveredRowID == id {
                    manager.hoveredRowID = nil
                }
            }
            rowView.setStatusContent(
                AnyView(SessionStatusIndicator(manager: manager, session: target)))
            return rowView
        }

        private func showsPill(_ item: Any) -> Bool {
            guard let session = item as? SessionItem else { return false }
            // While renaming, the row draws its editing pill instead.
            return manager.selectedID == session.id && manager.editingID != session.id
        }

        /// In a selection of several, and not the lead (which has the pill).
        private func showsAlsoSelected(_ item: Any) -> Bool {
            guard let session = item as? SessionItem, manager.sidebarSelection.isMultiple else { return false }
            return manager.sidebarSelection.ids.contains(session.id) && manager.selectedID != session.id
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
                _ = manager.selectedID
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

        @objc func rowClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            // Folders already toggled on mouse-down; doing it again here (on
            // mouse-up) would undo it.
            guard row >= 0 else { return }
            guard let session = sender.item(atRow: row) as? SessionItem else { return }
            // ⌘ toggles the row in or out of the selection, ⇧ takes the range
            // from the anchor over the rows as drawn; neither moves the
            // terminal (see `SessionSelection`). A plain click is one row.
            manager.clickSidebarRow(session.id, Self.click(NSApp.currentEvent?.modifierFlags ?? []))
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
            // Right after the Pinned header (if any) and the Sessions header.
            let rows = IndexSet(integersIn: rootOffset..<(rootOffset + looseItems.count))
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
            if pb.string(forType: Self.sessionDragType) != nil {
                let drop = sessionDropTarget(at: point)
                if let folder = drop.onFolder {
                    // Drop *onto* a folder header → append + highlight the row.
                    hideInsertion()
                    setDropHighlight(folder)
                    outline.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
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
            let loose = shownLoose.count

            let folders = Self.directories(on: pb)
            if !folders.isEmpty {
                folders.forEach { manager.openFolder($0) }
                return true
            }

            if let folder = pb.string(forType: Self.folderDragType) {
                guard item == nil else { return false }
                manager.moveFolder(folder, toFolderIndex: max(0, index - rootOffset - loose))
                return true
            }
            if let ids = pb.string(forType: Self.sessionDragType)?
                .split(separator: "\n").compactMap({ UUID(uuidString: String($0)) }) {
                let byID = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0) })
                let moving = ids.compactMap { byID[$0] }
                guard !moving.isEmpty else { return false }
                let movingIDs = Set(moving.map(\.id))
                // Where it lands is named by the row drawn just below the drop
                // line (not a dragged one), or nil for the end of the section.
                // An index would mean something else in the stored order than
                // on screen once Sort Unread First is on; the row below is the
                // same row in both. Dropping still writes the stored order.
                func below(_ index: Int, in items: [SessionItem]) -> Session.ID? {
                    guard index != NSOutlineViewDropOnItemIndex, index >= 0 else { return nil }
                    return items.dropFirst(index).first { !movingIDs.contains($0.id) }?.id
                }
                // Into Pinned: pinned there, folders kept.
                if item is PinnedItem {
                    manager.setPinned(moving, true, before: below(index, in: pinnedItems))
                    return true
                }
                // Anywhere else: out of Pinned, and where it was dropped.
                if let folder = item as? FolderItem {
                    manager.moveSessions(moving.map(\.id), toFolder: folder.name,
                                         before: below(index, in: childrenByFolder[folder.name] ?? []), unpin: true)
                } else if item == nil {
                    // Into a folded Sessions (its header): at the end, as a
                    // drop on a folder header lands.
                    let before = looseShown ? below(index - rootOffset, in: shownLoose) : nil
                    manager.moveSessions(moving.map(\.id), toFolder: nil, before: before, unpin: true)
                } else {
                    return false
                }
                return true
            }
            return false
        }

        /// Nearest gap between folder sections, as a root child index in
        /// `[loose, loose+folders]`. Folders always render after the loose band.
        private func folderDropTarget(at point: NSPoint) -> Int {
            guard let outline else { return 0 }
            // Root indices, past the Pinned header when there is one: a folder
            // never goes above Pinned.
            let loose = rootOffset + shownLoose.count, folders = folderItems.count
            guard folders > 0 else { return loose }
            var boundaries: [(y: CGFloat, target: Int)] = []
            for (i, item) in folderItems.enumerated() {
                let row = outline.row(forItem: item)
                if row >= 0 { boundaries.append((outline.rect(ofRow: row).minY, loose + i)) }
            }
            let lastRow = outline.numberOfRows - 1
            if lastRow >= 0 { boundaries.append((outline.rect(ofRow: lastRow).maxY, loose + folders)) }
            return boundaries.min { abs($0.y - point.y) < abs($1.y - point.y) }?.target ?? loose
        }

        /// Where a dragged session should land. `onFolder` non-nil = drop onto
        /// that folder header (append); otherwise insert at (`parent`, `index`).
        private func sessionDropTarget(at point: NSPoint) -> (parent: Any?, index: Int, onFolder: FolderItem?) {
            guard let outline, outline.numberOfRows > 0 else { return (nil, 0, nil) }
            let hovered = outline.row(at: point)
            // Below the last row → append after the last row's context.
            let row = hovered >= 0 ? hovered : outline.numberOfRows - 1
            let topLevelEnd = rootOffset + shownLoose.count
            guard let item = outline.item(atRow: row) else { return (nil, topLevelEnd, nil) }
            let rect = outline.rect(ofRow: row)
            let topHalf = hovered >= 0 && point.y < rect.midY

            // Onto the Pinned header: pinned, at the end of the pinned. Folded,
            // onto the header itself: there are no rows to put a line between.
            if item is PinnedItem {
                return outline.isItemExpanded(pinnedItem)
                    ? (pinnedItem, pinnedItems.count, nil)
                    : (pinnedItem, NSOutlineViewDropOnItemIndex, nil)
            }
            // Onto the Sessions header: out of any folder, at the end.
            if item is LooseHeaderItem { return (nil, topLevelEnd, nil) }
            if let folder = item as? FolderItem {
                // The top edge of the very first section is the "move to top
                // level" zone — the top-level band renders above the folders but
                // has no row to aim at when it's empty. Dropping here inserts
                // the session above the first folder (at top level).
                if folder === folderItems.first, point.y < rect.minY + rect.height * 0.34 {
                    return (nil, topLevelEnd, nil)
                }
                return (nil, 0, folder) // onto the header → append into the folder
            }
            if let session = item as? SessionItem,
               let i = pinnedItems.firstIndex(where: { $0 === session }) {
                return (pinnedItem, topHalf ? i : i + 1, nil)
            }
            if let session = item as? SessionItem {
                if let parent = session.session.folderPath, let parentItem = folderCache[parent] {
                    let i = childrenByFolder[parent]?.firstIndex { $0 === session } ?? 0
                    return (parentItem, topHalf ? i : i + 1, nil)
                }
                let i = shownLoose.firstIndex { $0 === session } ?? 0
                return (nil, rootOffset + (topHalf ? i : i + 1), nil)
            }
            return (nil, topLevelEnd, nil)
        }

        // MARK: Drop highlight

        private var dropHighlight: FolderItem?

        private func setDropHighlight(_ folder: FolderItem?) {
            guard dropHighlight !== folder else { return }
            let previous = dropHighlight
            dropHighlight = folder
            applyDropHighlight(previous)
            applyDropHighlight(folder)
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
            func bottomOfRow(_ row: Int) -> CGFloat { outline.rect(ofRow: row).maxY }

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
            // one), then loose items, then folders.
            let index = index - rootOffset
            let loose = shownLoose.count
            if index < loose, index >= 0 {
                return topOfRow(outline.row(forItem: shownLoose[index]))
            }
            let folderIdx = index - loose
            if folderIdx >= 0, folderIdx < folderItems.count {
                return topOfRow(outline.row(forItem: folderItems[folderIdx]))
            }
            let lastRow = outline.numberOfRows - 1
            return lastRow >= 0 ? bottomOfRow(lastRow) : 0
        }

        private func applyDropHighlight(_ folder: FolderItem?) {
            guard let outline, let folder else { return }
            let row = outline.row(forItem: folder)
            guard row >= 0,
                  let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarPillRowView
            else { return }
            rowView.showsDropHighlight = (folder === dropHighlight)
        }
    }
}
