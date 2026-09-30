import AppKit
import WebKit

/// A window a page opened itself (`window.open`): a sign-in, a payment, an
/// OAuth consent screen. It has to be a real web view made from the
/// configuration WebKit hands over, or the page that opened it has no
/// `window.opener` to hear back from, and the sign-in never lands.
///
/// A small window of its own over Wortel's, as Safari shows one, rather
/// than a tab: it's there for a minute and closes itself (`window.close()`),
/// and ⌘W closes it too (`AppDelegate.closeSession` closes any window that
/// isn't the main one).
@MainActor
final class BrowserPopup: NSObject {
    /// The open ones. A popup keeps itself until its window closes.
    private static var open: [BrowserPopup] = []

    private let webView: WKWebView
    private let window: NSWindow
    private var titleObservation: NSKeyValueObservation?

    /// A popup for `configuration`, shown over `parent`; its web view is
    /// what `createWebViewWith` returns.
    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                     over parent: NSWindow?) -> WKWebView {
        let popup = BrowserPopup(configuration: configuration, features: features, over: parent)
        open.append(popup)
        return popup.webView
    }

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, over parent: NSWindow?) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        // The size the page asked for, within reason; Google's is 500×600.
        let width = min(max(features.width?.doubleValue ?? 500, 320), 1200)
        let height = min(max(features.height?.doubleValue ?? 640, 320), 1000)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        webView.uiDelegate = self
        webView.isInspectable = true
        window.isReleasedWhenClosed = false
        // In the same container a tab's page is in, so a key the page
        // ignores doesn't beep here either.
        let container = WebViewContainer()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container
        window.delegate = self
        titleObservation = webView.observe(\.title) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.window.title = view.title ?? "" }
        }
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

extension BrowserPopup: WKUIDelegate, NSWindowDelegate {
    /// The page closed itself: the sign-in is done.
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    /// A popup opening another (an account chooser's "use another account"):
    /// another window, for the same reason.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        BrowserPopup.open(configuration: configuration, features: windowFeatures, over: window)
    }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        titleObservation = nil
        Self.open.removeAll { $0 === self }
    }
}
