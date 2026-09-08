import AppKit
import Observation
import SwiftUI

/// Row view that draws the always-accent selection pill at the *row* level, so
/// it spans the full sidebar width — across the chevron gutter and indentation
/// — like Mail's and Icon Composer's selection, instead of hugging the cell.
final class SidebarPillRowView: NSTableRowView {
    /// How far the pill is inset from the row. Also what the close button keeps
    /// clear of the pill's edges, so its padding reads the same on all three
    /// sides it touches.
    private static let pillInset = NSSize(width: 10, height: 2)

    var showsPill = false {
        didSet {
            guard showsPill != oldValue else { return }
            needsDisplay = true
            closeButton.onAccent = showsPill
        }
    }
    /// A dragged session is hovering this folder header (drop-on / append).
    var showsDropHighlight = false {
        didSet { if showsDropHighlight != oldValue { needsDisplay = true } }
    }
    /// The pointer is over this row. Drawn as a very light fill in the pill's
    /// shape — enough to say *this* is the row the “×” would close, without
    /// competing with the accent pill of the selected one.
    private var showsHover = false {
        didSet { if showsHover != oldValue { needsDisplay = true } }
    }

    /// The pill, and the box the close button is laid out against.
    private var pillRect: NSRect {
        bounds.insetBy(dx: Self.pillInset.width, dy: Self.pillInset.height)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let rect = pillRect
        if showsPill {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else if showsDropHighlight {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else if showsHover {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    // MARK: - Close button
    //
    // It lives on the *row* rather than in the cell view because only the row
    // shares the pill's geometry: the source-list style insets cell views from
    // the row, so "12pt from the cell's trailing edge" stops well short of the
    // pill's right edge — and a cell can't be clicked outside its own bounds.

    private let closeButton = SidebarCloseButton()
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
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What the close button does. Session rows set this; folder headers don't.
    func setCloseAction(_ handler: @escaping () -> Void) {
        closeButton.onClick = handler
        closable = true
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
        // One rect for both, so hovering swaps the glyph without moving it.
        closeButton.frame = slot
        statusHost.frame = slot
    }

    /// AppKit inserts the cell view after ours, which would bury them. Keep both
    /// in front — the button so it can take its own clicks, the indicator so it
    /// isn't drawn behind the row's content.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== closeButton, subview !== statusHost else { return }
        if statusHost.superview === self {
            addSubview(statusHost, positioned: .above, relativeTo: nil)
        }
        if closeButton.superview === self {
            addSubview(closeButton, positioned: .above, relativeTo: nil)
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
        // turn of lag. Folder headers aren't closable and stay flat: the cue is
        // about which session you might close.
        let shows = hovered && closable
        showsHover = shows
        guard closeButton.isHidden == shows else { return }
        closeButton.isHidden = !shows
        // The two share one rect, so the indicator has to give it up rather than
        // sit under the button.
        statusHost.isHidden = shows
        if !shows { closeButton.setHovering(false) }
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

    /// The row underneath is the accent selection pill, so glyph and disc both
    /// have to come off it. Unselected rows sit on the sidebar material instead.
    var onAccent = false {
        didSet {
            guard onAccent != oldValue else { return }
            contentTintColor = onAccent ? .white : .secondaryLabelColor
            applyHover()
        }
    }

    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Session")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        contentTintColor = .secondaryLabelColor
        toolTip = "Close Session"
        target = self
        action = #selector(fire)
        // The terminal owns keyboard focus; closing a session must not take it.
        refusesFirstResponder = true
        wantsLayer = true
        setAccessibilityLabel("Close Session")
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
        let tint = onAccent
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.labelColor.withAlphaComponent(0.12)
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
/// this composites the content over an opaque rounded card instead.
final class SidebarCellView: NSTableCellView {
    private let hosting: NSHostingView<AnyView>
    /// What the drag image paints — set per-row in viewForItem.
    var dragTitle = ""
    var dragSubtitle: String?
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

    /// The drag image, hand-drawn: a solid rounded rectangle with the row's text
    /// on it. No SwiftUI snapshot / cacheDisplay (those produced a transparent
    /// image) — plain AppKit fills and NSString drawing, guaranteed opaque.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return [] }
        let title = dragTitle, subtitle = dragSubtitle, isHeader = dragIsHeader

        let component = NSDraggingImageComponent(key: .icon)
        component.frame = NSRect(origin: .zero, size: size)
        component.contents = NSImage(size: size, flipped: false) { rect in
            let card = rect.insetBy(dx: 8, dy: 3)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()

            let x = card.minX + 10
            if isHeader {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor]
                (title as NSString).draw(at: NSPoint(x: x, y: card.midY - 7), withAttributes: attrs)
            } else if let subtitle {
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
                (title as NSString).draw(at: NSPoint(x: x, y: card.midY + 2), withAttributes: titleAttrs)
                (subtitle as NSString).draw(at: NSPoint(x: x, y: card.midY - 15), withAttributes: subAttrs)
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                (title as NSString).draw(at: NSPoint(x: x, y: card.midY - 8), withAttributes: attrs)
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
        if row >= 0, let item = item(atRow: row),
           !frameOfOutlineCell(atRow: row).contains(point) {
            onHeaderPressed?(item)
        }
        super.mouseDown(with: event)
    }

    /// Let a row's close button keep its own clicks. NSTableView claims every
    /// click over a cell for selection and drag-to-reorder unless this says
    /// otherwise; the default answer for anything inside a cell view is no.
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
/// accent pill, attention dots, and inline rename are the same views as before.
struct SidebarOutlineView: NSViewRepresentable {
    let manager: SessionManager
    let snapshot: [SidebarSnapshotGroup]

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutline()
        outline.onDragEnd = { [weak coordinator = context.coordinator] in
            coordinator?.clearDropHighlight()
            coordinator?.hideInsertion()
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
        // Selection is drawn by the hosted row (always-accent pill), never by
        // AppKit — the native highlight would grey out whenever the sidebar
        // isn't the focused column, and the terminal always is.
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

        outline.registerForDraggedTypes([Coordinator.sessionDragType, Coordinator.folderDragType])
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

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.apply(snapshot)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(snapshot)
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
        final class SessionItem {
            let session: Session
            var id: Session.ID { session.id }
            init(session: Session) { self.session = session }
        }

        let manager: SessionManager
        weak var outline: NSOutlineView?
        weak var insertionLine: SidebarInsertionLine?

        private var snapshot: [SidebarSnapshotGroup] = []
        private var looseItems: [SessionItem] = []
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

        init(manager: SessionManager) { self.manager = manager }

        // MARK: Snapshot → outline

        func apply(_ new: [SidebarSnapshotGroup]) {
            guard let outline else { return }
            if new != snapshot {
                snapshot = new
                rebuildItems()
                isSyncing = true
                outline.reloadData()
                isSyncing = false
            }
            syncExpansion()
        }

        private func rebuildItems() {
            let byID = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0) })
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
                if let folder = group.folder {
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
            if item == nil { return looseItems.count + folderItems.count }
            if let folder = item as? FolderItem { return childrenByFolder[folder.name]?.count ?? 0 }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return index < looseItems.count
                    ? looseItems[index]
                    : folderItems[index - looseItems.count]
            }
            let folder = item as! FolderItem
            return childrenByFolder[folder.name]![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is FolderItem
        }

        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let content: AnyView
            let cell: SidebarCellView
            if let session = item as? SessionItem {
                content = AnyView(SidebarRowContent(manager: manager, session: session.session))
                cell = SidebarCellView(content: content)
                cell.dragTitle = session.session.leafName
                let path = session.session.abbreviatedPath
                cell.dragSubtitle = path.isEmpty ? nil : path
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
            // Header height includes the section's breathing room above the
            // title (content bottom-aligns, see SidebarHeaderContent). A
            // worktree session named for its task carries its branch on a
            // second line (see `Session.showsBranchLine`).
            if item is FolderItem { return 32 }
            if let session = (item as? SessionItem)?.session, session.showsBranchLine { return 42 }
            return 30
        }

        /// Row views draw the selection pill (full row width, across the
        /// chevron gutter and indentation — Mail-style) and carry the hover close
        /// button, which needs that same full-width geometry. See
        /// SidebarPillRowView.
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let rowView = SidebarPillRowView()
            rowView.showsPill = showsPill(item)
            guard let session = item as? SessionItem else { return rowView }

            let manager = self.manager, target = session.session
            rowView.setCloseAction { manager.requestClose(target) }
            rowView.setStatusContent(
                AnyView(SessionStatusIndicator(manager: manager, session: target)))
            return rowView
        }

        private func showsPill(_ item: Any) -> Bool {
            guard let session = item as? SessionItem else { return false }
            // Suppressed while renaming so the edit field sits on a normal
            // background (matches SessionRow's onAccent logic).
            return manager.selectedID == session.id && manager.editingID != session.id
        }

        /// Re-render the selection pill whenever selection or rename state
        /// changes — which also re-tints the row's close button for the
        /// background it now sits on. The hosted SwiftUI cells track Observation
        /// on their own; the AppKit row views need this explicit loop.
        func observeSelection() {
            withObservationTracking {
                _ = manager.selectedID
                _ = manager.editingID
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshSelection()
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
            guard row >= 0, let session = sender.item(atRow: row) as? SessionItem else { return }
            manager.selectedID = session.id
        }

        /// Whole-header press toggles the section, on mouse-down so it matches
        /// the chevron. If the press turns out to be the start of a drag,
        /// `draggingSession:willBeginAt:` undoes it.
        func headerPressed(_ item: Any, in outline: NSOutlineView) {
            guard let folder = item as? FolderItem else { return }
            pressedFolder = folder
            toggle(folder, in: outline)
        }

        @objc func rowDoubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            // Sessions rename on double-click. Headers have no double-click
            // meaning at all — each press just toggles them, and rename lives in
            // their context menu.
            guard row >= 0, let session = sender.item(atRow: row) as? SessionItem else { return }
            manager.selectedID = session.id
            manager.editingID = session.id
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
            guard !isSyncing, let folder = notification.userInfo?["NSObject"] as? FolderItem else { return }
            manager.setFolder(folder.name, collapsed: false)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncing, let folder = notification.userInfo?["NSObject"] as? FolderItem else { return }
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
                pb.setString(session.id.uuidString, forType: Self.sessionDragType)
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

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let outline else { return [] }
            let pb = info.draggingPasteboard
            let point = outline.convert(info.draggingLocation, from: nil)

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
                } else {
                    clearDropHighlight()
                    outline.setDropItem(drop.parent, dropChildIndex: drop.index)
                    showInsertion(parent: drop.parent, index: drop.index)
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
            let loose = looseItems.count

            if let folder = pb.string(forType: Self.folderDragType) {
                guard item == nil else { return false }
                manager.moveFolder(folder, toFolderIndex: max(0, index - loose))
                return true
            }
            if let idString = pb.string(forType: Self.sessionDragType),
               let id = UUID(uuidString: idString) {
                if let folder = item as? FolderItem {
                    manager.moveSession(id: id, toFolder: folder.name,
                                        at: index == NSOutlineViewDropOnItemIndex ? .max : index)
                } else if item == nil {
                    manager.moveSession(id: id, toFolder: nil, at: max(0, index))
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
            let loose = looseItems.count, folders = folderItems.count
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
            guard let item = outline.item(atRow: row) else { return (nil, looseItems.count, nil) }
            let rect = outline.rect(ofRow: row)
            let topHalf = hovered >= 0 && point.y < rect.midY

            if let folder = item as? FolderItem {
                // The top edge of the very first section is the "move to top
                // level" zone — the top-level band renders above the folders but
                // has no row to aim at when it's empty. Dropping here inserts
                // the session above the first folder (at top level).
                if row == looseItems.count, point.y < rect.minY + rect.height * 0.34 {
                    return (nil, looseItems.count, nil)
                }
                return (nil, 0, folder) // onto the header → append into the folder
            }
            if let session = item as? SessionItem {
                if let parent = session.session.folderPath, let parentItem = folderCache[parent] {
                    let i = childrenByFolder[parent]?.firstIndex { $0 === session } ?? 0
                    return (parentItem, topHalf ? i : i + 1, nil)
                }
                let i = looseItems.firstIndex { $0 === session } ?? 0
                return (nil, topHalf ? i : i + 1, nil)
            }
            return (nil, looseItems.count, nil)
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
        private func showInsertion(parent: Any?, index: Int) {
            guard let outline, let line = insertionLine else { return }
            let inFolder = parent is FolderItem
            let leading: CGFloat = inFolder ? 28 : 12
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
            // Top-level: root children are loose items then folders.
            let loose = looseItems.count
            if index < loose {
                return topOfRow(outline.row(forItem: looseItems[index]))
            }
            let folderIdx = index - loose
            if folderIdx < folderItems.count {
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
