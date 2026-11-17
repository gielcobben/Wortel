import AppKit

/// Remind Me in a session's menus: Slack's "Add a reminder". The submenu is
/// Slack's six choices and nothing else. While a reminder is set, a row's
/// menu calls it Edit Reminder and has Cancel Reminder under it; when it is
/// set for is the row's own to say (on a line under the name), not the
/// menu's. One builder for the row's menus (closures) and the Session menu
/// (`AppDelegate`'s actions on the selected session, which the ⌘P palette
/// finds there), as `SessionColourMenu` is, so the two can't drift apart.
@MainActor
enum ReminderMenu {
    /// The glyph for a reminder, in the menu and on the row's line.
    static let glyph = "clock"

    /// For one session's own menu.
    static func items(for session: Session, manager: SessionManager) -> [NSMenuItem] {
        items(for: [session], manager: manager)
    }

    /// For the sidebar selection's menu: each choice reminds you of all of
    /// them, and Cancel ends every reminder among them.
    static func items(for sessions: [Session], manager: SessionManager) -> [NSMenuItem] {
        let pending = sessions.contains { $0.remindAt != nil }
        // With one set, the item says so before it's opened, as Slack's does.
        let remind = wrap(choices(for: sessions, manager: manager),
                          title: pending ? "Edit Reminder" : "Remind Me", glyph: true)
        return pending ? [remind, cancel(for: sessions, manager: manager)] : [remind]
    }

    /// Slack's six.
    private static func choices(for sessions: [Session], manager: SessionManager) -> NSMenu {
        let menu = NSMenu(title: "Remind Me")
        for preset in ReminderTime.Preset.allCases {
            menu.addItem(ClosureMenuItem(title: preset.title) {
                manager.setReminder(sessions, at: ReminderTime.date(for: preset, now: Date()))
            })
        }
        menu.addItem(ClosureMenuItem(title: "Custom\u{2026}") {
            let pending = sessions.compactMap(\.remindAt).min()
            ReminderDialog.present(on: NSApp.mainWindow, initial: pending) { date in
                manager.setReminder(sessions, at: date)
            }
        })
        return menu
    }

    private static func cancel(for sessions: [Session], manager: SessionManager) -> NSMenuItem {
        let item = ClosureMenuItem(title: "Cancel Reminder") { manager.setReminder(sessions, at: nil) }
        item.setGlyph("clock.badge.xmark")
        return item
    }

    /// For the Session menu: each preset carries its index, and acts on
    /// whichever session is selected when it's chosen. Cancel Reminder is
    /// always there, enabled in `AppDelegate.validateMenuItem`. And one name,
    /// set or not: ⌘P finds commands by it.
    static func items(preset: Selector, custom: Selector, cancel: Selector) -> [NSMenuItem] {
        let menu = NSMenu(title: "Remind Me")
        for (index, choice) in ReminderTime.Preset.allCases.enumerated() {
            let item = NSMenuItem(title: choice.title, action: preset, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Custom\u{2026}", action: custom, keyEquivalent: ""))
        // No glyph on the items themselves: none of the menu bar's have one.
        return [wrap(menu, title: "Remind Me", glyph: false),
                NSMenuItem(title: "Cancel Reminder", action: cancel, keyEquivalent: "")]
    }

    private static func wrap(_ menu: NSMenu, title: String, glyph: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if glyph { item.setGlyph(Self.glyph) }
        item.submenu = menu
        return item
    }
}
