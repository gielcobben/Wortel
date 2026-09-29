import AppKit
import Observation
import SwiftUI
import WebKit

/// Browsers in tabs: the dev server beside the agent editing it, docs beside
/// the terminal. A browser is a tab like any other: "+" or ⇧⌘L opens one, it
/// moves between rows, and a session can have several. There's no window of
/// its own: the way out is your browser, which is better at being one.
///
/// One live page per tab, kept here rather than in the view, for the same
/// reason terminals live in their keepers: a tab moves between rows and
/// sessions come and go, and a page rebuilt on every move would lose its
/// scroll, its form state and its HMR connection each time. The view borrows
/// the page's web view and hands it back (`WebViewHost`).
///
/// Where each browser is, is session state (`Session.browserAddresses`),
/// reached through `address` and written through `onNavigate`, both set by
/// AppDelegate. A page is made the first time its tab is shown.
@Observable
@MainActor
final class BrowserTabs {
    static let shared = BrowserTabs()

    private var pages: [UUID: BrowserPage] = [:]

    /// Where a browser tab is, from its session.
    @ObservationIgnored var address: (UUID) -> URL? = { _ in nil }
    /// A browser tab went somewhere: record it on its session.
    @ObservationIgnored var onNavigate: (UUID, URL) -> Void = { _, _ in }
    /// What's serving on this Mac, the selected session's first: what an
    /// address field offers.
    @ObservationIgnored var servers: () -> [BrowserServer] = { [] }

    /// The page for a tab, loaded the first time it's asked for.
    func page(for id: UUID) -> BrowserPage {
        if let page = pages[id] { return page }
        let page = BrowserPage(address: address(id))
        page.onNavigate = { [weak self] url in self?.onNavigate(id, url) }
        pages[id] = page
        return page
    }

    /// The page for a tab if it has one yet: what its tab is titled by.
    func existingPage(for id: UUID) -> BrowserPage? { pages[id] }

    /// A tab closed: let its page go.
    func forget(_ id: UUID) {
        pages.removeValue(forKey: id)?.close()
    }
}

/// One page and what its header shows about it.
@Observable
@MainActor
final class BrowserPage: NSObject {
    @ObservationIgnored let webView: WKWebView
    /// Where it was opened, or nil for a new browser with nothing typed yet.
    private(set) var address: URL?
    private(set) var currentURL: URL?
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// Nothing answers at a local address, yet or any more: a server starting,
    /// or restarting. The page keeps trying until it does.
    private(set) var isWaiting = false
    /// Why the last load failed, for anything that isn't a local server coming
    /// back: a typo, no network.
    private(set) var failure: String?
    /// Bumped to put the keyboard in the address field.
    private(set) var addressFocusRequest = 0

    @ObservationIgnored var onNavigate: (URL) -> Void = { _ in }
    /// The view the web view is in, or should be: the newest place showing
    /// this page. See `WebViewHost`.
    @ObservationIgnored fileprivate weak var host: NSView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var retry: Task<Void, Never>?

    /// How often a page whose local server is down tries again.
    private static let retryInterval: Duration = .seconds(1)

    init(address: URL?) {
        self.address = address
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Inspect Element in the context menu.
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        observations = [
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url else { return }
                    self.currentURL = url
                    self.onNavigate(url)
                }
            },
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
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
        if let address {
            webView.load(URLRequest(url: address))
        } else {
            addressFocusRequest += 1
        }
    }

    /// Where the page is, or is about to be.
    var location: URL? { currentURL ?? address }

    /// What a tab is called: the page's title, or where it is until it has
    /// one, or "New Tab" before it's anywhere.
    var tabTitle: String {
        if !title.isEmpty { return title }
        return location.map(BrowserAddress.short) ?? "New Tab"
    }

    /// Go where the address field says.
    func go(to typed: String) {
        guard let url = BrowserAddress.url(from: typed) else { return }
        if address == nil { address = url }
        load(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if isWaiting || failure != nil || webView.url == nil {
            if let location { load(location) }
        } else {
            webView.reload()
        }
    }

    func stop() { webView.stopLoading() }

    func openInBrowser() {
        if let location { NSWorkspace.shared.open(location) }
    }

    func focusAddress() { addressFocusRequest += 1 }

    fileprivate func close() {
        retry?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func load(_ url: URL) {
        failure = nil
        currentURL = url
        webView.load(URLRequest(url: url))
    }

    /// Try again in a moment, until something answers.
    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled, let self, self.isWaiting, let location = self.location else { return }
            self.webView.load(URLRequest(url: location))
        }
    }
}

