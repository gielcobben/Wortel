import AppKit
import Foundation
import Observation

/// One entry in the file tree. A reference type because the tree is walked and
/// mutated in place — a directory's children arrive after it's already on
/// screen, and re-listing one directory must not rebuild the rows above it.
@MainActor
final class FileNode: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Loaded on first expand and kept afterwards, so collapsing and reopening a
    /// directory is instant and costs no disk.
    var children: [FileNode]?
    /// Entries beyond the listing cap, reported rather than silently dropped.
    var hiddenChildCount = 0
    /// Whether git ignores this entry. nil until the parent's ignore check has
    /// come back, which is why the row draws as normal in the meantime rather
    /// than flashing grey.
    var isIgnored: Bool?

    /// Stored rather than computed from `url`, so it satisfies `Identifiable`
    /// without the conformance reaching into main-actor state — the shape Swift
    /// 6 will require, and free to do now.
    let id: String

    /// A link to somewhere else. Worth drawing, because the one thing a tree
    /// must not do is let you edit a file believing it lives where you clicked
    /// it — an aliased directory of skills or configs looks exactly like a real
    /// one, right up until you wonder why your change didn't take.
    let isSymlink: Bool

    init(url: URL, isDirectory: Bool, isSymlink: Bool = false) {
        self.url = url
        self.id = url.path
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

/// One flattened, drawable row: a node and how deep it sits. The panel renders
/// this array directly, so only expanded directories cost anything.
struct FileTreeRow: Identifiable {
    let node: FileNode
    let depth: Int
    let id: String

    init(node: FileNode, depth: Int) {
        self.node = node
        self.depth = depth
        self.id = node.id
    }
}

/// Drives the Files pane: what the tree is rooted at, which directories are
/// open, and what's inside them.
///
/// Two rules shape everything here, both inherited from the git panel beside it:
///
/// 1. **Cost tracks the window, not the repo.** Only expanded directories are
///    listed, watched, or ignore-checked. A collapsed `node_modules` is a single
///    row and no work whatsoever. Expanding one is capped (see `listingCap`)
///    rather than trusted to be small.
/// 2. **Nothing heavy on the main actor.** Listing and `check-ignore` run off
///    it; this class only applies results. The terminal beside the pane has to
///    keep its frame rate while an agent rewrites a thousand files.
///
/// The root follows the selected session: its repo work-tree root when it's in
/// one, otherwise its cwd — which means a non-repo session re-roots as you `cd`,
/// because outside a repo there's no project to hold still for.
@Observable
@MainActor
final class FileTreeModel {
    /// The root node, or nil before a cwd has been reported.
    private(set) var root: FileNode?
    /// The flattened rows the panel draws. Rebuilt whenever the tree or the
    /// expansion set changes; never longer than what's actually open.
    private(set) var rows: [FileTreeRow] = []
    private(set) var selectedID: String?
    /// Git status for the current repo, as path → code plus directory roll-ups.
    private(set) var decorations = FileTreeDecorations()

    /// Bumped to ask the panel to put keyboard focus in the tree, mirroring
    /// `GitPanelModel.listFocusRequest` — see that property for why it's a
    /// counter rather than a Bool.
    private(set) var focusRequest = 0

    /// At most this many entries per directory. `node_modules/.pnpm` must not be
    /// able to cost the terminal a frame; the overflow is reported in a trailing
    /// row rather than silently dropped, because a truncated list that doesn't
    /// say so reads as "this is everything".
    static let listingCap = 1000

    /// The most directories one ⌥-expand will open, and how deep it will go. Both
    /// are backstops rather than targets: a source tree is tens of directories,
    /// and anything that reaches these numbers is a subtree you didn't mean.
    /// The cap also bounds the open file descriptors the walk takes, since an
    /// expanded directory is a watched directory.
    static let recursiveExpandCap = 200
    static let recursiveExpandDepth = 8

    /// The panel this one reads the repo from. `GitPanelModel` has already
    /// resolved the session's work-tree root and keeps its `GitStatus` fresh, so
    /// asking it costs nothing where a second `rev-parse` per `cd` would not.
    @ObservationIgnored private weak var git: GitPanelModel?
    /// Open a file in a preview window (a double-click).
    @ObservationIgnored var onOpenPreview: ((URL) -> Void)?
    /// Show a file in the preview tab: for a click, ↑/↓ or Space.
    @ObservationIgnored var onPeek: ((URL, PeekTrigger) -> Void)?

    @ObservationIgnored private weak var session: Session?
    /// Expanded directory paths for the current root.
    @ObservationIgnored private var expanded: Set<String> = []
    /// Expansion per root, so switching sessions and back — or `cd`-ing away and
    /// returning — restores the tree you left rather than collapsing it.
    @ObservationIgnored private var expansionCache: [String: Set<String>] = [:]
    /// One watcher per expanded directory. Keyed by path; removing the entry is
    /// what stops the watch (see DirectoryWatcher's deinit).
    @ObservationIgnored private var watchers: [String: DirectoryWatcher] = [:]
    /// Directories with a re-listing already scheduled, so a directory being
    /// written into hard doesn't queue one refresh per event.
    @ObservationIgnored private var pendingRefreshes: Set<String> = []
    /// `check-ignore` answers, cached per directory and dropped when that
    /// directory's listing changes.
    @ObservationIgnored private var ignoreChecked: Set<String> = []
    /// The session or its repo moved while the tree wasn't on screen; see
    /// `reroot`.
    @ObservationIgnored private var rerootPending = false

    /// How long a directory's re-listing waits after an event, coalescing a
    /// burst (an `npm install`, an agent writing a tree) into one pass.
    private static let refreshDebounce: TimeInterval = 0.25

    init(git: GitPanelModel) {
        self.git = git
    }

    // MARK: - Focus

    /// Point the tree at the selected session. Called on selection changes and
    /// whenever the selected session's cwd moves — i.e. on every shell prompt —
    /// so it must be cheap and must not disturb a tree whose root hasn't
    /// actually changed.
    func focus(session: Session?) {
        self.session = session
        reroot()
    }

    /// Re-read the root from the session and the git panel's resolved repo.
    /// Rebuilds only when the answer moved; the repo root arrives a beat after
    /// a cwd (it's resolved asynchronously), so this runs again when it lands.
    func reroot() {
        // Not on screen: just remember the root may have moved. Every session
        // switch lands here, and rebuilding a tree nobody is looking at (a
        // listing and a `check-ignore` per open directory, a watcher each)
        // was most of what a switch cost with the column on another pane.
        // `resync`, which the pane runs when it appears, picks this up.
        guard isShowing else {
            rerootPending = true
            return
        }
        rerootPending = false
        syncRepoRoot()
        let path = repoRoot ?? session?.cwd
        guard let path, !path.isEmpty else {
            root = nil
            rows = []
            releaseWatchers()
            return
        }
        guard root?.url.path != path else {
            refreshDecorations()
            return
        }

        // Park the outgoing root's expansion so coming back restores it.
        if let previous = root?.url.path { expansionCache[previous] = expanded }
        releaseWatchers()

        let url = URL(fileURLWithPath: path)
        let node = FileNode(url: url, isDirectory: true)
        root = node
        expanded = expansionCache[path] ?? ExpansionStore.load(root: path)
        // The root row is always open — a tree whose single row is its own root
        // would just be a button that says "expand me".
        expanded.insert(path)
        selectedID = nil
        ignoreChecked = []
        refreshDecorations()
        rebuildRows()
        Task { await load(node) }
    }

    /// The work-tree root the tree currently sits in, or nil outside a repo.
    ///
    /// Stored rather than read live off the git panel, because it's what every
    /// repo-relative path in the tree is derived from: a row drawn now and an
    /// ignore check answered a moment ago must be speaking about the same repo.
    /// `syncRepoRoot` is its only writer.
    private(set) var repoRoot: String?

    /// Adopt the git panel's work-tree root, and re-answer everything that was
    /// asked in terms of the old one.
    ///
    /// This is not a rare path: the root resolves asynchronously and lands a
    /// beat *after* the cwd it belongs to, so the first listing of a tree
    /// routinely happens with no repo at all. `reroot` can't handle that by
    /// rebuilding, because in the usual case — a session sitting at the repo
    /// root — the path doesn't change when the root arrives, and rebuilding a
    /// tree the user is looking at on every prompt is exactly what its early
    /// return exists to prevent.
    private func syncRepoRoot() {
        let resolved = git?.repo?.root
        guard resolved != repoRoot else { return }
        repoRoot = resolved
        // Every ignore answer on the tree was given about the old repo, or
        // about there not being one.
        ignoreChecked = []
        if resolved == nil, let root { clearIgnoreFlags(root) }
        // The rows read `repoRoot` to place themselves in the repo, so they
        // redraw off the assignment above on their own; this is for the ignore
        // flags cleared just now, which live on the nodes.
        rebuildRows()
        Task { await recheckIgnored() }
    }

    /// The node's path relative to the work-tree root, or nil when the tree
    /// isn't in a repo.
    ///
    /// Derived on demand rather than stamped onto the node when it was listed,
    /// which is the bug this replaced: a node outlives every re-listing of its
    /// parent (`apply` reuses it deliberately, so open subtrees don't move), so
    /// a path frozen before the repo root resolved was never corrected. Every
    /// directory listed in that first beat lost both its git colour and its
    /// ignore check for the life of the tree — silently, because "no decoration"
    /// is indistinguishable from "nothing changed in there". The cost of asking
    /// instead is a string slice per drawn row.
    func relativePath(of node: FileNode) -> String? {
        guard let repoRoot else { return nil }
        return FileTreeDecorations.relativePath(of: node.url.path, in: repoRoot)
    }

    /// Rebuild the git decoration from the panel's live status. Cheap — one pass
    /// over the *changed* files, a list bounded by what you've touched.
    func refreshDecorations() {
        let changes = git?.repo?.status.changes ?? []
        let updated = FileTreeDecorations(changes: changes)
        if updated != decorations { decorations = updated }
    }

    // MARK: - Expansion

    func isExpanded(_ node: FileNode) -> Bool { expanded.contains(node.url.path) }

    /// `recursive` is the ⌥ gesture — ⌥-click on a chevron, ⌥→/⌥← — which every
    /// outline view on the platform reads as "and everything under it".
    func toggleExpansion(_ node: FileNode, recursive: Bool = false) {
        guard node.isDirectory else { return }
        if isExpanded(node) {
            recursive ? collapseRecursively(node) : collapse(node)
        } else {
            recursive ? expandRecursively(node) : expand(node)
        }
    }

    func expand(_ node: FileNode) {
        guard node.isDirectory, !isExpanded(node) else { return }
        expanded.insert(node.url.path)
        persistExpansion()
        rebuildRows()
        if node.children == nil {
            Task { await load(node) }
        } else {
            watch(node)
        }
    }

    func collapse(_ node: FileNode) {
        guard isExpanded(node), node.url.path != root?.url.path else { return }
        expanded.remove(node.url.path)
        // Everything below stops being drawn, so it stops being watched too —
        // this is what keeps a big collapsed subtree free. Keys collected first:
        // removing while iterating `watchers.keys` copies the whole dictionary
        // per removal (the keys view holds the storage), which is quadratic on a
        // deep subtree and reads like a bug even though it isn't one.
        let prefix = node.url.path + "/"
        let stale = watchers.keys.filter { $0 == node.url.path || $0.hasPrefix(prefix) }
        for path in stale { watchers.removeValue(forKey: path) }
        persistExpansion()
        rebuildRows()
    }

    /// ⌥-collapse: shut this directory *and* forget the shape underneath it, so
    /// reopening it comes back closed rather than restoring the subtree. That
    /// difference is the whole point of the gesture — plain collapse deliberately
    /// remembers. On the root (which never collapses) it means "collapse all",
    /// which is the other half of what people reach for ⌥ to do.
    func collapseRecursively(_ node: FileNode) {
        let prefix = node.url.path + "/"
        let isRoot = node.url.path == root?.url.path
        guard isRoot || isExpanded(node) else { return }
        expanded = expanded.filter { path in
            if path == node.url.path { return isRoot }
            return !path.hasPrefix(prefix)
        }
        // Collected before removing; see `collapse` for why.
        let stale = watchers.keys.filter {
            $0.hasPrefix(prefix) || (!isRoot && $0 == node.url.path)
        }
        for path in stale { watchers.removeValue(forKey: path) }
        persistExpansion()
        rebuildRows()
    }

    /// ⌥-expand: open this directory and everything under it — bounded, because
    /// "everything under it" is a promise a file tree can't keep. One
    /// `node_modules` is tens of thousands of directories, and the pane's whole
    /// design is that cost tracks the window rather than the repo.
    ///
    /// Three things keep it honest, in the order they matter:
    ///
    /// 1. **Ignored directories are not descended into.** `node_modules`, `dist`,
    ///    `.venv` and friends are already answered by `git check-ignore`, and they
    ///    are exactly the subtrees nobody means to open. The directory you point
    ///    at always opens — the rule is about what the walk *wanders* into, so
    ///    ⌥-clicking `node_modules` shows you its contents and stops there.
    /// 2. **A directory budget and a depth limit** (`recursiveExpandCap`,
    ///    `recursiveExpandDepth`) bound the walk even outside a repo, where
    ///    there's no ignore file to consult. What the budget doesn't reach stays
    ///    closed, which the chevrons say for themselves.
    /// 3. **One `check-ignore` per level, not per directory.** The batched form
    ///    takes the whole level's children in a single call, so the walk costs a
    ///    handful of git invocations rather than one per folder.
    func expandRecursively(_ node: FileNode) {
        guard node.isDirectory else { return }
        Task { await expandSubtree(node) }
    }

    private func expandSubtree(_ start: FileNode) async {
        let tree = root
        var level = [start]
        var depth = 0
        var opened = 0

        while !level.isEmpty, depth <= Self.recursiveExpandDepth,
              opened < Self.recursiveExpandCap {
            // Trim to the remaining budget *before* touching the disk, so a
            // directory with five thousand children costs five thousand listings
            // only if that's what the budget actually allows.
            let batch = Array(level.prefix(Self.recursiveExpandCap - opened))
            for directory in batch where directory.children == nil {
                let listing = await Self.list(directory.url, cap: Self.listingCap)
                guard root === tree else { return } // re-rooted while we were away
                apply(listing, to: directory)
            }
            for directory in batch {
                expanded.insert(directory.url.path)
                watch(directory)
            }
            opened += batch.count
            rebuildRows() // once per level, not once per directory

            await checkIgnoredBatch(batch)
            guard root === tree else { return }

            level = batch.flatMap { $0.children ?? [] }
                .filter { $0.isDirectory && $0.isIgnored != true }
            depth += 1
        }

        persistExpansion()
        rebuildRows()
    }

    /// The parent of a row, for ← on a leaf.
    func parent(of node: FileNode) -> FileNode? {
        let parentPath = node.url.deletingLastPathComponent().path
        return rows.first { $0.node.url.path == parentPath }?.node
    }

    /// `reveal` is for keyboard moves only: they can land on a row that is off
    /// screen, and a click cannot. See `revealRequest`.
    func select(_ node: FileNode, reveal: Bool = false) {
        moveSelection(to: node, reveal: reveal)
    }

    /// The selected file in the preview tab (`PeekTrigger`). A folder has
    /// nothing to show.
    func peekSelected(_ trigger: PeekTrigger) {
        guard let node = rows.first(where: { $0.id == selectedID })?.node,
              !node.isDirectory else { return }
        onPeek?(node.url, trigger)
    }

    /// Bumped only when the selection moved by *keyboard*. The view scrolls the
    /// selected row into view on this, not on `selectedID` — because a click
    /// needs no scrolling (you clicked something you could already see) and
    /// scrolling under the pointer is how a double-click loses its second click:
    /// the row you aimed at slides away between the two presses.
    private(set) var revealRequest = 0

    /// The one place the selection changes — clicks and keys share it so the two
    /// can never disagree about what selecting means.
    private func moveSelection(to node: FileNode, reveal: Bool) {
        selectedID = node.id
        if reveal { revealRequest += 1 }
    }

    /// Move the selection by `delta` rows, clamped at both ends — the shape
    /// `keyboardNavigableList` expects.
    func selectAdjacent(_ delta: Int) {
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == selectedID }) else {
            if let first = rows.first { moveSelection(to: first.node, reveal: true) }
            return
        }
        let next = min(max(current + delta, 0), rows.count - 1)
        moveSelection(to: rows[next].node, reveal: true)
    }

    /// Select the next visible row whose name starts with `prefix`, wrapping —
    /// the type-to-select behaviour every Mac list has.
    ///
    /// Walked as a rotated index rather than by building `rows[start...] +
    /// rows[..<start]`, which copied the whole visible tree twice per keystroke,
    /// and matched with `.anchored` rather than `lowercased().hasPrefix`, which
    /// allocated a lowercased copy of every row's name to throw it away again.
    func selectMatching(prefix: String) {
        guard !prefix.isEmpty, !rows.isEmpty else { return }
        let start = (rows.firstIndex { $0.id == selectedID } ?? -1) + 1
        for offset in 0..<rows.count {
            let row = rows[(start + offset) % rows.count]
            if row.node.name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                moveSelection(to: row.node, reveal: true)
                return
            }
        }
    }

    func requestFocus() { focusRequest += 1 }

    /// Move an entry to the Trash.
    ///
    /// The one thing this pane changes on disk, and the exception proves the
    /// rule rather than breaking it: everything else here is read-only because
    /// the shell beside it does `mv` and `rm` better — but `rm` has no Trash.
    /// Recoverable deletion is the single file operation a terminal does
    /// *worse*, which is exactly what earns it a place in this menu.
    ///
    /// The root is refused: the tree is rooted at the work tree, and "delete the
    /// project you're looking at" is not a thing a context menu should offer.
    /// No confirmation otherwise — Finder doesn't ask either, because the
    /// Trash is the confirmation.
    func moveToTrash(_ node: FileNode) {
        guard node.url.path != root?.url.path else { return }
        let parent = parent(of: node)
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else {
                    // A permission problem or a volume with no Trash. Rare, and
                    // the shell is right there to say why — a beep is the
                    // macOS-shaped "that didn't happen".
                    NSSound.beep()
                    return
                }
                // The row goes on its own: the parent directory is expanded (or
                // this row wouldn't be drawn), so its watcher reports the entry
                // vanishing and the re-listing drops it. Only the selection
                // needs saying — it would otherwise point at something gone.
                if self.selectedID == node.id { self.selectedID = parent?.id }
            }
        }
    }

    /// Put a path at the focused session's prompt, escaped and with a trailing
    /// space so the user can keep typing — the same treatment a dropped file
    /// gets, through the same helper (see `SurfaceView.performDragOperation`).
    /// Goes to the session the tree is pointed at rather than to the first
    /// responder: the click happened in the inspector, and every other session's
    /// surface is still in the hierarchy, merely hidden.
    func insertPath(_ url: URL) {
        session?.surfaceView?.sendText(DropPasteboard.shellEscape(url.path) + " ")
    }

    // MARK: - Loading

    /// List one directory off the main actor and apply the result. Also starts
    /// watching it — a directory is watched exactly while it's expanded.
    private func load(_ node: FileNode) async {
        let cap = Self.listingCap
        let listing = await Self.list(node.url, cap: cap)
        // The tree may have re-rooted while we were off-actor.
        guard isExpanded(node) || node.url.path == root?.url.path else { return }
        apply(listing, to: node)
        rebuildRows()
        watch(node)
        // Children that are *already* marked expanded — restored from a previous
        // run, or cached from before a re-root — have no contents yet, and
        // nothing else would ever ask for them: they'd draw an open chevron over
        // an empty folder. Loading them here is what makes a restored tree come
        // back whole, and it walks only the open part, one level per await.
        for child in node.children ?? [] where child.isDirectory
        && child.children == nil && isExpanded(child) {
            await load(child)
        }
        await checkIgnored(node)
    }

    /// Merge a fresh listing into a node, reusing the existing child objects for
    /// paths that are still there. Reuse is what makes a re-listing invisible:
    /// an expanded subdirectory keeps its loaded children and its identity, so
    /// the rows above and below don't move.
    private func apply(_ listing: Listing, to node: FileNode) {
        let existing = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.url.path, $0) })
        node.children = listing.entries.map { entry in
            if let kept = existing[entry.url.path], kept.isDirectory == entry.isDirectory {
                return kept
            }
            return FileNode(url: entry.url, isDirectory: entry.isDirectory,
                            isSymlink: entry.isSymlink)
        }
        node.hiddenChildCount = listing.hiddenCount
    }

    /// Ask git which of a directory's children are ignored, once per directory.
    /// Only ever called for a directory that's actually open — see the class
    /// comment.
    private func checkIgnored(_ node: FileNode) async {
        guard let rootPath = repoRoot, let children = node.children else { return }
        guard !ignoreChecked.contains(node.url.path) else { return }
        let relatives = children.compactMap { relativePath(of: $0) }.filter { !$0.isEmpty }
        guard !relatives.isEmpty else { return }
        let ignored = await GitService.checkIgnore(root: rootPath, paths: relatives)
        ignoreChecked.insert(node.url.path)
        for child in children {
            guard let relative = relativePath(of: child) else { continue }
            child.isIgnored = ignored.contains(relative)
        }
        rebuildRows()
    }

    /// The same question as `checkIgnored`, asked for a whole level of the tree
    /// at once. `git check-ignore` reads paths from stdin, so a hundred
    /// directories' children cost one invocation instead of a hundred — which is
    /// what makes ⌥-expand affordable, since the answer is also what stops the
    /// walk descending into `node_modules`.
    private func checkIgnoredBatch(_ directories: [FileNode]) async {
        guard let rootPath = repoRoot else { return }
        let pending = directories.filter { !ignoreChecked.contains($0.url.path) }
        let children = pending.flatMap { $0.children ?? [] }
        let relatives = children.compactMap { relativePath(of: $0) }.filter { !$0.isEmpty }
        guard !relatives.isEmpty else { return }
        let ignored = await GitService.checkIgnore(root: rootPath, paths: relatives)
        for directory in pending { ignoreChecked.insert(directory.url.path) }
        for child in children {
            guard let relative = relativePath(of: child) else { continue }
            child.isIgnored = ignored.contains(relative)
        }
        rebuildRows()
    }

    /// Re-ask `check-ignore` for every directory already open, in one
    /// invocation. The tree on screen was listed before the work-tree root
    /// arrived — or under a different one — so the answers it has are about a
    /// repo that isn't this one.
    private func recheckIgnored() async {
        guard repoRoot != nil, let root else { return }
        var directories: [FileNode] = []
        collectLoaded(root, into: &directories)
        await checkIgnoredBatch(directories)
    }

    /// Every directory in the tree whose contents have been listed — which is
    /// the open part of it, and nothing else.
    private func collectLoaded(_ node: FileNode, into result: inout [FileNode]) {
        guard let children = node.children else { return }
        result.append(node)
        for child in children where child.isDirectory {
            collectLoaded(child, into: &result)
        }
    }

    /// Forget what git said about a subtree. Only for leaving a repo: nil is
    /// "not asked yet", which draws a row normally rather than flashing it grey.
    private func clearIgnoreFlags(_ node: FileNode) {
        for child in node.children ?? [] {
            child.isIgnored = nil
            clearIgnoreFlags(child)
        }
    }

    // MARK: - Watching

    private func watch(_ node: FileNode) {
        let path = node.url.path
        guard watchers[path] == nil, isExpanded(node) else { return }
        watchers[path] = DirectoryWatcher(path: path) { [weak self] vanished in
            Task { @MainActor in
                guard let self else { return }
                // The directory this watch was on is gone. Whatever sits at the
                // path now — a fresh checkout of it, a rebuilt `dist/` — is a
                // different inode, and the old watch will never report on it
                // again. Drop it so the re-listing below can put a live one back
                // (`load` ends in `watch`), or the subtree silently stops
                // updating for the rest of the session.
                if vanished { self.watchers.removeValue(forKey: path) }
                self.scheduleRefresh(path)
            }
        }
    }

    private func releaseWatchers() {
        watchers.removeAll()
        pendingRefreshes.removeAll()
    }

    /// Coalesce a burst of events for one directory into a single re-listing.
    /// The guard is per directory rather than global so a busy `dist/` can't
    /// starve the refresh of the directory you're actually looking at.
    private func scheduleRefresh(_ path: String) {
        guard !pendingRefreshes.contains(path) else { return }
        pendingRefreshes.insert(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDebounce) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingRefreshes.remove(path)
                // Its contents moved, so any ignore answer for them is stale,
                // shown or not: `resync` keeps the answers it has, so one left
                // here would leave new ignored files undimmed on return.
                self.ignoreChecked.remove(path)
                // Off screen: the pane re-lists everything open when it comes
                // back (`resync`), so a re-listing and a `check-ignore` per
                // burst of writes now are for nobody. An agent writing into an
                // open folder kept git busy with the pane hidden.
                guard self.isShowing else { return }
                guard let node = self.node(at: path), self.isExpanded(node) else { return }
                await self.load(node)
            }
        }
    }

    private func node(at path: String) -> FileNode? {
        if root?.url.path == path { return root }
        return rows.first { $0.node.url.path == path }?.node
    }

    /// Re-list every open directory — the Refresh command. Also drops the
    /// `check-ignore` answers, which is the difference from `resync`: those
    /// change with `.gitignore`, not with the files, and re-asking costs a git
    /// process per open directory.
    func refreshAll() {
        ignoreChecked.removeAll()
        resync()
    }

    /// Re-list every open directory, keeping what we already know about ignores.
    ///
    /// The safety net under the watchers. They are per-inode and per-directory,
    /// so there are events they structurally cannot see — an ancestor renamed
    /// out from under them, a volume remounted, a machine asleep while a branch
    /// changed — and the failure is silent: a tree that stopped updating looks
    /// exactly like a tree with nothing to report. Cheap enough to run on a
    /// glance because it walks only what's open, which is the pane's whole cost
    /// rule.
    func resync() {
        guard isShowing else { return }
        if rerootPending {
            // reroot lists what's open itself when the root moved, and does
            // nothing at all when it didn't.
            let before = root
            reroot()
            if root !== before { return }
        }
        guard let root else { return }
        // Snapshot the open directories first: each `load` rebuilds `rows`, so
        // iterating it while awaiting would walk a list changing underneath.
        let open = rows.map(\.node).filter { $0.isDirectory && isExpanded($0) }
        Task {
            await load(root)
            for node in open where node.url.path != root.url.path {
                await load(node)
            }
        }
    }

    /// Whether the tree is the thing the inspector is currently showing. A
    /// re-listing for a pane nobody is looking at is work the pane exists to
    /// avoid.
    private var isShowing: Bool {
        git?.showsFiles == true
    }

    // MARK: - Rows

    /// Flatten the open part of the tree. Walks only expanded directories, so
    /// this is proportional to what's on screen.
    private func rebuildRows() {
        guard let root else {
            rows = []
            return
        }
        var result: [FileTreeRow] = [FileTreeRow(node: root, depth: 0)]
        appendChildren(of: root, depth: 1, into: &result)
        rows = result
    }

    private func appendChildren(of node: FileNode, depth: Int, into result: inout [FileTreeRow]) {
        guard isExpanded(node), let children = node.children else { return }
        for child in children {
            result.append(FileTreeRow(node: child, depth: depth))
            appendChildren(of: child, depth: depth + 1, into: &result)
        }
    }

    // MARK: - Expansion persistence

    private func persistExpansion() {
        guard let rootPath = root?.url.path else { return }
        expansionCache[rootPath] = expanded
        ExpansionStore.save(expanded, root: rootPath)
    }

    // MARK: - Listing (off the main actor)

    private struct Listing {
        struct Entry {
            let url: URL
            let isDirectory: Bool
            let isSymlink: Bool
        }
        var entries: [Entry] = []
        var hiddenCount = 0
    }

    /// Read one directory. `nonisolated` and static: this is the one piece that
    /// touches the disk, and it must never run on the main actor — a directory
    /// on a slow volume would stall the terminal's frame.
    nonisolated private static func list(_ url: URL, cap: Int) async -> Listing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        // **Resolve before listing.** `contentsOfDirectory(at:)` does not follow
        // a symlink: handed the link itself it fails with ENOTDIR (verified —
        // the path-based call does follow it, the URL-based one doesn't). That's
        // why an aliased folder opened onto nothing at all.
        let listingURL = url.resolvingSymlinksInPath()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: listingURL, includingPropertiesForKeys: keys,
            options: [])) ?? []

        var entries: [Listing.Entry] = []
        entries.reserveCapacity(min(contents.count, cap))
        for child in contents {
            // `.git` is not "ignored" in git's sense — check-ignore says nothing
            // about it — but a tree that shows `.git/objects` is noise. Every
            // other dotfile stays: .gitignore and .env are things you look for.
            if child.lastPathComponent == ".git" { continue }
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink ?? false
            // A symlink's resource values describe the **link**, not what it
            // points at — verified against a real one: a directory reached
            // through an alias reports `isDirectory == false`. Believing that
            // drew it as a leaf with a document icon and no chevron, so an
            // aliased folder of skills or configs simply could not be opened.
            // One extra stat, and only for the entries that are links.
            var isDirectory = values?.isDirectory ?? false
            if isSymlink {
                isDirectory = (try? child.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            }
            // Depth is bounded by the user's own clicks (and by the recursive
            // expand's own cap), so a symlink loop can't run away on its own.
            // **Re-attached to the path navigated, not the target's.** The
            // listing came from the resolved directory, so `child` lives under
            // wherever the alias points — and a node's id is its path. Left that
            // way, an aliased folder's children carry the *target's* ids, which
            // collide with the same files' rows if that real directory is also
            // open in the tree: `ForEach` sees duplicate identifiers and draws
            // blank rows. Keeping ids in terms of where you clicked also keeps
            // git-relative paths and the alias marker honest.
            let entry = url.appendingPathComponent(child.lastPathComponent)
            entries.append(Listing.Entry(
                url: entry, isDirectory: isDirectory,
                isSymlink: isSymlink))
        }

        // Directories first, then case-insensitively by name — the order every
        // file tree on the platform uses, and the one that makes a project's
        // shape readable at a glance.
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(
                rhs.url.lastPathComponent) == .orderedAscending
        }

        var listing = Listing()
        if entries.count > cap {
            listing.hiddenCount = entries.count - cap
            listing.entries = Array(entries.prefix(cap))
        } else {
            listing.entries = entries
        }
        return listing
    }

}

/// Which directories were open, per root, across relaunches.
///
/// App state rather than user config — the same category as `sessions.json`,
/// which is why it lives in UserDefaults and not in a settings file Wortel
/// deliberately doesn't have. Both dimensions are capped: a tree you expanded
/// exhaustively, and a machine you've opened a hundred projects on, must not
/// grow this without bound.
enum ExpansionStore {
    private static let key = "files.expanded"
    private static let pathsPerRoot = 200
    private static let roots = 10

    static func load(root: String) -> Set<String> {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]
        return Set(stored?[root] ?? [])
    }

    static func save(_ expanded: Set<String>, root: String) {
        var stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        // Deepest paths dropped first when capped: the shallow ones are the
        // shape of the project, the deep ones are where you happened to be.
        let capped = expanded.sorted { $0.count < $1.count }.prefix(pathsPerRoot)
        stored[root] = Array(capped)
        if stored.count > roots {
            // Nothing here records recency, and inventing a timestamp for a
            // convenience cache isn't worth it — drop the roots with the least
            // in them, which are the ones you've barely opened.
            let keep = stored.sorted { $0.value.count > $1.value.count }.prefix(roots)
            stored = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(stored, forKey: key)
    }
}
