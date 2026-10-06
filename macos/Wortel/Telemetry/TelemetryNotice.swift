import AppKit

/// The usage-data disclosure: an `NSPopover` hanging off the ⓘ that sits beside
/// the + in the sidebar's bottom bar.
///
/// **It is a popover because it is attached to a control that stays.** The first
/// version was a floating rounded box in the corner of the terminal — a thing
/// with no origin, which is exactly what a macOS app doesn't do: on this
/// platform a panel that appears unbidden either belongs to a control you can
/// point at or it is an alert. Hanging it off a permanent ⓘ makes it the former,
/// and it costs nothing, because the disclosure has to be reachable again
/// afterwards anyway. So the same popover is the first-run notice and the place
/// the switch lives, and the arrow says where it came from and where to find it.
///
/// **The switch replaced the two buttons.** "No thanks" / "Fine" is a consent
/// dialog, and consent dialogs are what people click through; an `NSSwitch`
/// showing the state it is actually in says the same thing without pretending a
/// decision is being taken here. The App menu item and this switch are the same
/// preference through the same funnel (`AppDelegate.toggleTelemetry`).
///
/// **It never takes the keyboard**, on first run or on a click, which is the one
/// rule carried over from the old panel: Wortel's pitch is that it is ready the
/// moment it opens, and the first thing it does must not be stopping you from
/// typing. So the popover is `.applicationDefined` (AppKit dismisses nothing on
/// its own), key goes straight back to the window with the terminal's first
/// responder intact, and the monitors below do the dismissing: a keystroke — it
/// passes through to the shell — or a click anywhere outside.
///
/// **And when Wortel stops being the app you're in.** The monitors only see
/// Wortel's own events, and the window losing key only happens to a window
/// that had it. A first-run notice shown while Wortel wasn't active (launched
/// in the background, at login, relaunched by an update) had neither: clicks
/// went to other apps, and the popover stayed up over the window for good.
/// So deactivating closes it too, and the first-run notice waits until the
/// app is active and the ⓘ is actually on screen.
@MainActor
final class TelemetryNotice: NSObject, NSPopoverDelegate {
    static let shared = TelemetryNotice()

    /// The ⓘ, registered by `TelemetryInfoButton` when the sidebar builds it.
    private weak var anchor: NSButton?
    private var popover: NSPopover?
    private var monitors: [Any] = []

    func register(anchor: NSButton) { self.anchor = anchor }

    /// Shown once ever, and only on a build that actually reports — `needsNotice`
    /// is false on Debug, on a 0.0.0 dev build and under `DO_NOT_TRACK`, where
    /// the notice would describe behaviour the app does not have. The ⓘ is still
    /// there on those builds; it just says so instead.
    ///
    /// Retries because this runs a runloop turn after the window is up, and the
    /// button it points at is built by SwiftUI's first layout.
    func presentFirstRunIfNeeded(retries: Int = 3) {
        guard TelemetrySettings.needsNotice else { return }
        guard anchor?.window != nil else {
            guard retries > 0 else { return }
            DispatchQueue.main.async { self.presentFirstRunIfNeeded(retries: retries - 1) }
            return
        }
        // Not now: shown to an app you aren't in, it has nothing to dismiss
        // it. Next time you come to Wortel instead, and only counted as seen
        // once it has been.
        guard NSApp.isActive, anchorIsOnScreen else {
            waitingForActivation = true
            return
        }
        guard show() else { return }
        TelemetrySettings.markNoticeShown()
    }

    private var waitingForActivation = false

    @objc private func appBecameActive() {
        guard waitingForActivation else { return }
        waitingForActivation = false
        // A turn later: activation and the window coming forward land together.
        DispatchQueue.main.async { self.presentFirstRunIfNeeded() }
    }

    /// The ⓘ is somewhere you can see it: its window up and not in the Dock,
    /// and the sidebar it sits in not collapsed.
    private var anchorIsOnScreen: Bool {
        guard let anchor, let window = anchor.window else { return false }
        return window.isVisible && !window.isMiniaturized
            && !anchor.isHiddenOrHasHiddenAncestor && !anchor.visibleRect.isEmpty
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc func toggleVisible(_ sender: Any?) {
        if popover == nil { show() } else { dismiss() }
    }

    /// AppKit closed it itself (its window went, say): forget it, so the next
    /// click on the ⓘ opens it rather than closing what's already gone.
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        tearDown()
    }

    // ---- showing ----------------------------------------------------------

