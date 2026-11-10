import Foundation

/// How the sidebar groups sessions and in what order: Pinned first, then the
/// top level, then one section per folder in the user's `folderOrder`; how
/// that order is kept in step with the folders that exist; and where a
/// dragged folder or session lands.
///
/// Rules over ids and folder names only. Every side effect stays in
/// `SessionManager`: the renaming a move implies, the save, the folds.
///
/// Pure, and a type of its own, because every way it can be wrong is silent.
/// A wrong index here doesn't throw: it files a session in another folder,
/// and since a session's folder is the part of its name before the last
/// slash, that renames it, and the manager saves the result.
enum SidebarLayout {
    /// One session as the layout sees it.
    struct Row<ID: Hashable>: Equatable {
        var id: ID
        /// nil for the top level.
        var folder: String?
    }

    /// One sidebar section, as `SidebarGroup` is, by id.
    struct Group<ID: Hashable>: Equatable {
        var folder: String?
        var ids: [ID]
        var isPinned = false
    }

    /// The sections in the order they are drawn. Pinned rows are shown in
    /// their own section, first, in `pinned` order, and not in their folders
    /// as well. Folders follow `folderOrder`; any not tracked there fall back
    /// to first appearance among `rows`, then declaration order, so nothing is
    /// ever dropped. Rows keep their array order within a group.
    static func groups<ID: Hashable>(
        rows: [Row<ID>], pinned: [ID], folderOrder: [String], declaredFolders: [String]
    ) -> [Group<ID>] {
        let pinnedRows = pinned.compactMap { id in rows.first { $0.id == id } }
        let pinnedSet = Set(pinnedRows.map(\.id))
        var byKey: [String: [ID]] = [:]
        for row in rows where !pinnedSet.contains(row.id) {
            byKey[row.folder ?? "", default: []].append(row.id)
        }
        // A folder whose sessions are all pinned stays, empty, to come back to.
        // One whose sessions are all archived doesn't: they're found with
        // ⌘P, and restoring one brings its folder back.
        let pinnedFolders = Set(pinnedRows.compactMap(\.folder))

        var groups: [Group<ID>] = []
        if !pinnedRows.isEmpty {
            groups.append(Group(folder: nil, ids: pinnedRows.map(\.id), isPinned: true))
        }
        if let top = byKey[""], !top.isEmpty {
            groups.append(Group(folder: nil, ids: top))
        }
        var emitted = Set<String>()
        func emit(_ folder: String) {
            guard !emitted.contains(folder),
                  byKey[folder] != nil || declaredFolders.contains(folder)
                    || pinnedFolders.contains(folder) else { return }
            emitted.insert(folder)
            groups.append(Group(folder: folder, ids: byKey[folder] ?? []))
        }
        for folder in folderOrder { emit(folder) }
        for row in rows { if let f = row.folder { emit(f) } }
        for folder in declaredFolders { emit(folder) }
        return groups
    }

    /// `folderOrder` reconciled with the folders that exist: those that
    /// vanished dropped, newly appeared ones appended (by first appearance
    /// among rows, then declared, then archived), duplicates removed, and the
    /// user's arrangement kept for everything already tracked.
    static func syncedFolderOrder<ID: Hashable>(
        _ folderOrder: [String], rows: [Row<ID>], declaredFolders: [String], archivedFolders: [String]
    ) -> [String] {
        var present: [String] = []
        var seen = Set<String>()
        for row in rows {
            if let f = row.folder, seen.insert(f).inserted { present.append(f) }
        }
        for f in declaredFolders where seen.insert(f).inserted { present.append(f) }
        // A folder whose sessions are all archived is still there: its fold is.
        for f in archivedFolders where seen.insert(f).inserted { present.append(f) }

        var order: [String] = []
        var added = Set<String>()
        for f in folderOrder where seen.contains(f) && added.insert(f).inserted { order.append(f) }
        for f in present where added.insert(f).inserted { order.append(f) }
        return order
    }

    /// `folderOrder` with `folder` moved to `index`.
    ///
    /// `index` is an insertion index as rendered before the move, so it may
    /// count the folder's own current place. nil when `folder` isn't there.
    static func movingFolder(_ folder: String, to index: Int, in folderOrder: [String]) -> [String]? {
        guard let from = folderOrder.firstIndex(of: folder) else { return nil }
        var target = index
        if from < target { target -= 1 } // the drop index counted its old slot
        var order = folderOrder
        order.remove(at: from)
        order.insert(folder, at: max(0, min(target, order.count)))
        return order
    }

    /// Where `moving` go among `rest` (every row but the moving ones, with
    /// `folder` already each moving row's folder): just before `before`,
    /// else after the last unpinned row of `folder`, else at the end.
    ///
    /// Only the position among the group's own members matters: the manager
    /// gathers each group together after.
    static func insertionIndex<ID: Hashable>(
        in rest: [Row<ID>], folder: String?, before: ID?, pinned: Set<ID>
    ) -> Int {
        before.flatMap { id in rest.firstIndex { $0.id == id } }
            ?? rest.lastIndex { $0.folder == folder && !pinned.contains($0.id) }.map { $0 + 1 }
            ?? rest.count
    }
}
