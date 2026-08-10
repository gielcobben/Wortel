import AppKit

/// Programmatic main menu. Kept deliberately small: AppKit scans key
/// equivalents on every keypress, so every item here is on the hot path.
enum MainMenu {
    /// The "Select All" item, retained so a session rename can flip its shortcut
    /// between ⌘⇧A (terminal: whole scrollback) and ⌘A (native select-all in the
    /// rename field). See `setTextEditing(_:)`.
    private static weak var selectAllItem: NSMenuItem?

    /// While a text field (a session rename) holds focus, bind "Select All" to
    /// ⌘A so it behaves like every other macOS text field; otherwise keep it on
    /// ⌘⇧A, leaving plain ⌘A free for the `wortel.conf` clear-line keybind. Only
    /// the modifier mask moves — the item and its `selectAll:` action are
    /// unchanged, so with the terminal focused it still selects the buffer.
    static func setTextEditing(_ active: Bool) {
        textEditing = active
        syncSelectAll()
    }

    private static var textEditing = false

    /// ⌘A for Select All wherever it isn't spoken for: a rename field, and a
    /// preview window — neither of which has the terminal's claim on it (⌘A is a
    /// `wortel.conf` keybind that clears the input line). Only the modifier moves;
    /// the `selectAll:` action is the same one the terminal answers on ⌘⇧A.
    private static func syncSelectAll() {
        let plain = textEditing || NSApp.keyWindow?.windowController is PreviewWindowController
        selectAllItem?.keyEquivalentModifierMask = plain ? [.command] : [.command, .shift]
    }

    /// ⌘1…⌘3 have two meanings and only one can be true at a time: "session 1–3"
    /// in the terminal window, "diff / source / rendered" in a preview.
    /// Validation can't arbitrate that. Measured: `performKeyEquivalent` stops at
    /// the *first* item whose key equivalent matches, and if that item validates
    /// disabled it swallows the event rather than looking for a second match — so
    /// a duplicate shortcut further down the menu bar is simply unreachable. The
    /// shortcut has to physically move, which has the happy side effect of both
    /// menus telling the truth: open the Session menu with a preview key and it
    /// shows no ⌘1 to give.
    private static var sessionDigitItems: [NSMenuItem] = []
    private static var previewModeItems: [NSMenuItem] = []

