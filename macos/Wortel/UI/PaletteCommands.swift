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
    /// The menus it sits in: ["View"], ["Session", "Move To"].
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

    /// What a palette has no business offering: quitting and hiding the app,
    /// text editing (it would act on the palette's own field), the window
    /// list, and the palette itself.
    private static let skipped: Set<String> = [
        "terminate:", "hide:", "hideOtherApplications:", "unhideAllApplications:",
        "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "delete:",
        "makeKeyAndOrderFront:", "orderFrontCharacterPalette:", "startDictation:",
        "showSessionSwitcher:", "showCommandPalette:", "selectSessionAtIndex:",
        "arrangeInFront:", "performMiniaturize:", "performZoom:", "toggleFullScreen:",
    ]

    @MainActor private static func collect(_ menu: NSMenu, path: [String]) -> [PaletteCommand] {
        menu.update()
        var commands: [PaletteCommand] = []
        for item in menu.items {
            guard !item.isSeparatorItem, !item.isHidden, !item.title.isEmpty else { continue }
            if let submenu = item.submenu {
                // The app menu's title is the app's name; the rest are theirs.
                let name = submenu.title.isEmpty ? item.title : submenu.title
                commands += collect(submenu, path: path + [name])
                continue
            }
            guard item.isEnabled, let action = item.action,
                  !skipped.contains(NSStringFromSelector(action)) else { continue }
            commands.append(PaletteCommand(
                title: item.title.replacingOccurrences(of: "\u{2026}", with: ""),
                path: path, shortcut: shortcut(of: item), image: item.image, item: item))
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
