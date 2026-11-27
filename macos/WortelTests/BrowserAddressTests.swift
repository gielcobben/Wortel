import XCTest

/// What a typed address means. Getting one wrong doesn't fail loudly: `3000`
/// searches for nothing, `localhost:5173` asks for https and never answers.
final class BrowserAddressTests: XCTestCase {
    private func url(_ typed: String) -> String? {
        BrowserAddress.url(from: typed)?.absoluteString
    }

    func testAPortAloneIsALocalServer() {
        XCTAssertEqual(url("3000"), "http://localhost:3000")
        XCTAssertEqual(url(":5173"), "http://localhost:5173")
    }

    /// `localhost:5173` would otherwise parse as scheme "localhost".
    func testLocalNamesAreHttp() {
        XCTAssertEqual(url("localhost:5173"), "http://localhost:5173")
        XCTAssertEqual(url("localhost:5173/docs?x=1"), "http://localhost:5173/docs?x=1")
        XCTAssertEqual(url("127.0.0.1:8080"), "http://127.0.0.1:8080")
        XCTAssertEqual(url("app.localhost"), "http://app.localhost")
    }

    func testEverythingElseIsHttps() {
        XCTAssertEqual(url("wortel.sh"), "https://wortel.sh")
        XCTAssertEqual(url("wortel.sh/updates"), "https://wortel.sh/updates")
    }

    func testASchemeIsKeptAsTyped() {
        XCTAssertEqual(url("http://example.com"), "http://example.com")
        XCTAssertEqual(url("  https://localhost:3000  "), "https://localhost:3000")
    }

    /// `vite --host` serves on the network: private addresses are http too.
    func testPrivateNetworkAddressesAreHttp() {
        XCTAssertEqual(url("192.168.1.5:5173"), "http://192.168.1.5:5173")
        XCTAssertEqual(url("10.0.0.2:3000"), "http://10.0.0.2:3000")
        XCTAssertEqual(url("172.20.1.1"), "http://172.20.1.1")
        XCTAssertEqual(url("172.32.1.1"), "https://172.32.1.1", "outside 172.16/12")
        XCTAssertEqual(url("8.8.8.8"), "https://8.8.8.8")
    }

    func testIPv6LoopbackIsLocal() {
        XCTAssertEqual(url("[::1]:3000"), "http://[::1]:3000")
        XCTAssertEqual(url("::1"), "http://[::1]")
        XCTAssertEqual(BrowserAddress.short(URL(string: "http://[::1]:3000/")!), "[::1]:3000")
    }

    func testOnlyRealPortsAndWebSchemes() {
        XCTAssertNil(url("65536"))
        XCTAssertNil(url("0"))
        XCTAssertNil(url("javascript:alert(1)"))
        XCTAssertNil(url("data:text/html,<p>x"))
    }

    /// Inline completion: the typed part kept as typed, the rest filled in
    /// from the first address that starts with it, in the form it was typed.
    func testCompletionFillsInTheRest() {
        let servers = [URL(string: "http://localhost:4321/")!, URL(string: "http://localhost:3000/")!]
        XCTAssertEqual(BrowserAddress.completion(of: "loc", among: servers)?.text, "localhost:4321")
        XCTAssertEqual(BrowserAddress.completion(of: "Loc", among: servers)?.text, "Localhost:4321",
                       "what was typed stays as typed")
        XCTAssertEqual(BrowserAddress.completion(of: "30", among: servers)?.text, "3000")
        XCTAssertEqual(BrowserAddress.completion(of: "30", among: servers)?.url, servers[1])
        XCTAssertEqual(BrowserAddress.completion(of: "http://localhost:3", among: servers)?.text,
                       "http://localhost:3000/")
        XCTAssertNil(BrowserAddress.completion(of: "wortel", among: servers))
        XCTAssertNil(BrowserAddress.completion(of: "localhost:4321", among: servers), "nothing left to fill in")
        XCTAssertNil(BrowserAddress.completion(of: "", among: servers))
    }

    func testNothingOrWordsGoNowhere() {
        XCTAssertNil(url(""))
        XCTAssertNil(url("   "))
        XCTAssertNil(url("two words"))
    }

