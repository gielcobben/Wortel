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
            .padding(.trailing, 8)
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
        menu.addItem(ClosureMenuItem(title: "Close Session") { manager.requestClose(session) })
        return menu
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

/// A folder header row's SwiftUI content: the section title styled like a
/// native sidebar header, plus the folder context menu. Expansion, the
/// disclosure chevron, click-to-toggle, and all drag & drop live in the
/// NSOutlineView layer (SidebarOutlineView) — this is presentation only.
struct SidebarHeaderContent: View {
    let manager: SessionManager
    let folder: String

    var body: some View {
        Text(folder)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 12)
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

/// One sidebar row: session name with the path below it.
struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let isEditing: Bool
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var draft = ""
    @State private var cancelling = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The selected row sits on an always-accent pill, so its content is white.
    // Not while editing: the rename field sits on a normal background.
    private var onAccent: Bool { isSelected && !isEditing }

    var body: some View {
        // Content padded inside an inset accent pill (~6pt from the cell edges,
        // so it's not edge-to-edge). The indicator is centered against the whole
        // row, not pinned to the title line.
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
            activityIndicator
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

    /// Trailing status glyph. Attention (blocked on you / failed / long command
    /// done while unselected) wins over busy — once you select the session the
    /// attention clears and the spinner shows if a command is still running.
    /// The dot's colour encodes *why*: amber = waiting on you, red = failed,
    /// mint = an agent finished its turn, blue = a plain command finished. On
    /// the accent selection pill everything goes white for contrast (but a
    /// selected row has already cleared its attention). A non-selected session
    /// you haven't caught up with shows a quiet hollow ring instead.
    @ViewBuilder
    private var activityIndicator: some View {
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
        } else if let kind = session.unread, !isSelected {
            // Quiet "you haven't caught up here" trail: a hollow ring in the
            // kind's colour, no pulse. Hidden on the selected row (you're on it,
            // the dwell clock is running).
            Circle()
                .stroke(Self.attentionColor(kind).opacity(0.8), lineWidth: 1.5)
                .frame(width: 7, height: 7)
        }
    }

    private static func attentionColor(_ kind: AttentionKind) -> Color {
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
private struct AttentionDot: View {
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
/// The git model is still here only to keep the panel pointed at the selected
/// session — its visibility and its repo both follow from that — which is
/// naturally expressed as a SwiftUI onChange.
struct DetailPane: View {
    let runtime: GhosttyRuntime
    @Bindable var manager: SessionManager
    @Bindable var git: GitPanelModel

    var body: some View {
        TerminalContainer(runtime: runtime, session: manager.selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { AttentionFlashOverlay(flash: manager.attentionFlash) }
            .onAppear {
                git.focus(session: manager.selected)
            }
            .onChange(of: manager.selectedID) { _, _ in
                git.focus(session: manager.selected)
            }
            .onChange(of: manager.selected?.cwd) { _, _ in
                git.focus(session: manager.selected)
            }
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
