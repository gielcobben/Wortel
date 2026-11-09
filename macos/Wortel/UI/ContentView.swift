import AppKit
import SwiftUI

/// Native single-field prompt for a folder name. Synchronous (an NSAlert modal)
/// — fine for a quick one-field ask, and simpler than threading sheet state
/// through the sidebar. Returns nil on Cancel or an empty entry.
@MainActor
func promptFolderName(title: String, confirm: String, initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.stringValue = initial
    field.placeholderString = "Folder name"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
}

/// Pick a directory. The whole of ⌘O and of the worktree sheet's Location,
/// and the only part of Wortel that ever opens a file panel.
///
/// Directories only, and no "New Folder" button unless asked (`canCreate`):
/// mostly this points at a project that already exists. Modal rather than a sheet for the same reason the name
/// prompt above is — one question, one answer, and no state to thread through
/// the sidebar. Returns nil on Cancel.
@MainActor
func chooseDirectory(title: String, startingAt current: String? = nil,
                     prompt: String = "Open", canCreate: Bool = false) -> String? {
    let panel = NSOpenPanel()
    panel.message = title
    panel.prompt = prompt
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = canCreate
    // Start where the folder already points, so "Set Directory…" opens on the
    // thing it is about to change rather than on wherever the panel was last.
    if let current { panel.directoryURL = URL(fileURLWithPath: current) }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path
}

/// The sidebar pane's content, hosted by MainSplitViewController's `.sidebar`
/// split item. Draws no background of its own: the split item behavior supplies
/// the system material, and painting over it would block the glass.
struct SidebarPane: View {
    @Bindable var manager: SessionManager

    var body: some View {
        // The session list is a native NSOutlineView (SidebarOutlineView), not a
        // SwiftUI List: two-level drag & drop with real insertion indicators —
        // sessions between rows / into folders, folders between sections — is
        // exactly NSOutlineView's home turf and beyond what List exposes. Row
        // *content* stays SwiftUI (SessionRow hosted per row), so the pill,
        // attention dots, and inline rename are unchanged.
        SidebarOutlineView(
            manager: manager,
            snapshot: manager.sidebarGroups.map {
                SidebarSnapshotGroup(
                    folder: $0.folder, sessionIDs: $0.sessions.map(\.id),
                    tallIDs: Set($0.sessions.filter(\.hasSecondLine).map(\.id)),
                    isPinned: $0.isPinned)
            },
            folding: SidebarFolding(folders: manager.collapsedFolders,
                                    pinned: manager.pinnedCollapsed,
                                    loose: manager.looseCollapsed),
            // Only read while the sort is on, so a dot coming and going costs
            // the sidebar nothing the rest of the time.
            sortKeys: manager.sortUnreadFirst
                ? Dictionary(uniqueKeysWithValues: manager.sessions.compactMap { session in
                    manager.sidebarSortKey(for: session).map { (session.id, $0) }
                })
                : nil)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 2) {
                    // AppKit, as the ⓘ and the update icon are, so all three
                    // light up under the pointer the same way (HoverFillButton,
                    // the titlebar's). See NewSessionButton for the menu.
                    NewSessionButton(manager: manager)
                        .frame(width: 24, height: 24)
                    TelemetryInfoButton()
                        .frame(width: 24, height: 24)
                    UpdateIndicator()
                    PermissionsIndicator()
                    Spacer()
                }
                // Equal on all four sides, so the 24pt hit box's centre sits on
                // the window corner's diagonal rather than leaning into it —
                // asymmetric padding (it was 10 / 6) puts the glyph nearer one
                // edge than the other, which is the part that reads as crammed.
                // 12 rather than the smallest value that lines the plus up with
                // the session names: a source-list's bottom bar is a band of its
                // own, and a control tucked into the rounded corner looks like it
                // slid there. Puts the glyph's centre 24pt off each edge.
                .padding(12)
            }
    }
}

/// The sidebar's word about updates, beside + and ⓘ and drawn like them: an
/// icon, nothing louder. While a downloaded update waits it's a download arrow
/// in the accent colour (as Safari's turns blue when there's something for
/// you) with a dot on its corner; its tooltip
/// names the version, and a click opens a popover that explains and offers
/// Restart Now.
///
/// An icon rather than Sparkle's window or a banner, because Wortel is never
/// quit: anything that interrupts gets dismissed, and anything loud becomes
/// furniture. This waits, quietly, until you pick the moment (see `Updater`).
struct UpdateIndicator: View {
    private var updater: Updater { .shared }

    var body: some View {
        if let version = updater.readyVersion {
            UpdateButton(version: version)
                .frame(width: 24, height: 24)
        }
    }
}

/// AppKit, as the ⓘ is, so the popover can hang off the real button.
struct UpdateButton: NSViewRepresentable {
    let version: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BadgedGlyphButton {
        // The hover every icon in the bar has, and the dot the running list's
        // icon has.
        let button = BadgedGlyphButton()
        // Blue, as Safari's download button turns blue when something's
        // there for you, with the dot on its corner.
        button.setGlyph(NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update ready")?
            .withSymbolConfiguration(SidebarBarButton.glyph))
        button.setAccessibilityLabel("Update ready")
        button.dotColor = .controlAccentColor
        button.contentTintColor = .controlAccentColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }

    func updateNSView(_ button: BadgedGlyphButton, context: Context) {
        // The sidebar redraws often (selection, dots, the working wave), and
        // setting a tooltip re-registers it: only when the version changes.
        guard context.coordinator.version != version else { return }
        context.coordinator.version = version
        button.toolTip = "Wortel \(version) is ready"
    }

    @MainActor
    final class Coordinator: NSObject {
        var version = ""

        @objc func clicked(_ sender: NSButton) {
            UpdateNotice.shared.toggle(from: sender, version: version)
        }
    }
}

/// The popover the update icon opens: what's waiting, that a restart costs
/// nothing, and the button. Shown only on a click, so it can behave as any
/// popover does (it closes on a click elsewhere).
@MainActor
final class UpdateNotice: NSObject, NSPopoverDelegate {
    static let shared = UpdateNotice()
    private var popover: NSPopover?
    /// Lit while its popover is open, as a titlebar button is.
    private weak var anchor: HoverFillButton?
    /// Whoever had the keyboard (the terminal), given it back on close:
    /// showing a popover moves key, and the surface would otherwise stop
    /// getting keys until the next click (as TelemetryNotice found).
    private weak var responder: NSResponder?
    /// When it last closed. A transient popover closes on the mouse-down of a
    /// click on its own icon, before that click's action runs; without this
    /// the action would find it closed and open it again.
    private var closedAt = Date.distantPast

    static func notesURL(for version: String) -> URL {
        URL(string: "https://wortel.sh/updates#\(version)")!
    }

