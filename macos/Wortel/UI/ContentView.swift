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

/// Pick a directory. The whole of ⌘O and of a folder's "Set Directory…", and
/// the only part of Wortel that ever opens a file panel.
///
/// Directories only, and no "New Folder" button: this points at a project that
/// already exists. Modal rather than a sheet for the same reason the name
/// prompt above is — one question, one answer, and no state to thread through
/// the sidebar. Returns nil on Cancel.
@MainActor
func chooseDirectory(title: String, startingAt current: String? = nil) -> String? {
    let panel = NSOpenPanel()
    panel.message = title
    panel.prompt = "Open"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
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
                    tallIDs: Set($0.sessions.filter(\.hasSecondLine).map(\.id)))
            })
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 2) {
                    // Grouped like the Session menu, and in the same order, so
                    // the two places you reach for this agree with each other:
                    // ways to start a session, then the two folder verbs.
                    Menu {
                        Button("New Session") { manager.newSession() }
                        // "New Session" here looks global but isn't — it lands
                        // in whichever folder the selection is in. This is the
                        // way out of that, and it belongs next to the thing it
                        // is the exception to rather than only on a shortcut
                        // nobody has met yet.
                        Button("New Session at Home") { manager.newHomeSession() }
                        // Its own branch and its own files: what makes running
                        // two agents in one repository safe.
                        Button("New Session on Branch…") { newSessionOnBranch(manager) }
                        Divider()
                        Button("New Folder…") {
                            if let name = promptFolderName(title: "New Folder", confirm: "Create") {
                                manager.addFolder(named: name)
                            }
                        }
                        // The way to reach a project no session is standing in
                        // without typing `cd` — and the way a folder usually
                        // gets its directory, since opening one creates the
                        // folder for it.
                        Button("Open Folder…") { openFolderSession(manager) }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New Session or Folder")
                    TelemetryInfoButton()
                        .frame(width: 24, height: 24)
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

/// The ⓘ beside the +, and the anchor the usage-data popover hangs off.
///
/// AppKit rather than a SwiftUI `Button` with `.popover`, for the one thing this
/// popover has to do that SwiftUI's cannot: appear without taking the keyboard
/// away from the terminal (see `TelemetryNotice`). That needs the real `NSView`
/// to anchor to and the real `NSPopover` to configure, so the button is the
/// AppKit one and the presenter owns the rest.
struct TelemetryInfoButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: TelemetryNotice.shared,
                              action: #selector(TelemetryNotice.toggleVisible(_:)))
        button.image = NSImage(systemSymbolName: "info.circle",
                               accessibilityDescription: "Anonymous usage data")
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Anonymous usage data"
        TelemetryNotice.shared.register(anchor: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}
}

/// One outline row's SwiftUI content: the session row on its selection pill,
/// plus the row context menu. Reads the manager's observable
/// state directly, so selection, rename, and attention changes update live
/// inside the hosted view — no outline reload involved.
struct SidebarRowContent: View {
    let manager: SessionManager
    let session: Session

    var body: some View {
        SessionRow(
            session: session,
            isSelected: manager.selectedID == session.id,
            isEditing: manager.editingID == session.id,
            isInWorktree: session.isInOwnWorktree,
            waiting: session.attention.map { kind in
                let note = manager.attentionNote(for: session)
                return SessionRow.Waiting(kind: kind, message: note.message, since: note.since)
            },
            commit: { newName in
                manager.rename(session, to: newName)
                manager.editingID = nil
            },
            cancel: { manager.editingID = nil })
            // The selection pill is drawn by the row view (SidebarPillRowView),
            // full row width — this content just sits on top of it.
            .padding(.leading, 12)
            // Keeps a long name clear of the trailing slot, which the row view
            // owns (status indicator, or "…" and × while hovered). Only
            // decides where the name truncates, so it's deliberately generous
            // rather than measured against the cell's inset.
            .padding(.trailing, 44)
            // Fill the row height and center vertically — otherwise the short
            // name+path content sits at the top of the (taller) row, leaving
            // dead space below each session that reads as loose spacing.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Native right-click, popped instantly on rightMouseDown, and it
            // selects the row on the way so the terminal follows. SwiftUI's
            // `.contextMenu` presents on a press-hold and rebuilds its content
            // on every render — the same lag the git panel abandoned it over.
            .overlay(RightClickCatcher(onRightClick: rightClickSelect, makeMenu: makeContextMenu))
    }

    /// Select the row when it's right-clicked, so the detail pane follows it —
    /// matching a left-click.
    private func rightClickSelect() {
        if manager.selectedID != session.id { manager.selectedID = session.id }
    }

    /// Build the native right-click menu, freshly each time it opens.
    private func makeContextMenu() -> NSMenu {
        SessionActions.menu(for: session, manager: manager)
    }
}

/// What can be done to one session: the row's right-click menu, its hover
/// "…", and (for the selected session) the Session menu, and so the ⌘P
/// palette. One place, so the three can't drift apart.
@MainActor
enum SessionActions {
    static func menu(for session: Session, manager: SessionManager) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Rename") { manager.editingID = session.id })
        if let moveTo = moveToMenu(for: session, manager: manager) {
            let item = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
            item.submenu = moveTo
            menu.addItem(item)
        }
        menu.addItem(ClosureMenuItem(title: "Mark as Unread") { manager.markUnread(session) })
        menu.addItem(.separator())
        // Only for a worktree Wortel made, and it closes the session with it —
        // the directory is what the session *is*. git refuses while there are
        // uncommitted changes, and that refusal is shown rather than overridden:
        // a worktree is where work lives.
        if session.isInOwnWorktree {
            menu.addItem(ClosureMenuItem(title: "Remove Worktree\u{2026}") {
                removeWorktree(session, manager: manager)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Close Session") { manager.requestClose(session) })
        return menu
    }

    static func removeWorktree(_ session: Session, manager: SessionManager) {
        let confirm = NSAlert()
        confirm.messageText =
            "Remove the worktree for \u{201c}\(session.worktreeLabel ?? session.leafName)\u{201d}?"
        confirm.informativeText = "The directory is deleted and the session closes. "
            + "The branch and its commits are untouched, and nothing is removed if there "
            + "are uncommitted changes."
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        manager.removeWorktree(of: session) { message in
            let alert = NSAlert()
            alert.messageText = "Couldn't remove the worktree"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// "Move To": top level plus every other folder, the no-drag way to
    /// refile. Nil when there's nowhere to move to.
    static func moveToMenu(for session: Session, manager: SessionManager) -> NSMenu? {
        let destinations = manager.folderNames.filter { $0 != session.folderPath }
        guard session.folderPath != nil || !destinations.isEmpty else { return nil }
        let submenu = NSMenu(title: "Move To")
        fillMoveTo(submenu, for: session, manager: manager)
        return submenu
    }

    static func fillMoveTo(_ submenu: NSMenu, for session: Session, manager: SessionManager) {
        submenu.removeAllItems()
        if session.folderPath != nil {
            submenu.addItem(ClosureMenuItem(title: "Top Level") {
                manager.moveSession(id: session.id, toFolder: nil, at: .max)
            })
        }
        for folder in manager.folderNames where folder != session.folderPath {
            submenu.addItem(ClosureMenuItem(title: folder) {
                manager.moveSession(id: session.id, toFolder: folder, at: .max)
            })
        }
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
func newSessionOnBranch(_ manager: SessionManager, inFolder folder: String? = nil) {
    Task { @MainActor in
        // Started before the dialog and collected after it, so the network time
        // overlaps the typing rather than following it. Nothing on screen is
        // waiting for this and nothing on screen changes when it lands: a fetch
        // moves `refs/remotes/*`, and both lists in the dialog are built from
        // `refs/heads`. What it changes is where the branch is about to start —
        // see GitService.defaultBase.
        let fetch = Task { await manager.fetchFromOrigin() }
        let branches = await manager.localBranches()
        let withWorktree = await manager.branchesWithWorktrees()
        let defaultBase = await manager.defaultBase()
        let catalog = BranchCatalog(local: branches, withWorktree: withWorktree)
        guard let window = AppDelegate.mainWindow else { return }
        // The remote branches are loaded *while the sheet is up*, never before
        // it. They are the one list whose length tracks the repository rather
        // than the person (140ms at 4000 refs), and none of them is needed to
        // put the sheet on screen: what you usually want is local, and what you
        // came here to do is usually type a name that doesn't exist yet. So the
        // sheet opens on the local half and the rest arrives underneath it. The
        // fetch above is the same bargain, one step earlier.
        guard let choice = await BranchSheet.present(
            over: window, catalog: catalog, defaultBase: defaultBase,
            whileOpen: { sheet in
                catalog.beginLoadingRemote()
                Task { @MainActor in
                    // Twice, and on purpose. First with the refs already on
                    // disk, which is a local read and arrives in milliseconds;
                    // then again once the fetch lands, which is a network round
                    // trip and may have added or pruned branches. Waiting for
                    // the fetch before showing anything would put the network
                    // between you and a list that was sitting there already.
                    catalog.finishLoadingRemote(await manager.remoteBranches())
                    sheet.catalogChanged()
                    await fetch.value
                    catalog.finishLoadingRemote(await manager.remoteBranches())
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
        await fetch.finishing(within: .seconds(3))
        openSessionOnBranch(manager, branch: choice.branch, base: choice.base, inFolder: folder)
    }
}

@MainActor
func openSessionOnBranch(
    _ manager: SessionManager, branch: String, base: String? = nil,
    inFolder folder: String? = nil
) {
    manager.newSession(onBranch: branch, base: base, inFolder: folder) { message in
        let alert = NSAlert()
        alert.messageText = "Couldn't open a worktree for \u{201c}\(branch)\u{201d}"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
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
        HStack(spacing: 6) {
            // The same size as the rows under it, and set apart by colour alone:
            // a small bold header is a second type size and a second weight
            // doing a job the grey already does.
            Text(folder)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            // Open or collapsed, after the name rather than as a triangle in
            // front of it: down when open, turned to point at the name's end
            // when collapsed. The whole header is the button (SidebarOutline).
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(manager.isFolderCollapsed(folder) ? -90 : 0))
                .animation(.easeOut(duration: 0.15), value: manager.isFolderCollapsed(folder))
            // What the folder is hiding. Same dot as a session row's, so it
            // reads as the same fact rather than as a new kind of badge — and
            // it pulses for the same reason, because a blocked agent you can't
            // see is exactly the case this whole system is for.
            if let kind = manager.attention(inFolder: folder) {
                AttentionDot(color: SessionStatusIndicator.attentionColor(kind),
                             motion: kind == .needsInput ? .pulse : .still)
            }
            Spacer(minLength: 4)
        }
            // The directory the folder stands for (where a new session in it
            // starts) is on hover, not on the header: a path on every header
            // was grey noise for something you rarely need to see. The "+" says
            // it too, and right-click sets or clears it.
            .help(root ?? "")
            .padding(.leading, 12)
            // Clear of the "+" that appears on hover (SidebarPillRowView).
            .padding(.trailing, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Native right-click, instant on rightMouseDown — same reasoning as
            // the session rows above.
            .overlay(RightClickCatcher(onRightClick: {}, makeMenu: makeContextMenu))
    }

    /// Build the native right-click menu, freshly each time it opens.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New Session in “\(folder)”") {
            manager.newSession(inFolder: folder)
        })
        menu.addItem(ClosureMenuItem(title: "New Session on Branch…") {
            newSessionOnBranch(manager, inFolder: folder)
        })
        menu.addItem(ClosureMenuItem(title: "Rename Folder…") {
            if let name = promptFolderName(title: "Rename Folder", confirm: "Rename", initial: folder) {
                manager.renameFolder(folder, to: name)
            }
        })
        menu.addItem(.separator())
        // What makes the first item above mean this folder. Worded as "Set"
        // rather than "Choose" because it is a property of the folder, not a
        // one-off open — ⌘O is the one-off.
        menu.addItem(ClosureMenuItem(title: "Set Directory\u{2026}") {
            guard let path = chooseDirectory(
                title: "Set the directory for \u{201c}\(folder)\u{201d}",
                startingAt: manager.root(ofFolder: folder)) else { return }
            manager.setRoot(path, ofFolder: folder)
        })
        // Only offered when there is one, and it turns the folder back into a
        // plain label rather than deleting anything.
        if manager.root(ofFolder: folder) != nil {
            menu.addItem(ClosureMenuItem(title: "Clear Directory") {
                manager.setRoot(nil, ofFolder: folder)
            })
        }
        menu.addItem(.separator())
        // Non-destructive: the sessions drop to the top level, they're not closed.
        menu.addItem(ClosureMenuItem(title: "Delete Folder") { manager.deleteFolder(folder) })
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
    /// What the session is waiting on you for, while it is: shown as the
    /// row's second line, in place of the branch.
    let waiting: Waiting?
    let commit: (String) -> Void
    let cancel: () -> Void

    struct Waiting {
        let kind: AttentionKind
        /// What it said: the body of its notification.
        let message: String?
        let since: Date?
    }

    @State private var draft = ""
    @State private var cancelling = false
    @FocusState private var fieldFocused: Bool

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
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        // Route *every* way of ending an edit — Return, Escape,
                        // and clicking away — through one focus-resignation
                        // path. If the field is torn out of the tree (editingID
                        // = nil) while it's still first responder, AppKit's
                        // field editor is left dangling and the sidebar stops
                        // receiving clicks. Dropping focus first, then letting
                        // onChange commit/cancel, avoids that.
                        .onSubmit { fieldFocused = false }
                        .onExitCommand {
                            cancelling = true
                            fieldFocused = false
                        }
                        .onChange(of: fieldFocused) { _, focused in
                            // While the field holds focus, ⌘A means select-all
                            // here (not the terminal's clear-line keybind).
                            MainMenu.setTextEditing(focused)
                            guard !focused else { return }
                            if cancelling { cancel() } else { commit(draft) }
                        }
                        .task {
                            cancelling = false
                            draft = session.name
                            fieldFocused = true
                            await selectLeafName()
                        }
                        // Backstop: if the field is torn out of the tree before
                        // focus resigns, still restore ⌘A to the terminal.
                        .onDisappear { MainMenu.setTextEditing(false) }
                } else {
                    // The folder prefix lives in the section header, so the row
                    // shows just the leaf ("giel/hello" -> "hello"). The rename
                    // field (draft = session.name) still edits the full name, so
                    // retyping the prefix is how you move between folders — but
                    // it opens with only the leaf selected (`selectLeafName`).
                    // An AppKit label rather than Text, for the native
                    // hover-to-expand on a name the row had to cut short.
                    TruncatingLabel(text: session.leafName, color: .labelColor)
                }
                // What it's waiting on, while it is: the useful half of a
                // notification, where the session already is. The row grows
                // for it and shrinks back once you've looked (SidebarOutlineView
                // eases the height).
                if let waiting, !isEditing {
                    WaitingLine(waiting: waiting)
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
    }

    /// Narrow the rename selection to the leaf, so "Wakker/Worker" opens with
    /// only "Worker" selected.
    ///
    /// Making a text field first responder programmatically has AppKit's field
    /// editor select the whole string, and the draft is the *full* name — so on
    /// a foldered session the first keystroke took the prefix with it and the
    /// session silently jumped to the top level. The prefix stays visible and
    /// editable: retyping it is still how you move between folders.
    ///
    /// SwiftUI's TextField exposes no selection API, hence going through the
    /// field editor. Focus lands on it a runloop turn or two after
    /// `fieldFocused = true`, so poll for it rather than guessing a delay, and
    /// match on the string to be sure it's *this* row's editor and not some
    /// other field that happens to hold focus — and that SwiftUI has pushed the
    /// draft into it, since selecting before that would be overwritten.
    ///
    /// Failing to find it just leaves the whole name selected, i.e. the old
    /// behaviour, which is why this gives up quietly rather than retrying hard.
    @MainActor
    private func selectLeafName() async {
        let name = session.name
        guard let leaf = SessionName.leafRange(of: name) else { return }

        for _ in 0..<10 {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
               editor.string == name {
                editor.selectedRange = leaf
                return
            }
            if (try? await Task.sleep(for: .milliseconds(16))) == nil { return }
        }
    }
}

/// A waiting session's second line: what it said, or what kind of wait it is,
/// and for how long. "Allow edit to App.swift? · 4m", "Finished its turn · now".
private struct WaitingLine: View {
    let waiting: SessionRow.Waiting

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            TruncatingLabel(text: text(at: context.date), font: .systemFont(ofSize: 11),
                            color: .secondaryLabelColor)
        }
    }

    private func text(at now: Date) -> String {
        let what = waiting.message ?? {
            switch waiting.kind {
            case .needsInput: return "Waiting on you"
            case .failed: return "A command failed"
            case .turnDone: return "Finished its turn"
            case .finished: return "A command finished"
            }
        }()
        guard let since = waiting.since else { return what }
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

    var body: some View {
        HStack(spacing: 4) {
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
                // Working. A small grey dot breathing slowly, where there used to
                // be a spinner: a spinner says *the app* is loading, and three of
                // them turning at once in a list of agents was the busiest thing
                // on screen, for the least urgent news in it.
                AttentionDot(color: .secondaryLabelColor, diameter: 6, motion: .breathe)
            }
        }
        // Centre in whatever slot the row view gives us — the same rect the
        // close button gets, so swapping between them doesn't shift anything.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A status dot that can pulse (urgent), breathe (working) or sit still.
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
        /// A slow, shallow opacity swell: present without asking for anything.
        case breathe
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
            case .breathe:
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0.3
                fade.duration = 1.2
                add(fade)
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
        TerminalContainer(runtime: runtime, session: manager.selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { AttentionFlashOverlay(flash: manager.attentionFlash) }
            .onAppear { focusInspector() }
            .onChange(of: manager.selectedID) { _, _ in focusInspector() }
            .onChange(of: manager.selected?.cwd) { _, _ in focusInspector() }
            // The repo resolves a beat after the cwd (a work-tree root has to be
            // walked to), and the tree roots on it — so re-root when it lands,
            // or a session would show its cwd where its repo root belongs until
            // something else moved.
            .onChange(of: git.repo?.root) { _, _ in files.reroot() }
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

    func makeNSViewController(context: Context) -> TerminalHostViewController {
        TerminalHostViewController()
    }

    func updateNSViewController(_ controller: TerminalHostViewController, context: Context) {
        if let session {
            controller.show(session, runtime: runtime)
        }
    }
}
