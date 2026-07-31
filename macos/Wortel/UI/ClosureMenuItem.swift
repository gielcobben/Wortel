import AppKit

/// An `NSMenuItem` that runs a closure when chosen, so a menu can be built
/// inline without a separate target/selector object.
///
/// **This class must stay copyable.** AppKit copies menu items behind your back:
/// `NSToolbarClippedItemsIndicator` copies every item's
/// `menuFormRepresentation` when it builds the toolbar's `»` menu, and
/// `-[NSMenuItem copyWithZone:]` does that by calling the *designated*
/// initializer, `init(title:action:keyEquivalent:)`, on this subclass. With a
/// non-optional stored `handler` that initializer can't be inherited, so Swift
/// emits a trapping stub in its place — and clicking `»` crashed the app on it
/// (EXC_BREAKPOINT), from a stack with nothing of ours above AppKit.
final class ClosureMenuItem: NSMenuItem {
    /// Optional so the initializer AppKit copies through can exist at all. A
    /// copy is handed the original's closure in `copy(with:)` below, so nothing
    /// ends up with a nil one in practice.
    private var handler: (() -> Void)?

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    /// Reachable only from AppKit's copying. It deliberately doesn't set a
    /// target or action: whatever `copyWithZone:` is duplicating supplies those
    /// straight afterwards.
    override init(title: String, action: Selector?, keyEquivalent: String) {
        self.handler = nil
        super.init(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Let AppKit copy everything it knows about (title, image, state, submenu),
    /// then carry the closure across and re-point the copy at *itself*. Leaving
    /// the copied target aimed at the original would work only for as long as
    /// the original stayed alive — and the whole reason a copy exists is that
    /// AppKit intends to outlive the item it was made from.
    override func copy(with zone: NSZone? = nil) -> Any {
        let duplicate = super.copy(with: zone)
        if let duplicate = duplicate as? ClosureMenuItem {
            duplicate.handler = handler
            duplicate.target = duplicate
            duplicate.action = #selector(fire)
        }
        return duplicate
    }

    @objc private func fire() { handler?() }
}