    func toggle(from anchor: NSView, version: String) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        // That same click, closing it: leave it closed.
        guard Date().timeIntervalSince(closedAt) > 0.3 else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: UpdateNoticeView(
            version: version,
            restart: { [weak self] in
                self?.popover?.close()
                Updater.shared.restartToUpdate()
            },
            whatsNew: { [weak self] in
                self?.popover?.close()
                NSWorkspace.shared.open(Self.notesURL(for: version))
            }))
        self.popover = popover
        responder = anchor.window?.firstResponder
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        self.anchor = anchor as? HoverFillButton
        self.anchor?.isSelected = true
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        if let window = anchor?.window, let responder {
            window.makeKey()
            window.makeFirstResponder(responder)
        }
        anchor?.isSelected = false
        anchor = nil
        responder = nil
    }
}

private struct UpdateNoticeView: View {
    let version: String
    let restart: () -> Void
    let whatsNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wortel \(version) is ready")
                    .font(.system(size: 13, weight: .semibold))
                Text("It's downloaded. Restarting takes a second or two, and every session, agent and layout comes back as it was.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("What's New", action: whatsNew)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                Spacer()
                Button("Restart Now", action: restart)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 272)
    }
}

/// The ⓘ beside the +, and the anchor the usage-data popover hangs off.
///
/// AppKit rather than a SwiftUI `Button` with `.popover`, for the one thing this
/// popover has to do that SwiftUI's cannot: appear without taking the keyboard
/// away from the terminal (see `TelemetryNotice`). That needs the real `NSView`
/// to anchor to and the real `NSPopover` to configure, so the button is the
/// AppKit one and the presenter owns the rest.
struct TelemetryInfoButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = HoverFillButton()
        button.target = TelemetryNotice.shared
        button.action = #selector(TelemetryNotice.toggleVisible(_:))
        button.image = NSImage(systemSymbolName: "info.circle",
                               accessibilityDescription: "Anonymous usage data")?
            .withSymbolConfiguration(SidebarBarButton.glyph)
        button.toolTip = "Anonymous usage data"
        TelemetryNotice.shared.register(anchor: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}
}

/// The sidebar bottom bar's three icons share a size and weight.
enum SidebarBarButton {
    static let glyph = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
}

/// The bottom bar's "+": new sessions and folders, grouped like the Session
/// menu and in the same order, so the two places you reach for this agree:
/// ways to start a session, then the two folder verbs. A native menu from an
/// AppKit button (as the rows' "…" do), so it lights up under the pointer like
/// the ⓘ and the update icon beside it.
struct NewSessionButton: NSViewRepresentable {
    let manager: SessionManager

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

    func makeNSView(context: Context) -> NSButton {
        let button = HoverFillButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")?
            .withSymbolConfiguration(SidebarBarButton.glyph)
        button.toolTip = "New Session"
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.manager = manager
    }

    @MainActor
    final class Coordinator: NSObject {
        var manager: SessionManager
        init(manager: SessionManager) { self.manager = manager }

        @objc func showMenu(_ sender: NSButton) {
            let manager = self.manager
            let menu = NSMenu()
            // Glyphs as every other menu here has them (`setGlyph`), the
            // palette's for the same commands.
            func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
                let item = ClosureMenuItem(title: title, handler: action)
                item.setGlyph(symbol)
                menu.addItem(item)
            }
            add("New Session", "plus.square") { manager.newSession() }
            // "New Session" here looks global but isn't: it lands in whichever
            // folder the selection is in. This is the way out of that, next to
            // the thing it's the exception to.
            add("New Session at Home", "house") { manager.newHomeSession() }
            add("New Worktree Session\u{2026}", "plus.square.dashed") { newWorktreeSessionFromSheet(manager) }
            menu.addItem(.separator())
            // The way to reach a project no session is standing in without
            // typing `cd`, and how a folder gets made, with its directory.
            add("Open Folder\u{2026}", "folder") { openFolderSession(manager) }
            // Lit while open, then opening upward from the button, as a menu
            // at the bottom of a window does.
            // The point is the menu's top-left: one menu-height above the
            // button (which is flipped, so up is smaller y).
            let top = sender.isFlipped ? sender.bounds.minY - menu.size.height - 4
                                       : sender.bounds.maxY + menu.size.height + 4
            sender.highlight(true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: sender)
            sender.highlight(false)
        }
    }
}

/// One outline row's SwiftUI content: the session row on its selection pill,
/// plus the row context menu. Reads the manager's observable
/// state directly, so selection, rename, and attention changes update live
/// inside the hosted view — no outline reload involved.
struct SidebarRowContent: View {
    let manager: SessionManager
    let session: Session

    /// Whether the row's trailing status indicator shows anything: the
    /// same conditions SessionStatusIndicator draws under, its ⌘-number
    /// included, or that draws over the end of the name.
    private var showsStatus: Bool {
        let selected = manager.selectedID == session.id
        return manager.shortcutNumber(for: session.id) != nil
            || session.attention != nil || session.isBusy
            || (session.unread != nil && (!selected || session.markedUnread))
    }

