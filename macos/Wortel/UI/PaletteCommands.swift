import AppKit

/// One thing the palette can run: a menu item, found by walking the menu bar.
///
/// Read from the menus rather than listed by hand, so the palette offers
/// exactly what the menus do, under the same names and shortcuts, and
/// anything added to a menu turns up here without a second list to keep in
/// step. Read while the main window is still key, so validation (enabled,
/// "Show" or "Hide") is for the window you're in, not for the palette.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    /// The menus it sits in: ["View"], ["Tab", "Move Tab"].
    let path: [String]
    /// "⇧⌘T".
    let shortcut: String?
    let image: NSImage?
    let item: NSMenuItem

    /// Run it as its menu item would be: through the responder chain of the
    /// key window.
    @MainActor func perform() {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

enum PaletteCommands {
    /// Every enabled item in the menu bar, submenus included, in menu order.
    @MainActor static func all() -> [PaletteCommand] {
        guard let main = NSApp.mainMenu else { return [] }
        return collect(main, path: [])
    }

    /// The app menu has no title of its own (the system draws the app's name
    /// there), and its item's title is the class name: "NSMenuItem".
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// What a palette has no business offering: quitting and hiding the app,
    /// text editing (it would act on the palette's own field), the window
    /// list, and the palette itself.
    private static let skipped: Set<String> = [
        "terminate:", "hide:", "hideOtherApplications:", "unhideAllApplications:",
        "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "delete:",
        "makeKeyAndOrderFront:", "orderFrontCharacterPalette:", "startDictation:",
        "showSessionSwitcher:", "showCommandPalette:", "selectSessionAtIndex:",
        "arrangeInFront:", "performMiniaturize:", "performZoom:", "toggleFullScreen:",
        // The global shortcut's item: from the palette it could only hide the
        // window you're in.
        "toggleAppVisibility:",
    ]

    /// A symbol for commands whose menu item has none, so the list isn't a
    /// column of identical ⌘ tiles. The menu's own icon wins when it has one.
    private static let symbols: [String: String] = [
        "orderFrontStandardAboutPanel:": "info.circle",
        "checkForUpdates:": "arrow.down.circle",
        "restartToUpdate:": "arrow.clockwise.circle",
        "showSettings:": "gearshape",
        "newSession:": "plus.square",
        "newTerminalSession:": "terminal",
        "newHomeSession:": "house",
        "newWorktreeSession:": "plus.square.dashed",
        "showPromptHistory:": "clock.arrow.circlepath",
        "openFolder:": "folder",
        "renameSession:": "pencil",
        "closeSession:": "xmark",
        "closeWholeSession:": "xmark.square",
        "selectNextAttentionSession:": "bell.badge",
        "selectNextSession:": "chevron.down",
        "selectPreviousSession:": "chevron.up",
        "increaseFontSize:": "textformat.size.larger",
        "decreaseFontSize:": "textformat.size.smaller",
        "resetFontSize:": "textformat.size",
        "toggleSessionSidebar:": "sidebar.left",
        "goBackSession:": "chevron.left",
        "goForwardSession:": "chevron.right",
        "toggleSourceControl:": "arrow.triangle.branch",
        // As the panes' own tabs show them.
        "showChanges:": InspectorPane.changes.symbol,
        "showHistory:": InspectorPane.history.symbol,
        "toggleFileTree:": InspectorPane.files.symbol,
        "focusSourceControlList:": "list.bullet",
        "newTerminalHere:": "apple.terminal",
        "newBrowserHere:": "globe",
        "toggleSideColumn:": "sidebar.right",
        "toggleBottomStrip:": "rectangle.bottomthird.inset.filled",
        "toggleColumnSide:": "arrow.left.arrow.right",
        "openBrowserLocation:": "link",
        "newBottomTerminal:": "apple.terminal",
        "reopenClosedTab:": "arrow.uturn.backward",
        "selectNextSideTab:": "arrow.right",
        "selectPreviousSideTab:": "arrow.left",
        "focusNextArea:": "rectangle.righthalf.inset.filled.arrow.right",
        "focusPreviousArea:": "rectangle.lefthalf.inset.filled.arrow.left",
        "moveTabLeft:": "arrow.left.to.line",
        "moveTabRight:": "arrow.right.to.line",
        "moveTabDown:": "arrow.down.to.line",
        "moveTabUp:": "arrow.up.to.line",
        "showPreviewFind:": "magnifyingglass",
        "markSessionUnread:": "circle.dashed",
        "togglePinSession:": "pin",
        "cleanUpWorktrees:": "folder.badge.minus",
    ]

    @MainActor private static func collect(_ menu: NSMenu, path: [String]) -> [PaletteCommand] {
        // Menus filled as they open are filled now.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var commands: [PaletteCommand] = []
        for (index, item) in menu.items.enumerated() {
            guard !item.isSeparatorItem, !item.isHidden, !item.title.isEmpty else { continue }
            if let submenu = item.submenu {
                // The system's Services are other apps' commands, not Wortel's.
                guard submenu !== NSApp.servicesMenu else { continue }
                let name = path.isEmpty && index == 0 ? appName
                    : submenu.title.isEmpty ? item.title : submenu.title
                commands += collect(submenu, path: path + [name])
                continue
            }
            guard item.isEnabled, let action = item.action,
                  !skipped.contains(NSStringFromSelector(action)) else { continue }
            commands.append(PaletteCommand(
                title: item.title.replacingOccurrences(of: "\u{2026}", with: ""),
                path: path, shortcut: shortcut(of: item),
                image: item.image ?? symbols[NSStringFromSelector(action)].flatMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: nil)
                },
                item: item))
        }
        return commands
    }

    /// "⇧⌘T" for an item's key equivalent, as the menu draws it.
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var flags = item.keyEquivalentModifierMask
        // An uppercase letter is its own Shift.
        if key.count == 1, let c = key.first, c.isLetter, c.isUppercase { flags.insert(.shift) }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + display(key)
    }

    private static func display(_ key: String) -> String {
        switch key.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey?: return "↑"
        case NSDownArrowFunctionKey?: return "↓"
        case NSLeftArrowFunctionKey?: return "←"
        case NSRightArrowFunctionKey?: return "→"
        case 0x09?: return "⇥"
        case 0x0D?: return "↩"
        case 0x1B?: return "⎋"
        case 0x20?: return "Space"
        case 0x7F?, 0x08?: return "⌫"
        default: return key.uppercased()
        }
    }
}
