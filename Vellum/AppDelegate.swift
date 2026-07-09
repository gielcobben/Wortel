import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        manager.restore()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
