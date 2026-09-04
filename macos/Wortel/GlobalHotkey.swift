import AppKit
import Carbon.HIToolbox

/// The one shortcut Wortel owns outside its own window.
///
/// Every other key equivalent in this app is a menu item, which means AppKit
/// only ever sees it while Wortel is frontmost — the moment you are in your
/// editor or your browser, none of them exist. A terminal holding the sessions
/// you are waiting on is worth reaching without first having to find it, so this
/// registers ⌃⌥⌘. with the window server and toggles the app on it.
///
/// **Carbon, and not an event monitor.** `NSEvent.addGlobalMonitorForEvents` is
/// the modern-looking way to do this and the wrong one twice over: it requires
/// the Accessibility permission (a prompt, on first launch, for an app that
/// otherwise asks for nothing), and it *observes* rather than claims the chord,
/// so the keystroke still reaches whatever app you were in — ⌃⌥⌘. would summon
/// Wortel and type a period into your editor. `RegisterEventHotKey` needs no
/// permission at all and consumes the event.
///
/// It also consumes it ahead of AppKit's menu scan, which is why the matching
/// item in the App menu is not a second, conflicting binding: while this
/// registration holds, that item's key equivalent is unreachable and purely
/// descriptive. If registration fails — another app got to ⌃⌥⌘. first — the menu
/// item quietly becomes the real binding, working wherever Wortel is frontmost,
/// which is the most that is still available in that case.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// ⌃⌥⌘. — three modifiers because a system-wide chord has to survive being
    /// pressed inside every other app on the machine, and anything shorter is
    /// something a terminal, an editor or a browser already wants.
    ///
    /// Deliberately the same chord cmux uses for its equivalent: theirs ships
    /// off by default, and for anyone running both, one of the two failing to
    /// register is a better outcome than one chord summoning either terminal
    /// depending on launch order.
    private static let keyCode = UInt32(kVK_ANSI_Period)
    private static let modifiers = UInt32(cmdKey | optionKey | controlKey)
    /// "WORT". Scopes the events this handler answers to the hot key we
    /// registered, since the handler is installed on the whole application and
    /// would otherwise see anyone else's.
    private static let signature = OSType(0x574F_5254)
    private static let identifier: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    fileprivate var onFire: (() -> Void)?

    private init() {}

    /// Claim the chord. Idempotent, and silent on failure by design: there is no
    /// settings UI to report into and nothing the user could do about a chord
    /// another app already owns, so the fallback (the menu item's own key
    /// equivalent) is left to speak for itself.
    func start(onFire: @escaping () -> Void) {
        guard hotKey == nil else { return }
        self.onFire = onFire

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            globalHotkeyEventHandler,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &handler)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(Self.keyCode,
                                         Self.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: Self.identifier),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr { hotKey = ref }
    }

    fileprivate static func matches(_ id: EventHotKeyID) -> Bool {
        id.signature == signature && id.id == identifier
    }
}

/// A file-private free function rather than a static on the class: an
/// `EventHandlerUPP` is a C function pointer, which cannot carry actor
/// isolation. The instance arrives through `userData` instead.
private let globalHotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &id)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
    // Carbon already delivers this on the main thread; the hop is what gives the
    // compiler the main-actor isolation it needs from a C callback, and it costs
    // one runloop turn on a keystroke that is about to raise a window anyway.
    DispatchQueue.main.async {
        guard GlobalHotkey.matches(id) else { return }
        hotkey.onFire?()
    }
    return OSStatus(noErr)
}