    static func syncPreviewShortcuts() {
        let toPreview = NSApp.keyWindow?.windowController is PreviewWindowController
        for (index, item) in previewModeItems.enumerated() {
            item.keyEquivalent = toPreview ? "\(index + 1)" : ""
        }
        for (index, item) in sessionDigitItems.enumerated() {
            item.keyEquivalent = toPreview ? "" : "\(index + 1)"
        }
        syncSelectAll()
    }

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
        // The entire settings surface of a zero-config app, and one checkmark
        // is the right size for it: there is no settings window to put this in,
        // and that is the feature rather than the gap. AppDelegate carries the
        // checkmark and HIDES the item outright on any build that cannot report
        // anyway (Debug, a 0.0.0 dev build, DO_NOT_TRACK set), because a switch
        // that controls nothing is worse than no switch at all.
        appMenu.addItem(withTitle: "Share Anonymous Usage Data",
                        action: #selector(AppDelegate.toggleTelemetry(_:)),
                        keyEquivalent: "")
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
        // Undo/Redo/Cut carry the standard first-responder selectors, so they
        // reach the field editor of whatever text field is being edited (e.g. a
        // session rename) and feel native there. SurfaceView implements none of
        // them, so with the terminal focused the items are disabled and the
        // keypress falls through — ⌘Z reaches ghostty's cmd+z keybind (undo the
        // input line), ⌘X and ⌘⇧Z are simply no-ops.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(SurfaceView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(SurfaceView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        // Cmd+Shift+A, not Cmd+A: Cmd+A is a keybind in wortel.conf that clears
        // the input line (a terminal can't select just the typed command). The
        // menu is authoritative for key equivalents, so freeing Cmd+A here is
        // what lets that keybind reach the surface. While a session is being
        // renamed, `setTextEditing(_:)` flips this to ⌘A so select-all works in
        // the field, then flips it back.
        let selectAll = editMenu.addItem(withTitle: "Select All", action: #selector(SurfaceView.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        // Only ever enabled while a preview window is key: it resolves through
        // the responder chain to PreviewWindowController, and nothing in the
        // main window implements it. That's what lets ⌘F live in the menu
        // without taking it away from the shell, where ⌘F is the terminal's.
        editMenu.addItem(withTitle: "Find",
                         action: #selector(PreviewWindowController.showPreviewFind(_:)),
                         keyEquivalent: "f")
        selectAllItem = selectAll

        // Session menu — the heart of the app, all keyboard-driven.
        let sessionItem = NSMenuItem()
        main.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionItem.submenu = sessionMenu
        sessionMenu.addItem(withTitle: "New Session", action: #selector(AppDelegate.newSession(_:)), keyEquivalent: "n")
        // ⌘T is every terminal's "new tab". Wortel has no tabs — a session is
        // the thing that shortcut reaches for — so it's an alias of ⌘N above
        // rather than a second visible row in a menu kept deliberately small.
        // Hidden items are skipped by the key-equivalent scan unless they opt in
        // via `allowsKeyEquivalentWhenHidden`. Free of a wortel.conf keybind.
        let newSessionTab = sessionMenu.addItem(withTitle: "New Session", action: #selector(AppDelegate.newSession(_:)), keyEquivalent: "t")
        newSessionTab.isHidden = true
        newSessionTab.allowsKeyEquivalentWhenHidden = true
        let newSection = sessionMenu.addItem(withTitle: "New Section", action: #selector(AppDelegate.newSection(_:)), keyEquivalent: "n")
        newSection.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(withTitle: "Rename Session", action: #selector(AppDelegate.renameSession(_:)), keyEquivalent: "r")
        sessionMenu.addItem(withTitle: "Close Session", action: #selector(AppDelegate.closeSession(_:)), keyEquivalent: "w")
        sessionMenu.addItem(.separator())
        // ⌘⇧[ / ⌘⇧] walk the sidebar. They're the system-wide convention for
        // "previous/next thing in this window" — Safari, Chrome, Finder,
        // Ghostty — so they're what the menu advertises, even though Wortel's
        // sessions aren't tabs. Free of a wortel.conf keybind (that file binds
        // alt+arrow and cmd+arrow, never a shifted bracket).
        let prev = sessionMenu.addItem(
            withTitle: "Previous Session",
            action: #selector(AppDelegate.selectPreviousSession(_:)),
            keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        let next = sessionMenu.addItem(
            withTitle: "Next Session",
            action: #selector(AppDelegate.selectNextSession(_:)),
            keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        // AppKit matches a key equivalent against the event's
        // charactersIgnoringModifiers, which *keeps* Shift applied — so
        // depending on the event, ⌘⇧] arrives as "]" or as "}", and an item
        // authored the conventional way ("]" + ⌘⇧) only matches the former.
        // Rather than bet on one shape, carry a hidden twin for the other.
        // Verified: whichever shape arrives, exactly one item fires — matching
        // stops at the first hit, so this can't skip two sessions at once.
        let prevShifted = sessionMenu.addItem(
            withTitle: "Previous Session",
            action: #selector(AppDelegate.selectPreviousSession(_:)),
            keyEquivalent: "{")
        prevShifted.keyEquivalentModifierMask = [.command, .shift]
        prevShifted.isHidden = true
        let nextShifted = sessionMenu.addItem(
            withTitle: "Next Session",
            action: #selector(AppDelegate.selectNextSession(_:)),
            keyEquivalent: "}")
        nextShifted.keyEquivalentModifierMask = [.command, .shift]
        nextShifted.isHidden = true
        // ⌘⌥↑/↓ keep working — they read as "move in the list" and were the
        // original binding, so muscle memory shouldn't break. Hidden rather
        // than shown twice: a hidden item is skipped when the menu is drawn but
        // still matched by NSMenu.performKeyEquivalent, which is exactly the
        // "second binding, one menu entry" shape we want.
        let prevArrow = sessionMenu.addItem(
            withTitle: "Previous Session",
            action: #selector(AppDelegate.selectPreviousSession(_:)),
            keyEquivalent: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!))
        prevArrow.keyEquivalentModifierMask = [.command, .option]
        prevArrow.isHidden = true
        let nextArrow = sessionMenu.addItem(
            withTitle: "Next Session",
            action: #selector(AppDelegate.selectNextSession(_:)),
            keyEquivalent: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))
        nextArrow.keyEquivalentModifierMask = [.command, .option]
        nextArrow.isHidden = true
        // Jump straight to whatever is waiting on you, wherever it sits in the
        // list. Disabled (via AppDelegate.validateMenuItem) when nothing waits.
        let nextAlert = sessionMenu.addItem(withTitle: "Next Waiting Session", action: #selector(AppDelegate.selectNextAttentionSession(_:)), keyEquivalent: "]")
        nextAlert.keyEquivalentModifierMask = [.command, .option]
        sessionMenu.addItem(.separator())
        for i in 1...9 {
            let item = sessionMenu.addItem(
                withTitle: "Session \(i)",
                action: #selector(AppDelegate.selectSessionAtIndex(_:)),
                keyEquivalent: "\(i)")
            item.tag = i - 1
            if i <= 3 { sessionDigitItems.append(item) }
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
        // What a preview window is showing. A submenu rather than three more
        // entries in View: "Show Source" sitting next to "Show Source Control"
        // reads as a typo, and these three only ever mean something with a
        // preview key. Their ⌘1…⌘3 are lent by `syncPreviewShortcuts`.
        let previewItem = viewMenu.addItem(withTitle: "Preview", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu(title: "Preview")
        previewItem.submenu = previewMenu
        for mode in [PreviewMode.diff, .source, .rendered] {
            let item = previewMenu.addItem(
                withTitle: mode.title,
                action: #selector(PreviewWindowController.showPreviewMode(_:)),
                keyEquivalent: "")
            item.tag = mode.menuTag
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            previewModeItems.append(item)
        }
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
        // ⌘⌥E for the third pane of the same column — free in both this file and
        // wortel.conf. It behaves exactly like ⌘⌥G and the toolbar segments: open
        // on Files, swap to Files, or close if Files is already up.
        let files = viewMenu.addItem(withTitle: "Show Files", action: #selector(AppDelegate.toggleFileTree(_:)), keyEquivalent: "e")
        files.keyEquivalentModifierMask = [.command, .option]
        files.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        // ⌘⌥L: reveal the panel (if hidden) and move focus into whichever list is
        // showing — files on Changes, commits on History, the tree on Files — so
        // ↑/↓ navigate it without reaching for the mouse.
        let focusList = viewMenu.addItem(withTitle: "Focus List", action: #selector(AppDelegate.focusSourceControlList(_:)), keyEquivalent: "l")
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

        // Which window is key is the only thing that moves ⌘1…⌘3. Read the key
        // window a turn later rather than trusting the notification's window: a
        // preview is still `NSApp.keyWindow` while it resigns, and going from one
        // preview to another resigns and becomes in an order we shouldn't bet on.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { syncPreviewShortcuts() }
            }
        }
        syncPreviewShortcuts()

        return main
    }
}
