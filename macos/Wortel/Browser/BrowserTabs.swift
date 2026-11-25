import AppKit
import Observation
import SwiftUI
import WebKit

/// Browsers in tabs: the dev server beside the agent editing it, docs beside
/// the terminal. A browser is a tab like any other: "+" or ⇧⌘B opens one, it
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

    /// Not observed: a page is made while a tab's view is being built, and
    /// writing an observed property there invalidates that same view.
    /// `revision` says a page appeared, a turn later.
    @ObservationIgnored private var pages: [UUID: BrowserPage] = [:]
    private var revision = 0

    /// Where a browser tab is, from its session.
    @ObservationIgnored var address: (UUID) -> URL? = { _ in nil }
    /// A browser tab went somewhere: record it on its session.
    @ObservationIgnored var onNavigate: (UUID, URL) -> Void = { _, _ in }
    /// What's serving on this Mac, the selected session's first: what an
    /// address field offers.
    @ObservationIgnored var servers: () -> [BrowserServer] = { [] }
    /// The file previews: what a tab on a file borrows to show the file's
    /// source in place of the page (Page · Source).
    @ObservationIgnored var previews: PreviewTabs?

    /// The page for a tab, loaded the first time it's asked for.
    func page(for id: UUID) -> BrowserPage {
        if let page = pages[id] { return page }
        let page = BrowserPage(address: address(id))
        page.onNavigate = { [weak self] url in self?.onNavigate(id, url) }
        pages[id] = page
        // So a tab row that read no page for this tab reads it now.
        DispatchQueue.main.async { [weak self] in self?.revision += 1 }
        return page
    }

    /// The page for a tab if it has one yet: what its tab is titled by.
    func existingPage(for id: UUID) -> BrowserPage? {
        _ = revision
        return pages[id]
    }

    /// The page whose web view `responder` is, or is inside: the browser that
    /// has the keyboard.
    func page(holding responder: NSResponder?) -> BrowserPage? {
        var view = responder as? NSView
        while let current = view {
            if let webView = current as? WKWebView {
                return pages.values.first { $0.webView === webView }
            }
            // The mark-up note lies over its page, beside the web view and
            // not inside it: with the keyboard there, ⌘+ is still the page's.
            if let container = current as? WebViewContainer,
               let webView = container.subviews.lazy.compactMap({ $0 as? WKWebView }).first {
                return pages.values.first { $0.webView === webView }
            }
            view = current.superview
        }
        return nil
    }

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

    /// ⌘F over this page.
    @ObservationIgnored let find = BrowserFind()

    /// Mark-up over this page (`Wortel/Markup/`): made the first time its
    /// header is drawn, a flag and empty lists until it is turned on.
    @ObservationIgnored private(set) lazy var markup: MarkupSession = {
        let session = MarkupSession()
        session.surface = WebMarkupSurface(webView: webView)
        session.place = .page
        session.subject = { [weak self] in
            guard let location = self?.location else { return .page("") }
            return .page(location.isFileURL ? location.path : location.absoluteString)
        }
        session.onChange = { [weak self] in self?.markupChanged() }
        hasMarkup = true
        return session
    }()
    @ObservationIgnored private var hasMarkup = false

    /// Whether there is a page here to mark up: somewhere, loaded, and not
    /// behind its own source.
    var canMarkUp: Bool {
        location != nil && !isWaiting && failure == nil && !showsSource
    }

    /// Mark-up went on or off. While it is on, a sideways scroll must not
    /// become a step back in history (scrolling passes through the marks to
    /// the page), and the page takes no pointer of its own.
    private func markupChanged() {
        let on = markup.isOn
        webView.allowsBackForwardNavigationGestures = !on
        (webView as? BrowserWebView)?.isMarkingUp = on
        guard !on else { return }
        // The keyboard back to the page, if the note had it.
        if let window = webView.window, BrowserTabs.shared.page(holding: window.firstResponder) === self {
            focusPage()
        }
        // And the reload that waited for the note (`fileChanged`).
        screenMayHaveChanged()
    }

    /// The page went elsewhere, or is gone: its marks would point at
    /// nothing, so they go, and the note with them.
    private func endMarkup() {
        guard hasMarkup else { return }
        (markup.surface as? WebMarkupSurface)?.pageLeft()
        markup.end()
    }

    /// A file's source, shown in place of its page.
    struct Source {
        let file: URL
        let document: PreviewDocument
        let find: PreviewFind
    }

    /// The source of the file this tab is on, from the first time it was
    /// asked for until the tab goes somewhere else. Kept while the page is
    /// showing, so the way back to the source is where you left it.
    private(set) var source: Source?
    /// The header's Page · Source is on Source: the file's text covers the
    /// page. The page is not unloaded or hidden, only covered, so it keeps
    /// its scroll, its state and its reloads, and the way back is one cut.
    private(set) var showsSource = false
    /// Loads the page again when its file changes on disk.
    @ObservationIgnored private let watch = BrowserPageWatch()

    @ObservationIgnored var onNavigate: (URL) -> Void = { _ in }
    /// The view the web view is in, or should be: the newest place showing
    /// this page. See `WebViewHost`.
    @ObservationIgnored fileprivate weak var host: NSView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// The page as it last looked, for its tab's hover card: a page that
    /// isn't in front isn't drawn, so it's taken while it is.
    @ObservationIgnored private var snapshot: NSImage?
    /// When the page's process last died, for the crash-reload cap.
    @ObservationIgnored private var crashes: [Date] = []
    @ObservationIgnored private var reloadWhenShown = false
    @ObservationIgnored private var snapshotTimer: Timer?

    /// What Safari adds to WebKit's user agent, which a bare web view leaves
    /// out. Without it Google won't sign you in ("this browser or app may not
    /// be secure") and some sites call the browser unsupported. The version is
    /// the Safari on this Mac, the engine the page is actually getting.
    private static let safariUserAgent: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "26.0") Safari/605.1.15"
    }()

    /// How often a page whose local server is down tries again.
    private static let retryInterval: Duration = .seconds(1)

    init(address: URL?) {
        self.address = address
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = Self.safariUserAgent
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        find.webView = webView
        watch.onChange = { [weak self] in self?.fileChanged() }
        // Inspect Element in the context menu.
        webView.isInspectable = true
        // What `toggleInspector` needs: without it the inspector never
        // connects, and the private call it makes silently does nothing.
        let preferences = configuration.preferences
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        observations = [
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url else { return }
                    // A new address, a route change in a single-page app.
                    if url != self.currentURL { self.endMarkup() }
                    self.currentURL = url
                    self.leaveSourceIfElsewhere()
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
        // A file by its name, as its file tab would be called.
        if let location, location.isFileURL { return location.lastPathComponent }
        return location.map(BrowserAddress.short) ?? "New Tab"
    }

    /// The file this tab shows as a page, when it is on one: what Page ·
    /// Source switches over.
    var pageFile: URL? {
        guard let location, BrowserAddress.isPage(location) else { return nil }
        return location
    }

    /// Page · Source. The source is the file's own text in the view a file
    /// tab uses (`PreviewContent`), with a document of this tab's own.
    func showSource(_ on: Bool) {
        guard on != showsSource else { return }
        // Another view of the file: the marks were on this one.
        endMarkup()
        guard on else {
            showsSource = false
            source?.find.dismiss()
            // The keyboard back to the page, if it was taken off it below and
            // nothing has it since.
            if let window = webView.window, window.firstResponder === window { focusPage() }
            return
        }
        guard let file = pageFile, let previews = BrowserTabs.shared.previews else { return }
        if source?.file.path != file.path {
            source = Source(file: file, document: previews.sourceDocument(for: file), find: PreviewFind())
        }
        // Typing must not go on into a page nobody can see.
        if BrowserTabs.shared.page(holding: webView.window?.firstResponder) === self {
            webView.window?.makeFirstResponder(nil)
        }
        showsSource = true
    }

    /// The source, while it is what the tab shows: what ⌘F searches then.
    var shownSource: Source? { showsSource ? source : nil }

    /// The tab went somewhere else: the source it was showing is another
    /// file's, or no file's.
    private func leaveSourceIfElsewhere() {
        guard let source, pageFile?.path != source.file.path else { return }
        showsSource = false
        self.source = nil
    }

    /// The file the page is from, or one it loaded, changed on disk.
    private func fileChanged() {
        // Not on screen: when it is shown, as a page that crashed there.
        // Being marked up: when that is over. A reload drops the marks and
        // the note, and this one would do it mid-sentence, for an edit the
        // agent made and nobody at the page asked for.
        guard webView.window != nil, !webView.isHiddenOrHasHiddenAncestor,
              !(hasMarkup && markup.isOn) else {
            reloadWhenShown = true
            return
        }
        // Past the cache: a stylesheet has no server to say it changed.
        reloadFromOrigin()
    }

    /// Every address the page's own markup loads from. Run apart from the
    /// page's scripts (`.defaultClient`), so a page can't redefine what it
    /// answers with.
    private static let loadedAddresses = """
        Array.from(document.querySelectorAll(
            'link[href],script[src],img[src],source[src],video[src],audio[src],iframe[src]'
        )).map(function (e) { return e.href || e.src || '' })
        """

    /// Watch the file this tab is on, and the local files it loaded, so a
    /// change on disk reloads it. Asked after each load: the list is the
    /// page's as it is now. Any `file:` address is watched, a page or not.
    private func followFile() {
        guard let file = location, file.isFileURL else { return watch.stop() }
        webView.evaluateJavaScript(Self.loadedAddresses, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.location?.path == file.path else { return }
                let addresses = (try? result.get()) as? [String] ?? []
                self.watch.watch(page: file.path, resources: BrowserAddress.localFiles(in: addresses))
            }
        }
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

    /// Reload past the cache. ⇧⌘R.
    func reloadFromOrigin() {
        if isWaiting || failure != nil || webView.url == nil {
            reload()
        } else {
            webView.reloadFromOrigin()
        }
    }

    /// One step in (1) or out (-1), or back to actual size (0). ⌘+ / ⌘- / ⌘0.
    func zoom(by step: Int) {
        guard step != 0 else { webView.pageZoom = 1; return }
        let zoomed = webView.pageZoom * (step > 0 ? 1.1 : 1 / 1.1)
        webView.pageZoom = min(max(zoomed, 0.5), 3)
    }

    func stop() { webView.stopLoading() }

    func openInBrowser() {
        if let location { NSWorkspace.shared.open(location) }
    }

    func focusAddress() { addressFocusRequest += 1 }

    /// Web Inspector, docked under the page, and away again: ⌥⌘I, as in
    /// Safari. WebKit has no public call for it, only the context menu's
    /// Inspect Element (`isInspectable`), so this is its private `_inspector`.
    /// If a macOS release takes that away the shortcut does nothing, and
    /// Inspect Element is still there.
    func toggleInspector() {
        guard let inspector else { return }
        let action = NSSelectorFromString(isInspectorVisible ? "hide" : "show")
        if inspector.responds(to: action) { inspector.perform(action) }
    }

    var isInspectorVisible: Bool {
        guard let inspector, inspector.responds(to: NSSelectorFromString("isVisible")) else { return false }
        return inspector.value(forKey: "isVisible") as? Bool ?? false
    }

    /// The inspector docks into the view the page is in, so it's put away
    /// before the page moves to another one, rather than left behind.
    fileprivate func hideInspector() {
        guard isInspectorVisible, let inspector else { return }
        inspector.perform(NSSelectorFromString("hide"))
    }

    private var inspector: NSObject? {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter) else { return nil }
        return webView.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    /// The keyboard to the page itself. ⌘] onto a browser.
    func focusPage() {
        webView.window?.makeFirstResponder(webView)
    }

    /// The page as it last looked, refreshed if it's on screen now.
    func previewSnapshot() -> NSImage? {
        captureSnapshot()
        return snapshot
    }

    /// Take a picture of the page, if it's on screen to take one of.
    fileprivate func captureSnapshot() {
        guard webView.window != nil, !webView.isHiddenOrHasHiddenAncestor,
              webView.bounds.width > 1, location != nil, !isWaiting, failure == nil else { return }
        let configuration = WKSnapshotConfiguration()
        // Points: as wide as the card shows it, at the screen's own scale.
        configuration.snapshotWidth = 300
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
            }
        }
    }

    fileprivate func screenMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let visible = self.webView.window != nil && !self.webView.isHiddenOrHasHiddenAncestor
            if visible, self.reloadWhenShown, !(self.hasMarkup && self.markup.isOn) {
                self.reloadWhenShown = false
                // Past the cache: it may be owed for a file that changed.
                self.reloadFromOrigin()
            }
            self.onScreenChanged(visible)
        }
    }

    /// While the page is on screen, keep its picture recent: a page changes
    /// without navigating (a dev server's hot reload), and the moment it
    /// leaves the screen is too late to take one.
    private func onScreenChanged(_ visible: Bool) {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        guard visible else { return }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureSnapshot() }
        }
    }

    fileprivate func close() {
        endMarkup()
        retry?.cancel()
        watch.stop()
        snapshotTimer?.invalidate()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func load(_ url: URL) {
        failure = nil
        // Somewhere new: whatever it was waiting for is not what it wants now.
        isWaiting = false
        retry?.cancel()
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
    /// The page is another one from here on, or the same one loaded anew.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        endMarkup()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isWaiting = false
        failure = nil
        retry?.cancel()
        followFile()
        // Once it's had a moment to paint.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.captureSnapshot()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        let error = error as NSError
        // A load cut short by the next one isn't a failure, and neither is one
        // the policy below took elsewhere (WebKit's "frame load interrupted").
        guard error.code != NSURLErrorCancelled,
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        let unreachable: Set<Int> = [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                                     NSURLErrorTimedOut]
        if unreachable.contains(error.code), let host = location?.host(), BrowserAddress.isLocalHost(host) {
            isWaiting = true
            scheduleRetry()
        } else {
            isWaiting = false
            failure = error.localizedDescription
            // A file that isn't there (a restored tab, a branch switched
            // away): watched all the same, so it loads when it is back.
            if let location, location.isFileURL {
                watch.watch(page: location.path, resources: [])
            } else {
                watch.stop()
            }
        }
    }

    /// What isn't a page is another app's link (`mailto:`, `vscode://`). From the
    /// page itself it asks first, clicked or not, since a script can click a link
    /// as well as a person can; from a frame inside the page it goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        // Where it came from, not only where it goes: a link in an embedded
        // frame can target the page itself. Read as optional on purpose: a
        // navigation the app started (`load`) can arrive with no source frame
        // despite the type saying otherwise, and counts as the page's own.
        let source: WKFrameInfo? = action.sourceFrame
        let fromMainFrame = source?.isMainFrame ?? true
        // A new-window navigation has no target frame; it belongs to its source.
        let toMainFrame = action.targetFrame?.isMainFrame ?? true
        switch BrowserExternalLink.decide(scheme: url?.scheme,
                                          fromMainFrame: fromMainFrame, toMainFrame: toMainFrame) {
        case .load:
            guard action.shouldPerformDownload else { return decisionHandler(.allow) }
            // A link that says it is for saving (`<a download>`): saved from
            // the page and from its own frames, and from a frame on another
            // site it goes nowhere (`BrowserDownloadName.savesLink`).
            // Cancelled there, not loaded instead: aimed at the page itself
            // it would be saved after all, by the rule for the page's own
            // responses.
            let saves = BrowserDownloadName.savesLink(fromMainFrame: fromMainFrame,
                                                      frameHost: source?.securityOrigin.host,
                                                      pageHost: webView.url?.host())
            decisionHandler(saves ? .download : .cancel)
        case .ask:
            decisionHandler(.cancel)
            if let url { askToOpen(url, over: webView.window) }
        case .refuse:
            decisionHandler(.cancel)
        }
    }

    /// A page that wants another app says which, and waits for a yes.
    private func askToOpen(_ url: URL, over window: NSWindow?) {
        guard let window, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let name = FileManager.default.displayName(atPath: app.path)
        let alert = NSAlert()
        alert.messageText = "Open \u{201c}\(name)\u{201d}?"
        alert.informativeText = "This page wants to open a link in \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// A response the tab can't show, or that its server marked as an
    /// attachment, is saved to Downloads (`BrowserDownloads`). Nothing is
    /// opened, here or there.
    ///
    /// Until 2026-11-25 it went to the default browser, where the sign-in
    /// that got you the file doesn't exist. A `file:` the tab can't show is
    /// not a download (it is on this Mac already): it is shown in the
    /// Finder, never handed to NSWorkspace to open, since a local page
    /// linking to `file:///…/run.command` would have it run in Terminal,
    /// unasked. A link to another app (`mailto:`) never gets here: it is
    /// asked about before it loads (`BrowserExternalLink`).
    ///
    /// From a frame inside the page, only an attachment from the page's own
    /// host is saved (`BrowserDownloadName.saves`): a frame from another site
    /// can't put a file in Downloads. A frame's response the tab merely
    /// can't show is left alone, as it was.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        let saves = BrowserDownloadName.saves(
            isForMainFrame: response.isForMainFrame, canShow: response.canShowMIMEType,
            isAttachment: BrowserDownloadName.isAttachment(contentDisposition: disposition),
            host: response.response.url?.host(), pageHost: webView.url?.host())
        guard saves else { return decisionHandler(.allow) }
        switch response.response.url?.scheme?.lowercased() {
        case "http", "https", "blob", "data":
            decisionHandler(.download)
        case "file":
            if let url = response.response.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        BrowserDownloads.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        BrowserDownloads.shared.adopt(download)
    }

    /// The page's process died (a crash, or memory pressure): start again
    /// rather than leave a blank tab.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        endMarkup()
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        // Killed off screen under memory pressure: reloading now would undo
        // the reason. Crashing over and over: stop and say so.
        guard crashes.count <= 3 else {
            failure = "This page keeps crashing. Reload to try again."
            return
        }
        if webView.window != nil { reload() } else { reloadWhenShown = true }
    }

    /// A `target="_blank"` link: in this tab, as there's no second tab to
    /// give it. An empty one is ignored rather than blanking the page.
    ///
    /// A page's own `window.open` gets a window (`BrowserPopup`). What a page
    /// opens itself is usually a sign-in ("Sign in with Google") that reports
    /// back through `window.opener` and closes, and loaded in this tab it had
    /// no opener to report to: the sign-in went nowhere.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.navigationType != .linkActivated else {
            if let url = action.request.url, url.absoluteString != "about:blank" { webView.load(action.request) }
            return nil
        }
        return BrowserPopup.open(configuration: configuration, features: windowFeatures, over: webView.window)
    }

    // The page's own dialogs, as sheets on the window: the app being tested
    // has "Delete this?" confirmations and file inputs too.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = Self.alert(message, from: frame)
        alert.addButton(withTitle: "OK")
        present(alert, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = Self.alert(message, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = Self.alert(prompt, from: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private static func alert(_ text: String, from frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = text
        return alert
    }

    private func present(_ alert: NSAlert, in webView: WKWebView,
                         completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // Not on screen: the default answer, rather than an app-modal dialog
        // that would stop every terminal for a page nobody can see.
        guard let window = webView.window else { return completion(.alertSecondButtonReturn) }
        alert.beginSheetModal(for: window, completionHandler: completion)
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

    /// What's in the field: the page's address, what you typed, or that plus
    /// a completion.
    @State private var typed = ""
    /// What you typed, which is what the suggestions are filtered by. nil
    /// until you type, when every server is suggested.
    @State private var query: String?
    @State private var highlighted: URL?
    @FocusState private var editing: Bool
    @FocusState private var finding: Bool

    var body: some View {
        let servers = BrowserTabs.shared.servers()
        let suggestions = matching(servers)
        VStack(spacing: 0) {
            BrowserHeader(page: page, typed: $typed, query: $query,
                          editing: $editing, suggestions: suggestions, highlighted: $highlighted,
                          go: go)
                // Over the page, so the suggestions hanging from its field are.
                .zIndex(1)
            Rectangle()
                .fill(Color(nsColor: Chrome.hairline))
                .frame(height: 1)
            if page.find.isPresented, !page.showsSource {
                @Bindable var find = page.find
                FindBar(query: $find.query, summary: find.summary, canStep: find.canStep,
                        focused: $finding, next: find.next, previous: find.previous,
                        dismiss: find.dismiss)
                    // Made with the keyboard asked for (⌘F), or without (⌘G
                    // bringing the bar back).
                    .onAppear { if find.focusRequest != focusedFor { focusFind() } }
            }
            ZStack {
                WebViewHost(page: page, isMarkingUp: page.markup.isOn && page.canMarkUp)
                    // Whether it's on screen, once the move settles: a tab moving
                    // rows appears in one place and disappears from the other
                    // in no set order.
                    .onAppear { page.screenMayHaveChanged() }
                    .onDisappear { page.screenMayHaveChanged() }
                if page.location == nil {
                    // Nowhere yet: the page is what you could open.
                    // What the field filters, so the arrows walk what's shown.
                    BlankPage(servers: suggestions, highlighted: highlighted, pick: go)
                } else if page.isWaiting, let location = page.location {
                    PageNotice(spinner: true, text: "Waiting for \(BrowserAddress.short(location))")
                } else if let failure = page.failure {
                    PageNotice(spinner: false, text: failure)
                }
                // The file's source, over its page. The page stays under it,
                // loaded and laid out, so Page is one cut back.
                if page.showsSource, let source = page.source, let previews = BrowserTabs.shared.previews {
                    // Back where it was left, as a file tab is (`PreviewTab`).
                    let _ = source.document.anchorLine = source.document.visibleLine
                    let _ = source.document.anchorOffset = source.document.visibleOffset
                    PreviewContent(document: source.document, find: source.find,
                                   settings: previews.settings, onOpenFile: previews.onOpenFile)
                        .background(Color(nsColor: Chrome.content))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Chrome.content))
        .onAppear { focusedFor = page.find.focusRequest }
        .onChange(of: page.find.focusRequest) { _, _ in focusFind() }
        // Another browser in the same row is another web view to borrow.
        .id(ObjectIdentifier(page))
    }

    /// The find request the keyboard was last moved for, so a bar that comes
    /// back for ⌘G (no request) leaves the keyboard in the page.
    @State private var focusedFor = 0

    /// The keyboard into the find field, its text selected so typing
    /// replaces it, as ⌘F does in every browser.
    private func focusFind() {
        focusedFor = page.find.focusRequest
        finding = true
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }

    /// The servers the field suggests: all of them until you've typed, then
    /// the ones whose address or command has what you typed in it.
    private func matching(_ servers: [BrowserServer]) -> [BrowserServer] {
        let query = (query ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return servers }
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
    @Binding var query: String?
    var editing: FocusState<Bool>.Binding
    let suggestions: [BrowserServer]
    @Binding var highlighted: URL?
    let go: (URL) -> Void

    /// Set while the field's text is being set here rather than typed (a
    /// completion, an arrowed-to suggestion), so the change isn't read as
    /// typing.
    @State private var settingText = false

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
                .onExitCommand(perform: escape)
                // Up and down walk the suggestions, putting each in the field;
                // Return takes the one lit.
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
                .padding(.horizontal, 8)
                // Room for a port or a file's name before the pill beside
                // it gives way (`sourceToggle`).
                .frame(minWidth: 72)
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
            // Only on a file that is a page: the file as the page it makes,
            // or as its text. The pill a file tab has for Diff · Source.
            if page.pageFile != nil {
                // The pill while the address keeps some room beside it, one
                // button when the column is narrow: squeezed, the pill cut
                // "Source" short and then lost both words (seen in a render
                // at 384pt and at 260pt, the column's least).
                ViewThatFits(in: .horizontal) {
                    ModeSwitch(modes: [false, true],
                               selection: Binding(get: { page.showsSource }, set: { page.showSource($0) }),
                               title: { $0 ? "Source" : "Page" })
                        .fixedSize()
                        .padding(.horizontal, 4)
                    sourceToggle
                }
                .layoutPriority(1)
            }
            // There from the first download on, in every browser tab: the
            // list is the app's, as Safari's is.
            if !BrowserDownloads.shared.items.isEmpty {
                DownloadsButton(downloads: .shared)
            }
            button("arrow.up.forward.square", "Open in Your Browser", action: page.openInBrowser)
                .disabled(page.location == nil)
            // Last at the right in every preview's bar. Absent with no page
            // to mark up: nowhere yet, still waiting, failed, or its source.
            if page.canMarkUp {
                MarkupButton(session: page.markup)
            }
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
            // The whole address to edit, all of it selected so typing replaces
            // it, as a browser's field does; the short one to read.
            setText(now ? (page.location?.absoluteString ?? "") : shown)
            query = nil
            highlighted = nil
            if now { selectInField(from: 0) }
        }
        .onChange(of: typed) { old, new in
            if settingText {
                settingText = false
                return
            }
            guard editing.wrappedValue else { return }
            query = new
            highlighted = nil
            // Only while typing forward: deleting (a completion included)
            // must not have the completion put straight back.
            guard new.count > old.count, new.hasPrefix(old) || old.isEmpty else { return }
            let urls = suggestions.map(\.url)
            if let completion = BrowserAddress.completion(of: new, among: urls) {
                setText(completion.text)
                highlighted = completion.url
                selectInField(from: new.count)
            }
        }
    }

    private var shown: String {
        page.location.map(BrowserAddress.short) ?? ""
    }

    /// Page · Source as one button, lit while the source shows.
    private var sourceToggle: some View {
        Button { page.showSource(!page.showsSource) } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: page.showsSource ? Chrome.selectedFill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
        .foregroundStyle(.secondary)
        .help(page.showsSource ? "Show Page" : "Show Page Source")
        .accessibilityLabel(page.showsSource ? "Show Page" : "Show Page Source")
    }

    /// Change the field's text without it counting as typing.
    private func setText(_ text: String) {
        guard text != typed else { return }
        settingText = true
        typed = text
    }

    /// Select the field's text from `start` to the end: all of it on focus,
    /// the filled-in part of a completion.
    private func selectInField(from start: Int) {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let length = (editor.string as NSString).length
            let from = min(start, length)
            editor.setSelectedRange(NSRange(location: from, length: length - from))
        }
    }

    private func submit() {
        if let highlighted {
            go(highlighted)
        } else {
            page.go(to: typed)
            editing.wrappedValue = false
        }
    }

    /// Escape: back to what you typed if the field shows a suggestion; out
    /// of the field if it already shows what you typed.
    private func escape() {
        if let query, typed != query {
            setText(query)
            highlighted = nil
        } else {
            setText(shown)
            editing.wrappedValue = false
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let index = suggestions.firstIndex { $0.url == highlighted }
        let next = index.map { $0 + offset } ?? (offset > 0 ? 0 : suggestions.count - 1)
        if (0..<suggestions.count).contains(next) {
            let url = suggestions[next].url
            highlighted = url
            setText(BrowserAddress.short(url))
            selectInField(from: (BrowserAddress.short(url) as NSString).length)
        } else {
            // Past either end: back to what you typed.
            highlighted = nil
            setText(query ?? typed)
        }
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

/// The servers, as rows to click: the card hanging from the address field.
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
    /// Mark-up is on over this page: the layer with the marks and the note
    /// lies over the web view. A stored value, read where the view is
    /// built, so turning it on or off is what updates this host.
    var isMarkingUp = false

    func makeNSView(context: Context) -> NSView {
        let container = WebViewContainer()
        page.host = container
        attach(to: container)
        container.setMarkup(isMarkingUp ? page.markup : nil)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // A host whose place was taken over stays out of it, unless the one
        // that took over is gone. (Not "out of the window": a host just made
        // isn't in one yet, and that's exactly when the old one refreshes.)
        if page.host == nil { page.host = container }
        if page.host === container {
            attach(to: container)
            (container as? WebViewContainer)?.setMarkup(isMarkingUp ? page.markup : nil)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // The inspector docked in here goes too. A move usually hides it in
        // `attach`, but only if the new place attaches before this one goes.
        for case let webView as WKWebView in container.subviews {
            BrowserTabs.shared.page(holding: webView)?.hideInspector()
        }
        (container as? WebViewContainer)?.setMarkup(nil, animated: false)
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let webView = page.webView
        guard webView.superview !== container else { return }
        if webView.superview != nil { page.hideInspector() }
        webView.frame = container.bounds
        container.addSubview(webView)
    }
}

/// A page's web view, with a few of the app's shortcuts kept from the page.
///
/// A page gets every ⌘ key first, and the menu only what it lets go of: the
/// order Safari and Chrome use, and what lets a web app have its ⌘K. Like
/// Chrome, a short list skips the page, so no page can keep you in it: quit,
/// close, a new session, and moving between tabs and between sessions.
private final class BrowserWebView: WKWebView {
    /// Mark-up is on over this page. The layer over it takes the clicks,
    /// but a web view hears the pointer move through a tracking area, which
    /// a view on top does not stop: without this the page would go on
    /// lighting what the pointer passes and setting its own cursor.
    var isMarkingUp = false {
        didSet { if isMarkingUp, !oldValue { window?.invalidateCursorRects(for: self) } }
    }

    override func mouseMoved(with event: NSEvent) {
        if !isMarkingUp { super.mouseMoved(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if !isMarkingUp { super.mouseEntered(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !isMarkingUp { super.cursorUpdate(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, Self.isReserved(event),
           let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A file dragged out of one of Wortel's own lists is for the tab rows
    /// (TabDragController.handleFileDrag), to open beside the page: WebKit
    /// would take it and navigate to it as file://. Files from the Finder still
    /// reach the page.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is RowClickCatcher.CatcherView ? [] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is RowClickCatcher.CatcherView ? [] : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingSource is RowClickCatcher.CatcherView ? false : super.performDragOperation(sender)
    }

    private static let arrowUp = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
    private static let arrowDown = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)

    /// The keys, as the menu has them: ⇧⌘[ / ⇧⌘] for tabs ("{" and "}"
    /// because ⇧⌘[ arrives as either shape, see MainMenu's hidden twins),
    /// ⌥⌘↑ / ⌥⌘↓ for sessions, ⇧⌥⌘↓ and ⌥⌘] for the next waiting one.
    private static let reserved: [(NSEvent.ModifierFlags, Set<String>)] = [
        ([.command], ["q", "w", "n"]),
        ([.command, .shift], ["w", "[", "]", "{", "}"]),
        ([.command, .option], ["]", arrowUp, arrowDown]),
        ([.command, .option, .shift], [arrowDown]),
    ]

    private static func isReserved(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return reserved.contains { $0.0 == modifiers && $0.1.contains(key) }
    }
}

/// Where a web view sits: the next stop for a key its page didn't want.
///
/// WebKit hands a key the page passed on back to AppKit. A ⌘ key has had
/// the menu by then; anything else climbs the responder chain to the window,
/// which beeps. A canvas that pans on a held space claims the first press
/// and lets the repeats go, so holding space beeped. A browser doesn't beep
/// at a key a page ignored, so this ends the climb here.
final class WebViewContainer: NSView {
    override func keyDown(with event: NSEvent) {}

    /// The mark-up layer over the web view, while mark-up is on here.
    ///
    /// A view of this container beside the web view, not a SwiftUI overlay
    /// on the tab: the Web Inspector docks into this container and resizes
    /// the web view, and the layer follows the web view's frame, so it
    /// covers the page and never the inspector.
    private var markup: MarkupOverlayView?

    func setMarkup(_ session: MarkupSession?, animated: Bool = true) {
        guard let session, let surface = session.surface,
              let webView = subviews.first(where: { $0 is WKWebView }) else {
            guard let overlay = markup else { return }
            markup = nil
            if animated { overlay.leave() } else { overlay.removeFromSuperview() }
            return
        }
        if let markup, markup.session === session, markup.superview === self { return }
        markup?.removeFromSuperview()
        let overlay = MarkupOverlayView(session: session, surface: surface)
        overlay.follow(webView)
        addSubview(overlay, positioned: .above, relativeTo: webView)
        markup = overlay
    }
}
