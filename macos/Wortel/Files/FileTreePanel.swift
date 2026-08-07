import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Files pane: the session's project as a tree, in the trailing inspector
/// column beside its two source-control siblings.
///
/// Built as a `ScrollView` + `LazyVStack` of flattened rows rather than a `List`
/// or an `NSOutlineView`, matching the changes list and History: the pane's rows
/// carry an accent pill, an indent, and a status colour, and hand-rolling them
/// is what keeps all three panes looking like one thing. `FileTreeModel` does
/// the flattening, so only expanded directories cost anything here.
///
/// Deliberately read-only. There is a shell beside it that does `mv` and `rm`
/// better than a context menu can, so this offers only the actions the terminal
/// *can't*: open, reveal, copy a path, and hand one to the prompt.
struct FileTreePanel: View {
    @Bindable var model: FileTreeModel
    /// Monotonic focus-request token (⌘⌥L), mirroring the git panes.
    let focusRequest: Int
    @FocusState private var listFocused: Bool
    @State private var lastHandledFocusRequest = 0
    /// Accumulated type-to-select prefix, cleared after a pause the way every
    /// Mac list does it.
    @State private var typeAhead = ""
    @State private var typeAheadExpiry = Date.distantPast

    var body: some View {
        Group {
            if model.root == nil {
                emptyState
            } else {
                tree
            }
        }
        // No background on purpose — as an inspector split item the system
        // supplies the material itself. See SourceControlPanel.
        .onChange(of: focusRequest) { _, req in applyFocusRequest(req) }
        .onChange(of: model.focusRequest) { _, req in applyFocusRequest(req) }
        .onAppear {
            applyFocusRequest(focusRequest)
            // Nothing watches this pane's directories while another pane owns
            // the column — well, the watchers do, but a tree you come back to
            // should be right on arrival rather than one event later.
            model.resync()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No folder")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        FileRow(
                            row: row,
                            isSelected: model.selectedID == row.id,
                            isExpanded: model.isExpanded(row.node),
                            statusCode: statusCode(for: row.node),
                            // Clicking a row both selects it and gives the tree
                            // keyboard focus. Without the second half the click
                            // looks like it worked — the row highlights — while
                            // ↑/↓ keep going to the terminal, which in an agent
                            // session means walking the *shell's* history.
                            select: {
                                model.select(row.node)
                                listFocused = true
                            },
                            toggle: {
                                toggle(row.node)
                                listFocused = true
                            },
                            open: { open(row.node) },
                            makeMenu: { contextMenu(for: row.node) })
                        // The overflow row for a directory the listing capped.
                        if row.node.hiddenChildCount > 0, model.isExpanded(row.node) {
                            overflowRow(row)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            // Only when the *keyboard* moved the selection, and only far enough
            // to reveal it — no anchor, so a row already on screen doesn't move
            // at all. Centring every selection meant clicking a row slid it out
            // from under the pointer, which is both disorienting and how the
            // second click of a double-click misses.
            .onChange(of: model.revealRequest) { _, _ in
                guard let id = model.selectedID else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
        .keyboardNavigableList(focused: $listFocused) { model.selectAdjacent($0) }
        // ←/→ walk the tree's shape rather than its rows: → opens a directory
        // (or steps into an open one), ← closes it, and ← on a leaf goes to the
        // parent — the standard outline behaviour.
        // Holding ⌥ makes both take the whole subtree with them, matching the
        // ⌥-click on the chevron and every other outline view on the Mac.
        // ⌥ is read from the current event rather than `KeyPress.modifiers`,
        // matching the chevron's click: the key-equivalent overload hands the
        // action no press to inspect, and the flags are live during handling.
        .onKeyPress(.leftArrow) { collapseOrGoToParent(recursive: optionHeld); return .handled }
        .onKeyPress(.rightArrow) { expandOrStepIn(recursive: optionHeld); return .handled }
        .onKeyPress(.return) { openSelected(); return .handled }
        // ⌘⌫, as Finder has it. Bare ⌫ is deliberately not bound: the modifier
        // is the whole reason this can't be typed by accident.
        .onKeyPress(.delete) {
            guard NSEvent.modifierFlags.contains(.command), let node = selectedNode
            else { return .ignored }
            model.moveToTrash(node)
            return .handled
        }
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters)) { press in
            typeToSelect(press.characters)
            return .handled
        }
    }