    func testTheShortFormDropsTheScheme() {
        XCTAssertEqual(BrowserAddress.short(URL(string: "http://localhost:5173/")!), "localhost:5173")
        XCTAssertEqual(BrowserAddress.short(URL(string: "http://localhost:5173/docs")!), "localhost:5173/docs")
        XCTAssertEqual(BrowserAddress.short(URL(string: "https://wortel.sh")!), "wortel.sh")
    }

    // MARK: - Files

    /// A file is shown by its name and its folder, not as a `file:` address:
    /// the start of a path is the part every file shares.
    func testAFileIsShownByItsNameAndFolder() {
        XCTAssertEqual(BrowserAddress.short(URL(fileURLWithPath: "/Users/someone/proj/report.html")), "proj/report.html")
        XCTAssertEqual(BrowserAddress.short(URL(fileURLWithPath: "/tmp/a b.html")), "tmp/a b.html")
        XCTAssertEqual(BrowserAddress.short(URL(fileURLWithPath: "/index.html")), "index.html")
    }

    /// What the field shows for a file can be typed back, and so can a path.
    /// (Until 2026-11-25 a `file:` address was refused with the other
    /// non-web schemes; a tab shows files as pages now, and the field is
    /// only ever typed in by the person.)
    func testAPathOrAFileAddressIsAFile() {
        XCTAssertEqual(url("/tmp/report.html"), "file:///tmp/report.html")
        XCTAssertEqual(url("/tmp/a b.html"), "file:///tmp/a%20b.html")
        XCTAssertEqual(url("~/x.html"), URL(fileURLWithPath: NSHomeDirectory() + "/x.html").absoluteString)
        XCTAssertEqual(url("file:///tmp/a%20b.html"), "file:///tmp/a%20b.html")
        XCTAssertNil(url("file:"))
        XCTAssertNil(url("ftp://example.com/x"), "still only pages and files")
    }

    func testOnlyAnHTMLFileIsAPage() {
        XCTAssertTrue(BrowserAddress.isPage(URL(fileURLWithPath: "/tmp/report.html")))
        XCTAssertTrue(BrowserAddress.isPage(URL(fileURLWithPath: "/tmp/INDEX.HTM")))
        XCTAssertFalse(BrowserAddress.isPage(URL(fileURLWithPath: "/tmp/notes.md")))
        XCTAssertFalse(BrowserAddress.isPage(URL(string: "http://localhost:3000/index.html")!), "a server's page is not a file")
    }

    /// Every file has no host and no port. Matched as servers are, opening
    /// one file would bring forward a tab on any other.
    func testATabOnAnotherFileIsNotTheTabForThisOne() {
        let a = URL(fileURLWithPath: "/tmp/wortel-a/index.html")
        let b = URL(fileURLWithPath: "/tmp/wortel-b/index.html")
        XCTAssertTrue(BrowserAddress.showsSame(a, as: URL(string: "file:///tmp/wortel-a/./index.html")!))
        XCTAssertFalse(BrowserAddress.showsSame(a, as: b))
        XCTAssertFalse(BrowserAddress.showsSame(a, as: URL(string: "http://localhost:3000")!))
        XCTAssertFalse(BrowserAddress.showsSame(URL(string: "http://localhost:3000")!, as: a))
        // A server is one place, whatever the path.
        XCTAssertTrue(BrowserAddress.showsSame(URL(string: "http://localhost:3000/docs")!,
                                               as: URL(string: "http://localhost:3000")!))
        XCTAssertFalse(BrowserAddress.showsSame(URL(string: "http://localhost:3000")!,
                                                as: URL(string: "http://localhost:3001")!))
    }

