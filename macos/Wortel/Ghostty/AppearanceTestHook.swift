#if DEBUG
import AppKit

/// Flip one running copy between light and dark without flipping the Mac.
///
/// A test of appearance handling needs the appearance to change, and changing
/// the system's changes it for every app on the machine, the person's real
/// Wortel and the agents in it included. This sets `NSApp.appearance` instead,
/// which AppKit propagates exactly as it does a system change: the app's
/// `effectiveAppearance` changes (KVO fires) and every view in a window is told.
///
/// Debug builds only, and addressed by pid, so a notification meant for a test
/// copy can never reach another Wortel:
///
///     osascript -l JavaScript -e 'ObjC.import("Foundation");
///       $.NSDistributedNotificationCenter.defaultCenter
///        .postNotificationNameObjectUserInfoDeliverImmediately(
///          "sh.wortel.test.appearance.<pid>", "dark", $(), true)'
///
/// The object is `dark`, `light`, or `system` to hand it back to the Mac.
/// `macos/scripts/try-appearance.sh` wraps it.
enum AppearanceTestHook {
    private static var observer: NSObjectProtocol?

    static func install() {
        let name = Notification.Name("sh.wortel.test.appearance.\(ProcessInfo.processInfo.processIdentifier)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            switch note.object as? String {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        }
    }
}
#endif
