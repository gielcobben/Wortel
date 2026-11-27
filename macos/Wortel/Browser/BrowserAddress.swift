import Foundation

/// Addresses as a browser tab reads and writes them. Pure, so the rules for
/// what a typed address means have tests of their own (BrowserAddressTests).
enum BrowserAddress {
    /// `localhost:5173`, `localhost:5173/docs`, `wortel.sh`: what a tab and
    /// the address field call an address. The scheme is noise.
    static func short(_ url: URL) -> String {
        // A file by its name and the folder it is in: `proj/report.html`.
        // The whole path starts with the part every file shares, and in a
        // narrow field that was all there was room for. The field shows the
        // whole address when it has the keyboard, as for any page.
        if url.isFileURL {
            let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
            return parts.suffix(2).joined(separator: "/")
        }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        var text = host.contains(":") ? "[\(host)]" : host
        if let port = url.port { text += ":\(port)" }
        let path = url.path()
        if !path.isEmpty, path != "/" { text += path }
        if let query = url.query() { text += "?" + query }
        return text
    }

    /// What was typed, as somewhere to go, or nil when it isn't an address.
    /// A port alone is a local server (`3000`, `:3000`); a local name or a
    /// private network address without a scheme is http (dev servers don't
    /// do TLS), anything else https. Only http and https, and a file on this
    /// Mac: a `file:` address (what the field shows for a page opened from a
    /// file) or a path from `/` or `~`.
    static func url(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
        }
        if text.lowercased().hasPrefix("file:") {
            guard let url = URL(string: text), url.isFileURL, !url.path.isEmpty else { return nil }
            return url
        }
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if Int(text.dropFirst(text.hasPrefix(":") ? 1 : 0)) != nil {
            text = "localhost:" + text.drop { $0 == ":" }
        }
        if !text.contains("://") {
            // A bare IPv6 address (`::1`) needs its brackets to be a host.
            if !text.hasPrefix("["), !text.contains("/"), text.filter({ $0 == ":" }).count >= 2 {
                text = "[\(text)]"
            }
            text = (isLocalHost(host(of: text)) ? "http://" : "https://") + text
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return components.url
    }

    /// What the address field fills in as you type: the first address that
    /// starts with what's typed, in whichever form it was typed in (the whole
    /// URL, `localhost:4321`, or just `4321`). What you typed stays as typed;
    /// the rest is the completion, which the field selects so the next key
    /// replaces it. nil when nothing starts with it.
    static func completion(of typed: String, among urls: [URL]) -> (text: String, url: URL)? {
        let query = typed.lowercased()
        guard !query.isEmpty else { return nil }
        for url in urls {
            let forms = [url.absoluteString, short(url), url.port.map(String.init)].compactMap { $0 }
            for form in forms where form.lowercased().hasPrefix(query) && form.count > query.count {
                return (typed + form.dropFirst(typed.count), url)
            }
        }
        return nil
    }