extension BrowserPage: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isWaiting = false
        failure = nil
        retry?.cancel()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        let error = error as NSError
        // A load cut short by the next one isn't a failure.
        guard error.code != NSURLErrorCancelled else { return }
        let unreachable: Set<Int> = [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                                     NSURLErrorTimedOut]
        if unreachable.contains(error.code), let host = location?.host(), BrowserAddress.isLocalHost(host) {
            isWaiting = true
            scheduleRetry()
        } else {
            failure = error.localizedDescription
        }
    }

    /// `target="_blank"` and `window.open`: in this tab. There's no second
    /// window to give it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.request.url != nil { webView.load(action.request) }
        return nil
    }
}

// MARK: - Views

/// Something serving on this Mac, as an address field offers it.
struct BrowserServer: Identifiable, Equatable {
    let url: URL
    /// What's serving it: `vite`, `python3 -m http.server`.
    let label: String
    /// The session it's running in, when that isn't the one you're in.
    let session: String?

    var id: URL { url }
}

/// A browser: a slim header and the page.
///
/// The address field suggests what's serving: every running server while
/// it's empty or untouched, the ones matching what you type after that. A
/// new browser, with nowhere to be yet, shows the same list as its page.
struct BrowserTab: View {
    let page: BrowserPage

    @State private var typed = ""
    /// Whether what's in the field is the user's rather than the page's.
    @State private var edited = false
    @State private var highlighted: URL?
    @FocusState private var editing: Bool

    var body: some View {
        let servers = BrowserTabs.shared.servers()
        let suggestions = matching(servers)
        VStack(spacing: 0) {
            BrowserHeader(page: page, typed: $typed, edited: $edited,
                          editing: $editing, suggestions: suggestions, highlighted: $highlighted,
                          go: go)
                // Over the page, so the suggestions hanging from its field are.
                .zIndex(1)
            Rectangle()
                .fill(Color(nsColor: Chrome.hairline))
                .frame(height: 1)
            ZStack {
                WebViewHost(page: page)
                if page.location == nil {
                    // Nowhere yet: the page is what you could open.
                    BlankPage(servers: servers, highlighted: highlighted, pick: go)
                } else if page.isWaiting, let location = page.location {
                    PageNotice(spinner: true, text: "Waiting for \(BrowserAddress.short(location))")
                } else if let failure = page.failure {
                    PageNotice(spinner: false, text: failure)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
        // Another browser in the same row is another web view to borrow.
        .id(ObjectIdentifier(page))
    }

    /// The servers the field suggests: all of them until you've typed, then
    /// the ones whose address or command has what you typed in it.
    private func matching(_ servers: [BrowserServer]) -> [BrowserServer] {
        let query = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard edited, !query.isEmpty else { return servers }
        return servers.filter {
            BrowserAddress.short($0.url).lowercased().contains(query)
                || $0.label.lowercased().contains(query)
        }
    }

    private func go(_ url: URL) {
        page.go(to: url.absoluteString)
        editing = false
    }
}

/// Back, forward, reload, the address, and the way out to your browser.
/// Laid out like a file tab's header.
private struct BrowserHeader: View {
    let page: BrowserPage
    @Binding var typed: String
    @Binding var edited: Bool
    var editing: FocusState<Bool>.Binding
    let suggestions: [BrowserServer]
    @Binding var highlighted: URL?
    let go: (URL) -> Void

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
                    .disabled(page.location == nil)
            }
            TextField("Address, or a port like 3000", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(editing.wrappedValue ? .primary : .secondary)
                .focused(editing)
                .onSubmit(submit)
                .onExitCommand {
                    typed = shown
                    editing.wrappedValue = false
                }
                // Up and down walk the suggestions; Return takes the one lit.
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: editing.wrappedValue ? Chrome.hoverFill : .clear)))
                // The suggestions hang from the field itself: its left edge,
                // its width, a few points under it. Measuring the field and
                // placing them over the page didn't survive the round trip.
                .overlay(alignment: .topLeading) {
                    if editing.wrappedValue, page.location != nil, !suggestions.isEmpty {
                        SuggestionList(servers: suggestions, highlighted: highlighted, pick: go)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(y: 28)
                    }
                }
                .padding(.leading, 4)
            button("arrow.up.forward.square", "Open in Your Browser", action: page.openInBrowser)
                .disabled(page.location == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .onAppear {
            typed = shown
            if page.location == nil { editing.wrappedValue = true }
        }
        .onChange(of: page.currentURL) { _, _ in if !editing.wrappedValue { typed = shown } }
        .onChange(of: page.addressFocusRequest) { _, _ in editing.wrappedValue = true }
        .onChange(of: editing.wrappedValue) { _, now in
            // The whole address to edit; the short one to read.
            typed = now ? (page.location?.absoluteString ?? "") : shown
            edited = false
            highlighted = nil
        }
        .onChange(of: typed) { _, _ in
            if editing.wrappedValue, typed != (page.location?.absoluteString ?? "") { edited = true }
            if let highlighted, !suggestions.contains(where: { $0.url == highlighted }) {
                self.highlighted = nil
            }
        }
    }