    /// The row that says a directory has more in it than the tree will draw.
    /// Silence here would read as "this is everything" — see FileTreeModel's cap.
    private func overflowRow(_ row: FileTreeRow) -> some View {
        Button {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.node.url.path)
        } label: {
            Text("\(row.node.hiddenChildCount) more items — Reveal in Finder")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Lines up with the row content one level in: the chevron slot
                // (16) plus the stack's spacing, so widening the slot moves this
                // with it.
                .padding(.leading, CGFloat(row.depth + 1) * 12 + 24)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Decoration

    private func statusCode(for node: FileNode) -> Character? {
        guard let relative = node.relativePath, !relative.isEmpty else { return nil }
        return model.decorations.code(forRelativePath: relative, isDirectory: node.isDirectory)
    }

    // MARK: - Keyboard

    private func applyFocusRequest(_ req: Int) {
        guard req != lastHandledFocusRequest else { return }
        lastHandledFocusRequest = req
        if model.selectedID == nil { model.selectAdjacent(1) }
        // Next runloop turn: the focusable list is reliably installed by then,
        // even when this request is what revealed the pane.
        DispatchQueue.main.async { listFocused = true }
    }

    private var selectedNode: FileNode? {
        model.rows.first { $0.id == model.selectedID }?.node
    }

    /// ⌥ is read from the current event rather than tracked as state: the flags
    /// are live during event handling, which is exactly when these run, and a
    /// modifier watcher would re-render every row on every ⌥ press.
    private var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    /// A click on a row's chevron. With ⌥ it takes the whole subtree.
    private func toggle(_ node: FileNode) {
        model.toggleExpansion(node, recursive: optionHeld)
    }

    private func expandOrStepIn(recursive: Bool = false) {
        guard let node = selectedNode else { return }
        if node.isDirectory && !model.isExpanded(node) {
            recursive ? model.expandRecursively(node) : model.expand(node)
        } else if recursive, node.isDirectory {
            // Already open: ⌥→ still means "and everything under it".
            model.expandRecursively(node)
        } else {
            model.selectAdjacent(1)
        }
    }

    private func collapseOrGoToParent(recursive: Bool = false) {
        guard let node = selectedNode else { return }
        if node.isDirectory && model.isExpanded(node) {
            recursive ? model.collapseRecursively(node) : model.collapse(node)
        } else if let parent = model.parent(of: node) {
            // ← from a leaf jumps to its parent, which is very often above the
            // top of the pane — the one keyboard move that most needs revealing.
            model.select(parent, reveal: true)
        }
    }

    /// Letters typed while the tree has focus jump to the next matching row.
    /// The prefix accumulates for a second so "pro" reaches `project.yml`, then
    /// resets — typing "p" much later means "the next p", not "prop".
    private func typeToSelect(_ characters: String) {
        let now = Date()
        typeAhead = now < typeAheadExpiry ? typeAhead + characters : characters
        typeAheadExpiry = now.addingTimeInterval(1)
        model.selectMatching(prefix: typeAhead)
    }

    private func openSelected() {
        guard let node = selectedNode else { return }
        open(node)
    }

    // MARK: - Actions

    /// ⏎ or a double-click. A directory toggles; a Markdown file goes to the
    /// in-app preview (which takes the column over, exactly as clicking a `.md`
    /// path in the terminal does); anything else goes to whatever app owns it.
    private func open(_ node: FileNode) {
        model.select(node)
        if node.isDirectory {
            model.toggleExpansion(node)
        } else {
            // Every file goes to a preview window now, Markdown included — it
            // opens rendered rather than taking the inspector's column over.
            model.onOpenPreview?(node.url)
        }
    }

    private func contextMenu(for node: FileNode) -> NSMenu {
        model.select(node)
        let menu = NSMenu()
        menu.autoenablesItems = false

        if node.isDirectory {
            // The discoverable form of the ⌥ gesture — the shortcut is shown so
            // the menu teaches it rather than replacing it.
            let expand = ClosureMenuItem(title: "Expand All") { model.expandRecursively(node) }
            expand.keyEquivalent = "\u{F703}" // →
            expand.keyEquivalentModifierMask = [.option]
            menu.addItem(expand)
            let collapse = ClosureMenuItem(title: "Collapse All") { model.collapseRecursively(node) }
            collapse.keyEquivalent = "\u{F702}" // ←
            collapse.keyEquivalentModifierMask = [.option]
            menu.addItem(collapse)
            menu.addItem(.separator())
        } else {
            menu.addItem(ClosureMenuItem(title: "Open") {
                model.onOpenPreview?(node.url)
            })
            menu.addItem(.separator())
            menu.addEditItems(for: node.url, exists: true)
        }
        menu.addItem(ClosureMenuItem(title: "Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        })
        // Where the alias actually goes. Resolved here rather than at listing
        // time: it's one syscall for one row you asked about, instead of one per
        // entry in every directory you open.
        if node.isSymlink {
            let target = node.url.resolvingSymlinksInPath().standardizedFileURL
            let item = ClosureMenuItem(title: "Reveal Original in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            item.toolTip = target.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Path") {
            copy(node.url.path)
        })
        if let relative = node.relativePath, !relative.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Copy Relative Path") {
                copy(relative)
            })
        }
        // The keyboard counterpart of dragging the row onto the terminal: both
        // end up as a shell-escaped path at the prompt, which is the thing you
        // actually want when briefing an agent about a file.
        menu.addItem(ClosureMenuItem(title: "Insert Path in Terminal") {
            model.insertPath(node.url)
        })
        // The root is the project itself — offering to trash it would be a
        // context menu with a loaded gun in it.
        if node.url.path != model.root?.url.path {
            menu.addItem(.separator())
            let trash = ClosureMenuItem(title: "Move to Trash") { model.moveToTrash(node) }
            trash.keyEquivalent = "\u{8}" // ⌫, as Finder has it
            trash.keyEquivalentModifierMask = [.command]
            menu.addItem(trash)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Refresh") {
            model.refreshAll()
        })
        return menu
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

}