    /// What ends mark-up on a page. The addresses are what WebKit reported,
    /// measured 2026-11-26: a same-document change (a new fragment,
    /// `replaceState`, `pushState`) is heard only as a new `url`, never as
    /// a commit, so this is all there is to tell them by.
    func testOnlyAnotherDocumentOrRouteIsElsewhere() {
        let page = URL(string: "http://127.0.0.1:4321/docs/index.html")!
        func elsewhere(_ to: String, from: URL? = page) -> Bool {
            BrowserAddress.isElsewhere(URL(string: to)!, from: from)
        }
        // A heading written into the address as the page scrolls.
        XCTAssertFalse(elsewhere("http://127.0.0.1:4321/docs/index.html#install"))
        XCTAssertFalse(elsewhere("http://127.0.0.1:4321/docs/index.html",
                                 from: URL(string: "http://127.0.0.1:4321/docs/index.html#install")!))
        XCTAssertFalse(elsewhere("http://127.0.0.1:4321/docs/index.html#"))
        XCTAssertFalse(elsewhere(page.absoluteString))
        // A route in a single-page app, and a new query.
        XCTAssertTrue(elsewhere("http://127.0.0.1:4321/docs/other"))
        XCTAssertTrue(elsewhere("http://127.0.0.1:4321/docs/other#install"))
        XCTAssertTrue(elsewhere("http://127.0.0.1:4321/docs/index.html?page=2"))
        XCTAssertTrue(elsewhere("http://127.0.0.1:4322/docs/index.html"))
        XCTAssertTrue(elsewhere(page.absoluteString, from: nil))
        // A file's page, by its fragment too.
        let file = URL(fileURLWithPath: "/tmp/site/index.html")
        XCTAssertFalse(elsewhere("file:///tmp/site/index.html#b", from: file))
        XCTAssertTrue(elsewhere("file:///tmp/site/other.html", from: file))
    }

    /// A load the page makes by itself waits while the note holds it: a dev
    /// server's reload after an agent's edit dropped the note (2026-11-27).
    /// What the person does, and what can't be sent again, goes through.
    func testAPageLoadsByItselfOnlyOnceTheNoteLetsGo() {
        let page = URL(string: "http://localhost:5173/app?x=1")!
        func decide(_ to: String?, _ kind: BrowserAddress.LoadKind, holding: Bool = true, markingUp: Bool = true,
                    acted: Bool = false, mainFrame: Bool = true, method: String? = "GET",
                    current: URL? = page) -> BrowserAddress.PageLoad {
            BrowserAddress.pageLoad(holding: holding, markingUp: markingUp, personActed: acted,
                                    toMainFrame: mainFrame, kind: kind, method: method,
                                    url: to.flatMap(URL.init(string:)), current: current)
        }
        let same = page.absoluteString
        // `location.reload()`, `location.href = location.href`, a meta refresh.
        XCTAssertEqual(decide(same, .reload), .reloadLater)
        XCTAssertEqual(decide(same, .other), .reloadLater)
        XCTAssertEqual(decide(same + "#top", .reload), .reloadLater, "a reload with a fragment still loads")
        XCTAssertEqual(decide(same, .reload, markingUp: false), .reloadLater, "a note kept after Esc holds it too")
        XCTAssertEqual(decide(same, .reload, method: nil), .reloadLater)
        // Somewhere else the page sends itself: the edited page, a sign-in.
        XCTAssertEqual(decide("http://localhost:5173/login", .other),
                       .loadLater(URL(string: "http://localhost:5173/login")!))
        XCTAssertEqual(decide("http://localhost:5173/app?x=2", .other),
                       .loadLater(URL(string: "http://localhost:5173/app?x=2")!))
        // A script's click while marking up: the person's clicks are the layer's.
        XCTAssertEqual(decide("http://localhost:5173/next", .link),
                       .loadLater(URL(string: "http://localhost:5173/next")!))
        XCTAssertEqual(decide(same, .form), .reloadLater)
        // A script's `history.back()`: Wortel's Back lets go first, the swipe is off.
        XCTAssertEqual(decide("http://localhost:5173/", .backForward),
                       .loadLater(URL(string: "http://localhost:5173/")!))
        // A button's script, the person's click or not, while marking up.
        XCTAssertEqual(decide("http://localhost:5173/next", .other, acted: true),
                       .loadLater(URL(string: "http://localhost:5173/next")!))
        // After Esc, a dev server's reload with nobody at the page still waits.
        XCTAssertEqual(decide("http://localhost:5173/next", .other, markingUp: false),
                       .loadLater(URL(string: "http://localhost:5173/next")!))
        // Let through.
        XCTAssertEqual(decide(same, .reload, holding: false), .allow, "nothing to keep")
        XCTAssertEqual(decide(same, .reload, mainFrame: false), .allow, "a frame inside the page")
        XCTAssertEqual(decide("http://localhost:5173/", .backForward, markingUp: false), .allow)
        XCTAssertEqual(decide("http://localhost:5173/next", .link, markingUp: false), .allow,
                       "the person's click after Esc")
        XCTAssertEqual(decide(same, .form, markingUp: false), .allow)
        XCTAssertEqual(decide("http://localhost:5173/next", .other, markingUp: false, acted: true), .allow,
                       "a button's script after the person's click, after Esc")
        XCTAssertEqual(decide(same, .reload, markingUp: false, acted: true), .allow)
        XCTAssertEqual(decide(same, .other, method: "POST"), .allow, "sent twice if held")
        XCTAssertEqual(decide(same + "#install", .other), .allow, "a new fragment scrolls, no load")
        XCTAssertEqual(decide(same, .reload, current: nil), .allow, "nowhere yet")
        XCTAssertEqual(decide(nil, .reload), .allow)
    }

