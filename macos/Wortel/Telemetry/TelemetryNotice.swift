import AppKit

/// The one-time "here is what this reports" notice.
///
/// **Not an alert, and that is the whole design.** An `NSAlert` on first launch
/// is a modal sheet in front of a terminal that has just spawned your shell,
/// and the first thing this app would ever do is stop you from typing. Wortel's
/// entire pitch is that it is ready the moment it opens. So this is a small
/// panel in the corner of the window that says its piece, offers the two
/// answers, and gets out of the way on its own if you simply carry on working:
/// the first keystroke into the terminal dismisses it, because someone who has
/// started typing has decided this is not what they are here for.
///
/// Dismissing it by typing is NOT consent recorded silently. It is the opt-out
/// default standing, which is what the notice said would happen, and the switch
/// it points at is in the app menu forever after.
///
/// Shown once ever, from `TelemetrySettings.needsNotice`, and only on a build
/// that actually reports: a Debug or 0.0.0 build tells you about behaviour it
/// does not have.
@MainActor
final class TelemetryNotice {
    private var panel: NSView?
    private var monitor: Any?
    private weak var host: NSView?

    /// `onDecline` runs when the person says no. Saying nothing is a yes by
    /// default, and says nothing to the user beyond what the notice already did.
    func present(in host: NSView, onDecline: @escaping () -> Void) {
        guard panel == nil else { return }
        self.host = host

        let box = NSVisualEffectView()
        box.material = .popover
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Anonymous usage data")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Wortel reports how often features are used, and nothing else. "
            + "No session names, no directories, no commands, nothing from your screen. "
            + "You can turn it off any time in the Wortel menu.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 300

        let details = NSButton(title: "What is sent", target: self, action: #selector(openPolicy))
        details.bezelStyle = .inline
        details.isBordered = false
        details.contentTintColor = .linkColor
        details.font = .systemFont(ofSize: 12)

        let no = NSButton(title: "No thanks", target: self, action: #selector(decline))
        no.bezelStyle = .rounded
        let yes = NSButton(title: "Fine", target: self, action: #selector(accept))
        yes.bezelStyle = .rounded
        yes.keyEquivalent = "\r"

        self.onDecline = onDecline

        let buttons = NSStackView(views: [details, NSView(), no, yes])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        host.addSubview(box)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            box.widthAnchor.constraint(equalToConstant: 330),
            box.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            box.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
        ])
        panel = box

        // Typing into the terminal dismisses it. Local monitor rather than
        // first-responder games: the terminal owns the keyboard and must keep
        // owning it, so this watches without ever taking focus, and passes the
        // event straight through so the keystroke still reaches the shell.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    private var onDecline: (() -> Void)?

    @objc private func accept() { dismiss() }

    @objc private func decline() {
        onDecline?()
        dismiss()
    }

    @objc private func openPolicy() {
        NSWorkspace.shared.open(URL(string: "https://wortel.sh/privacy")!)
    }

    /// Whatever the answer, the notice is done: shown once, never again.
    private func dismiss() {
        TelemetrySettings.markNoticeShown()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel?.removeFromSuperview()
        panel = nil
        onDecline = nil
    }
}
