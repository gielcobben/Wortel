import AppKit

/// The sessions waiting on you, in the menu bar: there while at least one is,
/// gone the rest of the time.
///
/// The Dock badge says how many, and only while the Dock is showing. This is
/// for the rest of the day: Wortel behind a full-screen browser, the Dock
/// hidden, a second display. It says which, too, and takes you there.
///
/// **Only while something waits**, so there's nothing to configure and no
/// icon sitting in the menu bar for the hours nothing does: the item comes and
/// goes with the badge (`SessionManager.onAttentionChanged`). A dot in the
/// loudest kind's colour and the count, the same dot the sidebar shows.
@MainActor
final class AttentionStatusItem: NSObject, NSMenuDelegate {
    private let manager: SessionManager
    private let open: (Session.ID) -> Void
    private let showApp: () -> Void
    private var item: NSStatusItem?

    init(manager: SessionManager, open: @escaping (Session.ID) -> Void, showApp: @escaping () -> Void) {
        self.manager = manager
        self.open = open
        self.showApp = showApp
    }

    /// Waiting sessions, loudest first, then in sidebar order.
    private var waiting: [Session] {
        manager.sessionsInSidebarOrder.enumerated()
            .filter { $0.element.attention != nil }
            .sorted { a, b in
                let pa = a.element.attention?.priority ?? 0, pb = b.element.attention?.priority ?? 0
                return pa != pb ? pa > pb : a.offset < b.offset
            }
            .map(\.element)
    }

    func refresh() {
        let waiting = waiting
        guard let loudest = waiting.first?.attention else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = item ?? makeItem()
        self.item = item
        guard let button = item.button else { return }
        button.image = Self.dot(SessionStatusIndicator.attentionColor(loudest))
        button.imagePosition = .imageLeading
        button.title = " \(waiting.count)"
        button.toolTip = waiting.count == 1
            ? "\u{201c}\(waiting[0].leafName)\u{201d} is waiting"
            : "\(waiting.count) sessions are waiting"
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// Built as it opens, so it's never stale: a session that stopped waiting
    /// since the last refresh isn't offered.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        for session in waiting {
            guard let kind = session.attention else { continue }
            var parts = [session.leafName]
            if let folder = session.folderPath { parts.append(folder) }
            if let since = manager.attentionNote(for: session).since {
                parts.append(Self.age(now.timeIntervalSince(since)))
            }
            let entry = ClosureMenuItem(title: parts.joined(separator: " \u{00b7} ")) { [weak self] in
                self?.open(session.id)
            }
            entry.image = Self.dot(SessionStatusIndicator.attentionColor(kind))
            if let message = manager.attentionNote(for: session).message { entry.toolTip = message }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Show Wortel") { [weak self] in self?.showApp() })
    }

    /// "now", "4m", "2h", "3d".
    static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    private static func dot(_ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
