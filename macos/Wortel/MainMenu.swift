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

    /// The Window menu item macOS adds for a 🌐 shortcut, if `event` is one:
    /// Fill (🌐⌃F), Center (🌐⌃C), Return to Previous Size (🌐⌃R).
    /// `NSMenu.performKeyEquivalent` fills the Window menu with them but
    /// doesn't match them, and a view that takes its own keys (the terminal)
    /// then gets a plain ⌃C. Measured with a CGEvent-backed 🌐⌃C: the menu
    /// lookup returns false, and the item found here, sent its action,
    /// centres the window.
    ///
    /// Only for a key that isn't a function key itself. Arrows, F-keys and
    /// Home/End carry `.function` whether or not 🌐 is held, so for them the
    /// flag can't tell 🌐⌃← from ⌃←, and ⌃← belongs to the shell.
    static func globeWindowItem(for event: NSEvent) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
        let flags = event.modifierFlags.intersection(relevant)
        guard flags.contains(.function), !event.isFunctionKey,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let menu = NSApp.windowsMenu else { return nil }
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
                guard item.action != nil, item.keyEquivalent.lowercased() == key,
                      item.keyEquivalentModifierMask.intersection(relevant) == flags else { continue }
                // Validated only once it's the one: not the whole menu per key.
                menu.update()
                return item.isEnabled ? item : nil
            }
            return nil
        }
        return find(in: menu)
    }

    /// Keep Select All's shortcut right for wherever the keyboard is, just
    /// before each keypress is matched against the menu.
    static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) {
                syncSelectAll()
                syncReload()
            }
            // macOS's own Window items (Center is 🌐⌃C), here rather than in
            // each view that takes keys, so it works wherever the focus is.
            // The menu's own lookup goes first: it's what fills the Window
            // menu with them, and anything of ours on a 🌐 chord is its anyway.
            if event.modifierFlags.contains(.function), !event.isFunctionKey,
               NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return nil
            }
            if let item = globeWindowItem(for: event), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                return nil
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
        // The few things that differ per person (`AppSettings`): ⌘, where
        // every Mac app has it. Automatic updates and anonymous usage data are
        // rows in that window, and the usage-data switch is also in the
        // sidebar's ⓘ.
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings\u{2026}", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        // What macOS lets Wortel do. The sidebar's icon for it only shows
        // while something is off, so this is the way in when nothing is.
        appMenu.addItem(withTitle: "Permissions\u{2026}", action: #selector(AppDelegate.showPermissions(_:)), keyEquivalent: "")
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
        sessionItem.submenu = sessionMenu

        // -- Start a session ---------------------------------------------------
        // Here (⌘N, in the folder you're in), out of every folder (⌥⌘N, at
        // home), here on a branch of its own (⌥⇧⌘N), or somewhere else (⌘O).
        // Fork, Open Branch and New Folder were cut: seven ways to start
        // something was more than anyone could keep apart. Archived sessions
        // are found with ⌘P. Each of the four starts the command Settings
        // names for new sessions, if it names one (`SessionStart.preferred`).
        sessionMenu.addItem(withTitle: "New Session", action: #selector(AppDelegate.newSession(_:)), keyEquivalent: "n")
        // ⌘N without the command Settings names for new sessions, and so only
        // there while it names one: with the field empty this would be a
        // second New Session. Not a fifth way in (see the note above): the
        // same session, in the same place, minus one typed line. Shown and
        // hidden as the setting changes, the way Restart to Update is, since
        // `isHidden` from `validateMenuItem` doesn't reliably take. A hidden
        // item gives up its key and is left out of ⌘P. ⌃⌘N is free in
        // `wortel.conf`.
        let plainSession = sessionMenu.addItem(withTitle: "New Terminal", action: #selector(AppDelegate.newTerminalSession(_:)), keyEquivalent: "n")
        plainSession.keyEquivalentModifierMask = [.command, .control]
        plainSession.isHidden = !AppSettings.shared.startsSessionsWithCommand
        // ⌘N inherits the directory you're in, which is right until the moment
        // you want out of it. This is the way out, and it's a command rather
        // than a preference because both answers are wanted by the same person
        // on the same day. Free of a wortel.conf keybind (alt+n isn't bound).
        let newHome = sessionMenu.addItem(withTitle: "New Session at Home", action: #selector(AppDelegate.newHomeSession(_:)), keyEquivalent: "n")
        newHome.keyEquivalentModifierMask = [.command, .option]
        // ⌥⌘N without the command, as New Terminal is ⌘N without it, and
        // there on the same condition. ⌃⌥⌘N is the two of them added up:
        // ⌃ is "without the command", ⌥ is "at home". Free in `wortel.conf`.
        let plainHome = sessionMenu.addItem(withTitle: "New Terminal at Home", action: #selector(AppDelegate.newHomeTerminalSession(_:)), keyEquivalent: "n")
        plainHome.keyEquivalentModifierMask = [.command, .control, .option]
        plainHome.isHidden = !AppSettings.shared.startsSessionsWithCommand
        AppSettings.shared.onNewSessionCommandChange = { [weak plainSession, weak plainHome] in
            let hidden = !AppSettings.shared.startsSessionsWithCommand
            plainSession?.isHidden = hidden
            plainHome?.isHidden = hidden
        }
        // ⌘N's isolated sibling: the same repository, in a worktree and on a
        // branch of its own. A sheet with a placeholder name selected, so
        // Return alone starts it, and From and Location are there when they
        // aren't the defaults. ⌥⇧⌘N because ⇧⌘N is New Window, as in VS Code,
        // Zed and cmux, whose ⌘N also makes something smaller than a window.
        // Still in the N family, and free of a wortel.conf keybind.
        let newWorktree = sessionMenu.addItem(withTitle: "New Worktree Session\u{2026}", action: #selector(AppDelegate.newWorktreeSession(_:)), keyEquivalent: "n")
        newWorktree.keyEquivalentModifierMask = [.command, .option, .shift]
        // ⌘O is every Mac app's "open", and a directory is the only thing
        // Wortel opens. Files are opened by the tree and by ⌘-clicking a path,
        // which are both already in front of the file you mean. It files the
        // session in a folder for its repository, made if there's none: that
        // is how folders are made.
        sessionMenu.addItem(withTitle: "Open Folder\u{2026}", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")

        // -- Move between sessions ---------------------------------------------
        sessionMenu.addItem(.separator())
        // ⌘P, as VS Code, Cursor and Zed open a file by name: here, a session.
        sessionMenu.addItem(withTitle: "Go to Session\u{2026}", action: #selector(AppDelegate.showSessionSwitcher(_:)), keyEquivalent: "p")
        // ⌘Y, Safari's and Chrome's History: everything you've typed to an
        // agent, read from the agents' own history files, the pick typed into
        // this session unsent. Not ⌃R, which is the shell's own history
        // search (and an agent's), nor ⇧⌘R (Force Reload Page) or ⌥⌘R
        // (Rename Session). Free of a wortel.conf keybind.
        let promptHistory = sessionMenu.addItem(withTitle: "Prompt History\u{2026}", action: #selector(AppDelegate.showPromptHistory(_:)), keyEquivalent: "y")
        promptHistory.keyEquivalentModifierMask = [.command]
        // Back and Forward through the places you've been (a session and the
        // tab you had in front in it), as a browser goes through pages and
        // Xcode through files. ⌘[ / ⌘] are the areas (and a page's own Back
        // and Forward), and ⌃⌘←/→ move a tab, so these take ⌃⌘[ / ⌃⌘].
        let back = sessionMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.goBackSession(_:)), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.control, .command]
        let forward = sessionMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForwardSession(_:)), keyEquivalent: "]")
        forward.keyEquivalentModifierMask = [.control, .command]
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
        // Only while the selected session's agent is a version too old to say
        // what it is doing: hidden otherwise, and named for the agent
        // ("Update Pi…") in AppDelegate.validateMenuItem. First, as on the
        // session's own menu (SessionActions).
        let updateAgent = sessionMenu.addItem(withTitle: "Update Agent\u{2026}", action: #selector(AppDelegate.updateSessionAgent(_:)), keyEquivalent: "")
        updateAgent.isHidden = true
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
        // Slack's "Remind me about this": the session comes back as the
        // unread ring and a notification. Validated in AppDelegate.
        ReminderMenu.items(preset: #selector(AppDelegate.remindSession(_:)),
                           custom: #selector(AppDelegate.remindSessionCustom(_:)),
                           cancel: #selector(AppDelegate.cancelSessionReminder(_:)))
            .forEach(sessionMenu.addItem)
        // Every worktree Wortel made, including those of sessions long
        // archived. A session's own goes when you close it, if there's
        // nothing in it worth keeping (`SessionManager.archive`).
        sessionMenu.addItem(withTitle: "Clean Up Worktrees\u{2026}", action: #selector(AppDelegate.cleanUpWorktrees(_:)), keyEquivalent: "")

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
        // or a page in front of an area. With none it's disabled, and ⌘F goes
        // on to the shell, where it's the terminal's.
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
        // ⌘E, as in Safari and every Mac app with a find: what is selected in
        // a page becomes what ⌘G looks for. Only with the keyboard in a
        // page; otherwise it's disabled and ⌘E is the terminal's.
        findMenu.addItem(withTitle: "Use Selection for Find",
                         action: #selector(AppDelegate.useSelectionForFind(_:)),
                         keyEquivalent: "e")
        selectAllItem = selectAll

        // View menu: what's on screen. The areas first, then what fills the
        // side column, then the browser in front, then the text itself.
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        // The workspace: the splits, their tabs, and moving between them.
        // Aligned with what people already know (see docs/shortcuts.md): ⌘B
        // hides the sidebar, ⌥⌘B opens and closes Changes and Files and ⌘J is
        // the terminal below, as in VS Code, Zed and ChatGPT; ⇧⌘[ / ⇧⌘] for
        // tabs as in every Mac app (⌃Tab and ⌥⌘←/→ too); ⌘[ / ⌘] between
        // splits as in iTerm and Ghostty; ⇧⌘C, ⇧⌘H and ⇧⌘F for the panes
        // (⌃⌘1-3 were theirs, and stay as hidden items); ⌃⌘arrows to move a
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
        // ⌥⌘B and ⌘J were Show Side Column and Show Bottom Strip, hiding and
        // showing the window's two fixed places. Those are splits like any
        // other now and nothing is hidden: ⌥⌘B opens Changes and Files on
        // the right and closes them again, ⌘J takes you to the terminal
        // under the main row (making one if there is none) and back.
        let sideColumn = viewMenu.addItem(withTitle: "Show Changes and Files", action: #selector(AppDelegate.toggleSideColumn(_:)), keyEquivalent: "b")
        sideColumn.keyEquivalentModifierMask = [.command, .option]
        let bottomStrip = viewMenu.addItem(withTitle: "Terminal Below", action: #selector(AppDelegate.toggleBottomStrip(_:)), keyEquivalent: "j")
        bottomStrip.keyEquivalentModifierMask = [.command]
        // ⌃` too, as VS Code, Zed and ChatGPT go to their terminal panel.
        addHidden(viewMenu, "Terminal Below", #selector(AppDelegate.toggleBottomStrip(_:)), "`", [.control])
        // With the keyboard in a browser's page these are Forward and Back
        // while the page has somewhere to go, as in Safari and Chrome (and as
        // cmux splits the same two keys); see AppDelegate.focusNextArea.
        let focusNext = viewMenu.addItem(withTitle: "Focus Next Split", action: #selector(AppDelegate.focusNextArea(_:)), keyEquivalent: "]")
        focusNext.keyEquivalentModifierMask = [.command]
        let focusPrevious = viewMenu.addItem(withTitle: "Focus Previous Split", action: #selector(AppDelegate.focusPreviousArea(_:)), keyEquivalent: "[")
        focusPrevious.keyEquivalentModifierMask = [.command]
        // By direction, across the splits of the main area and on into the
        // column and the strip. ⌥⌘ with an arrow, every other terminal's keys
        // for this, are the sessions and the tabs here, and ⌃⌘ moves a tab;
        // ⌃⌥⌘ is what was free.
        let focusSplit = NSMenuItem(title: "Focus Split", action: nil, keyEquivalent: "")
        let focusSplitMenu = NSMenu(title: "Focus Split")
        for (title, action, key) in [
            ("Left", #selector(AppDelegate.focusSplitLeft(_:)), NSLeftArrowFunctionKey),
            ("Right", #selector(AppDelegate.focusSplitRight(_:)), NSRightArrowFunctionKey),
            ("Above", #selector(AppDelegate.focusSplitUp(_:)), NSUpArrowFunctionKey),
            ("Below", #selector(AppDelegate.focusSplitDown(_:)), NSDownArrowFunctionKey),
        ] {
            let item = focusSplitMenu.addItem(withTitle: title, action: action, keyEquivalent: arrow(key))
            item.keyEquivalentModifierMask = [.command, .option, .control]
        }
        focusSplit.submenu = focusSplitMenu
        viewMenu.addItem(focusSplit)
        // ⇧⌘↩ and ⌃⌘=: Ghostty's keys for the same two things.
        let zoomSplit = viewMenu.addItem(withTitle: "Zoom Split", action: #selector(AppDelegate.zoomSplit(_:)), keyEquivalent: "\r")
        zoomSplit.keyEquivalentModifierMask = [.command, .shift]
        let equalize = viewMenu.addItem(withTitle: "Equalize Splits", action: #selector(AppDelegate.equalizeSplits(_:)), keyEquivalent: "=")
        equalize.keyEquivalentModifierMask = [.command, .control]
        // No key: it is for when you are lost, not for every day, and it
        // undoes an arrangement somebody made. The first of what may become
        // a list of presets.
        viewMenu.addItem(withTitle: "Reset Layout", action: #selector(AppDelegate.resetLayout(_:)), keyEquivalent: "")

        viewMenu.addItem(.separator())
        // A checkmark here, not a row in Settings, because it is flipped
        // while working: in each sidebar section, the sessions that want you
        // are drawn first. Only how they're drawn; the order you dragged is
        // kept (SidebarSort).
        viewMenu.addItem(withTitle: "Sort Unread First", action: #selector(AppDelegate.toggleSortUnreadFirst(_:)), keyEquivalent: "")

        viewMenu.addItem(.separator())
        // The three panes, each by ⇧⌘ and its first letter: C, H, F. One
        // shape with the browser's ⇧⌘B (Tab menu), which is how VS Code, Zed
        // and the Claude app name theirs (⇧⌘E Explorer, ⇧⌘F Search or Files,
        // ⇧⌘D Changes, ⇧⌘B Browser), and what the empty tab's page lists. A
        // terminal is ⌘T, the one that differs, as it does in each of those.
        // Each opens its pane, brings it forward, or closes it when it is on
        // screen. Titles flip Show/Hide in AppDelegate.validateMenuItem.
        //
        // ⇧⌘F is also a default of libghostty's (end_search, performable),
        // which would take it ahead of this menu: unbound in wortel.conf.
        let changes = viewMenu.addItem(withTitle: "Show Changes", action: #selector(AppDelegate.showChanges(_:)), keyEquivalent: "c")
        changes.keyEquivalentModifierMask = [.command, .shift]
        let history = viewMenu.addItem(withTitle: "Show History", action: #selector(AppDelegate.showHistory(_:)), keyEquivalent: "h")
        history.keyEquivalentModifierMask = [.command, .shift]
        let files = viewMenu.addItem(withTitle: "Show Files", action: #selector(AppDelegate.toggleFileTree(_:)), keyEquivalent: "f")
        files.keyEquivalentModifierMask = [.command, .shift]
        // What they were until 2026-11-26 keeps working: ⌃⌘1, ⌃⌘2 and ⌃⌘3
        // (numbered as git apps number theirs, with ⌃ because ⌘1…⌘9 are the
        // sessions here), ⌥⇧⌘G for History, and for Files ⇧⌘E, as VS Code,
        // Cursor, Zed and Codex open their file tree, and ⌥⌘E.
        addHidden(viewMenu, "Show Changes", #selector(AppDelegate.showChanges(_:)), "1", [.control, .command])
        addHidden(viewMenu, "Show History", #selector(AppDelegate.showHistory(_:)), "2", [.control, .command])
        addHidden(viewMenu, "Show History", #selector(AppDelegate.showHistory(_:)), "g", [.command, .option, .shift])
        addHidden(viewMenu, "Show Files", #selector(AppDelegate.toggleFileTree(_:)), "3", [.control, .command])
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
        // A checkmark, flipped while working: the same as dragging the diff's
        // divider to the bottom of the Changes pane, and back up.
        viewMenu.addItem(withTitle: "Show Diff in Changes", action: #selector(AppDelegate.toggleChangesDiff(_:)), keyEquivalent: "")

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
        // ⌥⌘U, as Safari and Chrome show a page's source: for a page shown
        // from a file, the file's text in place of the page, and back.
        // Titled by AppDelegate.validateMenuItem; disabled on any other page.
        let pageSource = viewMenu.addItem(withTitle: "Show Page Source", action: #selector(AppDelegate.toggleBrowserSource(_:)), keyEquivalent: "u")
        pageSource.keyEquivalentModifierMask = [.command, .option]
        // ⌥⌘I, as Safari and Chrome open their inspector. Disabled with no
        // browser in front, so it goes on to the terminal.
        let inspector = viewMenu.addItem(withTitle: "Show Web Inspector", action: #selector(AppDelegate.showWebInspector(_:)), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]

        // ⇧⌘M: mark-up over the preview in front (a page, for now), with a
        // checkmark while it is on. Preview's own key for its Markup toolbar
        // is ⇧⌘A, which is Select All in a terminal here; M is free, and no
        // Mac convention sits on it. Outside the Browser section above: it
        // is every preview's, not the browser's.
        viewMenu.addItem(.separator())
        let markUp = viewMenu.addItem(withTitle: "Mark Up", action: #selector(AppDelegate.toggleMarkup(_:)), keyEquivalent: "m")
        markUp.keyEquivalentModifierMask = [.command, .shift]

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
        // ⌥⌘T: the tab that asks, the "+" of the row you're in as a key. An
        // empty tab whose page lists what it can become, and there a first
        // letter picks. ⌥ is "the other one" of a key here (⌘N and ⌥⌘N).
        // Not ⌘T: that is followed by typing, which on that page would pick
        // rows by their letters. Not ⇧⌘T: Reopen Closed Tab, here and in
        // every browser.
        let newTab = tabMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTabHere(_:)), keyEquivalent: "t")
        newTab.keyEquivalentModifierMask = [.command, .option]
        // ⌘T: a new tab, as everywhere else; here a terminal in the row you're
        // in, which is also what a terminal user's ⌘T has always given them: a
        // new shell, right where they are. ⌘N is New Session. (Until the rows
        // had tabs, ⌘T was an alias of ⌘N: a session was the only tab there was.)
        let newTerminal = tabMenu.addItem(withTitle: "New Terminal Tab", action: #selector(AppDelegate.newTerminalHere(_:)), keyEquivalent: "t")
        newTerminal.keyEquivalentModifierMask = [.command]
        // ⇧⌘B: a browser in the row you're in, by its first letter like the
        // panes (View menu) and as the Claude app opens its browser. ⇧⌘L,
        // what it was (cmux's key for it), keeps working.
        let newBrowser = tabMenu.addItem(withTitle: "New Browser Tab", action: #selector(AppDelegate.newBrowserHere(_:)), keyEquivalent: "b")
        newBrowser.keyEquivalentModifierMask = [.command, .shift]
        addHidden(tabMenu, "New Browser Tab", #selector(AppDelegate.newBrowserHere(_:)), "l", [.command, .shift])
        // ⌘D / ⇧⌘D: every terminal's split right and split down (iTerm,
        // Ghostty, Warp, cmux, Terminal), and since the main area can be
        // split, that is what they are: a new terminal in a split of its own,
        // beside the one you're in or under it. (Until then they were a
        // terminal in the side column and one in the bottom strip, which
        // keep their items below.)
        let splitRight = tabMenu.addItem(withTitle: "Split Right", action: #selector(AppDelegate.splitRight(_:)), keyEquivalent: "d")
        splitRight.keyEquivalentModifierMask = [.command]
        let splitDown = tabMenu.addItem(withTitle: "Split Down", action: #selector(AppDelegate.splitDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        // ⌃⇧`, as VS Code and Zed open a new terminal. The shifted twin, as
        // ⌘⇧] carries: with Shift kept, ⌃⇧` can arrive as ~.
        let newBottom = tabMenu.addItem(withTitle: "New Terminal Below", action: #selector(AppDelegate.newBottomTerminal(_:)), keyEquivalent: "`")
        newBottom.keyEquivalentModifierMask = [.control, .shift]
        addHidden(tabMenu, "New Terminal Below", #selector(AppDelegate.newBottomTerminal(_:)),
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
            ("Down", #selector(AppDelegate.moveTabDown(_:)), NSDownArrowFunctionKey),
            ("Up", #selector(AppDelegate.moveTabUp(_:)), NSUpArrowFunctionKey),
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
        // Windows of sessions: each has its own sidebar, and a session is in
        // one of them. ⇧⌘N because ⌘N is a session, as VS Code, Zed and cmux
        // keep ⌘N for the thing inside and ⇧⌘N for a window. Moving and
        // merging have no key, as AppKit's Merge All Windows has none: a
        // drag between sidebars is the quick way.
        let newWindow = windowMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Move Session to New Window", action: #selector(AppDelegate.moveSessionToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(AppDelegate.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
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
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: "Send Feedback\u{2026}", action: #selector(AppDelegate.sendFeedback(_:)), keyEquivalent: "")
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

private extension NSEvent {
    /// An arrow, F-key, Home/End and the like: keys that carry `.function`
    /// on their own, 🌐 held or not. Anything else that does, has 🌐 held.
    var isFunctionKey: Bool {
        guard let scalars = charactersIgnoringModifiers?.unicodeScalars, scalars.count == 1,
              let scalar = scalars.first else { return true }
        return (0xF700...0xF8FF).contains(scalar.value)
    }
}