    /// Only files on this Mac are watched beside the page, each once.
    func testTheFilesAPageLoadedAreItsLocalOnes() {
        XCTAssertEqual(BrowserAddress.localFiles(in: [
            "file:///tmp/site/a%20b.css", "https://cdn.example/x.js", "", "file:///tmp/site/sub/../a%20b.css",
            "data:image/png;base64,AAAA", "file:///tmp/site/app.js",
        ]), ["/tmp/site/a b.css", "/tmp/site/app.js"])
    }

    /// ⌘E looks for the selection's first line: no page text matches a line break.
    func testASelectionToLookForIsItsFirstLine() {
        XCTAssertEqual(BrowserAddress.searchable("  needle  "), "needle")
        XCTAssertEqual(BrowserAddress.searchable("first line\nsecond"), "first line")
        XCTAssertEqual(BrowserAddress.searchable("\n\nafter blanks"), "after blanks")
        XCTAssertNil(BrowserAddress.searchable("   "))
        XCTAssertNil(BrowserAddress.searchable(nil))
    }
}

final class BrowserExternalLinkTests: XCTestCase {
    /// A page must never be held up by the app question, wherever it comes from.
    func testPagesAlwaysLoad() {
        for scheme in ["http", "https", "about", "file", nil] as [String?] {
            for from in [true, false] {
                for to in [true, false] {
                    XCTAssertEqual(BrowserExternalLink.decide(scheme: scheme, fromMainFrame: from, toMainFrame: to), .load)
                }
            }
        }
    }

    /// A page opening another app always asks, so a script-made click can't skip the question.
    func testThePageOpeningAnAppAsksFirst() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", fromMainFrame: true, toMainFrame: true), .ask)
    }

    /// An embedded frame with `target="_top"` must not pass for the page itself.
    func testAFrameTargetingThePageIsRefused() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", fromMainFrame: false, toMainFrame: true), .refuse)
    }

    /// The page can't hand another app's link to a frame inside it either.
    func testThePageTargetingAFrameIsRefused() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", fromMainFrame: true, toMainFrame: false), .refuse)
    }

    /// A frame inside the page never opens an app, even within itself.
    func testAFrameInsideItselfIsRefused() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", fromMainFrame: false, toMainFrame: false), .refuse)
    }

    /// Upper-casing a scheme must not slip past the check.
    func testTheSchemeIsCaseInsensitive() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "MAILTO", fromMainFrame: true, toMainFrame: true), .ask)
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "HTTPS", fromMainFrame: false, toMainFrame: false), .load)
    }
}

