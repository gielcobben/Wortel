import AppKit

/// Programmatic main menu. Kept deliberately small: AppKit scans key
/// equivalents on every keypress, so every item here is on the hot path.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Vellum", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Vellum", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vellum", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (copy/paste route to the focused SurfaceView via the
        // responder chain; SurfaceView implements these selectors).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(SurfaceView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(SurfaceView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(SurfaceView.selectAll(_:)), keyEquivalent: "a")

        // View menu (font size; session-local)
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let bigger = viewMenu.addItem(withTitle: "Increase Font Size", action: #selector(SurfaceView.increaseFontSize(_:)), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.command]
        let smaller = viewMenu.addItem(withTitle: "Decrease Font Size", action: #selector(SurfaceView.decreaseFontSize(_:)), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(withTitle: "Reset Font Size", action: #selector(SurfaceView.resetFontSize(_:)), keyEquivalent: "0")

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }
}
