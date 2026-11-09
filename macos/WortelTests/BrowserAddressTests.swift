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
        XCTAssertNil(url("file:///etc/passwd"))
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
}

final class BrowserExternalLinkTests: XCTestCase {
    func testPagesAlwaysLoad() {
        for scheme in ["http", "https", "about", "file", nil] as [String?] {
            for clicked in [true, false] {
                for main in [true, false] {
                    XCTAssertEqual(BrowserExternalLink.decide(scheme: scheme, clicked: clicked, inMainFrame: main), .load)
                }
            }
        }
    }

    func testAClickedLinkInThePageOpensItsApp() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", clicked: true, inMainFrame: true), .open)
    }

    func testThePageDoingItByItselfAsksFirst() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", clicked: false, inMainFrame: true), .ask)
    }

    func testAFrameInsideThePageNeverOpensAnApp() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", clicked: true, inMainFrame: false), .refuse)
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "vscode", clicked: false, inMainFrame: false), .refuse)
    }

    func testTheSchemeIsCaseInsensitive() {
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "MAILTO", clicked: true, inMainFrame: true), .open)
        XCTAssertEqual(BrowserExternalLink.decide(scheme: "HTTPS", clicked: false, inMainFrame: false), .load)
    }
}
