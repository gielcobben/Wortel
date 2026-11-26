import AppKit
import SwiftUI

/// The mark-up layer over a file's preview, placed by SwiftUI over views
/// SwiftUI also places. (Over a page it is AppKit's, see `WebViewContainer`.)
struct MarkupOverlayHost: NSViewRepresentable {
    let session: MarkupSession

    func makeNSView(context: Context) -> NSView {
        guard let surface = session.surface else { return NSView() }
        return MarkupOverlayView(session: session, surface: surface)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
