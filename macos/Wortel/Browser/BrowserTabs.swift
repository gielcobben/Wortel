import AppKit
import Observation
import SwiftUI
import WebKit

/// Pages from what a session serves, shown in tabs: the dev server beside the
/// agent editing it.
///
/// One live page per address, kept here rather than in the view, for the same
/// reason terminals live in their keepers: a tab moves between rows and
/// sessions come and go, and a page rebuilt on every move would lose its
/// scroll, its form state and its HMR connection each time. The view borrows
/// the page's web view and hands it back (`WebViewHost`).
///
/// Not a browser. The address is where it was opened, there is no address
/// bar to type into, and a link to anywhere that isn't local goes to your
/// browser, which is where the rest of the web belongs.
@MainActor
final class BrowserTabs {
    static let shared = BrowserTabs()

    private var pages: [String: BrowserPage] = [:]

    /// The page for a tab, loaded the first time it's asked for.
    func page(for address: String) -> BrowserPage {
        if let page = pages[address] { return page }
        let page = BrowserPage(address: URL(string: address) ?? URL(string: "about:blank")!)
        pages[address] = page
        return page
    }

    /// A tab closed: let its page go.
    func forget(_ address: String) {
        pages.removeValue(forKey: address)?.close()
    }
}

/// One page and what its header shows about it.
@Observable
@MainActor
final class BrowserPage: NSObject {
    /// Where the tab was opened: what it retries while the server is down.
    let address: URL
    @ObservationIgnored let webView: WKWebView

    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// Nothing answers at the address yet, or any more: a server starting, or
    /// restarting. The page keeps trying until it does.
    private(set) var isWaiting = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var retry: Task<Void, Never>?

    /// How often a page whose server is down tries again.
    private static let retryInterval: Duration = .seconds(1)

    init(address: URL) {
        self.address = address
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Inspect Element in the context menu: it's a developer's page.
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        observations = [
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.currentURL = view.url }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
        ]
        webView.load(URLRequest(url: address))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if isWaiting || webView.url == nil {
            webView.load(URLRequest(url: currentURL ?? address))
        } else {
            webView.reload()
        }
    }

    func stop() { webView.stopLoading() }

    func openInBrowser() {
        NSWorkspace.shared.open(currentURL ?? address)
    }

    fileprivate func close() {
        retry?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// `localhost:5173`, `localhost:5173/docs`: what a tab and a header call an
    /// address. The scheme is always http and says nothing.
    static func shortAddress(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return url?.absoluteString ?? "Page" }
        var text = host
        if let port = url.port { text += ":\(port)" }
        let path = url.path()
        if !path.isEmpty, path != "/" { text += path }
        return text
    }

    /// Whether a URL is the session's own, a page to keep in the tab, rather
    /// than the web at large.
    fileprivate static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return url.scheme == "about" }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasSuffix(".localhost") || host.hasSuffix(".local")
    }

    /// Try the address again in a moment, until something answers.
    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled, let self, self.isWaiting else { return }
            self.webView.load(URLRequest(url: self.currentURL ?? self.address))
        }
    }
}

extension BrowserPage: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A link out of the session's own pages opens in the browser.
        if action.navigationType == .linkActivated, let url = action.request.url,
           action.targetFrame?.isMainFrame ?? true, !Self.isLocal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isWaiting = false
        retry?.cancel()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        let code = (error as NSError).code
        // A reload or link click cut short by the next one isn't a failure.
        guard code != NSURLErrorCancelled else { return }
        let unreachable: Set<Int> = [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                                     NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                                     NSURLErrorNotConnectedToInternet]
        guard unreachable.contains(code) else { return }
        isWaiting = true
        scheduleRetry()
    }

    /// `target="_blank"` and `window.open`: a local page in this tab, anything
    /// else in the browser. There's no second window to give it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if Self.isLocal(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }
}

/// A web page's tab: a slim header and the page.
struct BrowserTab: View {
    let page: BrowserPage

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabHeader(page: page)
            Rectangle()
                .fill(Color(nsColor: Chrome.hairline))
                .frame(height: 1)
            ZStack {
                WebViewHost(page: page)
                if page.isWaiting {
                    WaitingForServer(address: BrowserPage.shortAddress(page.address))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
        // Another page in the same row is another web view to borrow.
        .id(ObjectIdentifier(page))
    }
}

/// Back, forward, reload, where the page is, and the way out to the browser.
/// Laid out like a file tab's header.
private struct BrowserTabHeader: View {
    let page: BrowserPage

    var body: some View {
        HStack(spacing: 2) {
            button("chevron.left", "Back", action: page.goBack)
                .disabled(!page.canGoBack)
            button("chevron.right", "Forward", action: page.goForward)
                .disabled(!page.canGoForward)
            if page.isLoading && !page.isWaiting {
                button("xmark", "Stop Loading", action: page.stop)
            } else {
                button("arrow.clockwise", "Reload", action: page.reload)
            }
            Text(BrowserPage.shortAddress(page.currentURL ?? page.address))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help((page.currentURL ?? page.address).absoluteString)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            button("arrow.up.forward.square", "Open in Browser", action: page.openInBrowser)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private func button(_ symbol: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// What a page shows while nothing answers at its address.
private struct WaitingForServer: View {
    let address: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for \(address)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
    }
}

/// Borrows a page's web view for as long as the tab is on screen here. When
/// the tab moves, the next host takes the view over (adding it moves it), and
/// this one only lets go of it if it still has it.
private struct WebViewHost: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let webView = page.webView
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        container.addSubview(webView)
    }
}