    /// Whether `url` is a file a browser tab shows as a page: `.html` or
    /// `.htm` on this Mac. What `wortel open` and a ⌘-clicked path send to a
    /// browser tab, and what a tab offers Page · Source for.
    static func isPage(_ url: URL) -> Bool {
        url.isFileURL && ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Whether a tab at `open` is the one to bring forward for `wanted`. A
    /// server is one place whatever its path (a tab on `localhost:5173/docs`
    /// is the tab for `localhost:5173`). Files have no host and no port, so
    /// by that rule every file would be every other file: a file is itself.
    static func showsSame(_ open: URL, as wanted: URL) -> Bool {
        if open.isFileURL || wanted.isFileURL {
            guard open.isFileURL, wanted.isFileURL else { return false }
            return open.resolvingSymlinksInPath().standardizedFileURL.path
                == wanted.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return open.host() == wanted.host() && open.port == wanted.port
    }

    /// Whether a page whose address went from `old` to `new` is another
    /// page: another document, or another route in a single-page app. A
    /// change of the fragment alone is not, however the page made it: a
    /// docs site rewrites it as the page scrolls past its headings.
    static func isElsewhere(_ new: URL, from old: URL?) -> Bool {
        guard let old else { return true }
        return withoutFragment(new) != withoutFragment(old)
    }

    private static func withoutFragment(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    /// The local files in what a page says it loaded, as paths: what is
    /// watched beside the page's own file. Anything that isn't a `file:`
    /// address is somewhere a change on disk can't reach.
    static func localFiles(in addresses: [String]) -> [String] {
        var paths: [String] = []
        for address in addresses {
            guard let url = URL(string: address), url.isFileURL else { continue }
            let path = url.standardizedFileURL.path
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// A page's selection as something to look for (⌘E): its first line,
    /// trimmed. A selection across paragraphs has line breaks in it that no
    /// text in the page matches.
    static func searchable(_ selection: String?) -> String? {
        let line = selection?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The host of an address typed without a scheme.
    private static func host(of text: String) -> String {
        if text.hasPrefix("[") { return String(text.dropFirst().prefix { $0 != "]" }) }
        return text.split(whereSeparator: { ":/?#".contains($0) }).first.map(String.init) ?? text
    }

    /// This Mac or the network it's on: where dev servers are, served as http.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "::1", "0.0.0.0"].contains(host)
            || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31): return true
        default: return false
        }
    }
}

/// What a browser tab does with a navigation to something that isn't a page
/// (`mailto:`, `vscode://`): a scheme like that is a registered application,
/// and a page that could open one unasked could open any of them on load.
///
/// Always a question, clicked or not: a script calling `.click()` on a link
/// is a "link activated" to WebKit just as a real click is, so a click can't
/// be trusted to mean the user. And judged by the frame it came *from*: a
/// link in an embedded frame can target the page itself (`target="_top"`).
enum BrowserExternalLink: Equatable {
    /// A page: let the web view load it.
    case load
    /// Another app's link from the page itself: ask first.
    case ask
    /// Another app's link from a frame inside the page: never.
    case refuse

    static let pageSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file"]

    /// `fromMainFrame`: the navigation started in the page itself (or in the
    /// app, which has no frame). `toMainFrame`: it would replace the page, or
    /// open a new window (no target frame).
    static func decide(scheme: String?, fromMainFrame: Bool, toMainFrame: Bool) -> BrowserExternalLink {
        guard let scheme = scheme?.lowercased(), !pageSchemes.contains(scheme) else { return .load }
        return fromMainFrame && toMainFrame ? .ask : .refuse
    }
}

/// The name a download is saved under, in the Downloads folder.
///
/// WebKit has already made the server's name one path component (measured
/// 2026-11-25: `re:port/../x.zip` arrives as `re_port_.._x.zip`), so what is
/// left here is what a folder of your own wants: nothing hidden, nothing
/// empty, and never a file that was already there.
enum BrowserDownloadName {
    /// `suggested` as a file name: one component, not hidden, not empty, and
    /// short enough for the file system (255 bytes) with room for a number.
    static func cleaned(_ suggested: String) -> String {
        var name = String(String.UnicodeScalarView(suggested.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        name = name.trimmingCharacters(in: .whitespaces)
        // A leading dot would save it where the Finder doesn't show it.
        name = String(name.drop { $0 == "." })
        guard !name.isEmpty else { return "download" }
        let whole = name as NSString
        let ext = whole.pathExtension
        var stem = whole.deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        while (stem + suffix).utf8.count > 240, stem.count > 1 { stem.removeLast() }
        return stem + suffix
    }

    /// `name`, or `name 2`, `name 3`… before its extension: the first that
    /// isn't taken, numbered as the Finder numbers a copy. A download never
    /// replaces a file.
    static func free(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let whole = name as NSString
        let ext = whole.pathExtension
        let stem = whole.deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// Whether a response is saved to Downloads.
    ///
    /// The page itself (`isForMainFrame`): what the tab can't show, or what
    /// its server marked as an attachment. A frame inside the page: only an
    /// attachment, and only from the page's own host. A frame from somewhere
    /// else is usually an advertisement, and one of those answering with an
    /// attachment would put a file in Downloads that nobody clicked for. A
    /// site's own hidden frame is how many of them start a download, so that
    /// still works.
    static func saves(isForMainFrame: Bool, canShow: Bool, isAttachment: Bool,
                      host: String?, pageHost: String?) -> Bool {
        if isForMainFrame { return isAttachment || !canShow }
        return isAttachment && isPagesOwn(host, pageHost: pageHost)
    }

    /// Whether a link that says it is for saving (`<a download>`) is saved.
    ///
    /// By the rule a response is held to: from the page itself, or from a
    /// frame on the page's own host. What counts is the frame the link is
    /// in, not where the link points. A frame from another site can point a
    /// link at the page's own host as easily as at its own, and can click
    /// it from script with no person involved. A frame with no host of its
    /// own (a sandboxed one, a `data:` document) is nobody's.
    static func savesLink(fromMainFrame: Bool, frameHost: String?, pageHost: String?) -> Bool {
        fromMainFrame || isPagesOwn(frameHost, pageHost: pageHost)
    }

    /// The host must match exactly: a frame on `cdn.example.com` in a page
    /// on `example.com` saves nothing.
    private static func isPagesOwn(_ host: String?, pageHost: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return host == pageHost?.lowercased()
    }

    /// Whether a response is one to save, not show: the server said so.
    static func isAttachment(contentDisposition: String?) -> Bool {
        guard let value = contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return value == "attachment" || value.hasPrefix("attachment;")
    }
}