    @discardableResult
    private func show() -> Bool {
        guard popover == nil, anchorIsOnScreen, let anchor, let window = anchor.window else { return false }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = makeContent()
        self.popover = popover

        // The terminal's first responder, restored below: showing a popover
        // makes its own window key, and the surface would silently stop
        // receiving keys until the next click.
        let responder = window.firstResponder
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        window.makeKey()
        if let responder { window.makeFirstResponder(responder) }

        if let typing = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.dismiss()
            return event
        }) {
            monitors.append(typing)
        }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.window === self.popover?.contentViewController?.view.window { return event }
            self.dismiss()
            // A click on the ⓘ closes and stops there. Letting it through would
            // reach the button's action, which would reopen what it just shut.
            return self.isOnAnchor(event) ? nil : event
        }) {
            monitors.append(clicks)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey),
            name: NSApplication.didResignActiveNotification, object: nil)
        return true
    }

    private func isOnAnchor(_ event: NSEvent) -> Bool {
        guard let anchor, event.window === anchor.window else { return false }
        return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }

    @objc private func windowResignedKey() { dismiss() }

    private func dismiss() {
        guard let popover else { return }
        tearDown()
        // `close()`, not `performClose(_:)`: the second is the user-initiated
        // path, and this popover's behaviour is `.applicationDefined`.
        popover.close()
    }

    /// Everything that was watching for a reason to close it.
    private func tearDown() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        popover = nil
    }

    // ---- the content ------------------------------------------------------

    /// Where the ⓘ and the menu item part company, and deliberately. On a build
    /// that cannot report (Debug, a 0.0.0 dev build, `DO_NOT_TRACK`) the menu
    /// item is not there at all, because a switch that controls nothing is
    /// worse than no switch. The ⓘ stays and disables its switch with the
    /// reason underneath, because it is not only a switch: it is the answer to
    /// "what does this app report", which is worth giving even when the answer
    /// is "nothing on this build".
    private var switchable: Bool { TelemetrySettings.isSwitchable }

    private var inertReason: String {
        if TelemetrySettings.doNotTrack { return "DO_NOT_TRACK is set, so this build reports nothing." }
        return "This is a development build. It reports nothing."
    }

    private func makeContent() -> NSViewController {
        let title = NSTextField(labelWithString: "Anonymous usage data")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Wortel counts which features get used, like a session being created "
            + "or the git panel being opened, and nothing else. No session names, "
            + "no directories, no commands, nothing from your screen.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 272

        let separator = NSBox()
        separator.boxType = .separator

        let switchLabel = NSTextField(labelWithString: "Share usage data")
        switchLabel.font = .systemFont(ofSize: 12)

        let toggle = FirstMouseSwitch()
        toggle.controlSize = .small
        toggle.state = TelemetrySettings.isEnabled ? .on : .off
        toggle.isEnabled = switchable
        toggle.target = self
        toggle.action = #selector(switchChanged)

        let switchRow = NSStackView(views: [switchLabel, NSView(), toggle])
        switchRow.orientation = .horizontal
        switchRow.spacing = 8

        let details = FirstMouseButton(title: "What is sent", target: self, action: #selector(openPolicy))
        details.bezelStyle = .inline
        details.isBordered = false
        details.contentTintColor = .linkColor
        details.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [title, body, separator, switchRow, details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if !switchable {
            let note = NSTextField(wrappingLabelWithString: inertReason)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .tertiaryLabelColor
            note.preferredMaxLayoutWidth = 272
            stack.insertArrangedSubview(note, at: stack.arrangedSubviews.count - 1)
            stack.setCustomSpacing(2, after: switchRow)
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -13),
            stack.widthAnchor.constraint(equalToConstant: 272),
            // Both rows span the popover so the switch sits at its trailing edge
            // and the link at its leading one, rather than each hugging its text.
            switchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let controller = NSViewController()
        controller.view = content
        return controller
    }

    /// Through the same funnel as the menu item, so there is one definition of
    /// what turning it off does — including the final event on the way out.
    @objc private func switchChanged(_ sender: NSSwitch) {
        guard (sender.state == .on) != TelemetrySettings.isEnabledByUser else { return }
        NSApp.sendAction(#selector(AppDelegate.toggleTelemetry(_:)), to: nil, from: self)
        sender.state = TelemetrySettings.isEnabled ? .on : .off
    }

    @objc private func openPolicy() {
        NSWorkspace.shared.open(URL(string: "https://wortel.sh/privacy")!)
    }
}

/// The two controls in the popover, and the one thing they have to override.
///
/// A click into a window that is not key is spent making it key, and the
/// control under it never sees it — which is a sensible default and exactly
/// wrong here, because this popover gives the keyboard straight back to the
/// terminal on purpose (see `TelemetryNotice`). Without these, the switch takes
/// two clicks to flip: one to wake a window the user never noticed was asleep.
private final class FirstMouseSwitch: NSSwitch {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