    var body: some View {
        SessionRow(
            session: session,
            isSelected: manager.selectedID == session.id,
            isEditing: manager.editingID == session.id,
            isInWorktree: session.isInWorktree,
            isHovered: manager.hoveredRowID == session.id,
            waiting: session.attention.map { kind in
                let note = manager.attentionNote(for: session)
                return SessionRow.Waiting(kind: kind, message: note.message, since: note.since)
            },
            // Only this row's rename: a late end of this field's edit, after
            // another row's has begun, must not end that one too.
            commit: { newName in
                manager.rename(session, to: newName)
                if manager.editingID == session.id { manager.editingID = nil }
            },
            cancel: { if manager.editingID == session.id { manager.editingID = nil } })
            // The selection pill is drawn by the row view (SidebarPillRowView),
            // full row width — this content just sits on top of it. 10pt into
            // the pill, which is 10pt in from the row (its inset).
            .padding(.leading, 20)
            // Keeps a long name clear of the trailing slot the row view owns:
            // "…" and × while the row is hovered, the status dot at rest when
            // there is one, and otherwise only the pill's own edge. Room for
            // what's actually there, so a name isn't cut short for a dot or
            // buttons that aren't.
            .padding(.trailing, manager.hoveredRowID == session.id ? 52 : (showsStatus ? 34 : 12))
            // Fill the row height and center vertically — otherwise the short
            // name+path content sits at the top of the (taller) row, leaving
            // dead space below each session that reads as loose spacing.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The colour you gave the session: a bar just inside the pill.
            // Placed off a screenshot at 2x, then by eye:
            // - across, 4.5pt in from the pill's edge (10pt in), a device
            //   pixel nearer the name than the measured middle, which read as
            //   too close to the edge;
            // - down, 2pt past the name's ink at both ends (its tallest
            //   letters to its baseline), which is centred 0.25pt below the
            //   row's middle: hence 8.5 above and 8 below in a 30pt row.
            // The only coloured thing at that end of the row; the attention
            // dots are at the other.
            .overlay(alignment: .leading) {
                if let colour = session.colour {
                    Capsule()
                        .fill(Color(nsColor: colour.nsColor))
                        .frame(width: 3)
                        .padding(.top, 8.5)
                        .padding(.bottom, 8)
                        .padding(.leading, 14.5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityValue(session.colour?.title ?? "")
            // Native right-click, popped instantly on rightMouseDown, and it
            // selects the row on the way so the terminal follows. SwiftUI's
            // `.contextMenu` presents on a press-hold and rebuilds its content
            // on every render — the same lag the git panel abandoned it over.
            .overlay(RightClickCatcher(onRightClick: rightClickSelect, makeMenu: makeContextMenu))
    }

    /// Select the row when it's right-clicked, so the detail pane follows it —
    /// matching a left-click. Inside a selection of several it's kept, and the
    /// menu is about all of them; outside, it collapses onto this row. The
    /// Finder's rule, and the git panel's changes list's.
    private func rightClickSelect() {
        guard !manager.isInMultipleSelection(session) else { return }
        if manager.selectedID != session.id { manager.selectedID = session.id }
    }

    /// Build the native right-click menu, freshly each time it opens.
    private func makeContextMenu() -> NSMenu {
        if manager.isInMultipleSelection(session) {
            return SessionActions.menu(for: manager.sidebarSelectedSessions, manager: manager)
        }
        return SessionActions.menu(for: session, manager: manager)
    }
}

/// A section header's label, the same for a folder, Pinned and Sessions so the
/// three read as one kind of thing: the title, the chevron after it, and a dot
/// for what a folded section is hiding.
struct SidebarSectionLabel: View {
    let title: String
    let collapsed: Bool
    let attention: AttentionKind?

    var body: some View {
        HStack(spacing: 6) {
            // The same size as the rows under it, and set apart by colour alone:
            // a small bold header is a second type size and a second weight
            // doing a job the grey already does.
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            // Open or collapsed, after the name rather than as a triangle in
            // front of it: down when open, turned to point at the name's end
            // when collapsed. The whole header is the button (SidebarOutline).
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .animation(.easeOut(duration: 0.15), value: collapsed)
            // What the section is hiding. Same dot as a session row's, so it
            // reads as the same fact rather than as a new kind of badge — and
            // it pulses for the same reason, because a blocked agent you can't
            // see is exactly the case this whole system is for.
            if let kind = attention {
                AttentionDot(color: SessionStatusIndicator.attentionColor(kind),
                             motion: kind.pulses ? .pulse : .still)
            }
            Spacer(minLength: 4)
        }
    }
}

/// A fixed section's header (Pinned, Sessions): a press anywhere folds it, as a
/// folder header's does; never dragged, no menu.
struct SidebarSectionHeaderContent: View {
    let manager: SessionManager
    /// Pinned, or the folderless "Sessions".
    let isPinned: Bool

    var body: some View {
        SidebarSectionLabel(title: isPinned ? "Pinned" : "Sessions",
                            collapsed: isPinned ? manager.pinnedCollapsed : manager.looseCollapsed,
                            attention: manager.attention(inPinned: isPinned))
        // Placed exactly as a folder's title is.
        .padding(.leading, 20)
        .padding(.trailing, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

extension NSMenuItem {
    /// A glyph beside the title, as every menu in the chrome has: one size
    /// and weight everywhere, and shown on macOS 27, which otherwise hides a
    /// menu item's image.
    func setGlyph(_ symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(Chrome.menuGlyph)
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }
}

/// What can be done to one session: the row's right-click menu, its hover
/// "…", the titlebar's "…" (under that row's own items), and, through the
/// Session menu, the ⌘P palette. One place, so the names, glyphs and order
/// can't drift apart between them.
@MainActor
enum SessionActions {
    static func menu(for session: Session, manager: SessionManager) -> NSMenu {
        let menu = NSMenu()
        // Shortcuts act on the selected session, so they're shown only on its
        // menu: on another row's they'd promise to act on that one.
        let selected = manager.selectedID == session.id
        func item(_ title: String, _ glyph: String, key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = [.command],
                  _ handler: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, handler: handler)
            item.setGlyph(glyph)
            if selected, !key.isEmpty {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = modifiers
            }
            menu.addItem(item)
            return item
        }

        // Shortest title first, so the group reads as a tidy wedge rather
        // than a ragged edge. "Unpin" is still the shortest.
        let pinned = manager.isPinned(session)
        _ = item(pinned ? "Unpin" : "Pin", pinned ? "pin.slash" : "pin", key: "p", [.command, .option]) {
            manager.setPinned(session, !pinned)
        }
        // ⌥⌘R, as in the Session menu: plain ⌘R is a browser's Reload.
        _ = item("Rename", "pencil", key: "r", [.command, .option]) { manager.editingID = session.id }
        menu.addItem(SessionColourMenu.item(for: session, manager: manager))
        _ = item("Mark as Unread", "circle.dashed", key: "u", [.command, .shift]) {
            manager.markUnread(session)
        }

        menu.addItem(.separator())
        if let cwd = session.cwd {
            _ = item("Show in Finder", "folder.badge.gearshape") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
            }
            _ = item("Copy Path", "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
            }
        }

        menu.addItem(.separator())
        // In a worktree, closing archives (`SessionManager.end`): the
        // session waits to be restored from ⌘P, and its worktree goes
        // to the Trash only when nothing in it is worth keeping.
        _ = item("Close Session", "xmark.square", key: "w", [.command, .shift]) {
            manager.requestClose(session)
        }
        return menu
    }

    /// What can be done to several sessions at once: the right-click menu of
    /// the sidebar's selection. Each item acts on every one of them, as one
    /// change (`SessionManager`'s batch twins), and offers only what changes
    /// something: Pin while any is unpinned, Unpin while any is pinned. No
    /// shortcuts are shown: those act on the session on screen alone.
    static func menu(for sessions: [Session], manager: SessionManager) -> NSMenu {
        guard sessions.count > 1 else {
            return sessions.first.map { menu(for: $0, manager: manager) } ?? NSMenu()
        }
        let menu = NSMenu()
        func item(_ title: String, _ glyph: String, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: handler)
            item.setGlyph(glyph)
            menu.addItem(item)
        }
        let unpinned = sessions.filter { !manager.isPinned($0) }
        if !unpinned.isEmpty { item("Pin", "pin") { manager.setPinned(unpinned, true) } }
        if unpinned.count < sessions.count {
            item("Unpin", "pin.slash") { manager.setPinned(sessions.filter(manager.isPinned), false) }
        }
        if sessions.contains(where: { $0.attention != nil || $0.unread != nil }) {
            item("Mark as Read", "circle") { manager.markRead(sessions) }
        }
        if sessions.contains(where: { !$0.markedUnread }) {
            item("Mark as Unread", "circle.dashed") { manager.markUnread(sessions) }
        }
        menu.addItem(SessionColourMenu.item(for: sessions, manager: manager))
        menu.addItem(.separator())
        // Worktree sessions archive, as closing one does (`SessionManager.end`).
        item("Close \(sessions.count) Sessions", "xmark.square") { manager.requestClose(sessions) }
        return menu
    }

}

/// ⌘O: pick a directory and open a session in it. One funnel for the menu bar,
/// the sidebar's + menu and anything else that grows one, so the panel and what
/// happens to the chosen path are described in exactly one place.
@MainActor
func openFolderSession(_ manager: SessionManager) {
    guard let path = chooseDirectory(title: "Open a folder as a session") else { return }
    manager.openFolder(path)
}

/// Open a session on a branch, in its own worktree. Failures are shown as git
/// wrote them — "already checked out at …" names the directory you want, and
/// rewriting it would take that away.
@MainActor
func newSessionOnBranch(_ manager: SessionManager, for session: Session? = nil,
                        inFolder folder: String? = nil, name: String? = nil, from directory: String? = nil,
                        title: String = "New Branch From\u{2026}") {
    let from = directory ?? manager.branchSource(for: session, inFolder: folder)
    Task { @MainActor in
        // Started before the dialog and collected after it, so the network time
        // overlaps the typing rather than following it. Nothing on screen is
        // waiting for this and nothing on screen changes when it lands: a fetch
        // moves `refs/remotes/*`, and both lists in the dialog are built from
        // `refs/heads`. What it changes is where the branch is about to start —
        // see GitService.defaultBase.
        let fetch = Task { await manager.fetchFromOrigin(in: from) }
        let branches = await manager.localBranches(in: from)
        let withWorktree = await manager.branchesWithWorktrees(in: from)
        let defaultBase = await manager.defaultBase(in: from)
        let catalog = BranchCatalog(local: branches, withWorktree: withWorktree)
        // Read fresh rather than from the listing's cache: the row names where
        // this worktree will go, and a stale answer would be a wrong one.
        let home = from.flatMap(GitWorktree.repositoryHome(containing:))
        var location: WorktreeLocationChoice?
        if let home {
            location = WorktreeLocationChoice(
                repoHome: home, template: await GitService.worktreeLocation(root: home),
                canReset: await GitService.worktreeLocationIsOnlyLocal(root: home))
        }
        guard let window = AppDelegate.mainWindow else { return }
        // The remote branches are loaded *while the sheet is up*, never before
        // it. They are the one list whose length tracks the repository rather
        // than the person (140ms at 4000 refs), and none of them is needed to
        // put the sheet on screen: what you usually want is local, and what you
        // came here to do is usually type a name that doesn't exist yet. So the
        // sheet opens on the local half and the rest arrives underneath it. The
        // fetch above is the same bargain, one step earlier.
        guard let answer = await BranchSheet.present(
            over: window, catalog: catalog, defaultBase: defaultBase, name: name,
            title: title, location: location,
            whileOpen: { sheet in
                catalog.beginLoadingRemote()
                Task { @MainActor in
                    // Twice, and on purpose. First with the refs already on
                    // disk, which is a local read and arrives in milliseconds;
                    // then again once the fetch lands, which is a network round
                    // trip and may have added or pruned branches. Waiting for
                    // the fetch before showing anything would put the network
                    // between you and a list that was sitting there already.
                    catalog.finishLoadingRemote(await manager.remoteBranches(in: from))
                    sheet.catalogChanged()
                    await fetch.value
                    catalog.finishLoadingRemote(await manager.remoteBranches(in: from))
                    sheet.catalogChanged()
                }
            })
        else { return }
        // The fork point has to be current *before* `worktree add` resolves it,
        // which is the whole point of running the fetch at all. By here it has
        // usually had the life of the dialog to finish, so this nearly always
        // returns immediately.
        //
        // **But the wait is bounded, because the dialog is not a wait.** The
        // name is prefilled and Return accepts it, so the sheet can be answered
        // in well under a second, which leaves the whole network round trip on
        // this line. Off the VPN that hosts the remote, or on a host that is
        // simply not answering, `git fetch` sits in a TCP connect for over a
        // minute; `GIT_TERMINAL_PROMPT=0` keeps it from asking for credentials
        // but nothing keeps it from hanging. You pressed Create, the sheet
        // vanished, and nothing happens at all: no session, no progress, no
        // reason given.
        //
        // Giving up on the fetch is the cheap failure. It costs exactly what
        // being offline already costs (see `fetchFromOrigin`, which swallows a
        // failed fetch for the same reason): the branch forks from the last
        // refs we managed to pull, which is where it would have forked from a
        // moment ago anyway. The fetch is not cancelled, only stopped waiting
        // for, so it still lands for next time.
        //
        // That wait happens with the new session already on screen, saying it's
        // preparing (`SessionManager.newSession(onBranch:)`), and so does a
        // refusal: on its own page, not in an alert.
        // Written before the worktree is made, which reads it.
        if let home, let changed = answer.location {
            await manager.applyWorktreeLocation(changed, forRepository: home)
        }
        switch answer.choice {
        case .branch(let branch, let base):
            manager.newSession(onBranch: branch, base: base, from: from, inFolder: folder, after: fetch)
        case .pullRequest(let pr):
            manager.newSession(onPullRequest: pr, from: from, inFolder: folder, after: fetch)
        }
    }
}

/// ⇧⌘N: New Worktree Session, as a sheet with a placeholder branch already
/// in it, selected, so Return makes the session at once and typing names
/// the branch. The From and Location rows are there to change when the
/// default branch or Wortel's folder isn't the one. Outside a repository
/// there's nothing to ask: the instant path says why on the session's page.
@MainActor
func newWorktreeSessionFromSheet(_ manager: SessionManager, inFolder folder: String? = nil) {
    let from = manager.branchSource(inFolder: folder)
    guard let from, GitWorktree.repositoryHome(containing: from) != nil else {
        manager.newWorktreeSession(from: from, inFolder: folder)
        return
    }
    newSessionOnBranch(manager, inFolder: folder, name: manager.placeholderBranch(), from: from,
                       title: "New Worktree Session")
}

/// A folder header row's SwiftUI content: the section title styled like a
/// native sidebar header, plus the folder context menu. Expansion, the
/// disclosure chevron, click-to-toggle, and all drag & drop live in the
/// NSOutlineView layer (SidebarOutlineView) — this is presentation only.
struct SidebarHeaderContent: View {
    let manager: SessionManager
    let folder: String

    /// Tilde-abbreviated, like a session row's path: `~/Developer/wortel` is
    /// the way anyone would write it, and the home prefix is the same on every
    /// row so it earns none of this width.
    private var root: String? {
        manager.root(ofFolder: folder).map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    var body: some View {
        SidebarSectionLabel(title: folder,
                            collapsed: manager.isFolderCollapsed(folder),
                            attention: manager.attention(inFolder: folder))
            // The directory the folder stands for (where a new session in it
            // starts) is on hover, not on the header: a path on every header
            // was grey noise for something you rarely need to see. The "+" says
            // it too, and right-click sets or clears it.
            .help(root ?? "")
            // Where the rows' names start, so the two line up.
            .padding(.leading, 20)
            // Clear of the "…" and "+" that appear on hover (SidebarPillRowView).
            .padding(.trailing, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Native right-click, instant on rightMouseDown — same reasoning as
            // the session rows above.
            .overlay(RightClickCatcher(onRightClick: {}, makeMenu: makeContextMenu))
    }

    /// Build the native right-click menu, freshly each time it opens.
    private func makeContextMenu() -> NSMenu {
        FolderActions.menu(for: folder, manager: manager)
    }
}

/// What can be done to a folder: its header's right-click menu and its hover
/// "…". Named and drawn as the session menus are (SessionActions), so "Rename…"
/// is one thing wherever it appears.
@MainActor
enum FolderActions {
    static func menu(for folder: String, manager: SessionManager) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ glyph: String, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: handler)
            item.setGlyph(glyph)
            menu.addItem(item)
        }
        // "New Session", as in the Session menu: the menu is the folder's, so
        // naming the folder again only made it the widest item.
        item("New Session", "plus.square") { manager.newSession(inFolder: folder) }
        item("New Worktree Session\u{2026}", "plus.square.dashed") {
            newWorktreeSessionFromSheet(manager, inFolder: folder)
        }
        item("Rename\u{2026}", "pencil") {
            if let name = promptFolderName(title: "Rename Folder", confirm: "Rename", initial: folder) {
                manager.renameFolder(folder, to: name)
            }
        }
        menu.addItem(.separator())
        // Non-destructive: the sessions drop to the top level, they're not
        // closed, and nothing on disk is touched. Named for what happens, since
        // "Delete Folder" in a Mac app reads as deleting one from the disk.
        let hasSessions = manager.sessions.contains { $0.folderPath == folder }
        item(hasSessions ? "Ungroup Sessions" : "Remove from Sidebar",
             hasSessions ? "rectangle.stack.badge.minus" : "minus.circle") {
            manager.deleteFolder(folder)
        }
        return menu
    }
}

/// One sidebar row: the session name, and the inline rename field it becomes.
///
/// The trailing slot — status indicator, or the close button while the row is
/// hovered — is *not* here. It lives on the row view (SidebarPillRowView),
/// because only the row shares the selection pill's geometry: cell views are
/// inset by the source-list style, so anything trailing-aligned in here sits
/// further from the edge than the button does. Putting both in one slot the row
/// view owns is what keeps them interchangeable.
struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let isEditing: Bool
    /// A worktree session shows its branch: as a second line under the name
    /// once the session is named for its task, and until then, when the name
    /// still *is* the branch, as a leading glyph — without which it sits in the
    /// list looking exactly like a session that's just a shell in a directory.
    let isInWorktree: Bool
    /// The pointer is on the row: a name too long for it slides to show the
    /// rest (MarqueeName).
    let isHovered: Bool
    /// What the session is waiting on you for, while it is: the row's tooltip.
    let waiting: Waiting?
    let commit: (String) -> Void
    let cancel: () -> Void

    struct Waiting {
        let kind: AttentionKind
        /// What it said: the body of its notification.
        let message: String?
        let since: Date?
    }

    var body: some View {
        // Content padded inside an inset pill (~6pt from the cell edges, so
        // it's not edge-to-edge).
        HStack(spacing: 8) {
            // The same symbol the repo header's branch carries, so the two
            // places that mean "branch" look like the same fact. Not while
            // editing: the rename field should start where every other one does.
            // And not once the branch has its own line below the name.
            if isInWorktree && !isEditing && !session.showsBranchLine {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    SidebarRenameField(name: session.name, commit: commit, cancel: cancel)
                        // The editor sets its text 2pt in (its line padding),
                        // measured: back by that, the text is where the name was.
                        .padding(.leading, -2)
                } else {
                    // The folder prefix lives in the section header, so the row
                    // shows just the leaf ("giel/hello" -> "hello"). The rename
                    // field still edits the full name (SidebarRenameField), so
                    // retyping the prefix is how you move between folders — but
                    // it opens with only the leaf selected.
                    // An ellipsis at rest; on hover, a name that doesn't fit
                    // slides to show the rest, as the ChatGPT app's do.
                    MarqueeName(text: session.leafName, active: isHovered)
                }
                if session.folderIsGone, !isEditing {
                    // Under the name, where a worktree's branch would be: the
                    // row's folder was deleted. Close it with its ×.
                    HStack(spacing: 3) {
                        Image(systemName: "folder.badge.minus")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        TruncatingLabel(text: "Folder is gone", font: .systemFont(ofSize: 11),
                                        color: .tertiaryLabelColor)
                    }
                    .help("This session's folder no longer exists. Close the session when you're done with it.")
                } else if session.showsBranchLine, let branch = session.worktreeLabel {
                    // Where the work lives, under what the work is. Only for a
                    // worktree session whose name has moved on from the branch;
                    // the row height follows `hasSecondLine` (SidebarOutlineView).
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        TruncatingLabel(text: branch, font: .systemFont(ofSize: 11),
                                        color: .tertiaryLabelColor)
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        // What a waiting session said, and for how long, on hover. It used to
        // be a second line under the name, but the dot already says a session
        // wants you and opening it shows the question itself; the line only
        // made rows grow and shrink each time an agent finished. The row
        // redraws when the pointer comes onto it, so "4m" is current.
        .help(waiting.map { $0.text(at: .now) } ?? "")
    }
}

/// A session's name in its row: cut short with an ellipsis at rest, and on
/// hover, when it doesn't fit, a marquee: after the pointer has rested a
/// moment it slides slowly left to show the rest, between soft edges, and
/// stops with the name's end by the row's buttons, as the ChatGPT app's rows
/// do. Leaving the row puts it back.
///
/// Driven frame by frame from when the hover began (TimelineView), not by a
/// SwiftUI animation: the sliding text appears in the same update the hover
/// does, and an animation started there was skipped, the name jumping
/// straight to its end.
private struct MarqueeName: View {
    let text: String
    let active: Bool

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    /// When the pointer came onto the row.
    @State private var hoverStart: Date?
    /// The slide has reached its end: stop redrawing.
    @State private var settled = false

    private static let font = Font.system(size: 13)
    /// Points a second: slow enough to read along.
    static let speed: CGFloat = 24
    /// How long the pointer rests on the row before it moves: passing over a
    /// row on the way somewhere doesn't set it going.
    static let delay: TimeInterval = 1.0
    /// The soft edges: wider where the text has come from than where it's
    /// going, so the end of the name sits close to the row's buttons.
    private static let leadingFade: CGFloat = 24
    private static let trailingFade: CGFloat = 16
    /// How far the sliding text may run past its box to the left: the
    /// pill's padding, so it slides out at the pill's edge.
    private static let bleed: CGFloat = 10

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    /// To the name's end exactly: the trailing fade shrinks away as the end
    /// arrives, so the last letter lands by the buttons unfaded.
    private var distance: CGFloat { overflow }
    private var sliding: Bool { active && overflow > 0.5 }

    var body: some View {
        ZStack(alignment: .leading) {
            if sliding, let hoverStart {
                // Hung from an empty box's leading edge: a view wider than its
                // container is otherwise centred in it, and the name jumped
                // left by half its overflow on hover and ended that far off.
                // (A flexible frame's `.leading` didn't hold it; measured.)
                TimelineView(.animation(minimumInterval: nil, paused: settled)) { context in
                    let slid = Self.offset(after: context.date.timeIntervalSince(hoverStart), distance: distance)
                    Color.clear
                        .frame(height: 16)
                        .overlay(alignment: .leading) {
                            Text(text)
                                .font(Self.font)
                                .lineLimit(1)
                                .fixedSize()
                                .offset(x: -slid)
                                // Where it sits at rest, inside the widened box.
                                .padding(.leading, Self.bleed)
                        }
                        .clipped()
                        // No fade on the left until there's something past the
                        // edge to fade: it grows with the slide, up to its full
                        // width once that much has gone by.
                        // And on the right, only while there's text still
                        // hidden there: it shrinks away as the end arrives.
                        .mask(edges(leading: min(Self.leadingFade, slid),
                                    trailing: min(Self.trailingFade, max(0, distance - slid)),
                                    width: boxWidth + Self.bleed))
                        // Out to the pill's edge while it slides, so the text
                        // fades away there rather than vanishing 10pt short of it.
                        .padding(.leading, -Self.bleed)
                }
            } else {
                Text(text)
                    .font(Self.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
        // The name's full width, measured off to the side.
        .background(
            Text(text).font(Self.font).lineLimit(1).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 },
            alignment: .leading)
        .onChange(of: active) { _, now in begin(now) }
        .onAppear { begin(active) }
        .accessibilityLabel(text)
    }

    private func begin(_ hovering: Bool) {
        settled = false
        hoverStart = hovering ? Date() : nil
        guard hovering else { return }
        // Stop redrawing once it has arrived.
        let total = Self.delay + Self.duration(for: distance)
        let started = hoverStart
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.05) {
            if hoverStart == started { settled = true }
        }
    }

    /// Faded at the ends: on the left by `leading` points (what has slid past
    /// the edge), and on the right, where the rest of the name is still to
    /// come.
    ///
    /// The left one is eased (smoothstep through a few stops) rather than a
    /// straight ramp, which read as a hard line.
    private func edges(leading leadingFade: CGFloat, trailing trailingFade: CGFloat,
                       width: CGFloat) -> some View {
        let leading = width > 0 ? leadingFade / width : 0
        let trailing = width > 0 ? trailingFade / width : 0
        let steps = Array(stride(from: 0.0, through: 1.0, by: 0.2))
        func eased(_ step: Double) -> Double { step * step * (3 - 2 * step) }
        // In from the left, eased...
        var stops: [Gradient.Stop] = steps.map {
            .init(color: .black.opacity(eased($0)), location: leading * $0)
        }
        // ...and out to the right, eased the same way.
        stops += steps.reversed().map {
            .init(color: .black.opacity(eased($0)), location: 1 - trailing * $0)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    static func duration(for distance: CGFloat) -> TimeInterval {
        TimeInterval(distance / speed)
    }

    /// How far the name has slid `elapsed` seconds into the hover: nothing
    /// during the delay, then eased in and out over the distance, then there.
    static func offset(after elapsed: TimeInterval, distance: CGFloat) -> CGFloat {
        let duration = self.duration(for: distance)
        guard elapsed > delay, duration > 0 else { return 0 }
        let t = min(1, (elapsed - delay) / duration)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return distance * CGFloat(eased)
    }
}

/// What a waiting session said, or what kind of wait it is, and for how long.
/// "Allow edit to App.swift? · 4m", "Finished its turn · now".
extension SessionRow.Waiting {
    func text(at now: Date) -> String {
        let what = message ?? {
            switch kind {
            case .needsInput: return "Waiting on you"
            case .failed: return "A command failed"
            case .turnDone: return "Finished its turn"
            case .finished: return "A command finished"
            }
        }()
        guard let since else { return what }
        return "\(what) · \(Self.elapsed(from: since, to: now))"
    }

    /// "now", "4m", "2h", "3d".
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

/// The row's trailing status glyph, hosted by the row view in the same slot as
/// the close button so the two are interchangeable — see SidebarPillRowView.
///
/// Attention (blocked on you / failed / long command done while unselected) wins
/// over busy — once you select the session the attention clears and the busy dot
/// shows if a command is still running. The dot's colour encodes *why*: amber =
/// waiting on you, red = failed, mint = an agent finished its turn, blue = a
/// plain command finished. With the selection pill neutral, a dot keeps its
/// colour on the selected row too. A non-selected session you haven't caught up
/// with also carries a quiet hollow ring, which sits *next to* the busy dot rather
/// than being replaced by it — otherwise a session that failed and immediately
/// started working again would look like any other busy session.
///
/// It reads the manager directly rather than taking its state as arguments, so
/// selection and attention changes redraw it through Observation without the
/// outline reloading anything.
struct SessionStatusIndicator: View {
    let manager: SessionManager
    let session: Session

    private var isSelected: Bool { manager.selectedID == session.id }

    /// This row's ⌘1…⌘9, while ⌘ is held: its place in the drawn order.
    private var shortcutHint: String? {
        manager.shortcutNumber(for: session.id).map { "\u{2318}\($0)" }
    }

    var body: some View {
        ZStack {
            if let shortcutHint {
                Text(verbatim: shortcutHint)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                status.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: shortcutHint)
        // Centre in whatever slot the row view gives us — the same rect the
        // close button gets, so swapping between them doesn't shift anything.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: some View {
        HStack(spacing: 4) {
            // A worktree on its way: the same three dots as a working agent,
            // because to the row it's the same news (something is under way
            // here, nothing for you yet). The page itself has the spinner.
            // Orange once git has refused, the colour of a session waiting on
            // you.
            if let preparation = session.preparation {
                if preparation.failure != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else {
                    WorkingIndicator()
                }
            }
            // The unread trail sits *beside* the busy dot rather than behind it:
            // a session that failed and is already working again still says so.
            // Hidden while a loud dot is up (the dot outranks it) and on the
            // selected row (you're on it, the dwell clock is running).
            // Marked unread by hand shows even on the selected row: you asked
            // for it, and a flag you can't see looks like it didn't take.
            if let kind = session.unread, !isSelected || session.markedUnread, session.attention == nil {
                // Quiet "you haven't caught up here" trail: a hollow ring in the
                // kind's colour, no pulse.
                Circle()
                    .stroke(Color(nsColor: Self.attentionColor(kind)).opacity(0.8), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
            }
            if let kind = session.attention {
                // Urgent states (waiting on you / failed) breathe to catch the eye
                // in peripheral vision; a clean finish sits still.
                AttentionDot(color: Self.attentionColor(kind),
                             motion: kind.pulses ? .pulse : .still)
            } else if session.isBusy {
                // Working: three small grey dots lighting up in turn, the
                // "someone is writing" of Messages and every chat app, because
                // that is what a working agent is doing. Before this it was a
                // grey dot breathing, which read as a status light rather than
                // as activity, and next to the coloured dots as one more of
                // them. A spinner was tried before that and dropped: it says
                // *the app* is loading, and several turning at once was the
                // busiest thing on screen for the least urgent news in it.
                WorkingIndicator()
            }
        }
    }

    static func attentionColor(_ kind: AttentionKind) -> NSColor {
        switch kind {
        case .needsInput: return .systemOrange
        case .failed: return .systemRed
        case .turnDone: return .systemMint
        case .finished: return .systemBlue
        }
    }
}

/// A status dot that can pulse (urgent) or sit still. (Working has its own
/// indicator: `WorkingIndicator`.)
///
/// A layer and a Core Animation animation rather than a SwiftUI
/// `repeatForever`: the render server runs it, so a list with several agents
/// working costs the main thread nothing per frame, where a SwiftUI animation
/// re-evaluates the hosting view on every one of them. The animation is added
/// when the dot reaches a window and goes with its layer when it leaves.
struct AttentionDot: NSViewRepresentable {
    enum Motion: Equatable {
        /// Opacity and a touch of scale, fast enough to catch the eye.
        case pulse
        case still
    }

    let color: NSColor
    var diameter: CGFloat = 7
    let motion: Motion

    func makeNSView(context: Context) -> DotView { DotView() }

    func updateNSView(_ view: DotView, context: Context) {
        view.configure(color: color, motion: motion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }

    final class DotView: NSView {
        private var color: NSColor = .clear
        private var motion: Motion = .still
        private let dot = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }

        func configure(color: NSColor, motion: Motion) {
            let motionChanged = motion != self.motion
            self.color = color
            self.motion = motion
            needsDisplay = true
            if motionChanged { applyMotion() }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
            CATransaction.commit()
        }

        /// A layer's colour is a fixed CGColor, so a change between light and
        /// dark has to re-resolve it: without this a dot kept the colour of the
        /// appearance it was first drawn in (the old grey working dot showed
        /// near-black on a dark sidebar that way).
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        /// Colours resolve against this view's appearance, so a dynamic colour
        /// follows light and dark instead of freezing at whatever was current.
        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dot.backgroundColor = color.cgColor
            }
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMotion()
        }

        private func applyMotion() {
            dot.removeAllAnimations()
            dot.opacity = 1
            guard window != nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            switch motion {
            case .still:
                return
            case .pulse:
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0.35
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1
                grow.toValue = 1.18
                let group = CAAnimationGroup()
                group.animations = [fade, grow]
                group.duration = 0.7
                add(group)
            }
        }

        private func add(_ animation: CAAnimation) {
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = false
            dot.add(animation, forKey: "motion")
        }
    }
}

/// "Working": three small dots in a soft wave, as a chat app shows someone
/// typing. Each brightens and lifts a point as the wave passes, then settles,
/// so the three read as one ripple rather than as blinking lights. Grey, so it
/// never competes with the coloured dots that mean something needs you, but
/// never faint either: about a third there at rest, two thirds at the crest.
///
/// Core Animation for the same reason as `AttentionDot`: the render server
/// runs it, so a sidebar full of working agents costs the main thread nothing.
/// The colour is resolved for the view's own appearance, and again when that
/// changes, so it's light on a dark sidebar and dark on a light one. With
/// Reduce Motion the dots sit still.
struct WorkingIndicator: NSViewRepresentable {
    static let dotDiameter: CGFloat = 3
    static let spacing: CGFloat = 2
    /// How far a dot rises at the crest of the wave.
    static let lift: CGFloat = 1.2

    func makeNSView(context: Context) -> DotsView { DotsView() }
    func updateNSView(_ view: DotsView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsView, context: Context) -> CGSize? {
        CGSize(width: Self.dotDiameter * 3 + Self.spacing * 2, height: Self.dotDiameter + Self.lift * 2)
    }

    final class DotsView: NSView {
        private let dots = (0..<3).map { _ in CALayer() }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dots.forEach { layer?.addSublayer($0) }
            // The colour is set in `updateLayer`; ask for it, or a new view
            // whose appearance never changes would keep colourless dots.
            needsDisplay = true
            // Reduce Motion turned on or off while agents work: re-read it.
            NotificationCenter.default.addObserver(
                self, selector: #selector(displayOptionsChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: NSWorkspace.shared)
        }

        @objc private func displayOptionsChanged() { animate() }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let d = WorkingIndicator.dotDiameter
            let y = (bounds.height - d) / 2
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * (d + WorkingIndicator.spacing), y: y, width: d, height: d)
                dot.cornerRadius = d / 2
            }
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = NSColor.labelColor.cgColor
                dots.forEach { $0.backgroundColor = color }
            }
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            animate()
        }

        private func animate() {
            dots.forEach { $0.removeAllAnimations() }
            // Every direct change below without Core Animation's implicit fade:
            // that fade starts from full opacity, so new dots flashed bright
            // before settling, Reduce Motion or not.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            // The label colour itself, dimmed by opacity: about a third there at
            // rest and two thirds at the crest, so it reads as grey in either
            // appearance without going faint.
            let rest: Float = 0.32
            let crest: Float = 0.68
            guard window != nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                dots.forEach { $0.opacity = 0.5 }
                return
            }
            // One wave through the three every 1.3s: each brightens and lifts
            // in a fifth of it and settles in the next fifth, a beat after the
            // one before, then all three rest together before the next.
            let now = CACurrentMediaTime()
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, dot) in dots.enumerated() {
                dot.opacity = rest
                let glow = CAKeyframeAnimation(keyPath: "opacity")
                glow.values = [rest, crest, rest, rest]
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                // Up is +y in a layer-backed view.
                rise.values = [0, WorkingIndicator.lift, 0, 0]
                for frames in [glow, rise] {
                    frames.keyTimes = [0, 0.2, 0.42, 1]
                    frames.timingFunctions = [ease, ease, ease]
                }
                let wave = CAAnimationGroup()
                wave.animations = [glow, rise]
                wave.duration = 1.3
                wave.repeatCount = .infinity
                wave.beginTime = now + Double(index) * 0.14
                wave.isRemovedOnCompletion = false
                dot.add(wave, forKey: "working")
            }
        }
    }
}

/// A brief coloured ring drawn over the terminal when you switch into a session
/// that was waiting on you — a quick "this is the one" cue. Invisible at rest;
/// each fresh `flash.id` fades a ring in fast and back out. Purely decorative,
/// so it never intercepts clicks.
private struct AttentionFlashOverlay: View {
    let flash: AttentionFlash?
    @State private var opacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(color, lineWidth: 2.5)
            .padding(1.5)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: flash?.id) { _, id in
                guard id != nil else { return }
                if reduceMotion {
                    opacity = 0.85
                    withAnimation(.easeIn(duration: 0.5).delay(0.4)) { opacity = 0 }
                } else {
                    opacity = 0
                    withAnimation(.easeOut(duration: 0.12)) { opacity = 0.85 }
                    withAnimation(.easeIn(duration: 0.7).delay(0.12)) { opacity = 0 }
                }
            }
    }

    private var color: Color {
        switch flash?.kind {
        case .needsInput: return .orange
        case .failed: return .red
        case .turnDone: return .mint
        case .finished: return .blue
        case nil: return .clear
        }
    }
}