    private var shown: String {
        page.location.map(BrowserAddress.short) ?? ""
    }

    private func submit() {
        if let highlighted {
            go(highlighted)
        } else {
            page.go(to: typed)
            editing.wrappedValue = false
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let index = suggestions.firstIndex { $0.url == highlighted }
        let next = index.map { $0 + offset } ?? (offset > 0 ? 0 : suggestions.count - 1)
        highlighted = (0..<suggestions.count).contains(next) ? suggestions[next].url : nil
        return .handled
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

/// The servers, as rows to click: under the address field while you type, as
/// a card over the page.
private struct SuggestionList: View {
    let servers: [BrowserServer]
    let highlighted: URL?
    let pick: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(servers) { server in
                ServerRow(server: server, isHighlighted: server.url == highlighted) { pick(server.url) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: Chrome.raised))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: Chrome.hairlineStrong), lineWidth: 0.5)))
    }
}

/// A new browser's page: what's running to open, or how to get somewhere,
/// in the middle of the page as an empty state is.
private struct BlankPage: View {
    let servers: [BrowserServer]
    let highlighted: URL?
    let pick: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if servers.isEmpty {
                Text("Nothing is serving yet. Type an address, or just a port like 3000.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Running")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                VStack(spacing: 0) {
                    ForEach(servers) { server in
                        ServerRow(server: server, isHighlighted: server.url == highlighted) {
                            pick(server.url)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 24)
        // A little above the middle, where the eye puts "the middle".
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
    }
}

private struct ServerRow: View {
    let server: BrowserServer
    let isHighlighted: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(BrowserAddress.short(server.url))
                    .font(.system(size: 13))
                    .fixedSize()
                Text(server.session.map { "\(server.label) · \($0)" } ?? server.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: isHighlighted ? Chrome.selectedFill
                                     : hovering ? Chrome.hoverFill : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What a page shows when there's no page to show.
private struct PageNotice: View {
    let spinner: Bool
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
    }
}

/// Borrows a page's web view while the tab is on screen here.
///
/// A moving tab has two of these for a moment, the new place's and the old
/// one's, and SwiftUI updates and tears them down in no particular order:
/// the old one, refreshed after the new one took the view, used to take it
/// back and then leave with it, and the tab came up blank. So the page names
/// its host, the newest one made, and only that host attaches or removes it.
private struct WebViewHost: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        page.host = container
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // A host whose place was taken over stays out of it, unless the one
        // that took over is gone. (Not "out of the window": a host just made
        // isn't in one yet, and that's exactly when the old one refreshes.)
        if page.host == nil { page.host = container }
        if page.host === container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let webView = page.webView
        guard webView.superview !== container else { return }
        webView.frame = container.bounds
        container.addSubview(webView)
    }
}
