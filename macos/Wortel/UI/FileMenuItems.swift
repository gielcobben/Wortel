import AppKit

/// The "Edit / Edit With" pair every file row's context menu carries.
///
/// Named Edit rather than Open because **Open is the preview window** — the
/// in-app view a double-click already gives you, and the one that knows which
/// diff this row means. Handing the file to another application is a different
/// intent, and calling both of them "open" made the menu ask you to pick between
/// two things with the same name.
///
/// Shared rather than written three times: the file tree, the Changes list and
/// History all offer it, and a submenu that lists installed applications with
/// their icons is exactly the kind of code that drifts when it's copied.
extension NSMenu {
    /// Appends "Edit" and "Edit With ▸". `exists` is passed in rather than
    /// checked here because the caller often knows already — a Changes row for a
    /// deleted file, a History row for a file that no longer exists — and hitting
    /// the disk once per menu build is enough.
    func addEditItems(for url: URL, exists: Bool) {
        let edit = ClosureMenuItem(title: "Edit") { NSWorkspace.shared.open(url) }
        edit.isEnabled = exists
        addItem(edit)

        let apps = exists ? NSWorkspace.shared.urlsForApplications(toOpen: url) : []
        let editWith = NSMenuItem(title: "Edit With", action: nil, keyEquivalent: "")
        editWith.isEnabled = !apps.isEmpty
        if !apps.isEmpty {
            let submenu = NSMenu()
            for app in apps {
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                let item = ClosureMenuItem(
                    title: FileManager.default.displayName(atPath: app.path)
                ) {
                    NSWorkspace.shared.open(
                        [url], withApplicationAt: app,
                        configuration: NSWorkspace.OpenConfiguration())
                }
                item.image = icon
                submenu.addItem(item)
            }
            editWith.submenu = submenu
        }
        addItem(editWith)
    }
}