// MARK: - Row

private struct FileRow: View {
    let row: FileTreeRow
    let isSelected: Bool
    let isExpanded: Bool
    let statusCode: Character?
    let select: () -> Void
    let toggle: () -> Void
    let open: () -> Void
    let makeMenu: () -> NSMenu

    /// Selected rows are drawn on the accent, so everything on them has to come
    /// off it — the same rule as the changes list and History.
    private var onAccent: Bool { isSelected }
    /// An ignored entry is still shown (you may well want to drag something out
    /// of `dist/`), but dimmed so it can't be mistaken for part of the project.
    private var isIgnored: Bool { row.node.isIgnored == true }

    var body: some View {
        HStack(spacing: 4) {
            // The chevron is the directory's own control, so clicking it opens
            // the folder without also opening the file next to it. The glyph is
            // small; the thing you click is not — it fills the row's height and
            // reaches into the gap on either side, because a 9pt chevron is a
            // target you miss. Pressing it acts immediately (see PressCatcher),
            // matching the sidebar's folder headers and every outline view on
            // the platform.
            if row.node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    // Fills the row's height rather than declaring one: a fixed
                    // height here is the tallest thing in the stack and sets the
                    // row's, which made every row taller to make one glyph
                    // easier to hit. The name still decides how tall a row is.
                    .frame(width: 16)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .overlay(PressCatcher(onPress: toggle))
            } else {
                Spacer().frame(width: 16)
            }
            // Everything the row's left mouse does — select, double-click to
            // open, drag the file out — belongs to one AppKit view, because
            // those three cannot be split between SwiftUI and AppKit on the
            // same row (see RowClickCatcher). It covers the content rather than
            // the whole row so the chevron beside it keeps its own press.
            HStack(spacing: 4) {
                Image(systemName: row.node.isDirectory ? "folder" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 14)
                Text(row.node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(nameStyle)
                // An alias marker beside the name rather than badged onto the
                // icon: at 11pt a Finder-style badge lands *on* the folder glyph
                // and both become mush. A linked folder is still a folder — it
                // opens — so the icon shouldn't change; only the fact that it
                // points elsewhere needs saying.
                if row.node.isSymlink {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(onAccent
                            ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                        .padding(.leading, -1)
                }
                Spacer(minLength: 4)
                // The roll-up dot: on a collapsed directory it stands for the
                // most significant change anywhere beneath it, so you can see
                // where work is without opening anything.
                if let statusCode {
                    Circle()
                        .fill(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(GitStatusStyle.color(for: statusCode)))
                        .frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
            .overlay(RowClickCatcher(onClick: select, onDoubleClick: open, url: row.node.url))
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor)
            }
        }
        .padding(.horizontal, 4)
        .opacity(isIgnored && !isSelected ? 0.4 : 1)
        // Selection, double-click and drag all live in RowClickCatcher above:
        // SwiftUI's .onDrag swallows the second click of a double, so they can't
        // be split between the two worlds.
        .overlay(RightClickCatcher(onRightClick: select, makeMenu: makeMenu))
    }

    private var nameStyle: AnyShapeStyle {
        if onAccent { return AnyShapeStyle(.white) }
        if let statusCode { return AnyShapeStyle(GitStatusStyle.color(for: statusCode)) }
        return AnyShapeStyle(.primary)
    }
}

