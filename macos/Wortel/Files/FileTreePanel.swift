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
        .onAppear { applyFocusRequest(focusRequest) }
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
                            select: { model.select(row.node) },
                            toggle: { toggle(row.node) },
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
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
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
                .padding(.leading, CGFloat(row.depth + 1) * 12 + 20)
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
            model.select(parent)
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
        } else if node.url.pathExtension.lowercased() == "md" {
            model.onPreviewMarkdown?(node.url)
        } else {
            NSWorkspace.shared.open(node.url)
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
            if node.url.pathExtension.lowercased() == "md" {
                menu.addItem(ClosureMenuItem(title: "Preview") {
                    model.onPreviewMarkdown?(node.url)
                })
            }
            menu.addItem(ClosureMenuItem(title: "Open") {
                NSWorkspace.shared.open(node.url)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        })
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
            // the folder without also opening the file next to it.
            if row.node.isDirectory {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: row.node.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameStyle)
            Spacer(minLength: 4)
            // The roll-up dot: on a collapsed directory it stands for the most
            // significant change anywhere beneath it, so you can see where work
            // is without opening anything.
            if let statusCode {
                Circle()
                    .fill(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(GitStatusStyle.color(for: statusCode)))
                    .frame(width: 6, height: 6)
            }
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
        .onTapGesture(perform: select)
        // A file URL on the drag pasteboard is all the terminal needs: SurfaceView
        // already registers `.fileURL` and inserts the shell-escaped path.
        .onDrag { NSItemProvider(object: row.node.url as NSURL) }
        // Both catchers are AppKit overlays that claim only their own event —
        // see RightClickCatcher for why neither is a SwiftUI gesture.
        .overlay(DoubleClickCatcher(onDoubleClick: open))
        .overlay(RightClickCatcher(onRightClick: select, makeMenu: makeMenu))
    }

    private var nameStyle: AnyShapeStyle {
        if onAccent { return AnyShapeStyle(.white) }
        if let statusCode { return AnyShapeStyle(GitStatusStyle.color(for: statusCode)) }
        return AnyShapeStyle(.primary)
    }
}