/// The middle pane: just the terminal. The git panel is a sibling split item now
/// rather than a child of this view, and the window owns the title and toolbar —
/// so neither .navigationTitle nor .toolbar belongs here any more. Pane width is
/// the split item's business too (see MainSplitViewController), not a .frame.
/// The git and file-tree models are still here only to keep the inspector
/// pointed at the selected session — visibility, pane, repo and tree root all
/// follow from that — which is naturally expressed as a SwiftUI onChange.
struct DetailPane: View {
    let runtime: GhosttyRuntime
    @Bindable var manager: SessionManager
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel

    var body: some View {
        TerminalContainer(runtime: runtime, session: manager.selected,
                          preparing: manager.selected?.preparation != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Over the terminals rather than instead of them: the host keeps
            // every session's view alive, and taking it out would rebuild them.
            .overlay {
                if manager.sessions.isEmpty {
                    EmptySessionsPage(manager: manager)
                }
            }
            .overlay {
                if let session = manager.selected, let preparation = session.preparation {
                    WorktreePreparingPage(
                        preparation: preparation,
                        retry: { manager.retryWorktree(session) },
                        open: { manager.openPreparedWorktree(session) },
                        close: { manager.close(session) })
                }
            }
            .overlay { AttentionFlashOverlay(flash: manager.attentionFlash) }
            .onAppear { focusInspector() }
            .onChange(of: manager.selectedID) { _, _ in focusInspector() }
            .onChange(of: manager.selected?.cwd) { _, _ in focusInspector() }
            // The git panes follow where the session started (`homeFolder`),
            // which a worktree being attached or restored moves.
            .onChange(of: manager.selected?.originCwd) { _, _ in focusInspector() }
            // The repo resolves a beat after the cwd (a work-tree root has to be
            // walked to), and the tree roots on it — so re-root when it lands,
            // or a session would show its cwd where its repo root belongs until
            // something else moved.
            .onChange(of: git.repo?.root) { _, _ in files.reroot() }
            // The tree does no work while it's off screen, so it catches up
            // when it comes back however it does (the column reshown keeps the
            // pane mounted, so its own `onAppear` isn't enough).
            .onChange(of: git.showsFiles) { _, shows in if shows { files.resync() } }
            // The tree's git colouring is a view of the same status the changes
            // list draws, so it follows the same refreshes.
            .onChange(of: git.repo?.status) { _, _ in files.refreshDecorations() }
    }

    private func focusInspector() {
        git.focus(session: manager.selected)
        files.focus(session: manager.selected)
    }
}

/// Hosts the terminal. Reuses TerminalHostViewController so every session's
/// SurfaceView stays alive across switches (no rebuild). SwiftUI updates the
/// existing controller — makeNSViewController runs once — so the host and its
/// live views persist.
private struct TerminalContainer: NSViewControllerRepresentable {
    let runtime: GhosttyRuntime
    let session: Session?
    /// The session's worktree isn't there yet: no shell to show, and the one
    /// shown before it is put away so it can't be typed into by mistake.
    let preparing: Bool

