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
        appMenu.addItem(withTitle: "About Wortel", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Routes through the responder chain to AppDelegate, which drives the
        // Sparkle updater and validates (disables) this item mid-check.
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Wortel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Wortel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (copy/paste route to the focused SurfaceView via the
        // responder chain; SurfaceView implements these selectors).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(SurfaceView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(SurfaceView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        // Cmd+Shift+A, not Cmd+A: Cmd+A is a keybind in wortel.conf that clears
        // the input line (a terminal can't select just the typed command). The
        // menu is authoritative for key equivalents, so freeing Cmd+A here is
        // what lets that keybind reach the surface.
        let selectAll = editMenu.addItem(withTitle: "Select All", action: #selector(SurfaceView.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = [.command, .shift]

        // Session menu — the heart of the app, all keyboard-driven.
        let sessionItem = NSMenuItem()
        main.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionItem.submenu = sessionMenu
        sessionMenu.addItem(withTitle: "New Session", action: #selector(AppDelegate.newSession(_:)), keyEquivalent: "n")
        sessionMenu.addItem(withTitle: "Rename Session", action: #selector(AppDelegate.renameSession(_:)), keyEquivalent: "r")
        sessionMenu.addItem(withTitle: "Close Session", action: #selector(AppDelegate.closeSession(_:)), keyEquivalent: "w")
        sessionMenu.addItem(.separator())
        let next = sessionMenu.addItem(withTitle: "Next Session", action: #selector(AppDelegate.selectNextSession(_:)), keyEquivalent: "}")
        next.keyEquivalentModifierMask = [.command]
        let prev = sessionMenu.addItem(withTitle: "Previous Session", action: #selector(AppDelegate.selectPreviousSession(_:)), keyEquivalent: "{")
        prev.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(.separator())
        for i in 1...9 {
            let item = sessionMenu.addItem(
                withTitle: "Session \(i)",
                action: #selector(AppDelegate.selectSessionAtIndex(_:)),
                keyEquivalent: "\(i)")
            item.tag = i - 1
        }

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
        viewMenu.addItem(.separator())
        let toggleSidebar = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .option]
        // ⌘⌥G, not ⌘G: ⌘⌥S is already Toggle Sidebar above, and ⌘G is free of a
        // wortel.conf keybind. Routes through the responder chain to AppDelegate.
        // Title flips Show/Hide in AppDelegate.validateMenuItem based on panel
        // visibility; the icon stays put.
        let sourceControl = viewMenu.addItem(withTitle: "Show Source Control", action: #selector(AppDelegate.toggleSourceControl(_:)), keyEquivalent: "g")
        sourceControl.keyEquivalentModifierMask = [.command, .option]
        sourceControl.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        // ⌘⌥L: reveal the panel (if hidden) and move focus into the changes list
        // so ↑/↓ navigate files without reaching for the mouse.
        let focusList = viewMenu.addItem(withTitle: "Focus Changes List", action: #selector(AppDelegate.focusSourceControlList(_:)), keyEquivalent: "l")
        focusList.keyEquivalentModifierMask = [.command, .option]
        focusList.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)

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
