import AppKit

extension SessionColour {
    /// The system colour each one is drawn in, which adapts to light and dark
    /// as Finder's tags do. Mapped here rather than on the type so the model
    /// stays free of AppKit (see `SessionColour`).
    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .grey: return .systemGray
        }
    }

    /// A filled dot of this colour, for a menu item: the menu shows what you'd
    /// get, as Finder's Tags menu does.
    var swatch: NSImage? {
        NSImage(systemSymbolName: "circle.fill", accessibilityDescription: title)?
            .withSymbolConfiguration(Chrome.menuGlyph.applying(.init(paletteColors: [nsColor])))
    }
}

/// The Colour submenu: None, then the colours, with a check on the current
/// one. One builder for the row's menus (closures) and the Session menu
/// (`AppDelegate.setSessionColour(_:)`, which acts on the selected session),
/// so the two can't drift apart.
@MainActor
enum SessionColourMenu {
    /// For one session's own menu: each item sets that session's colour.
    static func item(for session: Session, manager: SessionManager) -> NSMenuItem {
        build { colour in
            let item = ClosureMenuItem(title: colour?.title ?? "None") { manager.setColour(session, colour) }
            item.state = session.colour == colour ? .on : .off
            return item
        }
    }

    /// For the sidebar selection's menu: each item colours all of them, and
    /// the check is on a colour only when they all share it.
    static func item(for sessions: [Session], manager: SessionManager) -> NSMenuItem {
        let colours = Set(sessions.map(\.colour))
        return build { colour in
            let item = ClosureMenuItem(title: colour?.title ?? "None") { manager.setColour(sessions, colour) }
            item.state = colours == [colour] ? .on : .off
            return item
        }
    }

    /// For the Session menu: each item carries its colour's raw value (none
    /// for None) and acts on whichever session is selected when it's chosen.
    /// The check is set in `AppDelegate.validateMenuItem`.
    static func item(action: Selector) -> NSMenuItem {
        // No glyph on the item itself: none of the menu bar's have one.
        build(glyph: false) { colour in
            let item = NSMenuItem(title: colour?.title ?? "None", action: action, keyEquivalent: "")
            item.representedObject = colour?.rawValue
            return item
        }
    }

    private static func build(glyph: Bool = true, _ make: (SessionColour?) -> NSMenuItem) -> NSMenuItem {
        let menu = NSMenu(title: "Colour")
        let none = make(nil)
        none.setGlyph("circle")
        menu.addItem(none)
        menu.addItem(.separator())
        for colour in SessionColour.allCases {
            let item = make(colour)
            item.image = colour.swatch
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            menu.addItem(item)
        }
        let item = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        if glyph { item.setGlyph("tag") }
        item.submenu = menu
        return item
    }
}