/// The name a download is saved under. Wrong, it replaces a file or hides one.
final class BrowserDownloadNameTests: XCTestCase {
    func testADownloadNameIsOneVisibleComponent() {
        XCTAssertEqual(BrowserDownloadName.cleaned("report.zip"), "report.zip")
        XCTAssertEqual(BrowserDownloadName.cleaned("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(BrowserDownloadName.cleaned(".zshrc"), "zshrc")
        XCTAssertEqual(BrowserDownloadName.cleaned("a:b"), "a_b")
        XCTAssertEqual(BrowserDownloadName.cleaned("  \u{0}  "), "download")
        XCTAssertEqual(BrowserDownloadName.cleaned(""), "download")
    }

    /// A name longer than the file system takes is cut in its stem, not its extension.
    func testALongDownloadNameKeepsItsExtension() {
        let name = BrowserDownloadName.cleaned(String(repeating: "é", count: 300) + ".tar")
        XCTAssertLessThanOrEqual(name.utf8.count, 240)
        XCTAssertTrue(name.hasSuffix(".tar"))
    }

    /// A download never replaces a file: it is numbered, as a copy in the Finder is.
    func testATakenDownloadNameIsNumbered() {
        let taken: Set<String> = ["report.zip", "report 2.zip", "notes"]
        XCTAssertEqual(BrowserDownloadName.free("new.zip", isTaken: taken.contains), "new.zip")
        XCTAssertEqual(BrowserDownloadName.free("report.zip", isTaken: taken.contains), "report 3.zip")
        XCTAssertEqual(BrowserDownloadName.free("notes", isTaken: taken.contains), "notes 2")
    }

    func testAnAttachmentIsSaved() {
        XCTAssertTrue(BrowserDownloadName.isAttachment(contentDisposition: "attachment; filename=\"a.pdf\""))
        XCTAssertTrue(BrowserDownloadName.isAttachment(contentDisposition: "Attachment"))
        XCTAssertFalse(BrowserDownloadName.isAttachment(contentDisposition: "inline; filename=\"attachment.pdf\""))
        XCTAssertFalse(BrowserDownloadName.isAttachment(contentDisposition: nil))
    }

    /// A frame from another site (an advertisement) can't put a file in Downloads.
    func testOnlyThePageAndItsOwnFramesSave() {
        func saves(main: Bool, canShow: Bool, attachment: Bool, host: String?, page: String?) -> Bool {
            BrowserDownloadName.saves(isForMainFrame: main, canShow: canShow, isAttachment: attachment,
                                      host: host, pageHost: page)
        }
        XCTAssertTrue(saves(main: true, canShow: false, attachment: false, host: "a.example", page: "b.example"))
        XCTAssertTrue(saves(main: true, canShow: true, attachment: true, host: "a.example", page: "a.example"))
        XCTAssertFalse(saves(main: true, canShow: true, attachment: false, host: "a.example", page: "a.example"))
        XCTAssertTrue(saves(main: false, canShow: true, attachment: true, host: "App.Example", page: "app.example"))
        XCTAssertFalse(saves(main: false, canShow: true, attachment: true, host: "ads.example", page: "app.example"))
        XCTAssertFalse(saves(main: false, canShow: false, attachment: false, host: "app.example", page: "app.example"))
        XCTAssertFalse(saves(main: false, canShow: true, attachment: true, host: nil, page: nil), "a blob in a frame")
    }

    /// A link that says it is for saving is held to the same rule, by the
    /// frame it is in: a frame from another site can click one from script.
    func testADownloadLinkSavesOnlyFromThePageAndItsOwnFrames() {
        func saves(main: Bool, frame: String?, page: String?) -> Bool {
            BrowserDownloadName.savesLink(fromMainFrame: main, frameHost: frame, pageHost: page)
        }
        XCTAssertTrue(saves(main: true, frame: nil, page: "app.example"))
        XCTAssertTrue(saves(main: true, frame: "app.example", page: nil), "a page with no host: a file")
        XCTAssertTrue(saves(main: false, frame: "App.Example", page: "app.example"))
        XCTAssertFalse(saves(main: false, frame: "ads.example", page: "app.example"))
        XCTAssertFalse(saves(main: false, frame: "cdn.app.example", page: "app.example"), "a subdomain is another host")
        XCTAssertFalse(saves(main: false, frame: "", page: ""), "a sandboxed frame has no host")
        XCTAssertFalse(saves(main: false, frame: nil, page: nil))
    }

    /// Open in Your Browser on a tab showing `run.command` handed it to
    /// NSWorkspace, which opened it in Terminal, which ran it. A file goes to
    /// the browser by name.
    func testOpenInYourBrowserNeverHandsAFileToItsOwnApp() {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let script = URL(fileURLWithPath: "/tmp/site/run.command")
        let page = URL(string: "https://example.com/docs")!
        func decide(_ url: URL, browser: URL? = safari, id: String? = "com.apple.Safari") -> BrowserOpenElsewhere {
            BrowserOpenElsewhere.decide(url, browser: browser, browserID: id, ownID: "sh.wortel.app")
        }
        XCTAssertEqual(decide(page), .open(page))
        XCTAssertEqual(decide(script), .openWith(script, app: safari))
        XCTAssertEqual(decide(script, browser: nil, id: nil), .showInFinder(script), "no browser to name")
        XCTAssertEqual(decide(script, browser: URL(fileURLWithPath: "/Applications/Wortel.app"), id: "sh.wortel.app"),
                       .showInFinder(script), "never Wortel itself")
        XCTAssertEqual(decide(URL(string: "about:blank")!), .nothing)
    }
}
