import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Notification userInfo key carrying the session UUID string, so a tap can
    /// route back to the right session.
    private static let sessionKey = "sessionID"
    private(set) var runtime: GhosttyRuntime!
    private var manager: SessionManager!
    private var window: NSWindow!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu must exist before launch so key equivalents resolve immediately.
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else {
            fatalError("failed to initialize libghostty")
        }
        self.runtime = runtime

        let manager = SessionManager(runtime: runtime)
        self.manager = manager

        // AppKit window hosting a SwiftUI NavigationSplitView (the Opslan
        // layout). fullSizeContentView so the sidebar runs to the top; SwiftUI
        // drives the title/toolbar/floating sidebar itself.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.tabbingMode = .disallowed
        // Drop the hairline the system draws under the titlebar/toolbar so the
        // terminal and sidebar run edge-to-edge with no border bottom.
        window.titlebarSeparatorStyle = .none
        window.contentViewController = NSHostingController(
            rootView: ContentView(runtime: runtime, manager: manager))
        window.setFrameAutosaveName("main")
        if window.frame.height < 320 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        self.window = window

        manager.onAllClosed = { [weak self] in self?.window?.close() }
        manager.confirmClose = { [weak self] session, completion in
            self?.confirmClose(session, completion: completion)
        }
        manager.onNeedsAttention = { [weak self] session, title, body in
            self?.postAttentionNotification(session, title: title, body: body)
        }

        // Native "a session needs you" notifications. The signal is
        // program-authored (e.g. Claude Code emits OSC 777 on a permission/idle
        // prompt because libghostty sets TERM_PROGRAM=ghostty) — we just relay
        // it. Ask once; if the user declines, the sidebar dot + Dock badge still
        // work.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        manager.restore()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Focus tracking (drives "actively viewing" → no attention shout)

    func applicationDidBecomeActive(_ notification: Notification) {
        manager?.appDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        manager?.appDidResignActive()
    }

    // MARK: - Attention notifications

    /// Post (or replace) the "needs you" notification for a session. Uses the
    /// session id as the request identifier so a chatty program updates one
    /// notification instead of stacking many.
    private func postAttentionNotification(_ session: Session, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.sessionKey: session.id.uuidString]
        let request = UNNotificationRequest(
            identifier: session.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Foreground delivery: still show the banner (the user is in another
    /// session, or away from the keyboard) — we only get here when the session
    /// isn't the actively-viewed one.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping the notification jumps to that session and brings Wortel front.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let idString = response.notification.request.content.userInfo[Self.sessionKey] as? String,
           let id = UUID(uuidString: idString) {
            manager?.select(id: id)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.saveNow()
    }

    // MARK: - Close confirmation

    /// Sheets a warning when closing a session that still has a running
    /// process. `completion(true)` proceeds with the close. Falls back to
    /// closing immediately if there's no window to sheet onto.
    private func confirmClose(_ session: Session, completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.name)”?"
        alert.informativeText =
            "A process is still running in this session. Closing it will terminate the process."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Menu actions (reached via the responder chain, target nil)

    @objc func newSession(_ sender: Any?) {
        manager.newSession()
    }

    @objc func closeSession(_ sender: Any?) {
        manager.requestCloseSelected()
    }

    @objc func renameSession(_ sender: Any?) {
        manager.beginRenameSelected()
    }

    @objc func selectNextSession(_ sender: Any?) {
        manager.selectNext()
    }

    @objc func selectPreviousSession(_ sender: Any?) {
        manager.selectPrevious()
    }

    @objc func selectSessionAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        manager.select(index: item.tag)
    }
}
