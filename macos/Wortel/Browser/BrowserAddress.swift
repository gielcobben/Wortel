import Foundation

/// Addresses as a browser tab reads and writes them. Pure, so the rules for
/// what a typed address means have tests of their own (BrowserAddressTests).
enum BrowserAddress {
    /// `localhost:5173`, `localhost:5173/docs`, `wortel.sh`: what a tab and
    /// the address field call an address. The scheme is noise.
    static func short(_ url: URL) -> String {
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
    /// do TLS), anything else https. Only http and https.
    static func url(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
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
