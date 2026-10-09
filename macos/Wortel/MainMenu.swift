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

    /// ⌘R has two meanings and, like ⌘1…⌘3 below, only one item can hold it:
    /// "Reload Page" while a browser is in front (Safari, Chrome, Codex), and
    /// the old binding for Rename Session otherwise (⌥⌘R is the one the menu
    /// shows). AppDelegate says which, asked before each ⌘ keypress is matched.
    static var browserInFront: () -> Bool = { false }
    private static weak var reloadItem: NSMenuItem?
    private static weak var renameAliasItem: NSMenuItem?

    private static func syncReload() {
        let browser = browserInFront()
        let reload = browser ? "r" : ""
        let rename = browser ? "" : "r"
        if reloadItem?.keyEquivalent != reload { reloadItem?.keyEquivalent = reload }
        if renameAliasItem?.keyEquivalent != rename { renameAliasItem?.keyEquivalent = rename }
    }

    private static var keyMonitor: Any?

    /// Keep Select All's shortcut right for wherever the keyboard is, just
    /// before each keypress is matched against the menu.
    static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) {
                syncSelectAll()
                syncReload()
            }
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

    /// Fills the Session menu's "Move To" for the selected session each time
    /// it opens (and when the palette reads the menus). Set by AppDelegate.
    static var fillMoveTo: (NSMenu) -> Void = { _ in }
    private static let moveToFiller = MenuFiller { MainMenu.fillMoveTo($0) }
    /// Whether the selected session has anywhere to move to. Set by
    /// AppDelegate; read as the Session menu opens.
    static var canMoveTo: () -> Bool = { false }
    private static weak var moveToItem: NSMenuItem?
    /// A row with a submenu has no action to validate, so its enabled state is
    /// set by hand, just before the menu opens (AppKit leaves a row without an
    /// action as it finds it). An empty "Move To" is a dead end; greyed out,
    /// it says there's nowhere to go, as the Finder's does.
    private static let sessionMenuUpdater = MenuFiller { _ in
        MainMenu.moveToItem?.isEnabled = MainMenu.canMoveTo()
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
        // Only while a downloaded update is waiting, and so in ⌘P only then.
        // Shown and hidden by the updater as that changes (twice a run at
        // most), rather than by a menu delegate, which AppKit would also ask
        // on every keypress while it looks for a shortcut. (`isHidden` from
        // `validateMenuItem` doesn't reliably take.)
        let restart = appMenu.addItem(withTitle: "Restart to Update", action: #selector(AppDelegate.restartToUpdate(_:)), keyEquivalent: "")
        restart.isHidden = true
        Updater.shared.onReadyVersionChange = { [weak restart] version in
            restart?.isHidden = version == nil
            restart?.title = version.map { "Restart to Update to \($0)" } ?? "Restart to Update"
        }
        // Checking and downloading in the background; on unless you turn it
        // off. Not on a development build, which doesn't update at all: a
        // switch that can't be turned on is worse than none (as the usage-data
        // item below).
        if !Updater.isDevelopmentBuild {
            appMenu.addItem(withTitle: "Check for Updates Automatically", action: #selector(AppDelegate.toggleAutomaticUpdates(_:)), keyEquivalent: "")
        }
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
        // Services, where every Mac app has it: the system fills it, and a
        // terminal is where "make a new note from this selection" and the like
        // are most often wanted.
        appMenu.addItem(.separator())
        let services = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
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
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
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
        sessionMenu.delegate = sessionMenuUpdater
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
        // The selected session's repository, on a branch of its own in its own
        // worktree: named as it is on the session's "…" and the folders'.
        sessionMenu.addItem(withTitle: "Fork\u{2026}", action: #selector(AppDelegate.forkSession(_:)), keyEquivalent: "")

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

        // -- Move between sessions ---------------------------------------------
        sessionMenu.addItem(.separator())
        // ⌘P, as VS Code, Cursor and Zed open a file by name: here, a session.
        sessionMenu.addItem(withTitle: "Go to Session\u{2026}", action: #selector(AppDelegate.showSessionSwitcher(_:)), keyEquivalent: "p")
        // ⌥⌘↑ / ⌥⌘↓ walk the sidebar: up and down, because it's a vertical
        // list, as Arc walks the tabs in its sidebar with the same keys. (It
        // was ⇧⌘[ / ⇧⌘], which every other Mac app means as previous/next
        // *tab*, so that is what those are now: Tab ▸ Next/Previous Tab.)
        let up = arrow(NSUpArrowFunctionKey)
        let down = arrow(NSDownArrowFunctionKey)
        let prev = sessionMenu.addItem(
            withTitle: "Previous Session",
            action: #selector(AppDelegate.selectPreviousSession(_:)),
            keyEquivalent: up)
        prev.keyEquivalentModifierMask = [.command, .option]
        let next = sessionMenu.addItem(
            withTitle: "Next Session",
            action: #selector(AppDelegate.selectNextSession(_:)),
            keyEquivalent: down)
        next.keyEquivalentModifierMask = [.command, .option]
        // Jump straight to whatever is waiting on you, wherever it sits in the
        // list: "next", with ⇧ for "only the ones that need me", as Slack's
        // ⌥⇧↓ goes to the next unread channel. Disabled (via
        // AppDelegate.validateMenuItem) when nothing waits. ⌥⌘], what it was,
        // keeps working.
        let nextAlert = sessionMenu.addItem(withTitle: "Next Waiting Session", action: #selector(AppDelegate.selectNextAttentionSession(_:)), keyEquivalent: down)
        nextAlert.keyEquivalentModifierMask = [.command, .option, .shift]
        addHidden(sessionMenu, "Next Waiting Session", #selector(AppDelegate.selectNextAttentionSession(_:)),
                  "]", [.command, .option])
        // ⌘1…⌘9: the sessions by position. Shortcuts only: nine rows reading
        // "Session 1" … "Session 9" said nothing the sidebar doesn't, and made
        // this menu twice the length of any other. As Safari's ⌘1…⌘9 for tabs.
        for i in 1...9 {
            let item = addHidden(sessionMenu, "Session \(i)", #selector(AppDelegate.selectSessionAtIndex(_:)),
                                 "\(i)", [.command])
            item.tag = i - 1
            if i <= 3 { sessionDigitItems.append(item) }
        }

        // -- This session ------------------------------------------------------
        // Acting on the selected session, as opposed to making one or moving
        // to one. No ellipsis on Rename: it starts an inline edit in the
        // sidebar, not a dialog. Also on its row's "…" and right-click
        // (SessionActions), and so in the ⇧⌘P palette.
        sessionMenu.addItem(.separator())
        // ⌥⌘R, as Codex renames a chat. Plain ⌘R is a browser's Reload; with
        // no browser in front it still renames (`syncReload`), as it always did.
        let rename = sessionMenu.addItem(withTitle: "Rename Session", action: #selector(AppDelegate.renameSession(_:)), keyEquivalent: "r")
        rename.keyEquivalentModifierMask = [.command, .option]
        renameAliasItem = addHidden(sessionMenu, "Rename Session", #selector(AppDelegate.renameSession(_:)), "", [.command])
        // ⌥⌘P, the ChatGPT app's: to the Pinned section at the top of the
        // sidebar, and back. Title flips in AppDelegate.validateMenuItem.
        let pin = sessionMenu.addItem(withTitle: "Pin Session", action: #selector(AppDelegate.togglePinSession(_:)), keyEquivalent: "p")
        pin.keyEquivalentModifierMask = [.command, .option]
        // ⇧⌘U, the ChatGPT app's: a "come back to this" flag.
        let unread = sessionMenu.addItem(withTitle: "Mark as Unread", action: #selector(AppDelegate.markSessionUnread(_:)), keyEquivalent: "u")
        unread.keyEquivalentModifierMask = [.command, .shift]
        // A colour of your own, for a session to come back to; checked in
        // AppDelegate.validateMenuItem.
        sessionMenu.addItem(SessionColourMenu.item(action: #selector(AppDelegate.setSessionColour(_:))))
        let moveTo = sessionMenu.addItem(withTitle: "Move To", action: nil, keyEquivalent: "")
        let moveToMenu = NSMenu(title: "Move To")
        moveToMenu.delegate = moveToFiller
        moveTo.submenu = moveToMenu
        moveToItem = moveTo
        // The worktree commands together, behind one row: the selected
        // session's own, and every worktree Wortel made, including those of
        // sessions long closed. Neither has a shortcut, and two rows of them
        // read as session commands they aren't.
        let worktree = sessionMenu.addItem(withTitle: "Worktree", action: nil, keyEquivalent: "")
        let worktreeMenu = NSMenu(title: "Worktree")
        worktree.submenu = worktreeMenu
        worktreeMenu.addItem(withTitle: "Remove This Worktree\u{2026}", action: #selector(AppDelegate.removeSessionWorktree(_:)), keyEquivalent: "")
        worktreeMenu.addItem(withTitle: "Clean Up Worktrees\u{2026}", action: #selector(AppDelegate.cleanUpWorktrees(_:)), keyEquivalent: "")

        // ⇧⌘W always means the whole session, as in iTerm and Ghostty. ⌘W,
        // which closes what you're in, is Tab ▸ Close Tab.
        sessionMenu.addItem(.separator())
        let closeSession = sessionMenu.addItem(withTitle: "Close Session", action: #selector(AppDelegate.closeWholeSession(_:)), keyEquivalent: "w")
        closeSession.keyEquivalentModifierMask = [.command, .shift]

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
        //
        // In a Find submenu, as every Apple app's Edit menu has it.
        let find = editMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        find.submenu = findMenu
        findMenu.addItem(withTitle: "Find\u{2026}",
                         action: #selector(PreviewWindowController.showPreviewFind(_:)),
                         keyEquivalent: "f")
        // ⌘G / ⇧⌘G walk the matches of an open find bar, as everywhere. With
        // none open they're disabled and go on to the terminal.
        findMenu.addItem(withTitle: "Find Next",
                         action: #selector(PreviewWindowController.previewFindNext(_:)),
                         keyEquivalent: "g")
        let findPrevious = findMenu.addItem(withTitle: "Find Previous",
                                            action: #selector(PreviewWindowController.previewFindPrevious(_:)),
                                            keyEquivalent: "g")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        selectAllItem = selectAll

        // View menu: what's on screen. The areas first, then what fills the
        // side column, then the browser in front, then the text itself.
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        // The workspace: the three areas, their tabs, and moving between them.
        // Aligned with what people already know (see docs/shortcuts.md): ⌘B /
        // ⌥⌘B / ⌘J for the sidebar, the column and the strip as in VS Code, Zed
        // and ChatGPT; ⇧⌘[ / ⇧⌘] for tabs as in every Mac app (⌃Tab and
        // ⌥⌘←/→ too); ⌘[ / ⌘] between areas as in iTerm and Ghostty; ⌃⌘1-3
        // for the panes, numbered as git apps number theirs; ⌃⌘arrows to move a
        // tab as VS Code moves an editor. Everything is ⌘-based but the Control
        // keys those apps use, which the terminal gives up nothing for:
        // Control+letter and Option+letter stay the shell's.
        //
        // ⌘B, as VS Code, Cursor, Zed and ChatGPT; ⌥⌘S (the Finder's, and what
        // Wortel had) keeps working.
        // Titled Show/Hide by AppDelegate.validateMenuItem, as Apple's are.
        let toggleSidebar = viewMenu.addItem(withTitle: "Hide Sidebar", action: #selector(AppDelegate.toggleSessionSidebar(_:)), keyEquivalent: "b")
        toggleSidebar.keyEquivalentModifierMask = [.command]
        addHidden(viewMenu, "Hide Sidebar", #selector(AppDelegate.toggleSessionSidebar(_:)), "s", [.command, .option])
        let sideColumn = viewMenu.addItem(withTitle: "Show Side Column", action: #selector(AppDelegate.toggleSideColumn(_:)), keyEquivalent: "b")
        sideColumn.keyEquivalentModifierMask = [.command, .option]
        let bottomStrip = viewMenu.addItem(withTitle: "Show Bottom Strip", action: #selector(AppDelegate.toggleBottomStrip(_:)), keyEquivalent: "j")
        bottomStrip.keyEquivalentModifierMask = [.command]
        // ⌃` too, as VS Code, Zed and ChatGPT toggle their terminal panel.
        addHidden(viewMenu, "Show Bottom Strip", #selector(AppDelegate.toggleBottomStrip(_:)), "`", [.control])
        let swapSides = viewMenu.addItem(withTitle: "Move Side Column to the Left", action: #selector(AppDelegate.toggleColumnSide(_:)), keyEquivalent: "b")
        swapSides.keyEquivalentModifierMask = [.command, .option, .shift]
        // With the keyboard in a browser's page these are Forward and Back
        // while the page has somewhere to go, as in Safari and Chrome (and as
        // cmux splits the same two keys); see AppDelegate.focusNextArea.
        let focusNext = viewMenu.addItem(withTitle: "Focus Next Area", action: #selector(AppDelegate.focusNextArea(_:)), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command]
        let focusPrevious = viewMenu.addItem(withTitle: "Focus Previous Area", action: #selector(AppDelegate.focusPreviousArea(_:)), keyEquivalent: "[")
        focusPrevious.keyEquivalentModifierMask = [.command]

        viewMenu.addItem(.separator())
        // The three panes by number, as git apps number theirs (GitHub Desktop,
        // Tower and Fork: ⌘1 Changes, ⌘2 History), with ⌃ added because ⌘1…⌘9
        // are the sessions here. Each opens its pane, brings it forward, or
        // closes it when it's already in front. Titles flip Show/Hide in
        // AppDelegate.validateMenuItem.
        let changes = viewMenu.addItem(withTitle: "Show Changes", action: #selector(AppDelegate.showChanges(_:)), keyEquivalent: "1")
        changes.keyEquivalentModifierMask = [.control, .command]
        let history = viewMenu.addItem(withTitle: "Show History", action: #selector(AppDelegate.showHistory(_:)), keyEquivalent: "2")
        history.keyEquivalentModifierMask = [.control, .command]
        // ⌥⇧⌘G, what History had, keeps working.
        addHidden(viewMenu, "Show History", #selector(AppDelegate.showHistory(_:)), "g", [.command, .option, .shift])
        let files = viewMenu.addItem(withTitle: "Show Files", action: #selector(AppDelegate.toggleFileTree(_:)), keyEquivalent: "3")
        files.keyEquivalentModifierMask = [.control, .command]
        // ⇧⌘E, as VS Code, Cursor, Zed and Codex open their file tree, and
        // ⌥⌘E, what Wortel had, keep working.
        addHidden(viewMenu, "Show Files", #selector(AppDelegate.toggleFileTree(_:)), "e", [.command, .shift])
        addHidden(viewMenu, "Show Files", #selector(AppDelegate.toggleFileTree(_:)), "e", [.command, .option])
        // ⌃⇧G, as VS Code, Cursor, Zed and Codex open source control: the
        // source control pane you used last. ⌥⌘G, what Wortel had, too.
        // Shown, not only a hidden key, so it's in the menu and the palette.
        let sourceControl = viewMenu.addItem(withTitle: "Show Source Control", action: #selector(AppDelegate.toggleSourceControl(_:)), keyEquivalent: "g")
        sourceControl.keyEquivalentModifierMask = [.control, .shift]
        addHidden(viewMenu, "Show Source Control", #selector(AppDelegate.toggleSourceControl(_:)), "g", [.command, .option])
        // ⌘⌥L: reveal the panel (if hidden) and move focus into whichever list is
        // showing — files on Changes, commits on History, the tree on Files — so
        // ↑/↓ navigate it without reaching for the mouse.
        let focusList = viewMenu.addItem(withTitle: "Focus List", action: #selector(AppDelegate.focusSourceControlList(_:)), keyEquivalent: "l")
        focusList.keyEquivalentModifierMask = [.command, .option]

        viewMenu.addItem(.separator())
        // ⇧⌘P, VS Code's command palette (which VS Code also keeps in View):
        // every command in these menus.
        let palette = viewMenu.addItem(withTitle: "Commands\u{2026}", action: #selector(AppDelegate.showCommandPalette(_:)), keyEquivalent: "p")
        palette.keyEquivalentModifierMask = [.command, .shift]

        // The browser in front. Headed, because four page commands among
        // terminal ones are otherwise easy to misread as the terminal's.
        viewMenu.addItem(.separator())
        viewMenu.addItem(.sectionHeader(title: "Browser"))
        // ⌘L, as in Safari and Chrome, puts you in the address field of the
        // browser in front; with none, the item is disabled and ⌘L goes on to
        // the terminal.
        let openLocation = viewMenu.addItem(withTitle: "Open Location", action: #selector(AppDelegate.openBrowserLocation(_:)), keyEquivalent: "l")
        openLocation.keyEquivalentModifierMask = [.command]
        // ⌘R / ⇧⌘R, as Chrome, Codex and cmux. The ⌘R is lent by `syncReload`
        // while a browser is in front.
        reloadItem = viewMenu.addItem(withTitle: "Reload Page", action: #selector(AppDelegate.reloadBrowserPage(_:)), keyEquivalent: "")
        let forceReload = viewMenu.addItem(withTitle: "Force Reload Page", action: #selector(AppDelegate.forceReloadBrowserPage(_:)), keyEquivalent: "r")
        forceReload.keyEquivalentModifierMask = [.command, .shift]
        // ⌥⌘I, as Safari and Chrome open their inspector. Disabled with no
        // browser in front, so it goes on to the terminal.
        let inspector = viewMenu.addItem(withTitle: "Show Web Inspector", action: #selector(AppDelegate.showWebInspector(_:)), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]

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
        let bigger = viewMenu.addItem(withTitle: "Increase Font Size", action: #selector(SurfaceView.increaseFontSize(_:)), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.command]
        let smaller = viewMenu.addItem(withTitle: "Decrease Font Size", action: #selector(SurfaceView.decreaseFontSize(_:)), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(withTitle: "Reset Font Size", action: #selector(SurfaceView.resetFontSize(_:)), keyEquivalent: "0")

        // ⌃⌘F, the Mac's own. Stated rather than left to AppKit's automatic
        // item, so it's there whatever AppKit decides about a built menu.
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]

        // Tab menu, as Chrome has one: the tabs of the row you're in. Opening,
        // moving between and closing them used to be spread over View (opening,
        // switching) and Session (⌘W), which is where neither is looked for.
        let tabItem = NSMenuItem()
        main.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tab")
        tabItem.submenu = tabMenu
        // ⌘T: a new tab, as everywhere else; here a terminal in the row you're
        // in, which is also what a terminal user's ⌘T has always given them: a
        // new shell, right where they are. ⌘N is New Session. (Until the rows
        // had tabs, ⌘T was an alias of ⌘N: a session was the only tab there was.)
        let newTerminal = tabMenu.addItem(withTitle: "New Terminal Tab", action: #selector(AppDelegate.newTerminalHere(_:)), keyEquivalent: "t")
        newTerminal.keyEquivalentModifierMask = [.command]
        // ⇧⌘L: a browser in the row you're in, as cmux opens its browser.
        let newBrowser = tabMenu.addItem(withTitle: "New Browser Tab", action: #selector(AppDelegate.newBrowserHere(_:)), keyEquivalent: "l")
        newBrowser.keyEquivalentModifierMask = [.command, .shift]
        // ⌘D / ⇧⌘D: every terminal's split right and split down (iTerm,
        // Ghostty, Warp, cmux, Terminal). Wortel's layout is fixed, so they
        // are a terminal beside the one you're in and one under it.
        let newSide = tabMenu.addItem(withTitle: "New Terminal in Side Column", action: #selector(AppDelegate.newSideTerminal(_:)), keyEquivalent: "d")
        newSide.keyEquivalentModifierMask = [.command]
        let newBottom = tabMenu.addItem(withTitle: "New Terminal in Bottom Strip", action: #selector(AppDelegate.newBottomTerminal(_:)), keyEquivalent: "d")
        newBottom.keyEquivalentModifierMask = [.command, .shift]
        // ⌃⇧` too, as VS Code and Zed open a new terminal. The shifted twin,
        // as ⌘⇧] carries: with Shift kept, ⌃⇧` can arrive as ~.
        addHidden(tabMenu, "New Terminal in Bottom Strip", #selector(AppDelegate.newBottomTerminal(_:)),
                  "`", [.control, .shift])
        addHidden(tabMenu, "New Terminal in Bottom Strip", #selector(AppDelegate.newBottomTerminal(_:)),
                  "~", [.control, .shift])

        tabMenu.addItem(.separator())
        // ⇧⌘] / ⇧⌘[: next and previous tab, as in Safari, Chrome, Finder,
        // Xcode, Terminal, iTerm2 and Ghostty.
        let nextTab = tabMenu.addItem(withTitle: "Next Tab", action: #selector(AppDelegate.selectNextSideTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let previousTab = tabMenu.addItem(withTitle: "Previous Tab", action: #selector(AppDelegate.selectPreviousSideTab(_:)), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        // AppKit matches a key equivalent against the event's
        // charactersIgnoringModifiers, which *keeps* Shift applied — so
        // depending on the event, ⌘⇧] arrives as "]" or as "}", and an item
        // authored the conventional way ("]" + ⌘⇧) only matches the former.
        // A hidden twin for the other shape. Matching stops at the first hit,
        // so whichever arrives, exactly one fires.
        addHidden(tabMenu, "Next Tab", #selector(AppDelegate.selectNextSideTab(_:)), "}", [.command, .shift])
        addHidden(tabMenu, "Previous Tab", #selector(AppDelegate.selectPreviousSideTab(_:)), "{", [.command, .shift])
        // ⌃⇥ / ⌃⇧⇥ too, as Safari and Chrome. Shift+Tab arrives as backtab on
        // some paths; a hidden twin catches that.
        addHidden(tabMenu, "Next Tab", #selector(AppDelegate.selectNextSideTab(_:)), "\t", [.control])
        addHidden(tabMenu, "Previous Tab", #selector(AppDelegate.selectPreviousSideTab(_:)), "\t", [.control, .shift])
        addHidden(tabMenu, "Previous Tab", #selector(AppDelegate.selectPreviousSideTab(_:)), "\u{19}", [.control, .shift])
        // ⌥⌘→ / ⌥⌘←, as VS Code, Zed and ChatGPT: horizontal for tabs, where
        // ⌥⌘↑ / ⌥⌘↓ are vertical for sessions.
        addHidden(tabMenu, "Next Tab", #selector(AppDelegate.selectNextSideTab(_:)), arrow(NSRightArrowFunctionKey), [.command, .option])
        addHidden(tabMenu, "Previous Tab", #selector(AppDelegate.selectPreviousSideTab(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option])
        // ⌥⌘1…9: a tab of the row you're in (⌘1…9 are sessions), 9 the last.
        for number in 1...9 {
            let item = addHidden(tabMenu, "Tab \(number)", #selector(AppDelegate.selectTabByNumber(_:)), "\(number)", [.command, .option])
            item.tag = number
        }
        let moveMenuItem = tabMenu.addItem(withTitle: "Move Tab", action: nil, keyEquivalent: "")
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

        tabMenu.addItem(.separator())
        let reopen = tabMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(AppDelegate.reopenClosedTab(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        // ⌘W closes what you're in: a tab, or the session when its own terminal
        // is in front (as closing a tab in any other terminal ends its shell).
        tabMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeSession(_:)), keyEquivalent: "w")

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // Help menu. Two things for the price of one item: the shortcut list
        // (⌘/, as Codex and Claude show theirs), and the system's search
        // field, which finds any command in these menus by name. That is the
        // nearest thing Wortel has to a command palette.
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(AppDelegate.showKeyboardShortcuts(_:)), keyEquivalent: "/")
        NSApp.helpMenu = helpMenu

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
        syncReload()

        return main
    }
}

/// A menu delegate that fills its menu from a closure just before it opens.
final class MenuFiller: NSObject, NSMenuDelegate {
    private let fill: (NSMenu) -> Void
    init(_ fill: @escaping (NSMenu) -> Void) { self.fill = fill }
    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }
}
