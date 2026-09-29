import AppKit
import WebKit

/// Programmatic main menu. Kept deliberately small: AppKit scans key
/// equivalents on every keypress, so every item here is on the hot path.
///
/// `@MainActor` because all of it is: the items it retains, the `NSApp.keyWindow`
/// it reads to decide who owns ⌘1, and the shortcuts it moves between them.
@MainActor
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

    /// ⌘A for Select All wherever it isn't spoken for: any text field or text
    /// view with the keyboard (a rename, a browser's address, the commit box,
    /// a find bar), a web page, and a preview window. None of those has the
    /// terminal's claim on it (⌘A is a `wortel.conf` keybind that clears the
    /// input line). Only the modifier moves; the `selectAll:` action is the
    /// same one the terminal answers on ⌘⇧A.
    ///
    /// Asked on every key down (`installKeyMonitor`), because nothing says
    /// when the keyboard moves into a field, and the item's shortcut has to be
    /// right before AppKit matches the keypress against the menu.
    private static func syncSelectAll() {
        let plain = textEditing || NSApp.keyWindow?.windowController is PreviewWindowController
            || keyboardIsInText
        let mask: NSEvent.ModifierFlags = plain ? [.command] : [.command, .shift]
        if selectAllItem?.keyEquivalentModifierMask != mask { selectAllItem?.keyEquivalentModifierMask = mask }
    }

    /// Whether the key window's first responder edits text or is a web page:
    /// a field editor or text view, or anything inside a web view.
    private static var keyboardIsInText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        if responder is NSTextView { return true }
        var view: NSView? = responder
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private static var keyMonitor: Any?

    /// Keep Select All's shortcut right for wherever the keyboard is, just
    /// before each keypress is matched against the menu.
    static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) { syncSelectAll() }
            return event
        }
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

    /// A menu item that's there for its shortcut only.
    @discardableResult
    private static func addHidden(_ menu: NSMenu, _ title: String, _ action: Selector,
                                  _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(UnicodeScalar(UInt16(key))!)
    }

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
        installKeyMonitor()

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
        // The same preference as the switch in the sidebar's ⓘ popover, in the
        // place a Mac user looks for a setting in an app that has no settings
        // window. AppDelegate carries the checkmark.
        //
        // Not added at all on a build that cannot report anyway (Debug, a 0.0.0
        // dev build, DO_NOT_TRACK set), because a switch that controls nothing
        // is worse than no switch. Decided here rather than hidden during
        // validation because none of those three can change while the app runs,
        // and `isHidden` set from `validateMenuItem` does not reliably take.
        // The ⓘ stays on those builds and says so instead: "what does this app
        // report" is worth an answer even when the answer is "nothing here".
        if TelemetrySettings.isSwitchable {
            appMenu.addItem(withTitle: "Share Anonymous Usage Data",
                            action: #selector(AppDelegate.toggleTelemetry(_:)),
                            keyEquivalent: "")
        }
        appMenu.addItem(.separator())
        // The only shortcut in this menu bar that works when Wortel is not the
        // app you are in: ⌃⌥⌘. summons it from anywhere and puts it away again.
        // Directly above Hide because that is the pair it belongs to — Hide is
        // the same verb with half the range, reachable only from inside.
        //
        // The key equivalent is very nearly decoration. A registered Carbon hot
        // key is consumed before AppKit ever scans this menu, so the item shows
        // the chord and never fires on it; it becomes the real binding only if
        // registration failed, which is exactly when an in-app fallback earns
        // its place. See GlobalHotkey.
        let showHide = appMenu.addItem(withTitle: "Show/Hide Wortel",
                                       action: #selector(AppDelegate.toggleAppVisibility(_:)),
                                       keyEquivalent: ".")
        showHide.keyEquivalentModifierMask = [.command, .option, .control]
        appMenu.addItem(withTitle: "Hide Wortel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Wortel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Session menu — the heart of the app, all keyboard-driven.
        //
        // **First after the app menu, before Edit**, which is where every Mac
        // app puts the menu named for the thing it works on: Terminal.app and
        // iTerm2 both put "Shell" there, and neither has a File menu at all. It
        // sat after Edit for a while and read subtly wrong for exactly that
        // reason. Menu order here is construction order, so this block staying
        // above Edit's *is* the fix — keep the file in menu-bar order.
        let sessionItem = NSMenuItem()
        main.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionItem.submenu = sessionMenu

        // -- Start a session ---------------------------------------------------
        // Two rows, and they're a deliberate pair: the same command with the two
        // answers to "where". ⌘N keeps you where you are, ⌥⌘N gets you out. They
        // sit together so the second reads as the exception to the first rather
        // than as a second, unexplained "New Session".
        sessionMenu.addItem(withTitle: "New Session", action: #selector(AppDelegate.newSession(_:)), keyEquivalent: "n")
        // ⌘N inherits the directory you're in, which is right until the moment
        // you want out of it. This is the way out, and it's a command rather
        // than a preference because both answers are wanted by the same person
        // on the same day. Free of a wortel.conf keybind (alt+n isn't bound).
        let newHome = sessionMenu.addItem(withTitle: "New Session at Home", action: #selector(AppDelegate.newHomeSession(_:)), keyEquivalent: "n")
        newHome.keyEquivalentModifierMask = [.command, .option]

        // -- Folders -----------------------------------------------------------
        // The two folder verbs, adjacent because that's how they read: make an
        // empty one to file sessions into, or open a directory that already
        // exists. New before Open, which is the order every Mac File menu uses.
        sessionMenu.addItem(.separator())
        // **"Folder", not "Section".** This item was the last place in the app
        // that called a folder a section — the sidebar's + menu, both header
        // context menus and every type and method say folder — and one letter
        // from "New Session" is a bad place to keep a synonym. Ellipsis because
        // it asks for a name.
        let newFolder = sessionMenu.addItem(withTitle: "New Folder\u{2026}", action: #selector(AppDelegate.newFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        // ⌘O is every Mac app's "open", and a directory is the only thing
        // Wortel opens. Files are opened by the tree and by ⌘-clicking a path,
        // which are both already in front of the file you mean.
        sessionMenu.addItem(withTitle: "Open Folder\u{2026}", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")

        // -- This session ------------------------------------------------------
        // Acting on the selected session, as opposed to making one. No ellipsis
        // on Rename: it starts an inline edit in the sidebar, not a dialog.
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Rename Session", action: #selector(AppDelegate.renameSession(_:)), keyEquivalent: "r")
        // ⌘W closes what you're in: a tab, or the session when its own terminal
        // is in front (as closing a tab in any other terminal ends its shell).
        // ⇧⌘W always means the whole session, as in iTerm and Ghostty.
        sessionMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeSession(_:)), keyEquivalent: "w")
        let closeSession = sessionMenu.addItem(withTitle: "Close Session", action: #selector(AppDelegate.closeWholeSession(_:)), keyEquivalent: "w")
        closeSession.keyEquivalentModifierMask = [.command, .shift]

        // -- Move between sessions ---------------------------------------------
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
        //
        // "Disabled" rests on the *window's* undo manager being empty, which is an
        // invariant something else has to keep: `undo:` resolves through the
        // responder chain to that manager, not to the first responder, so anything
        // registering there enables this item no matter what is focused. The commit
        // box got that wrong and it crashed the app (see `CommitMessageEditor`).
        // A view with `allowsUndo` owns its own manager, or this breaks again.
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
        // A preview window answers it for its file, and AppDelegate for a file
        // tab in front of an area. With neither it's disabled, and ⌘F goes on
        // to the shell, where it's the terminal's.
        editMenu.addItem(withTitle: "Find",
                         action: #selector(PreviewWindowController.showPreviewFind(_:)),
                         keyEquivalent: "f")
        selectAllItem = selectAll

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
        // ⌘B, as VS Code, Cursor, Zed and ChatGPT; ⌥⌘S (the Finder's, and what
        // Wortel had) keeps working.
        let toggleSidebar = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(AppDelegate.toggleSessionSidebar(_:)), keyEquivalent: "b")
        toggleSidebar.keyEquivalentModifierMask = [.command]
        addHidden(viewMenu, "Toggle Sidebar", #selector(AppDelegate.toggleSessionSidebar(_:)), "s", [.command, .option])
        // ⌘⌥G, not ⌘G: ⌘⌥S is already Toggle Sidebar above, and ⌘G is free of a
        // wortel.conf keybind. Routes through the responder chain to AppDelegate.
        // Title flips Show/Hide in AppDelegate.validateMenuItem based on panel
        // visibility; the icon stays put.
        let sourceControl = viewMenu.addItem(withTitle: "Show Source Control", action: #selector(AppDelegate.toggleSourceControl(_:)), keyEquivalent: "g")
        sourceControl.keyEquivalentModifierMask = [.command, .option]
        sourceControl.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        // ⌘⌥E for the third pane — free in both this file and wortel.conf. It
        // behaves exactly like ⌘⌥G: open on Files, bring it forward, or close
        // it if Files is already up.
        let history = viewMenu.addItem(withTitle: "Show History", action: #selector(AppDelegate.showHistory(_:)), keyEquivalent: "g")
        history.keyEquivalentModifierMask = [.command, .option, .shift]
        history.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let files = viewMenu.addItem(withTitle: "Show Files", action: #selector(AppDelegate.toggleFileTree(_:)), keyEquivalent: "e")
        files.keyEquivalentModifierMask = [.command, .option]
        files.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        // ⌘⌥L: reveal the panel (if hidden) and move focus into whichever list is
        // showing — files on Changes, commits on History, the tree on Files — so
        // ↑/↓ navigate it without reaching for the mouse.
        let focusList = viewMenu.addItem(withTitle: "Focus List", action: #selector(AppDelegate.focusSourceControlList(_:)), keyEquivalent: "l")
        focusList.keyEquivalentModifierMask = [.command, .option]
        focusList.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)

        // The workspace: the three areas, their tabs, and moving between them.
        // Aligned with what people already know (see docs/shortcuts.md): ⌘B /
        // ⌥⌘B / ⌘J for the sidebar, the column and the strip as in VS Code, Zed
        // and ChatGPT; ⌃Tab and ⌥⌘←/→ for tabs as in Safari and the editors;
        // ⌘[ / ⌘] between areas as in iTerm and Ghostty; ⌃⌘arrows to move a tab
        // as VS Code moves an editor. Everything is ⌘-based but the three
        // Control keys every one of those apps uses, which the terminal gives up
        // nothing for: Control+letter and Option+letter stay the shell's.
        viewMenu.addItem(.separator())
        let sideColumn = viewMenu.addItem(withTitle: "Show Side Column", action: #selector(AppDelegate.toggleSideColumn(_:)), keyEquivalent: "b")
        sideColumn.keyEquivalentModifierMask = [.command, .option]
        sideColumn.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        let bottomStrip = viewMenu.addItem(withTitle: "Show Bottom Strip", action: #selector(AppDelegate.toggleBottomStrip(_:)), keyEquivalent: "j")
        bottomStrip.keyEquivalentModifierMask = [.command]
        bottomStrip.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: nil)
        // ⌃` too, as VS Code, Zed and ChatGPT toggle their terminal panel.
        addHidden(viewMenu, "Show Bottom Strip", #selector(AppDelegate.toggleBottomStrip(_:)), "`", [.control])
        let swapSides = viewMenu.addItem(withTitle: "Move Side Column to the Left", action: #selector(AppDelegate.toggleColumnSide(_:)), keyEquivalent: "b")
        swapSides.keyEquivalentModifierMask = [.command, .option, .shift]

        viewMenu.addItem(.separator())
        // ⌘T: a new tab, as everywhere else; here a terminal in the row you're
        // in, which is also what a terminal user's ⌘T has always given them: a
        // new shell, right where they are. ⌘N is New Session. (Until the rows
        // had tabs, ⌘T was an alias of ⌘N: a session was the only tab there was.)
        let newTerminal = viewMenu.addItem(withTitle: "New Terminal Tab", action: #selector(AppDelegate.newTerminalHere(_:)), keyEquivalent: "t")
        newTerminal.keyEquivalentModifierMask = [.command]
        newTerminal.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)
        // ⇧⌘L: a browser in the row you're in, as cmux opens its browser. ⌘L,
        // as in Safari and Chrome, puts you in the address field of the
        // browser in front; with none, the item is disabled and ⌘L goes on to
        // the terminal.
        let newBrowser = viewMenu.addItem(withTitle: "New Browser Tab", action: #selector(AppDelegate.newBrowserHere(_:)), keyEquivalent: "l")
        newBrowser.keyEquivalentModifierMask = [.command, .shift]
        newBrowser.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let openLocation = viewMenu.addItem(withTitle: "Open Location", action: #selector(AppDelegate.openBrowserLocation(_:)), keyEquivalent: "l")
        openLocation.keyEquivalentModifierMask = [.command]
        let newBottom = viewMenu.addItem(withTitle: "New Terminal in Bottom Strip", action: #selector(AppDelegate.newBottomTerminal(_:)), keyEquivalent: "`")
        newBottom.keyEquivalentModifierMask = [.control, .shift]
        // The shifted twin, as ⌘⇧] carries: with Shift kept, ⌃⇧` can arrive as ~.
        addHidden(viewMenu, "New Terminal in Bottom Strip", #selector(AppDelegate.newBottomTerminal(_:)),
                  "~", [.control, .shift])
        let reopen = viewMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(AppDelegate.reopenClosedTab(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        let nextTab = viewMenu.addItem(withTitle: "Next Tab", action: #selector(AppDelegate.selectNextSideTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = viewMenu.addItem(withTitle: "Previous Tab", action: #selector(AppDelegate.selectPreviousSideTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        // Shift+Tab arrives as backtab on some paths; the hidden twin catches it.
        addHidden(viewMenu, "Previous Tab", #selector(AppDelegate.selectPreviousSideTab(_:)), "\u{19}", [.control, .shift])
        // ⌥⌘→ / ⌥⌘←, as VS Code, Zed and ChatGPT: horizontal for tabs, where
        // ⌥⌘↑ / ⌥⌘↓ are vertical for sessions.
        addHidden(viewMenu, "Next Tab", #selector(AppDelegate.selectNextSideTab(_:)), arrow(NSRightArrowFunctionKey), [.command, .option])
        addHidden(viewMenu, "Previous Tab", #selector(AppDelegate.selectPreviousSideTab(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option])
        // ⌥⌘1…9: a tab of the row you're in (⌘1…9 are sessions), 9 the last.
        for number in 1...9 {
            let item = addHidden(viewMenu, "Tab \(number)", #selector(AppDelegate.selectTabByNumber(_:)), "\(number)", [.command, .option])
            item.tag = number
        }

        viewMenu.addItem(.separator())
        let focusNext = viewMenu.addItem(withTitle: "Focus Next Area", action: #selector(AppDelegate.focusNextArea(_:)), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command]
        let focusPrevious = viewMenu.addItem(withTitle: "Focus Previous Area", action: #selector(AppDelegate.focusPreviousArea(_:)), keyEquivalent: "[")
        focusPrevious.keyEquivalentModifierMask = [.command]
        let moveMenuItem = viewMenu.addItem(withTitle: "Move Tab", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu(title: "Move Tab")
        moveMenuItem.submenu = moveMenu
        for (title, action, key) in [
            ("Left", #selector(AppDelegate.moveTabLeft(_:)), NSLeftArrowFunctionKey),
            ("Right", #selector(AppDelegate.moveTabRight(_:)), NSRightArrowFunctionKey),
            ("Down to Bottom Strip", #selector(AppDelegate.moveTabDown(_:)), NSDownArrowFunctionKey),
            ("Up to Main Area", #selector(AppDelegate.moveTabUp(_:)), NSUpArrowFunctionKey),
        ] {
            let item = moveMenu.addItem(withTitle: title, action: action, keyEquivalent: arrow(key))
            item.keyEquivalentModifierMask = [.control, .command]
        }

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
                DispatchQueue.main.async { MainActor.assumeIsolated { syncPreviewShortcuts() } }
            }
        }
        syncPreviewShortcuts()

        return main
    }
}
