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
                SidebarSnapshotGroup(folder: $0.folder, sessionIDs: $0.sessions.map(\.id))
            })
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("New Session") { manager.newSession() }
                        // Its own branch and its own files: what makes running
                        // two agents in one repository safe.
                        Button("New Session on Branch…") { newSessionOnBranch(manager) }
                        Button("New Folder…") {
                            if let name = promptFolderName(title: "New Folder", confirm: "Create") {
                                manager.addFolder(named: name)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New Session or Folder")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
    }
}

/// One outline row's SwiftUI content: the session row on its always-accent
/// selection pill, plus the row context menu. Reads the manager's observable
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
            commit: { newName in
                manager.rename(session, to: newName)
                manager.editingID = nil
            },
            cancel: { manager.editingID = nil })
            // The selection pill is drawn by the row view (SidebarPillRowView),
            // full row width — this content just sits on top of it.
            .padding(.leading, 12)
            // Keeps a long name clear of the trailing slot, which the row view
            // owns (status indicator, or the close button while hovered). Only
            // decides where the name truncates, so it's deliberately generous
            // rather than measured against the cell's inset.
            .padding(.trailing, 24)
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
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Rename") { manager.editingID = session.id })
        if let moveTo = moveToMenuItem() { menu.addItem(moveTo) }
        menu.addItem(.separator())
        // Only for a worktree Wortel made, and it closes the session with it —
        // the directory is what the session *is*. git refuses while there are
        // uncommitted changes, and that refusal is shown rather than overridden:
        // a worktree is where work lives.
        if isInOwnWorktree {
            menu.addItem(ClosureMenuItem(title: "Remove Worktree\u{2026}") { removeWorktree() })
        }
        menu.addItem(ClosureMenuItem(title: "Close Session") { manager.requestClose(session) })
        return menu
    }

    /// Cheap enough to ask while building a menu: a path prefix, no git call.
    /// The authoritative check happens in the manager before anything is removed.
    private var isInOwnWorktree: Bool {
        session.cwd?.hasPrefix(GitWorktree.root.path + "/") == true
    }

    private func removeWorktree() {
        let confirm = NSAlert()
        confirm.messageText = "Remove the worktree for \u{201c}\(session.leafName)\u{201d}?"
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

    /// "Move To" submenu: top level plus every other folder — the no-drag way
    /// to refile. Nil when there's nowhere to move to.
    private func moveToMenuItem() -> NSMenuItem? {
        let destinations = manager.folderNames.filter { $0 != session.folderPath }
        guard session.folderPath != nil || !destinations.isEmpty else { return nil }

        let submenu = NSMenu()
        if session.folderPath != nil {
            submenu.addItem(ClosureMenuItem(title: "Top Level") {
                manager.moveSession(id: session.id, toFolder: nil, at: .max)
            })
        }
        for folder in destinations {
            submenu.addItem(ClosureMenuItem(title: folder) {
                manager.moveSession(id: session.id, toFolder: folder, at: .max)
            })
        }
        let item = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

/// Ask for a branch and open a session in a worktree for it. Failures are shown
/// as git wrote them — "already checked out at …" names the directory you want,
/// and rewriting it would take that away.
@MainActor
func newSessionOnBranch(_ manager: SessionManager, inFolder folder: String? = nil) {
    Task { @MainActor in
        let existing = await manager.localBranches()
        guard let branch = promptBranch(existing: existing) else { return }
        manager.newSession(onBranch: branch, inFolder: folder) { message in
            let alert = NSAlert()
            alert.messageText = "Couldn't open a worktree for \u{201c}\(branch)\u{201d}"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

/// A branch prompt: type a new name, or pick one that exists with type-ahead.
///
/// A combo box rather than a plain field because both answers are legitimate
/// here — an existing branch or a new one — and a bare text field quietly turns
/// a typo into a *third* branch called `mian`.
/// Completions for the branch field: the native inline list, rather than
/// `NSComboBox`'s.
///
/// The combo box was the obvious control and the wrong one. Its dropdown is
/// legacy AppKit that never got the modern menu treatment — cramped rows, no
/// hover — and next to everything else on macOS 26 it reads as broken. A plain
/// text field with a completions delegate gets the same list Xcode and "Go to
/// Folder" use, and a menu button beside it gets a real `NSMenu`.
private final class BranchCompleter: NSObject, NSTextFieldDelegate {
    private let branches: [String]
    /// Completing while you delete fights you: it re-inserts what you just
    /// removed. Backspace has to be able to win.
    private var lastLength = 0

    init(branches: [String]) {
        self.branches = branches
    }

    func control(
        _ control: NSControl, textView: NSTextView, completions words: [String],
        forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let typed = (textView.string as NSString).substring(with: charRange).lowercased()
        guard !typed.isEmpty else { return branches }
        return branches.filter { $0.lowercased().hasPrefix(typed) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let length = field.stringValue.count
        defer { lastLength = length }
        guard length > lastLength else { return } // deleting
        field.currentEditor()?.complete(nil)
    }
}

@MainActor
private func promptBranch(existing: [String]) -> String? {
    let alert = NSAlert()
    alert.messageText = "New Session on Branch"
    // **No informative text**, and that is what makes this look like the folder
    // rename rather than a warning: an NSAlert carrying a body paragraph switches
    // to the wide, left-aligned layout, while one with only a title and an
    // accessory keeps the compact centred form. The placeholder says the little
    // that needs saying.
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let width: CGFloat = 220
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
    // The same field as the folder rename, so the two dialogs match exactly.
    let field = NSTextField(frame: NSRect(x: 0, y: 0,
                                          width: existing.isEmpty ? width : width - 26,
                                          height: 24))
    field.placeholderString = "Branch name"
    let completer = BranchCompleter(branches: existing)
    field.delegate = completer
    container.addSubview(field)

    if !existing.isEmpty {
        // A real NSMenu for browsing — modern metrics, hover, the lot.
        let button = NSButton(frame: NSRect(x: width - 22, y: 0, width: 22, height: 24))
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: "chevron.down",
                               accessibilityDescription: "Existing branches")
        button.imagePosition = .imageOnly
        let menu = NSMenu()
        for branch in existing {
            menu.addItem(ClosureMenuItem(title: branch) { field.stringValue = branch })
        }
        let opener = MenuOpener(menu: menu, under: button)
        button.target = opener
        button.action = #selector(MenuOpener.open)
        objc_setAssociatedObject(button, Unmanaged.passUnretained(button).toOpaque(),
                                 opener, .OBJC_ASSOCIATION_RETAIN)
        container.addSubview(button)
    }

    alert.accessoryView = container
    alert.window.initialFirstResponder = field

    // `completer` has to outlive the modal run; the field only holds it weakly.
    let branch = withExtendedLifetime(completer) { () -> String in
        guard alert.runModal() == .alertFirstButtonReturn else { return "" }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return branch.isEmpty ? nil : branch
}

/// Pops a menu under a button. A tiny object because a button's action needs a
/// target, and the closure-carrying menu item we already have is for menu items.
private final class MenuOpener: NSObject {
    private let menu: NSMenu
    private weak var anchor: NSView?

    init(menu: NSMenu, under anchor: NSView) {
        self.menu = menu
        self.anchor = anchor
    }

    @objc func open() {
        guard let anchor else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }
}

/// A folder header row's SwiftUI content: the section title styled like a
/// native sidebar header, plus the folder context menu. Expansion, the
/// disclosure chevron, click-to-toggle, and all drag & drop live in the
/// NSOutlineView layer (SidebarOutlineView) — this is presentation only.
struct SidebarHeaderContent: View {
    let manager: SessionManager
    let folder: String

    var body: some View {
        HStack(spacing: 6) {
            Text(folder)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // What the folder is hiding. Same dot as a session row's, so it
            // reads as the same fact rather than as a new kind of badge — and
            // it pulses for the same reason, because a blocked agent you can't
            // see is exactly the case this whole system is for.
            if let kind = manager.attention(inFolder: folder) {
                AttentionDot(color: SessionStatusIndicator.attentionColor(kind),
                             pulses: kind == .needsInput)
            }
            Spacer(minLength: 0)
        }
            .padding(.leading, 12)
            .padding(.trailing, 8)
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
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var draft = ""
    @State private var cancelling = false
    @FocusState private var fieldFocused: Bool

    // The selected row sits on an always-accent pill, so its content is white.
    // Not while editing: the rename field sits on a normal background.
    private var onAccent: Bool { isSelected && !isEditing }

    var body: some View {
        // Content padded inside an inset accent pill (~6pt from the cell edges,
        // so it's not edge-to-edge).
        HStack(spacing: 8) {
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
                    Text(session.leafName)
                        .foregroundStyle(onAccent ? .white : .primary)
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

/// The row's trailing status glyph, hosted by the row view in the same slot as
/// the close button so the two are interchangeable — see SidebarPillRowView.
///
/// Attention (blocked on you / failed / long command done while unselected) wins
/// over busy — once you select the session the attention clears and the spinner
/// shows if a command is still running. The dot's colour encodes *why*: amber =
/// waiting on you, red = failed, mint = an agent finished its turn, blue = a
/// plain command finished. On the accent selection pill everything goes white
/// for contrast (but a selected row has already cleared its attention). A
/// non-selected session you haven't caught up with also carries a quiet hollow
/// ring, which sits *next to* the spinner rather than being replaced by it —
/// otherwise a session that failed and immediately started working again would
/// look like any other busy session.
///
/// It reads the manager directly rather than taking its state as arguments, so
/// selection and attention changes redraw it through Observation without the
/// outline reloading anything.
struct SessionStatusIndicator: View {
    let manager: SessionManager
    let session: Session

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { manager.selectedID == session.id }
    /// Matches SessionRow: the rename field sits on a normal background, so the
    /// glyph comes off the accent only while the pill is actually drawn.
    private var onAccent: Bool { isSelected && manager.editingID != session.id }

    var body: some View {
        HStack(spacing: 4) {
            // The unread trail sits *beside* the spinner rather than behind it:
            // a session that failed and is already working again still says so.
            // Hidden while a loud dot is up (the dot outranks it) and on the
            // selected row (you're on it, the dwell clock is running).
            if let kind = session.unread, !isSelected, session.attention == nil {
                // Quiet "you haven't caught up here" trail: a hollow ring in the
                // kind's colour, no pulse.
                Circle()
                    .stroke(Self.attentionColor(kind).opacity(0.8), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
            }
            if let kind = session.attention {
                // Urgent states (waiting on you / failed) breathe to catch the eye
                // in peripheral vision; a clean finish sits still.
                AttentionDot(
                    color: onAccent ? .white : Self.attentionColor(kind),
                    pulses: kind.pulses && !reduceMotion)
            } else if session.isBusy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                    .tint(onAccent ? .white : .secondary)
            }
        }
        // Centre in whatever slot the row view gives us — the same rect the
        // close button gets, so swapping between them doesn't shift anything.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func attentionColor(_ kind: AttentionKind) -> Color {
        switch kind {
        case .needsInput: return .orange
        case .failed: return .red
        case .turnDone: return .mint
        case .finished: return .blue
        }
    }
}

/// A 7pt status dot that optionally "breathes" (opacity + a touch of scale) to
/// draw peripheral attention. The animation starts on appear and stops on its
/// own when the dot leaves the tree (attention cleared).
struct AttentionDot: View {
    let color: Color
    let pulses: Bool
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulses && animating ? 0.35 : 1)
            .scaleEffect(pulses && animating ? 1.18 : 1)
            // Start on appear *and* when the kind is upgraded in place (a steady
            // "finished" dot becoming a pulsing "needs input" without ever
            // leaving the tree), so the pulse never gets stuck off.
            .onAppear { syncPulse() }
            .onChange(of: pulses) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        if pulses {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                animating = true
            }
        } else {
            withAnimation(.linear(duration: 0.15)) { animating = false }
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