    func makeNSViewController(context: Context) -> TerminalHostViewController {
        TerminalHostViewController()
    }

    func updateNSViewController(_ controller: TerminalHostViewController, context: Context) {
        if preparing {
            controller.showNothing()
        } else if let session {
            controller.show(session, runtime: runtime)
        }
    }
}

/// The rename field in a session's row: AppKit rather than a SwiftUI
/// TextField, for the one thing SwiftUI's couldn't do, which is not be a
/// white box. It draws nothing of its own: the row draws its pill with an
/// accent edge (SidebarPillRowView.showsEditing), and the text sits on it
/// exactly where the name sat, in the name's font.
///
/// Every way out ends editing first and acts after: Return and a click
/// elsewhere save, Escape cancels. Tearing the field out while it still had
/// the keyboard left AppKit's field editor dangling, and the sidebar stopped
/// taking clicks.
///
/// It opens with the leaf selected ("Worker" in "Wakker/Worker"): the name it
/// edits is the full one, and a first keystroke taking the folder with it
/// moved the session out of its folder without saying so. Retyping the prefix
/// is still how you move one between folders.
private struct SidebarRenameField: NSViewRepresentable {
    let name: String
    let commit: (String) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A field in a source-list table is given a white background when it
    /// starts editing, by the table: this one keeps none, whoever asks. And
    /// no alignment insets, so SwiftUI puts its frame where the name's was.
    final class Field: NSTextField {
        override var drawsBackground: Bool {
            get { false }
            set {}
        }
        override var isBezeled: Bool {
            get { false }
            set {}
        }
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field(frame: .zero)
        field.cell = CenteredTextFieldCell(textCell: name)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.focus(field, attemptsLeft: 20)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
    }

