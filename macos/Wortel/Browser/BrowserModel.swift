import AppKit
import Observation
import WebKit

/// Drives the in-app browser shown in the trailing inspector's Browser pane —
/// a `WKWebView` for opening a localhost dev server (or any URL) beside the
/// terminal, in the same column as Changes and History.
///
/// The web view is owned **here**, not by the SwiftUI view, so switching
/// inspector panes (Changes/History/Browser) or sessions never tears the page
/// down and reloads it — the same keep-it-alive rule the terminal surfaces
/// follow. It's app-wide and deliberately not tied to a repo: a preview of a
/// running server is a global thing, not a property of one session.
///
/// `NSObject` because it is its own `WKNavigationDelegate`; WebKit delivers those
/// callbacks on the main thread, which is where this `@MainActor` model lives.
@Observable
@MainActor
final class BrowserModel: NSObject, WKNavigationDelegate {
    /// The address bar's text. Bound to the field, so it's free to diverge from
    /// the committed URL while the user types; a navigation snaps it back.
    var address: String = ""

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false

    /// The live web view, or nil before the pane is first shown. Observable so
    /// the host reinstalls it when `clear()` swaps in a fresh one. Created lazily
    /// (`ensureWebView`) — WebKit isn't spun up until the browser is opened, so
    /// launch stays lean.
    private(set) var webView: WKWebView?

    /// Where relaunch reopens: the last address that finished loading.
    private static let lastURLKey = "browser.lastURL"

    /// Asked to close the browser pane — set by the app layer, which owns the
    /// inspector's visibility. Fired after a detach so handing the page to the
    /// system browser also dismisses the in-app one.
    @ObservationIgnored var onRequestClose: (() -> Void)?

    // MARK: - Web view lifecycle

    /// Build the web view if it doesn't exist yet, reopening the last address.
    /// Called by the host when the pane appears.
    func ensureWebView() {
        guard webView == nil else { return }
        webView = makeWebView(loading: UserDefaults.standard.string(forKey: Self.lastURLKey))
    }

    /// Empty the browser: a fresh blank web view (so back/forward history goes
    /// too), an empty address bar, and no remembered page to reopen.
    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.lastURLKey)
        address = ""
        canGoBack = false
        canGoForward = false
        isLoading = false
        webView = makeWebView(loading: nil)
    }

    private func makeWebView(loading stored: String?) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        if let stored, let url = URL(string: stored) {
            address = stored
            view.load(URLRequest(url: url))
        }
        return view
    }

    // MARK: - Navigation commands

    /// Load whatever's in the address bar, turning a bare host into a URL.
    func submitAddress() {
        guard let url = Self.normalizedURL(from: address) else { return }
        load(url)
    }

    /// Load a specific URL (e.g. a ⌘-clicked terminal link), building the web
    /// view if the pane hasn't been opened yet.
    func load(_ url: URL) {
        ensureWebView()
        address = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    /// The current page as a URL for handing off elsewhere: the committed page if
    /// there is one, otherwise whatever's typed in the address bar.
    var externalURL: URL? {
        if let url = webView?.url, url.absoluteString != "about:blank" { return url }
        return Self.normalizedURL(from: address)
    }

    /// Hand the current page off to the system default browser — "detach" it —
    /// then empty and close the in-app pane. The page now lives out there, so it
    /// shouldn't linger here: `clear()` wipes the address, history, and the
    /// remembered URL, and the pane closes.
    func openInDefaultBrowser() {
        guard let url = externalURL else { return }
        NSWorkspace.shared.open(url)
        clear()
        onRequestClose?()
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// The reload button doubles as a stop button while a load is in flight.
    func reloadOrStop() {
        guard let webView else { return }
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    // MARK: - WKNavigationDelegate (mirror the web view's state onto observables)

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        sync(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sync(webView)
        // Follow redirects and in-page navigation in the address bar.
        if let url = webView.url { address = url.absoluteString }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync(webView)
        if let url = webView.url, url.absoluteString != "about:blank" {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        sync(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        sync(webView)
    }

    /// Only the live web view drives the chrome — a stale one finishing a load
    /// after `clear()` swapped it out must not light the buttons back up.
    private func sync(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    // MARK: - URL parsing

    /// Turn address-bar text into a URL. An explicit scheme is honored as typed;
    /// a bare host gets `http://` for loopback/dev hosts — so `localhost:3000`
    /// just works — and `https://` for everything else.
    static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let lower = host.lowercased()
        let isLocal = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
            || lower.hasPrefix("0.0.0.0") || lower.hasPrefix("[::1]")
        return URL(string: "\(isLocal ? "http" : "https")://\(trimmed)")
    }
}
