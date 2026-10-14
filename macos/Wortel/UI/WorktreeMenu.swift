import AppKit

/// "Open Worktree": every worktree of a repository that's on disk, whoever
/// made it (Wortel, another app, a script, `git worktree add`), to continue in.
/// Picking one goes to the session already there, or opens one.
///
/// It's how you get back to a worktree whose session you closed, or into one
/// your other tooling made, without remembering its branch or its folder.
///
/// **Filled while the menu is up**, never before it: the list is a `git
/// worktree list`, which reads a few files and walks nothing, but it is still
/// a process, and putting one between a right-click and its menu is the lag
/// the sidebar's menus are kept free of. The menu it's in opens at once with
/// "Loading…" here, and by the time the pointer reaches this item the list is
/// in, since the main queue is served while a menu tracks.
@MainActor
enum WorktreeMenu {
    static func item(manager: SessionManager, from cwd: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "Open Worktree", action: nil, keyEquivalent: "")
        item.setGlyph("rectangle.stack")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(note("Loading\u{2026}"))
        item.submenu = submenu
        Task { @MainActor in
            let worktrees = await manager.openableWorktrees(in: cwd)
            fill(submenu, with: worktrees, manager: manager)
        }
        return item
    }

    private static func fill(_ menu: NSMenu, with worktrees: [GitWorktree], manager: SessionManager) {
        menu.removeAllItems()
        guard !worktrees.isEmpty else {
            menu.addItem(note("No Other Worktrees"))
            return
        }
        for worktree in worktrees {
            let path = worktree.path
            let folder = (path as NSString).lastPathComponent
            let entry = ClosureMenuItem(title: worktree.branch ?? folder) {
                manager.openWorktree(at: path)
            }
            let place = (path as NSString).abbreviatingWithTildeInPath
            if #available(macOS 14.4, *) { entry.subtitle = place }
            entry.toolTip = place
            // A tick for the ones a session is already in: picking those goes
            // there rather than opening a second.
            entry.state = manager.hasSession(inWorktree: path) ? .on : .off
            menu.addItem(entry)
        }
    }

    private static func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
