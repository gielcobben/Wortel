import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var runtime: GhosttyRuntime!
    private var mainWindowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu must exist before the app finishes launching so key
        // equivalents resolve from the very first event.
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else {
            fatalError("failed to initialize libghostty")
        }
        self.runtime = runtime

        let controller = MainWindowController(runtime: runtime)
        self.mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