    /// Removed without being left (another row's Rename, a session switch, the
    /// row closed): the edit ends here, while the field is still in its window,
    /// so AppKit's field editor isn't left behind holding the keyboard, and the
    /// rename is dropped rather than saved, as the move away meant.
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.abandon()
        if field.currentEditor() != nil {
            field.abortEditing()
            if let window = field.window, window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
        MainMenu.setTextEditing(false)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarRenameField
        private var cancelling = false
        private var ended = false

        init(_ parent: SidebarRenameField) { self.parent = parent }

        /// The field is going away: whatever ends its edit now does nothing.
        func abandon() { ended = true }

        /// Into the field once it's in a key window, then the leaf selected.
        func focus(_ field: NSTextField, attemptsLeft: Int) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                guard let window = field.window, window.isKeyWindow else {
                    if attemptsLeft > 0 { self.focus(field, attemptsLeft: attemptsLeft - 1) }
                    return
                }
                window.makeFirstResponder(field)
                MainMenu.setTextEditing(true)
                let name = field.stringValue
                if let leaf = SessionName.leafRange(of: name) {
                    field.currentEditor()?.selectedRange = leaf
                } else {
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelling = true
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !ended, let field = notification.object as? NSTextField else { return }
            ended = true
            MainMenu.setTextEditing(false)
            let text = field.stringValue
            // After this event: the row goes away with the edit, and it
            // mustn't while AppKit is still finishing it.
            DispatchQueue.main.async { [parent, cancelling] in
                if cancelling { parent.cancel() } else { parent.commit(text) }
            }
        }
    }
}

/// The window with no session in it: what's left after the last one closes.
/// Open Folder first, because a new task is nearly always in a project.
struct EmptySessionsPage: View {
    let manager: SessionManager

    var body: some View {
        ZStack {
            Color(nsColor: Chrome.content)
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No sessions")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open a folder to start a session in it, or drop one on the sidebar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                HStack(spacing: 8) {
                    Button("New Session") { manager.newSession() }
                    Button("Open Folder\u{2026}") { openFolderSession(manager) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .padding(24)
        }
    }
}
